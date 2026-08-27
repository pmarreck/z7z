//! Codec dispatch: decompress packed data for a folder's coder pipeline.
//!
//! Wraps Zig stdlib decompressors (std.compress.lzma2, etc.)
//! to keep the archive module codec-agnostic.

const std = @import("std");
const meta = @import("metadata.zig");
const lzma2_enc = @import("lzma2_encoder.zig");
const aes = @import("aes_crypt.zig");
const ProgressContext = @import("progress.zig").ProgressContext;

pub const CodecError = error{
	UnsupportedMethod,
	DecompressFailed,
	OutOfMemory,
};

pub const SinkError = error{
	OutOfMemory,
	ResourceLimitExceeded,
	ChecksumError,
	StructuralError,
};

pub const StreamingError = CodecError || SinkError;

pub const OutputSink = struct {
	ptr: *anyopaque,
	writeFn: *const fn (*anyopaque, []const u8) SinkError!void,

	pub fn write(self: *OutputSink, data: []const u8) SinkError!void {
		try self.writeFn(self.ptr, data);
	}
};

/// Known method IDs.
const METHOD_COPY: u8 = 0x00;
const METHOD_LZMA2: u8 = 0x21;
const METHOD_LZMA: [3]u8 = .{ 0x03, 0x01, 0x01 };
const METHOD_BCJ_X86: [4]u8 = .{ 0x03, 0x03, 0x01, 0x03 };
const METHOD_BCJ2: [4]u8 = .{ 0x03, 0x03, 0x01, 0x1B };
const METHOD_7ZAES: [4]u8 = .{ 0x06, 0xF1, 0x07, 0x01 };
const METHOD_ZSTD: [4]u8 = .{ 0x04, 0xF7, 0x11, 0x01 };

/// Decompress packed data for a folder's coder pipeline.
/// Supports single-coder and multi-coder (filter + compressor, AES + compressor, BCJ2) folders.
/// pack_sizes: per-stream sizes within packed_data (needed for multi-stream codecs like BCJ2).
/// Pass password for encrypted archives, null otherwise.
/// Returns owned slice of decompressed bytes.
pub fn decompressFolder(
	folder: anytype,
	packed_data: []const u8,
	pack_sizes: []const u64,
	unpack_size: u64,
	password: ?[]const u8,
	allocator: std.mem.Allocator,
) CodecError![]u8 {
	if (folder.coders.len == 1) {
		const coder = folder.coders[0];
		// Single-coder 7zAES (encrypted header without compression)
		if (is7zAesMethod(coder.method_id)) {
			const pw = password orelse return CodecError.UnsupportedMethod;
			return aes.decrypt7zAes(packed_data, coder.properties, pw, unpack_size, allocator) catch
				return CodecError.DecompressFailed;
		}
		return decompressSingleCoder(coder, packed_data, unpack_size, allocator);
	} else if (folder.coders.len >= 2) {
		return decompressMultiCoderPipeline(folder, packed_data, pack_sizes, unpack_size, password, allocator);
	}
	return CodecError.UnsupportedMethod;
}

/// Decompress a folder directly into a sink for verification paths that do
/// not need retained output.
pub fn decompressFolderToSink(
	folder: anytype,
	packed_data: []const u8,
	pack_sizes: []const u64,
	unpack_size: u64,
	password: ?[]const u8,
	sink: *OutputSink,
	allocator: std.mem.Allocator,
) StreamingError!void {
	if (folder.coders.len == 0) return CodecError.UnsupportedMethod;
	if (folder.coders.len == 1) {
		const coder = folder.coders[0];
		if (is7zAesMethod(coder.method_id)) {
			const pw = password orelse return CodecError.UnsupportedMethod;
			const decrypted = aes.decrypt7zAes(packed_data, coder.properties, pw, unpack_size, allocator) catch
				return CodecError.DecompressFailed;
			defer allocator.free(decrypted);
			return sink.write(decrypted);
		}
		return decompressSingleCoderToSink(coder, packed_data, unpack_size, sink, allocator);
	}

	var aes_idx: ?usize = null;
	var compressor_idx: ?usize = null;
	var filter_idx: ?usize = null;
	var bcj2_idx: ?usize = null;
	for (folder.coders, 0..) |coder, i| {
		const mid = coder.method_id;
		if (is7zAesMethod(mid)) {
			aes_idx = i;
		} else if (isBcj2Method(mid)) {
			bcj2_idx = i;
		} else if (isCompressorMethod(mid)) {
			compressor_idx = i;
		} else if (isFilterMethod(mid)) {
			filter_idx = i;
		} else {
			return CodecError.UnsupportedMethod;
		}
	}
    if (bcj2_idx != null) {
        return decompressBcj2ToSink(folder, packed_data, pack_sizes, unpack_size, sink, allocator);
    }

	const comp_idx = compressor_idx orelse return CodecError.UnsupportedMethod;
	var current_data = packed_data;
	var decrypted_buf: ?[]u8 = null;
	defer if (decrypted_buf) |buf| allocator.free(buf);
	if (aes_idx) |ai| {
		const pw = password orelse return CodecError.UnsupportedMethod;
		const aes_unpack = if (ai < folder.unpack_sizes.len)
			folder.unpack_sizes[ai]
		else
			@as(u64, @intCast(packed_data.len));
		decrypted_buf = aes.decrypt7zAes(packed_data, folder.coders[ai].properties, pw, aes_unpack, allocator) catch
			return CodecError.DecompressFailed;
		current_data = decrypted_buf.?;
	}

	const comp_unpack = if (comp_idx < folder.unpack_sizes.len)
		folder.unpack_sizes[comp_idx]
	else
		unpack_size;
	if (filter_idx) |fi| {
		if (!isBcjX86Method(folder.coders[fi].method_id)) return CodecError.UnsupportedMethod;
		var filter = BcjX86Sink.init(sink);
		var filter_output = filter.outputSink();
		try decompressSingleCoderToSink(folder.coders[comp_idx], current_data, comp_unpack, &filter_output, allocator);
		return filter.finish();
	}
	return decompressSingleCoderToSink(folder.coders[comp_idx], current_data, comp_unpack, sink, allocator);
}

fn decompressSingleCoderToSink(
	coder: anytype,
	packed_data: []const u8,
	unpack_size: u64,
	sink: *OutputSink,
	allocator: std.mem.Allocator,
) StreamingError!void {
	const mid = coder.method_id;
	if (mid.len == 1 and mid[0] == METHOD_COPY) {
		if (@as(u64, @intCast(packed_data.len)) != unpack_size) return CodecError.DecompressFailed;
		return sink.write(packed_data);
	} else if (mid.len == 1 and mid[0] == METHOD_LZMA2) {
		return decodeLzma2ToSink(packed_data, unpack_size, coder.properties, sink, allocator);
	} else if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) {
		return decodeLzmaToSink(packed_data, unpack_size, coder.properties, sink, allocator);
	}
	return CodecError.UnsupportedMethod;
}

const BcjX86Sink = struct {
	const input_chunk_size = 4096;

	downstream: *OutputSink,
	pending: [4]u8 = undefined,
	pending_len: usize = 0,
	position: u32 = 0,
	state: u32 = 0,

	fn init(downstream: *OutputSink) BcjX86Sink {
		return .{ .downstream = downstream };
	}

	fn outputSink(self: *BcjX86Sink) OutputSink {
		return .{ .ptr = self, .writeFn = writeThunk };
	}

	fn writeThunk(ctx: *anyopaque, data: []const u8) SinkError!void {
		const self: *BcjX86Sink = @ptrCast(@alignCast(ctx));
		try self.write(data);
	}

	fn write(self: *BcjX86Sink, data: []const u8) SinkError!void {
		var offset: usize = 0;
		while (offset < data.len) {
			var scratch: [input_chunk_size + 4]u8 = undefined;
			@memcpy(scratch[0..self.pending_len], self.pending[0..self.pending_len]);

			const take = @min(input_chunk_size, data.len - offset);
			@memcpy(scratch[self.pending_len .. self.pending_len + take], data[offset .. offset + take]);
			const available = self.pending_len + take;
			const processed = bcjX86Convert(scratch[0..available], self.position, &self.state, false);
			if (processed > 0) {
				try self.downstream.write(scratch[0..processed]);
				self.position +%= @intCast(processed);
			}

			self.pending_len = available - processed;
			std.debug.assert(self.pending_len <= self.pending.len);
			@memcpy(self.pending[0..self.pending_len], scratch[processed..available]);
			offset += take;
		}
	}

	fn finish(self: *BcjX86Sink) SinkError!void {
		if (self.pending_len == 0) return;
		try self.downstream.write(self.pending[0..self.pending_len]);
		self.position +%= @intCast(self.pending_len);
		self.pending_len = 0;
	}
};

/// Decompress with a single coder (Copy, LZMA2, LZMA, or ZSTD).
fn decompressSingleCoder(coder: anytype, packed_data: []const u8, unpack_size: u64, allocator: std.mem.Allocator) CodecError![]u8 {
	const mid = coder.method_id;
	if (mid.len == 1 and mid[0] == METHOD_COPY) {
		return decodeCopy(packed_data, allocator);
	} else if (mid.len == 1 and mid[0] == METHOD_LZMA2) {
		return decodeLzma2(packed_data, unpack_size, allocator);
	} else if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) {
		return decodeLzma(packed_data, unpack_size, coder.properties, allocator);
	} else if (mid.len == 4 and std.mem.eql(u8, mid, &METHOD_ZSTD)) {
		return decodeZstd(packed_data, unpack_size, allocator);
	}
	return CodecError.UnsupportedMethod;
}

/// Decompress a multi-coder pipeline (e.g. BCJ+LZMA2, 7zAES+LZMA2, 7zAES+BCJ+LZMA2).
/// Processes coders in reverse order: decrypt → decompress → filter.
fn decompressMultiCoderPipeline(
	folder: anytype,
	packed_data: []const u8,
	pack_sizes: []const u64,
	unpack_size: u64,
	password: ?[]const u8,
	allocator: std.mem.Allocator,
) CodecError![]u8 {
	// Classify coders
	var aes_idx: ?usize = null;
	var compressor_idx: ?usize = null;
	var filter_idx: ?usize = null;
	var bcj2_idx: ?usize = null;

	for (folder.coders, 0..) |coder, i| {
		const mid = coder.method_id;
		if (is7zAesMethod(mid)) {
			aes_idx = i;
		} else if (isBcj2Method(mid)) {
			bcj2_idx = i;
		} else if (isCompressorMethod(mid)) {
			compressor_idx = i;
		} else if (isFilterMethod(mid)) {
			filter_idx = i;
		}
	}

	// BCJ2 pipeline: multi-stream DAG (separate code path)
	if (bcj2_idx != null) {
		return decompressBcj2Pipeline(folder, packed_data, pack_sizes, unpack_size, allocator);
	}

	const comp_idx = compressor_idx orelse return CodecError.UnsupportedMethod;
	var current_data: []const u8 = packed_data;
	var decrypted_buf: ?[]u8 = null;
	defer if (decrypted_buf) |b| allocator.free(b);

	// Step 1: If encrypted, decrypt first
	if (aes_idx) |ai| {
		const pw = password orelse return CodecError.UnsupportedMethod;
		const aes_coder = folder.coders[ai];
		// The AES coder's unpack_size tells us how many bytes of decrypted
		// output are real data (remainder is AES block padding).
		const aes_unpack: u64 = if (ai < folder.unpack_sizes.len)
			folder.unpack_sizes[ai]
		else
			packed_data.len; // fallback
		const dec = aes.decrypt7zAes(
			packed_data,
			aes_coder.properties,
			pw,
			aes_unpack,
			allocator,
		) catch return CodecError.DecompressFailed;
		decrypted_buf = dec;
		current_data = dec;
	}

	// Step 2: Decompress with the compressor
	// Use the compressor's own unpack_size from the folder, not the passed-in one
	// (which may be the last entry and could correspond to a different coder).
	const comp_unpack: u64 = if (comp_idx < folder.unpack_sizes.len)
		folder.unpack_sizes[comp_idx]
	else
		unpack_size;
	const decompressed = try decompressSingleCoder(folder.coders[comp_idx], current_data, comp_unpack, allocator);
	errdefer allocator.free(decompressed);

	// Step 3: Apply filter decode in-place (if present)
	if (filter_idx) |fi| {
		const filt_mid = folder.coders[fi].method_id;
		if (isBcjX86Method(filt_mid)) {
			bcjX86Decode(decompressed);
		}
	}

	return decompressed;
}

/// Decompress a BCJ2 multi-stream pipeline.
/// BCJ2 folders have N compressor coders feeding into 1 BCJ2 coder (4 in, 1 out).
/// Each pack stream is decompressed independently, then BCJ2 recombines 4 sub-streams.
fn decompressBcj2Pipeline(
	folder: anytype,
	packed_data: []const u8,
	pack_sizes: []const u64,
	unpack_size: u64,
	allocator: std.mem.Allocator,
) CodecError![]u8 {
	// Find the BCJ2 coder and compute its global input stream range
	var bcj2_coder_idx: ?usize = null;
	var bcj2_first_in: usize = 0;
	{
		var in_offset: usize = 0;
		for (folder.coders, 0..) |coder, i| {
			if (isBcj2Method(coder.method_id)) {
				bcj2_coder_idx = i;
				bcj2_first_in = in_offset;
			}
			in_offset += @intCast(coder.num_in_streams);
		}
	}
	const bcj2_idx = bcj2_coder_idx orelse return CodecError.UnsupportedMethod;
	_ = bcj2_idx;

	// BCJ2 has 4 inputs. For each, resolve: is it bound to a coder output, or a raw pack stream?
	// Decompressed sub-streams: [main, call, jump, rc]
	var sub_streams: [4]?[]u8 = .{ null, null, null, null };
	defer for (&sub_streams) |*s| if (s.*) |buf| allocator.free(buf);

	// Split packed_data into per-stream slices using pack_sizes
	// Build pack stream offset table
	const max_pack = 16;
	var pack_offsets: [max_pack]usize = undefined;
	var pack_off: usize = 0;
	for (0..@min(pack_sizes.len, max_pack)) |i| {
		pack_offsets[i] = pack_off;
		pack_off += @intCast(pack_sizes[i]);
	}

	// For each of BCJ2's 4 inputs, resolve the data source
	for (0..4) |bcj2_in_local| {
		const bcj2_global_in: usize = bcj2_first_in + bcj2_in_local;

		// Check if this input is bound to another coder's output
		var source_coder_out: ?usize = null;
		for (folder.bind_pairs) |bp| {
			if (bp.in_index == bcj2_global_in) {
				source_coder_out = @intCast(bp.out_index);
				break;
			}
		}

		if (source_coder_out) |src_out| {
			// Find which coder produces this output stream, and which pack stream feeds it
			var out_offset: usize = 0;
			var src_coder_idx: ?usize = null;
			for (folder.coders, 0..) |coder, ci| {
				if (src_out >= out_offset and src_out < out_offset + @as(usize, @intCast(coder.num_out_streams))) {
					src_coder_idx = ci;
					break;
				}
				out_offset += @intCast(coder.num_out_streams);
			}
			const sci = src_coder_idx orelse {
				return CodecError.DecompressFailed;
			};

			// Find which pack stream feeds this coder's input
			// The coder's global input is computed by summing in_streams of coders before it
			var coder_global_in: usize = 0;
			for (0..sci) |ci| {
				coder_global_in += @intCast(folder.coders[ci].num_in_streams);
			}

			// Find this input's pack stream index (which unbound input is it?)
			const pack_idx = findPackStreamIndex(folder, coder_global_in, pack_sizes.len) orelse {
				return CodecError.DecompressFailed;
			};
			if (pack_idx >= pack_sizes.len) return CodecError.DecompressFailed;

			const ps_off = pack_offsets[pack_idx];
			const ps_size: usize = @intCast(pack_sizes[pack_idx]);
			if (ps_off + ps_size > packed_data.len) return CodecError.DecompressFailed;
			const stream_packed = packed_data[ps_off .. ps_off + ps_size];

			// Get unpack size for this coder from folder.unpack_sizes
			const coder_unpack: u64 = if (sci < folder.unpack_sizes.len)
				folder.unpack_sizes[sci]
			else
				0;

			// Decompress this coder
			sub_streams[bcj2_in_local] = decompressSingleCoder(
				folder.coders[sci],
				stream_packed,
				coder_unpack,
				allocator,
			) catch |e| {
				return e;
			};
		} else {
			// Unbound input — raw pack stream (typically the RC stream)
			const pack_idx = findPackStreamIndex(folder, bcj2_global_in, pack_sizes.len) orelse {
				return CodecError.DecompressFailed;
			};
			if (pack_idx >= pack_sizes.len) return CodecError.DecompressFailed;

			const ps_off = pack_offsets[pack_idx];
			const ps_size: usize = @intCast(pack_sizes[pack_idx]);
			if (ps_off + ps_size > packed_data.len) return CodecError.DecompressFailed;

			// Copy raw data as the sub-stream
			sub_streams[bcj2_in_local] = allocator.dupe(u8, packed_data[ps_off .. ps_off + ps_size]) catch
				return CodecError.OutOfMemory;
		}
	}

	// All 4 sub-streams resolved; run BCJ2 decode
	const main_data = sub_streams[0] orelse return CodecError.DecompressFailed;
	const call_data = sub_streams[1] orelse return CodecError.DecompressFailed;
	const jump_data = sub_streams[2] orelse return CodecError.DecompressFailed;
	const rc_data = sub_streams[3] orelse return CodecError.DecompressFailed;

	const out_buf = allocator.alloc(u8, @intCast(unpack_size)) catch return CodecError.OutOfMemory;
	errdefer allocator.free(out_buf);

	const n = bcj2Decode(main_data, call_data, jump_data, rc_data, out_buf) catch |e| {
		return e;
	};

	if (n != @as(usize, @intCast(unpack_size))) {
		// errdefer frees `out_buf`; do not free explicitly (would double-free).
		return CodecError.DecompressFailed;
	}

	return out_buf;
}

const PullError = StreamingError || error{EndOfStream};

const PullCollector = struct {
    buffer: []u8,
    len: usize = 0,
    read_pos: usize = 0,

    fn outputSink(self: *PullCollector) OutputSink {
        return .{ .ptr = self, .writeFn = writeThunk };
    }

    fn writeThunk(ctx: *anyopaque, data: []const u8) SinkError!void {
        const self: *PullCollector = @ptrCast(@alignCast(ctx));
        if (data.len > self.buffer.len - self.len) return SinkError.StructuralError;
        @memcpy(self.buffer[self.len .. self.len + data.len], data);
        self.len += data.len;
    }

    fn reset(self: *PullCollector) void {
        self.len = 0;
        self.read_pos = 0;
    }

    fn readByte(self: *PullCollector) ?u8 {
        if (self.read_pos == self.len) return null;
        const byte = self.buffer[self.read_pos];
        self.read_pos += 1;
        return byte;
    }
};

const Lzma2Pull = struct {
    const max_chunk_output = 2 * 1024 * 1024;

    reader: std.Io.Reader,
    fake_allocating: std.Io.Writer.Allocating,
    collector: PullCollector,
    collector_sink: OutputSink,
    accum: StreamingLzBuffer,
    decoder: std.compress.lzma.Decode,
    window: []u8,
    n_read: u64 = 0,
    packed_size: usize,
    expected_size: u64,
    done: bool = false,

    fn create(
        packed_data: []const u8,
        unpack_size: u64,
        properties: []const u8,
        allocator: std.mem.Allocator,
    ) StreamingError!*Lzma2Pull {
        const dict_size = try lzma2DictSize(properties, unpack_size);
        const self = allocator.create(Lzma2Pull) catch return CodecError.OutOfMemory;
        errdefer allocator.destroy(self);
        const window = allocator.alloc(u8, dict_size) catch return CodecError.OutOfMemory;
        errdefer allocator.free(window);
        const output_capacity: usize = @intCast(@max(
            @as(u64, 1),
            @min(unpack_size, max_chunk_output),
        ));
        const output = allocator.alloc(u8, output_capacity) catch return CodecError.OutOfMemory;
        errdefer allocator.free(output);
        const decoder = std.compress.lzma.Decode.init(allocator, .{ .lc = 0, .lp = 0, .pb = 0 }) catch
            return CodecError.OutOfMemory;
        errdefer {
            var owned_decoder = decoder;
            owned_decoder.deinit(allocator);
        }

        self.reader = .fixed(packed_data);
        self.fake_allocating = .{
            .allocator = allocator,
            .writer = std.Io.Writer.failing,
            .alignment = .of(u8),
        };
        self.collector = .{ .buffer = output };
        self.collector_sink = self.collector.outputSink();
        self.accum = StreamingLzBuffer.init(window, &self.collector_sink);
        self.decoder = decoder;
        self.window = window;
        self.n_read = 0;
        self.packed_size = packed_data.len;
        self.expected_size = unpack_size;
        self.done = false;
        return self;
    }

    fn deinit(self: *Lzma2Pull, allocator: std.mem.Allocator) void {
        self.decoder.deinit(allocator);
        allocator.free(self.collector.buffer);
        allocator.free(self.window);
        allocator.destroy(self);
    }

    fn readByte(self: *Lzma2Pull) PullError!u8 {
        if (self.collector.readByte()) |byte| return byte;
        try self.refill();
        return self.collector.readByte() orelse error.EndOfStream;
    }

    fn refill(self: *Lzma2Pull) PullError!void {
        self.collector.reset();
        while (self.collector.len == 0) {
            if (self.done) return error.EndOfStream;
            const status = self.reader.takeByte() catch return CodecError.DecompressFailed;
            self.n_read += 1;
            switch (status) {
                0 => {
                    self.accum.flush() catch |e| return mapStreamingLzma2Error(e);
                    if (self.n_read != self.packed_size or self.accum.total_len != self.expected_size) {
                        return CodecError.DecompressFailed;
                    }
                    self.done = true;
                    if (self.collector.len == 0) return error.EndOfStream;
                },
                1 => self.n_read += parseLzma2Uncompressed(&self.reader, &self.accum, true) catch |e|
                    return mapStreamingLzma2Error(e),
                2 => self.n_read += parseLzma2Uncompressed(&self.reader, &self.accum, false) catch |e|
                    return mapStreamingLzma2Error(e),
                else => self.n_read += parseLzma2Compressed(
                    &self.decoder,
                    &self.reader,
                    &self.fake_allocating,
                    &self.accum,
                    status,
                ) catch |e| return mapStreamingLzma2Error(e),
            }
            self.accum.flush() catch |e| return mapStreamingLzma2Error(e);
            if (self.accum.total_len > self.expected_size) return CodecError.DecompressFailed;
        }
    }
};

const LzmaPull = struct {
    const step_output_capacity = 4096;

    reader: std.Io.Reader,
    fake_allocating: std.Io.Writer.Allocating,
    collector: PullCollector,
    collector_sink: OutputSink,
    accum: StreamingLzBuffer,
    decoder: std.compress.lzma.Decode,
    range_decoder: std.compress.lzma.RangeDecoder,
    window: []u8,
    n_read: u64 = 0,
    expected_size: u64,
    done: bool = false,

    fn create(
        packed_data: []const u8,
        unpack_size: u64,
        properties: []const u8,
        allocator: std.mem.Allocator,
    ) StreamingError!*LzmaPull {
        if (properties.len < 5 or unpack_size > std.math.maxInt(usize)) return CodecError.DecompressFailed;
        const props_byte = properties[0];
        if (props_byte >= 225) return CodecError.DecompressFailed;
        const lc: u4 = @intCast(props_byte % 9);
        const lp_pb = props_byte / 9;
        const lp: u3 = @intCast(lp_pb % 5);
        const pb: u3 = @intCast(lp_pb / 5);
        if (@as(u8, lc) + @as(u8, lp) > 4) return CodecError.DecompressFailed;

        const declared_dict_size = std.mem.readInt(u32, properties[1..5], .little);
        const dict_size: usize = @intCast(@max(
            @as(u64, 1),
            @min(@as(u64, declared_dict_size), unpack_size),
        ));
        const self = allocator.create(LzmaPull) catch return CodecError.OutOfMemory;
        errdefer allocator.destroy(self);
        const window = allocator.alloc(u8, dict_size) catch return CodecError.OutOfMemory;
        errdefer allocator.free(window);
        const output = allocator.alloc(u8, step_output_capacity) catch return CodecError.OutOfMemory;
        errdefer allocator.free(output);
        const decoder = std.compress.lzma.Decode.init(allocator, .{ .lc = lc, .lp = lp, .pb = pb }) catch
            return CodecError.OutOfMemory;
        errdefer {
            var owned_decoder = decoder;
            owned_decoder.deinit(allocator);
        }

        self.reader = .fixed(packed_data);
        self.fake_allocating = .{
            .allocator = allocator,
            .writer = std.Io.Writer.failing,
            .alignment = .of(u8),
        };
        self.collector = .{ .buffer = output };
        self.collector_sink = self.collector.outputSink();
        self.accum = StreamingLzBuffer.init(window, &self.collector_sink);
        self.decoder = decoder;
        self.window = window;
        self.n_read = 0;
        self.expected_size = unpack_size;
        self.done = false;
        self.range_decoder = std.compress.lzma.RangeDecoder.initCounting(&self.reader, &self.n_read) catch
            return CodecError.DecompressFailed;
        return self;
    }

    fn deinit(self: *LzmaPull, allocator: std.mem.Allocator) void {
        self.decoder.deinit(allocator);
        allocator.free(self.collector.buffer);
        allocator.free(self.window);
        allocator.destroy(self);
    }

    fn readByte(self: *LzmaPull) PullError!u8 {
        if (self.collector.readByte()) |byte| return byte;
        try self.refill();
        return self.collector.readByte() orelse error.EndOfStream;
    }

    fn refill(self: *LzmaPull) PullError!void {
        self.collector.reset();
        while (self.collector.len == 0) {
            if (self.done) return error.EndOfStream;
            if (self.accum.total_len == self.expected_size) {
                self.done = true;
                return error.EndOfStream;
            }
            const status = self.decoder.process(
                &self.reader,
                &self.fake_allocating,
                &self.accum,
                &self.range_decoder,
                &self.n_read,
            ) catch |e| return mapStreamingLzma2Error(e);
            self.accum.flush() catch |e| return mapStreamingLzma2Error(e);
            if (self.accum.total_len > self.expected_size or status == .finished) {
                if (self.accum.total_len != self.expected_size) return CodecError.DecompressFailed;
                self.done = true;
            }
        }
    }
};

const Bcj2PullInput = union(enum) {
    direct: struct { data: []const u8, pos: usize = 0 },
    lzma2: *Lzma2Pull,
    lzma: *LzmaPull,

    fn deinit(self: *Bcj2PullInput, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .direct => {},
            .lzma2 => |decoder| decoder.deinit(allocator),
            .lzma => |decoder| decoder.deinit(allocator),
        }
    }

    fn readByte(self: *Bcj2PullInput) PullError!u8 {
        return switch (self.*) {
            .direct => |*stream| blk: {
                if (stream.pos == stream.data.len) return error.EndOfStream;
                const byte = stream.data[stream.pos];
                stream.pos += 1;
                break :blk byte;
            },
            .lzma2 => |decoder| decoder.readByte(),
            .lzma => |decoder| decoder.readByte(),
        };
    }

    fn readBe32(self: *Bcj2PullInput) PullError!u32 {
        var bytes: [4]u8 = undefined;
        for (&bytes) |*byte| byte.* = try self.readByte();
        return std.mem.readInt(u32, &bytes, .big);
    }
};

const Bcj2SinkOutput = struct {
    const capacity = 16 * 1024;

    downstream: *OutputSink,
    expected_size: u64,
    total: u64 = 0,
    buffer: [capacity]u8 = undefined,
    len: usize = 0,

    fn writeByte(self: *Bcj2SinkOutput, byte: u8) StreamingError!void {
        if (self.total >= self.expected_size) return CodecError.DecompressFailed;
        if (self.len == self.buffer.len) try self.flush();
        self.buffer[self.len] = byte;
        self.len += 1;
        self.total += 1;
    }

    fn writeLe32(self: *Bcj2SinkOutput, value: u32) StreamingError!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        for (bytes) |byte| try self.writeByte(byte);
    }

    fn flush(self: *Bcj2SinkOutput) StreamingError!void {
        if (self.len == 0) return;
        try self.downstream.write(self.buffer[0..self.len]);
        self.len = 0;
    }
};

fn initBcj2PullInput(
    coder: anytype,
    packed_data: []const u8,
    unpack_size: u64,
    allocator: std.mem.Allocator,
) StreamingError!Bcj2PullInput {
    const mid = coder.method_id;
    if (mid.len == 1 and mid[0] == METHOD_COPY) {
        if (@as(u64, @intCast(packed_data.len)) != unpack_size) return CodecError.DecompressFailed;
        return .{ .direct = .{ .data = packed_data } };
    }
    if (mid.len == 1 and mid[0] == METHOD_LZMA2) {
        return .{ .lzma2 = try Lzma2Pull.create(packed_data, unpack_size, coder.properties, allocator) };
    }
    if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) {
        return .{ .lzma = try LzmaPull.create(packed_data, unpack_size, coder.properties, allocator) };
    }
    return CodecError.UnsupportedMethod;
}

fn mapPullError(err: PullError) StreamingError {
    return switch (err) {
        error.EndOfStream => CodecError.DecompressFailed,
        error.UnsupportedMethod => CodecError.UnsupportedMethod,
        error.DecompressFailed => CodecError.DecompressFailed,
        error.OutOfMemory => CodecError.OutOfMemory,
        error.ResourceLimitExceeded => SinkError.ResourceLimitExceeded,
        error.ChecksumError => SinkError.ChecksumError,
        error.StructuralError => SinkError.StructuralError,
    };
}

fn bcj2RangeDecodePull(
    prob: *u16,
    range: *u32,
    code: *u32,
    rc_stream: *Bcj2PullInput,
) PullError!u1 {
    const bound: u32 = (range.* >> 11) *% @as(u32, prob.*);
    if (code.* < bound) {
        range.* = bound;
        prob.* +%= @intCast((@as(u32, BCJ2_BIT_MODEL_TOTAL) - prob.*) >> BCJ2_NUM_MOVE_BITS);
        if (range.* < BCJ2_TOP) {
            range.* <<= 8;
            code.* = (code.* << 8) | try rc_stream.readByte();
        }
        return 0;
    }

    range.* -= bound;
    code.* -= bound;
    prob.* -= @intCast(prob.* >> BCJ2_NUM_MOVE_BITS);
    if (range.* < BCJ2_TOP) {
        range.* <<= 8;
        code.* = (code.* << 8) | try rc_stream.readByte();
    }
    return 1;
}

fn decompressBcj2ToSink(
    folder: anytype,
    packed_data: []const u8,
    pack_sizes: []const u64,
    unpack_size: u64,
    sink: *OutputSink,
    allocator: std.mem.Allocator,
) StreamingError!void {
    var bcj2_first_in: usize = 0;
    var found_bcj2 = false;
    var in_offset: usize = 0;
    for (folder.coders) |coder| {
        if (isBcj2Method(coder.method_id)) {
            bcj2_first_in = in_offset;
            found_bcj2 = true;
        }
        in_offset += @intCast(coder.num_in_streams);
    }
    if (!found_bcj2) return CodecError.UnsupportedMethod;

    const pack_offsets = allocator.alloc(usize, pack_sizes.len) catch return CodecError.OutOfMemory;
    defer allocator.free(pack_offsets);
    var pack_off: usize = 0;
    for (pack_sizes, 0..) |pack_size, i| {
        pack_offsets[i] = pack_off;
        pack_off = std.math.add(usize, pack_off, @intCast(pack_size)) catch return CodecError.DecompressFailed;
    }
    if (pack_off != packed_data.len) return CodecError.DecompressFailed;

    var inputs: [4]?Bcj2PullInput = .{ null, null, null, null };
    defer for (&inputs) |*maybe_input| {
        if (maybe_input.*) |*input| input.deinit(allocator);
    };

    for (0..4) |local_in| {
        const global_in = bcj2_first_in + local_in;
        var source_out: ?usize = null;
        for (folder.bind_pairs) |bind_pair| {
            if (bind_pair.in_index == global_in) {
                source_out = @intCast(bind_pair.out_index);
                break;
            }
        }

        if (source_out) |output_index| {
            var output_offset: usize = 0;
            var source_coder_idx: ?usize = null;
            for (folder.coders, 0..) |coder, coder_idx| {
                const output_count: usize = @intCast(coder.num_out_streams);
                if (output_index >= output_offset and output_index < output_offset + output_count) {
                    source_coder_idx = coder_idx;
                    break;
                }
                output_offset += output_count;
            }
            const coder_idx = source_coder_idx orelse return CodecError.DecompressFailed;
            const coder = folder.coders[coder_idx];
            if (coder.num_in_streams != 1 or coder.num_out_streams != 1) return CodecError.UnsupportedMethod;

            var coder_global_in: usize = 0;
            for (0..coder_idx) |i| coder_global_in += @intCast(folder.coders[i].num_in_streams);
            const pack_idx = findPackStreamIndex(folder, coder_global_in, pack_sizes.len) orelse
                return CodecError.DecompressFailed;
            if (pack_idx >= pack_sizes.len) return CodecError.DecompressFailed;
            const start = pack_offsets[pack_idx];
            const size: usize = @intCast(pack_sizes[pack_idx]);
            const coder_unpack = if (coder_idx < folder.unpack_sizes.len) folder.unpack_sizes[coder_idx] else 0;
            inputs[local_in] = try initBcj2PullInput(coder, packed_data[start .. start + size], coder_unpack, allocator);
        } else {
            const pack_idx = findPackStreamIndex(folder, global_in, pack_sizes.len) orelse
                return CodecError.DecompressFailed;
            if (pack_idx >= pack_sizes.len) return CodecError.DecompressFailed;
            const start = pack_offsets[pack_idx];
            const size: usize = @intCast(pack_sizes[pack_idx]);
            inputs[local_in] = .{ .direct = .{ .data = packed_data[start .. start + size] } };
        }
    }

    var probs: [BCJ2_NUM_PROBS]u16 = @splat(BCJ2_BIT_MODEL_TOTAL / 2);
    var range: u32 = 0xFFFF_FFFF;
    var code: u32 = 0;
    _ = inputs[3].?.readByte() catch |e| return mapPullError(e);
    for (0..4) |_| code = (code << 8) | (inputs[3].?.readByte() catch |e| return mapPullError(e));

    var output = Bcj2SinkOutput{ .downstream = sink, .expected_size = unpack_size };
    var prev_byte: u8 = 0;
    while (true) {
        const byte = inputs[0].?.readByte() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return mapPullError(e),
        };
        try output.writeByte(byte);

        var prob_idx: ?usize = null;
        var use_call_stream = false;
        if (byte == 0xE8) {
            prob_idx = prev_byte;
            use_call_stream = true;
        } else if (byte == 0xE9) {
            prob_idx = 256;
        } else if (byte >= 0x80 and byte <= 0x8F and prev_byte == 0x0F) {
            prob_idx = 257;
        }

        if (prob_idx) |idx| {
            const bit = bcj2RangeDecodePull(&probs[idx], &range, &code, &inputs[3].?) catch |e|
                return mapPullError(e);
            if (bit == 1) {
                const address = if (use_call_stream)
                    inputs[1].?.readBe32() catch |e| return mapPullError(e)
                else
                    inputs[2].?.readBe32() catch |e| return mapPullError(e);
                const relative = address -% @as(u32, @intCast(output.total + 4));
                try output.writeLe32(relative);
                prev_byte = @truncate(relative >> 24);
                continue;
            }
        }
        prev_byte = byte;
    }

    try output.flush();
    if (output.total != unpack_size) return CodecError.DecompressFailed;
}

/// Find the pack stream index for a given global input stream.
/// Pack streams are inputs not consumed by any bind pair. Returns their ordinal index
/// among all unbound inputs, which maps to pack_sizes[].
fn findPackStreamIndex(folder: anytype, global_in: usize, max_pack: usize) ?usize {
	_ = max_pack;
	// If folder has explicit packed_indices, use them
	if (folder.packed_indices.len > 0) {
		for (folder.packed_indices, 0..) |pi, idx| {
			if (pi == global_in) return idx;
		}
		return null;
	}
	// Otherwise, enumerate unbound inputs in order
	var total_in: usize = 0;
	for (folder.coders) |coder| {
		total_in += @intCast(coder.num_in_streams);
	}
	var pack_idx: usize = 0;
	for (0..total_in) |gin| {
		var is_bound = false;
		for (folder.bind_pairs) |bp| {
			if (bp.in_index == gin) {
				is_bound = true;
				break;
			}
		}
		if (!is_bound) {
			if (gin == global_in) return pack_idx;
			pack_idx += 1;
		}
	}
	return null;
}

fn isCompressorMethod(mid: []const u8) bool {
	if (mid.len == 1 and mid[0] == METHOD_LZMA2) return true;
	if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) return true;
	if (mid.len == 1 and mid[0] == METHOD_COPY) return true;
	if (mid.len == 4 and std.mem.eql(u8, mid, &METHOD_ZSTD)) return true;
	return false;
}

fn isFilterMethod(mid: []const u8) bool {
	return isBcjX86Method(mid);
}

fn isBcj2Method(mid: []const u8) bool {
	return mid.len == 4 and std.mem.eql(u8, mid, &METHOD_BCJ2);
}

fn isBcjX86Method(mid: []const u8) bool {
	return mid.len == 4 and std.mem.eql(u8, mid, &METHOD_BCJ_X86);
}

fn is7zAesMethod(mid: []const u8) bool {
	return mid.len == 4 and std.mem.eql(u8, mid, &METHOD_7ZAES);
}

fn decodeCopy(data: []const u8, allocator: std.mem.Allocator) CodecError![]u8 {
	return allocator.dupe(u8, data) catch return CodecError.OutOfMemory;
}

fn decodeLzma(packed_data: []const u8, unpack_size: u64, properties: []const u8, allocator: std.mem.Allocator) CodecError![]u8 {
	// LZMA properties in 7z: 5 bytes (1 byte lc/lp/pb + 4 bytes dict_size)
	// The stdlib LZMA decoder reads these from the stream header.
	// We prepend the properties + the unpack size to form a valid LZMA stream header.
	if (properties.len < 5) return CodecError.DecompressFailed;

	// Build a synthetic LZMA stream: properties(5) + unpack_size(8, LE) + packed_data
	const header_len = 5 + 8;
	const synth_len = header_len + packed_data.len;
	const synth = allocator.alloc(u8, synth_len) catch return CodecError.OutOfMemory;
	defer allocator.free(synth);

	// Copy properties (lc/lp/pb byte + 4 bytes dict_size)
	@memcpy(synth[0..5], properties[0..5]);

	// Workaround for Zig stdlib LZMA dictionary wrap bug:
	// std.compress.lzma fails with CorruptInput when output exceeds dict_size.
	// Override dict_size to be at least unpack_size so the circular buffer never wraps.
	const orig_dict_size = std.mem.readInt(u32, properties[1..5], .little);
	const safe_dict_size: u32 = @intCast(@min(
		@max(@as(u64, orig_dict_size), unpack_size),
		std.math.maxInt(u32),
	));
	std.mem.writeInt(u32, synth[1..5], safe_dict_size, .little);

	// Write unpack size as 8-byte LE
	std.mem.writeInt(u64, synth[5..13], unpack_size, .little);
	// Copy packed data
	@memcpy(synth[header_len..], packed_data);

	// Zig 0.16: std.compress.lzma.decompress is gone. Use the low-level
	// Decode primitives directly. Parse the 13-byte stream header we just
	// constructed (props + dict_size + unpack_size), then drive the decoder
	// against a fixed Reader until expected_size bytes have been produced.
	var in: std.Io.Reader = .fixed(synth);

	// Properties byte
	const props_byte = in.takeByte() catch return CodecError.DecompressFailed;
	if (props_byte >= 225) return CodecError.DecompressFailed;
	const lc: u4 = @intCast(props_byte % 9);
	const lp_pb = props_byte / 9;
	const lp: u3 = @intCast(lp_pb % 5);
	const pb: u3 = @intCast(lp_pb / 5);
	if (@as(u8, lc) + @as(u8, lp) > 4) return CodecError.DecompressFailed;

	// Skip dict size (already factored into safe_dict_size local) and unpack size
	_ = in.takeInt(u32, .little) catch return CodecError.DecompressFailed;
	_ = in.takeInt(u64, .little) catch return CodecError.DecompressFailed;

	var allocating: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, @intCast(unpack_size)) catch
		return CodecError.OutOfMemory;
	errdefer allocating.deinit();

	var dec: std.compress.lzma.Decode = std.compress.lzma.Decode.init(allocator, .{ .lc = lc, .lp = lp, .pb = pb }) catch
		return CodecError.OutOfMemory;
	defer dec.deinit(allocator);

	const mem_limit = std.math.maxInt(usize);
	var buffer = std.compress.lzma.Decode.CircularBuffer.init(@as(usize, safe_dict_size), mem_limit);
	defer buffer.deinit(allocator);

	var n_read: u64 = 0;
	var range_decoder = std.compress.lzma.RangeDecoder.initCounting(&in, &n_read) catch
		return CodecError.DecompressFailed;

	while (buffer.len < @as(usize, @intCast(unpack_size))) {
		const status = dec.process(&in, &allocating, &buffer, &range_decoder, &n_read) catch
			return CodecError.DecompressFailed;
		if (status == .finished) break;
	}

	buffer.finish(&allocating.writer) catch return CodecError.DecompressFailed;

	if (allocating.written().len != @as(usize, @intCast(unpack_size))) {
		return CodecError.DecompressFailed;
	}

	return allocating.toOwnedSlice() catch return CodecError.OutOfMemory;
}

fn decodeLzma2(packed_data: []const u8, unpack_size: u64, allocator: std.mem.Allocator) CodecError![]u8 {
	// Zig 0.16: std.compress.lzma2.decompress is now a method on Decode,
	// taking a *Reader + *Writer.Allocating.
	var in: std.Io.Reader = .fixed(packed_data);
	var allocating: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, @intCast(unpack_size)) catch
		return CodecError.OutOfMemory;
	errdefer allocating.deinit();

	var dec = std.compress.lzma2.Decode.init(allocator) catch return CodecError.OutOfMemory;
	defer dec.deinit(allocator);

	_ = dec.decompress(&in, &allocating) catch {
		return CodecError.DecompressFailed;
	};

	const written = allocating.written();
	if (written.len != @as(usize, @intCast(unpack_size))) {
		return CodecError.DecompressFailed;
	}

	return allocating.toOwnedSlice() catch return CodecError.OutOfMemory;
}

fn lzma2DictSize(properties: []const u8, unpack_size: u64) CodecError!usize {
	if (unpack_size == 0) return 1;
	if (properties.len == 0) return @intCast(@min(unpack_size, @as(u64, 1 << 23)));
	if (properties.len != 1) return CodecError.DecompressFailed;
	const p = properties[0];
	if (p > 40) return CodecError.DecompressFailed;
	const raw = (@as(u64, 2 | (p & 1)) << @intCast(p / 2 + 11));
	return @intCast(@max(@as(u64, 1), @min(raw, unpack_size)));
}

const StreamingLzBuffer = struct {
	const output_buffer_size = 16 * 1024;

	window: []u8,
	start: usize = 0,
	count: usize = 0,
	len: usize = 0,
	total_len: u64 = 0,
	sink: *OutputSink,
	pending: [output_buffer_size]u8 = undefined,
	pending_len: usize = 0,

	fn init(window: []u8, sink: *OutputSink) StreamingLzBuffer {
		return .{
			.window = window,
			.sink = sink,
		};
	}

	fn pushWindowByte(self: *StreamingLzBuffer, byte: u8) void {
		if (self.count < self.window.len) {
			var write_pos = self.start + self.count;
			if (write_pos >= self.window.len) write_pos -= self.window.len;
			self.window[write_pos] = byte;
			self.count += 1;
		} else {
			self.window[self.start] = byte;
			self.start += 1;
			if (self.start == self.window.len) self.start = 0;
		}
		self.len += 1;
		self.total_len += 1;
	}

	/// Append bytes to the LZ dictionary window without emitting them. This
	/// keeps match lookback state current while sink writes are batched.
	fn pushWindowSlice(self: *StreamingLzBuffer, data: []const u8) void {
		self.len += data.len;
		self.total_len += data.len;
		if (data.len >= self.window.len) {
			@memcpy(self.window, data[data.len - self.window.len ..]);
			self.start = 0;
			self.count = self.window.len;
			return;
		}

		var remaining = data;
		while (remaining.len > 0) {
			const write_pos = if (self.count < self.window.len)
				(self.start + self.count) % self.window.len
			else
				self.start;
			const contig = if (self.count < self.window.len and write_pos < self.start)
				self.start - write_pos
			else
				self.window.len - write_pos;
			const n = @min(contig, remaining.len);
			@memcpy(self.window[write_pos .. write_pos + n], remaining[0..n]);
			if (self.count < self.window.len) {
				self.count += n;
			} else {
				self.start = (self.start + n) % self.window.len;
			}
			remaining = remaining[n..];
		}
	}

	/// Batch decoded output before handing it to the verification sink, reducing
	/// callback, limit-check, and incremental-CRC overhead for literal-heavy data.
	fn emit(self: *StreamingLzBuffer, data: []const u8) !void {
		if (data.len == 0) return;
		if (data.len >= self.pending.len) {
			try self.flush();
			try self.sink.write(data);
			return;
		}
		if (data.len > self.pending.len - self.pending_len) {
			try self.flush();
		}
		@memcpy(self.pending[self.pending_len .. self.pending_len + data.len], data);
		self.pending_len += data.len;
	}

	fn flush(self: *StreamingLzBuffer) !void {
		if (self.pending_len == 0) return;
		try self.sink.write(self.pending[0..self.pending_len]);
		self.pending_len = 0;
	}

	fn emitByte(self: *StreamingLzBuffer, byte: u8) !void {
		if (self.pending_len == self.pending.len) {
			try self.flush();
		}
		self.pending[self.pending_len] = byte;
		self.pending_len += 1;
	}

	pub fn reset(self: *StreamingLzBuffer, writer: *std.Io.Writer) !void {
		_ = writer;
		self.start = 0;
		self.count = 0;
		self.len = 0;
	}

	pub fn lastOr(self: StreamingLzBuffer, lit: u8) u8 {
		if (self.count == 0) return lit;
		var index = self.start + self.count - 1;
		if (index >= self.window.len) index -= self.window.len;
		return self.window[index];
	}

	pub fn lastN(self: StreamingLzBuffer, dist: usize) !u8 {
		if (dist == 0 or dist > self.count) return error.CorruptInput;
		var index = self.start + self.count - dist;
		if (index >= self.window.len) index -= self.window.len;
		return self.window[index];
	}

	pub fn appendLiteral(
		self: *StreamingLzBuffer,
		gpa: std.mem.Allocator,
		lit: u8,
		writer: *std.Io.Writer,
	) !void {
		_ = gpa;
		_ = writer;
		try self.appendRawLiteral(lit);
	}

	fn appendRawLiteral(self: *StreamingLzBuffer, lit: u8) !void {
		self.pushWindowByte(lit);
		try self.emitByte(lit);
	}

	fn appendRawSlice(self: *StreamingLzBuffer, data: []const u8) !void {
		self.pushWindowSlice(data);
		try self.emit(data);
	}

	pub fn appendLz(
		self: *StreamingLzBuffer,
		gpa: std.mem.Allocator,
		len: usize,
		dist: usize,
		writer: *std.Io.Writer,
	) !void {
		_ = gpa;
		_ = writer;
		if (dist == 0 or dist > self.count) return error.CorruptInput;

		if (self.start == 0 and self.count + len <= self.window.len) {
			const buf_len = self.count;
			const src = self.window[buf_len - dist ..][0..len];
			const dst = self.window[buf_len..][0..len];
			for (dst, src) |*d, s| d.* = s;
			self.count += len;
			self.len += len;
			self.total_len += len;
			try self.emit(dst);
			return;
		}

		var scratch: [4096]u8 = undefined;
		var remaining = len;
		while (remaining > 0) {
			const n = @min(remaining, scratch.len);
			for (scratch[0..n]) |*out| {
				var index = self.start + self.count - dist;
				if (index >= self.window.len) index -= self.window.len;
				const byte = self.window[index];
				out.* = byte;
				self.pushWindowByte(byte);
			}
			try self.emit(scratch[0..n]);
			remaining -= n;
		}
	}

	pub fn finish(self: *StreamingLzBuffer, writer: *std.Io.Writer) !void {
		_ = writer;
		try self.flush();
	}
};

fn parseLzma2Uncompressed(
	reader: *std.Io.Reader,
	accum: *StreamingLzBuffer,
	reset_dict: bool,
) !usize {
	var unused_writer = std.Io.Writer.failing;
	const unpacked_size = @as(u17, try reader.takeInt(u16, .big)) + 1;
	if (reset_dict) try accum.reset(&unused_writer);
	try accum.appendRawSlice(try reader.take(unpacked_size));
	return 2 + unpacked_size;
}

fn parseLzma2Compressed(
	ld: *std.compress.lzma.Decode,
	reader: *std.Io.Reader,
	allocating: *std.Io.Writer.Allocating,
	accum: *StreamingLzBuffer,
	status: u8,
) !u64 {
	if (status & 0x80 == 0) return error.CorruptInput;

	const Reset = struct {
		dict: bool,
		state: bool,
		props: bool,
	};

	const reset: Reset = switch ((status >> 5) & 0x3) {
		0 => .{ .dict = false, .state = false, .props = false },
		1 => .{ .dict = false, .state = true, .props = false },
		2 => .{ .dict = false, .state = true, .props = true },
		3 => .{ .dict = true, .state = true, .props = true },
		else => unreachable,
	};

	var n_read: u64 = 0;
	const unpacked_size = blk: {
		var tmp: u64 = status & 0x1F;
		tmp <<= 16;
		tmp |= try reader.takeInt(u16, .big);
		n_read += 2;
		break :blk tmp + 1;
	};
	const packed_size = blk: {
		const tmp: u17 = try reader.takeInt(u16, .big);
		n_read += 2;
		break :blk tmp + 1;
	};

	if (reset.dict) try accum.reset(&allocating.writer);

	if (reset.state) {
		var new_props = ld.properties;
		if (reset.props) {
			var props = try reader.takeByte();
			n_read += 1;
			if (props >= 225) return error.CorruptInput;

			const lc: u4 = @intCast(props % 9);
			props /= 9;
			const lp: u3 = @intCast(props % 5);
			props /= 5;
			const pb: u3 = @intCast(props);
			if (lc + lp > 4) return error.CorruptInput;
			new_props = .{ .lc = lc, .lp = lp, .pb = pb };
		}
		try ld.resetState(allocating.allocator, new_props);
	}

	const expected_unpacked_size = accum.len + unpacked_size;
	const start_count = n_read;
	var range_decoder = try std.compress.lzma.RangeDecoder.initCounting(reader, &n_read);

	while (accum.len < expected_unpacked_size) {
		const status_result = try ld.process(reader, allocating, accum, &range_decoder, &n_read);
		if (status_result == .finished) break;
	}

	if (accum.len != expected_unpacked_size) return error.DecompressedSizeMismatch;
	if (n_read - start_count != packed_size) return error.CompressedSizeMismatch;

	return n_read;
}

fn decodeLzma2ToSink(
	packed_data: []const u8,
	unpack_size: u64,
	properties: []const u8,
	sink: *OutputSink,
	allocator: std.mem.Allocator,
) StreamingError!void {
	const dict_size = try lzma2DictSize(properties, unpack_size);
	const window = allocator.alloc(u8, dict_size) catch return CodecError.OutOfMemory;
	defer allocator.free(window);

	var in: std.Io.Reader = .fixed(packed_data);
	var fake_allocating: std.Io.Writer.Allocating = .{
		.allocator = allocator,
		.writer = std.Io.Writer.failing,
		.alignment = .of(u8),
	};
	var accum = StreamingLzBuffer.init(window, sink);
	var ld = std.compress.lzma.Decode.init(allocator, .{ .lc = 0, .lp = 0, .pb = 0 }) catch return CodecError.OutOfMemory;
	defer ld.deinit(allocator);

	var n_read: u64 = 0;
	while (true) {
		const status = in.takeByte() catch return CodecError.DecompressFailed;
		n_read += 1;
		switch (status) {
			0 => break,
			1 => n_read += parseLzma2Uncompressed(&in, &accum, true) catch |e| return mapStreamingLzma2Error(e),
			2 => n_read += parseLzma2Uncompressed(&in, &accum, false) catch |e| return mapStreamingLzma2Error(e),
			else => n_read += parseLzma2Compressed(&ld, &in, &fake_allocating, &accum, status) catch |e| return mapStreamingLzma2Error(e),
		}
	}

	accum.finish(&fake_allocating.writer) catch |e| return mapStreamingLzma2Error(e);
	if (n_read != packed_data.len) return CodecError.DecompressFailed;
	if (accum.total_len != unpack_size) return CodecError.DecompressFailed;
}

fn decodeLzmaToSink(
	packed_data: []const u8,
	unpack_size: u64,
	properties: []const u8,
	sink: *OutputSink,
	allocator: std.mem.Allocator,
) StreamingError!void {
	if (properties.len < 5 or unpack_size > std.math.maxInt(usize)) return CodecError.DecompressFailed;

	const props_byte = properties[0];
	if (props_byte >= 225) return CodecError.DecompressFailed;
	const lc: u4 = @intCast(props_byte % 9);
	const lp_pb = props_byte / 9;
	const lp: u3 = @intCast(lp_pb % 5);
	const pb: u3 = @intCast(lp_pb / 5);
	if (@as(u8, lc) + @as(u8, lp) > 4) return CodecError.DecompressFailed;

	const declared_dict_size = std.mem.readInt(u32, properties[1..5], .little);
	const dict_size: usize = @intCast(@max(
		@as(u64, 1),
		@min(@as(u64, declared_dict_size), unpack_size),
	));
	const window = allocator.alloc(u8, dict_size) catch return CodecError.OutOfMemory;
	defer allocator.free(window);

	var in: std.Io.Reader = .fixed(packed_data);
	var fake_allocating: std.Io.Writer.Allocating = .{
		.allocator = allocator,
		.writer = std.Io.Writer.failing,
		.alignment = .of(u8),
	};
	var accum = StreamingLzBuffer.init(window, sink);
	var dec = std.compress.lzma.Decode.init(allocator, .{ .lc = lc, .lp = lp, .pb = pb }) catch
		return CodecError.OutOfMemory;
	defer dec.deinit(allocator);

	var n_read: u64 = 0;
	var range_decoder = std.compress.lzma.RangeDecoder.initCounting(&in, &n_read) catch
		return CodecError.DecompressFailed;
	while (accum.total_len < unpack_size) {
		const status = dec.process(&in, &fake_allocating, &accum, &range_decoder, &n_read) catch |e|
			return mapStreamingLzma2Error(e);
		if (status == .finished) break;
	}

	accum.finish(&fake_allocating.writer) catch |e| return mapStreamingLzma2Error(e);
	if (accum.total_len != unpack_size) return CodecError.DecompressFailed;
}

fn mapStreamingLzma2Error(err: anyerror) StreamingError {
	return switch (err) {
		error.OutOfMemory => CodecError.OutOfMemory,
		error.ResourceLimitExceeded => SinkError.ResourceLimitExceeded,
		error.ChecksumError => SinkError.ChecksumError,
		error.StructuralError => SinkError.StructuralError,
		else => CodecError.DecompressFailed,
	};
}

/// Decompress Zstandard-compressed data using Zig's std.compress.zstd.
/// 7z method ID 04.F7.11.01, added to the 7z format in 7-Zip 21.01 (2021).
fn decodeZstd(packed_data: []const u8, unpack_size: u64, allocator: std.mem.Allocator) CodecError![]u8 {
	const out_buf = allocator.alloc(u8, @intCast(unpack_size)) catch return CodecError.OutOfMemory;
	errdefer allocator.free(out_buf);

	var in: std.Io.Reader = .fixed(packed_data);
	var out: std.Io.Writer = .fixed(out_buf);
	var zstd_stream = std.compress.zstd.Decompress.init(&in, &.{}, .{});
	_ = zstd_stream.reader.streamRemaining(&out) catch {
		return CodecError.DecompressFailed;
	};

	if (out.end != @as(usize, @intCast(unpack_size))) {
		return CodecError.DecompressFailed;
	}

	return out_buf;
}
/// Compress data using LZMA2.
/// Returns owned slice of LZMA2-compressed bytes.
pub fn compressLzma2(data: []const u8, dict_size: u32, nice_len: u32, progress: ProgressContext, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
	return compressLzma2WithThreads(data, dict_size, nice_len, 0, progress, allocator);
}

/// Compress data using LZMA2 with explicit thread count control.
/// thread_count: 0 = auto-detect, 1 = single-threaded, N = use N threads.
pub fn compressLzma2WithThreads(data: []const u8, dict_size: u32, nice_len: u32, thread_count: u32, progress: ProgressContext, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
	return lzma2_enc.compressWithThreads(data, dict_size, nice_len, thread_count, progress, allocator) catch |e| switch (e) {
		error.OutOfMemory => return error.OutOfMemory,
		else => unreachable,
	};
}

/// Re-export LevelParams for consumers of codec.zig.
pub const LevelParams = lzma2_enc.LevelParams;

// ============================================================================
// BCJ x86 filter (cleanroom from LZMA SDK public domain algorithm)
// ============================================================================

/// Test if byte is 0x00 or 0xFF (valid sign-extension for branch targets).
fn test86MSByte(b: u8) bool {
	return ((@as(u16, b) +% 1) & 0xFE) == 0;
}

/// BCJ x86 filter core: convert between relative and absolute branch addresses.
/// Scans for E8 (CALL) and E9 (JMP) instructions and transforms the 4-byte
/// LE address operand. Transforms data in-place.
/// Returns number of bytes processed.
fn bcjX86Convert(data: []u8, ip_init: u32, state: *u32, encoding: bool) usize {
	if (data.len < 5) return 0;

	const size = data.len - 4;
	var pos: usize = 0;
	var mask: u32 = state.* & 7;
	const ip = ip_init +% 5;

	while (true) {
		// Scan for E8 (CALL) or E9 (JMP)
		var scan = pos;
		while (scan < size) : (scan += 1) {
			if ((data[scan] & 0xFE) == 0xE8) break;
		}

		const d = scan - pos;
		pos = scan;

		if (pos >= size) {
			// End of scannable region
			state.* = if (d > 2) 0 else mask >> @as(u5, @intCast(d));
			return pos;
		}

		if (d > 2) {
			mask = 0;
		} else {
			mask >>= @as(u5, @intCast(d));
			if (mask != 0 and (mask > 4 or mask == 3 or test86MSByte(data[pos + @as(usize, mask >> 1) + 1]))) {
				mask = (mask >> 1) | 4;
				pos += 1;
				continue;
			}
		}

		if (test86MSByte(data[pos + 4])) {
			var v: u32 = (@as(u32, data[pos + 4]) << 24) |
				(@as(u32, data[pos + 3]) << 16) |
				(@as(u32, data[pos + 2]) << 8) |
				(@as(u32, data[pos + 1]));

			const cur = ip +% @as(u32, @intCast(pos));
			pos += 5;

			if (encoding) {
				v +%= cur;
			} else {
				v -%= cur;
			}

			if (mask != 0) {
				const sh: u5 = @intCast((mask & 6) << 2);
				if (test86MSByte(@truncate(v >> sh))) {
					// Compute XOR mask: (0x100 << sh) - 1, handling sh=24 overflow
					const total_shift: u6 = @as(u6, sh) + 8;
					const xor_mask: u32 = if (total_shift >= 32)
						0xFFFFFFFF
					else
						(@as(u32, 1) << @as(u5, @intCast(total_shift))) - 1;
					v ^= xor_mask;
					if (encoding) {
						v +%= cur;
					} else {
						v -%= cur;
					}
				}
				mask = 0;
			}

			data[pos - 4] = @truncate(v);
			data[pos - 3] = @truncate(v >> 8);
			data[pos - 2] = @truncate(v >> 16);
			// Sign-extend MSByte to 0x00 or 0xFF
			data[pos - 1] = @as(u8, 0) -% @as(u8, @truncate((v >> 24) & 1));
		} else {
			mask = (mask >> 1) | 4;
			pos += 1;
		}
	}
}

/// BCJ x86 encode: convert relative CALL/JMP addresses to absolute (in-place).
fn bcjX86Encode(data: []u8) void {
	var state: u32 = 0;
	_ = bcjX86Convert(data, 0, &state, true);
}

/// BCJ x86 decode: convert absolute CALL/JMP addresses back to relative (in-place).
fn bcjX86Decode(data: []u8) void {
	var state: u32 = 0;
	_ = bcjX86Convert(data, 0, &state, false);
}

// ============================================================================
// Tests
// ============================================================================

/// Test helper: minimal folder-like struct that works with comptime data.
const TestFolder = struct {
	coders: []const meta.Coder,
	bind_pairs: []const meta.BindPair = &.{},
	packed_indices: []const u64 = &.{},
	unpack_sizes: []const u64 = &.{},
	unpack_crc: ?u32 = null,
};

const TestMaxSingleAllocationAllocator = struct {
    backing: std.mem.Allocator,
    max_single_alloc: usize,
    max_observed_alloc: usize = 0,

    fn init(backing: std.mem.Allocator, max_single_alloc: usize) TestMaxSingleAllocationAllocator {
        return .{ .backing = backing, .max_single_alloc = max_single_alloc };
    }

    fn allocator(self: *TestMaxSingleAllocationAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn fromContext(ctx: *anyopaque) *TestMaxSingleAllocationAllocator {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, len);
        if (len > self.max_single_alloc) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, new_len);
        if (new_len > self.max_single_alloc) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, new_len);
        if (new_len > self.max_single_alloc) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromContext(ctx);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "codec: copy passthrough" {
	const allocator = std.testing.allocator;
	const input = "hello world";
	const folder = TestFolder{
		.coders = &.{.{
			.method_id = &.{METHOD_COPY},
			.properties = &.{},
			.num_in_streams = 1,
			.num_out_streams = 1,
		}},
	};

	const output = try decompressFolder(folder, input, &.{11}, 11, null, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualStrings("hello world", output);
}

test "codec: lzma2 decompress" {
	const allocator = std.testing.allocator;

	// LZMA2 compressed "Hello\nWorld!\n" from stdlib test
	const compressed = &[_]u8{
		0x01, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
		0x0A, 0x02, 0x00, 0x06, 0x57, 0x6F, 0x72, 0x6C,
		0x64, 0x21, 0x0A, 0x00,
	};
	const expected = "Hello\nWorld!\n";

	const folder = TestFolder{
		.coders = &.{.{
			.method_id = &.{METHOD_LZMA2},
			.properties = &.{},
			.num_in_streams = 1,
			.num_out_streams = 1,
		}},
	};

	const output = try decompressFolder(folder, compressed, &.{compressed.len}, 13, null, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualStrings(expected, output);
}

test "codec: zstd decompress" {
	const allocator = std.testing.allocator;

	// ZSTD-compressed "Hello\nWorld!\n" (zstd -3)
	const compressed = &[_]u8{
		0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x69, 0x00,
		0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x57,
		0x6F, 0x72, 0x6C, 0x64, 0x21, 0x0A, 0x91, 0xE2,
		0xB3, 0x20,
	};
	const expected = "Hello\nWorld!\n";

	const folder = TestFolder{
		.coders = &.{.{
			.method_id = &METHOD_ZSTD,
			.properties = &.{},
			.num_in_streams = 1,
			.num_out_streams = 1,
		}},
	};

	const output = try decompressFolder(folder, compressed, &.{compressed.len}, 13, null, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualStrings(expected, output);
}

test "codec: bcj x86 decode" {
	// BCJ x86 filter transforms relative CALL/JMP addresses to absolute.
	// Create data with an E8 (CALL) at position 10 with a relative offset.
	// After BCJ encode: relative offset becomes absolute (pos + offset + 5).
	// After BCJ decode: absolute converts back to relative.
	var input: [32]u8 = [_]u8{0x90} ** 32; // NOP sled
	// Place a CALL instruction at position 10: E8 xx xx xx xx
	input[10] = 0xE8;
	// Relative offset to position 100: need offset = 100 - (10 + 5) = 85 = 0x55
	input[11] = 0x55; // LE byte 0
	input[12] = 0x00;
	input[13] = 0x00;
	input[14] = 0x00;

	// BCJ encode: convert relative to absolute
	var encoded = input;
	bcjX86Encode(&encoded);

	// Verify the CALL offset was transformed
	// Absolute address = relative + position + 5 = 0x55 + 10 + 5 = 0x64
	try std.testing.expectEqual(@as(u8, 0xE8), encoded[10]); // opcode unchanged
	// The 4 bytes after E8 should now be the absolute address
	const abs_addr = std.mem.readInt(u32, encoded[11..15], .little);
	try std.testing.expectEqual(@as(u32, 0x64), abs_addr);

	// BCJ decode: convert absolute back to relative
	var decoded = encoded;
	bcjX86Decode(&decoded);

	// Should match original
	try std.testing.expectEqualSlices(u8, &input, &decoded);
}

test "codec: streaming bcj x86 preserves branches split across chunks" {
	const Collector = struct {
		buffer: []u8,
		len: usize = 0,

		fn outputSink(self: *@This()) OutputSink {
			return .{ .ptr = self, .writeFn = writeThunk };
		}

		fn writeThunk(ctx: *anyopaque, data: []const u8) SinkError!void {
			const self: *@This() = @ptrCast(@alignCast(ctx));
			if (data.len > self.buffer.len - self.len) return SinkError.StructuralError;
			@memcpy(self.buffer[self.len .. self.len + data.len], data);
			self.len += data.len;
		}
	};

	var original: [8200]u8 = [_]u8{0x90} ** 8200;
	for (&[_]usize{ 4094, 4096, 8189 }) |pos| {
		original[pos] = 0xE8;
		std.mem.writeInt(u32, original[pos + 1 ..][0..4], @intCast(0x1000 + pos), .little);
	}
	var encoded = original;
	bcjX86Encode(&encoded);

	var decoded: [original.len]u8 = undefined;
	var collector = Collector{ .buffer = &decoded };
	var downstream = collector.outputSink();
	var filter = BcjX86Sink.init(&downstream);
	try filter.write(encoded[0..1]);
	try filter.write(encoded[1..4095]);
	try filter.write(encoded[4095..4098]);
	try filter.write(encoded[4098..]);
	try filter.finish();

	try std.testing.expectEqual(original.len, collector.len);
	try std.testing.expectEqualSlices(u8, &original, decoded[0..collector.len]);
}

test "codec: multi-coder folder (BCJ+LZMA2)" {
	const allocator = std.testing.allocator;

	// Create a folder with two coders: BCJ (filter) → LZMA2 (compressor)
	// First apply BCJ, then compress with LZMA2
	var input: [64]u8 = undefined;
	for (&input, 0..) |*b, i| {
		b.* = @intCast(i & 0xFF);
	}
	// Insert CALL instructions
	input[10] = 0xE8;
	input[30] = 0xE8;
	input[50] = 0xE8;

	// BCJ encode then LZMA2 compress
	var bcj_buf = input;
	bcjX86Encode(&bcj_buf);
	const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
	const lzma2_data = try compressLzma2(&bcj_buf, p.dict_size, p.nice_len, .{}, allocator);
	defer allocator.free(lzma2_data);

	// Build a two-coder folder and decompress
	const folder = TestFolder{
		.coders = &.{
			.{ // Coder 0: BCJ (x86)
				.method_id = &.{ 0x03, 0x03, 0x01, 0x03 },
				.properties = &.{},
				.num_in_streams = 1,
				.num_out_streams = 1,
			},
			.{ // Coder 1: LZMA2
				.method_id = &.{0x21},
				.properties = &.{},
				.num_in_streams = 1,
				.num_out_streams = 1,
			},
		},
		.bind_pairs = &.{.{ .in_index = 0, .out_index = 1 }},
		.packed_indices = &.{},
		.unpack_sizes = &.{ 64, 64 },
	};

	const output = try decompressFolder(folder, lzma2_data, &.{lzma2_data.len}, 64, null, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualSlices(u8, &input, output);
}

// ============================================================================
// BCJ2 filter (Branch/Call/Jump filter version 2)
// ============================================================================
//
// BCJ2 splits x86 code into 4 sub-streams for better compression:
//   Stream 0 (main): all bytes except addresses of detected branches
//   Stream 1 (call): 4-byte absolute addresses from E8 (CALL) instructions
//   Stream 2 (jump): 4-byte absolute addresses from E9 (JMP) and 0F 8x (Jcc) instructions
//   Stream 3 (rc):   range-coded bitstream indicating which E8/E9/0F8x are real branches
//
// The decoder recombines these streams: reads main byte-by-byte, and when it
// encounters E8/E9/0F8x, consults the range coder to decide whether to splice
// in a 4-byte address from the call/jump stream (converting absolute→relative).

const BCJ2_NUM_PROBS = 258; // 256 for E8 (indexed by prev byte) + 1 for E9 + 1 for Jcc
const BCJ2_BIT_MODEL_TOTAL: u16 = 1 << 11; // 2048
const BCJ2_NUM_MOVE_BITS: u5 = 5;
const BCJ2_RC_INIT_BYTES = 5;
const BCJ2_TOP: u32 = 1 << 24;

/// Decode BCJ2-encoded data from 4 sub-streams into a single output buffer.
/// Returns the number of bytes written to out_buf.
fn bcj2Decode(
	main_stream: []const u8,
	call_stream: []const u8,
	jump_stream: []const u8,
	rc_stream: []const u8,
	out_buf: []u8,
) CodecError!usize {
	if (rc_stream.len < BCJ2_RC_INIT_BYTES) return CodecError.DecompressFailed;

	// Initialize probability contexts
	var probs: [BCJ2_NUM_PROBS]u16 = undefined;
	for (&probs) |*p| p.* = BCJ2_BIT_MODEL_TOTAL / 2;

	// Initialize range coder: first byte is discarded, next 4 form the code
	var rc_pos: usize = BCJ2_RC_INIT_BYTES;
	var range: u32 = 0xFFFFFFFF;
	var code: u32 = (@as(u32, rc_stream[1]) << 24) |
		(@as(u32, rc_stream[2]) << 16) |
		(@as(u32, rc_stream[3]) << 8) |
		@as(u32, rc_stream[4]);

	var main_pos: usize = 0;
	var call_pos: usize = 0;
	var jump_pos: usize = 0;
	var out_pos: usize = 0;
	var prev_byte: u8 = 0;

	while (main_pos < main_stream.len) {
		const b = main_stream[main_pos];
		main_pos += 1;
		if (out_pos >= out_buf.len) {
			return CodecError.DecompressFailed;
		}
		out_buf[out_pos] = b;
		out_pos += 1;

		// Determine if this byte starts a branch instruction
		var prob_idx: ?usize = null;
		var use_call_stream = false;

		if (b == 0xE8) {
			prob_idx = prev_byte; // 0..255
			use_call_stream = true;
		} else if (b == 0xE9) {
			prob_idx = 256;
		} else if (b >= 0x80 and b <= 0x8F and prev_byte == 0x0F) {
			prob_idx = 257;
		}

		if (prob_idx) |pidx| {
			const bit = bcj2RangeDecode(&probs[pidx], &range, &code, rc_stream, &rc_pos);
			if (bit == 1) {
				// Read 4-byte absolute address from call or jump stream (BIG ENDIAN)
				var addr: u32 = undefined;
				if (use_call_stream) {
					if (call_pos + 4 > call_stream.len) {
						return CodecError.DecompressFailed;
					}
					addr = std.mem.readInt(u32, call_stream[call_pos..][0..4], .big);
					call_pos += 4;
				} else {
					if (jump_pos + 4 > jump_stream.len) {
						return CodecError.DecompressFailed;
					}
					addr = std.mem.readInt(u32, jump_stream[jump_pos..][0..4], .big);
					jump_pos += 4;
				}
				// Convert absolute to relative: subtract (opcode_pos + 5)
				// BCJ2 stores: absolute = relative + (opcode_pos + 5)
				// out_pos is already opcode_pos + 1, so: addr -= (out_pos + 4)
				addr -%= @as(u32, @intCast(out_pos + 4));
				// Write 4 address bytes to output
				if (out_pos + 4 > out_buf.len) {
					return CodecError.DecompressFailed;
				}
				out_buf[out_pos] = @truncate(addr);
				out_buf[out_pos + 1] = @truncate(addr >> 8);
				out_buf[out_pos + 2] = @truncate(addr >> 16);
				out_buf[out_pos + 3] = @truncate(addr >> 24);
				prev_byte = out_buf[out_pos + 3];
				out_pos += 4;
				continue;
			}
		}
		prev_byte = b;
	}

	return out_pos;
}

/// Binary arithmetic range decoder for BCJ2 probability contexts.
fn bcj2RangeDecode(prob: *u16, range: *u32, code: *u32, stream: []const u8, pos: *usize) u1 {
	const bound: u32 = (range.* >> 11) *% @as(u32, prob.*);
	if (code.* < bound) {
		range.* = bound;
		prob.* +%= @intCast((@as(u32, BCJ2_BIT_MODEL_TOTAL) - prob.*) >> BCJ2_NUM_MOVE_BITS);
		if (range.* < BCJ2_TOP) {
			range.* <<= 8;
			const next_byte: u32 = if (pos.* < stream.len) stream[pos.*] else 0;
			code.* = (code.* << 8) | next_byte;
			pos.* += 1;
		}
		return 0;
	} else {
		range.* -= bound;
		code.* -= bound;
		prob.* -= @intCast(prob.* >> BCJ2_NUM_MOVE_BITS);
		if (range.* < BCJ2_TOP) {
			range.* <<= 8;
			const next_byte: u32 = if (pos.* < stream.len) stream[pos.*] else 0;
			code.* = (code.* << 8) | next_byte;
			pos.* += 1;
		}
		return 1;
	}
}

test "codec: bcj2 decode no-branch passthrough" {
	// Data with no E8/E9/0F8x — should pass through unchanged
	const input = "hello world!";
	const rc = [_]u8{ 0, 0, 0, 0, 0 }; // range coder never consulted
	var out: [12]u8 = undefined;
	const n = try bcj2Decode(input, &.{}, &.{}, &rc, &out);
	try std.testing.expectEqual(@as(usize, 12), n);
	try std.testing.expectEqualStrings("hello world!", out[0..n]);
}

test "codec: bcj2 decode single E8 branch" {
	// Input (32 bytes): NOP*10, E8, rel_addr(0x55,0,0,0), NOP*17
	// BCJ2 encoding: main stream has E8 but address bytes removed (28 bytes),
	// call stream has absolute address, range coder encodes "1" (real branch).
	//
	// BCJ2 stores absolute = relative + (opcode_pos + 5) = 0x55 + 15 = 0x64
	// Addresses in BIG ENDIAN.
	// Range coder: prob[0x90]=1024, code=0xFFFFFFFF >= bound=0x7FFFFC00 → bit=1

	// Main stream: 10 NOPs + E8 + 17 NOPs = 28 bytes
	var main_buf: [28]u8 = undefined;
	for (main_buf[0..10]) |*b| b.* = 0x90;
	main_buf[10] = 0xE8;
	for (main_buf[11..28]) |*b| b.* = 0x90;

	const call_buf = [_]u8{ 0x00, 0x00, 0x00, 0x64 }; // absolute address BE: 0x64
	const rc_buf = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF }; // decodes bit=1

	var out: [32]u8 = undefined;
	const n = try bcj2Decode(&main_buf, &call_buf, &.{}, &rc_buf, &out);
	try std.testing.expectEqual(@as(usize, 32), n);

	// Expected: NOP*10, E8, 0x55, 0x00, 0x00, 0x00, NOP*17
	var expected: [32]u8 = undefined;
	for (expected[0..10]) |*b| b.* = 0x90;
	expected[10] = 0xE8;
	expected[11] = 0x55;
	expected[12] = 0x00;
	expected[13] = 0x00;
	expected[14] = 0x00;
	for (expected[15..32]) |*b| b.* = 0x90;

	try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

test "codec: bcj2 multi-coder pipeline (BCJ2 + LZMA2)" {
	const allocator = std.testing.allocator;

	// BCJ2 encoded sub-streams (same as the "single E8 branch" test):
	// Main stream: NOP*10, E8, NOP*17 = 28 bytes
	var main_raw: [28]u8 = undefined;
	for (main_raw[0..10]) |*b| b.* = 0x90;
	main_raw[10] = 0xE8;
	for (main_raw[11..28]) |*b| b.* = 0x90;

	const call_raw = [_]u8{ 0x00, 0x00, 0x00, 0x64 }; // absolute address BE: 0x55 + (10 + 5) = 0x64
	const rc_raw = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF }; // range coder stream

	// LZMA2-compress the main, call, and jump streams; RC stream stays raw
	const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
	const main_comp = try compressLzma2(&main_raw, p.dict_size, p.nice_len, .{}, allocator);
	defer allocator.free(main_comp);
	const call_comp = try compressLzma2(&call_raw, p.dict_size, p.nice_len, .{}, allocator);
	defer allocator.free(call_comp);

	// Jump stream is empty — use Copy (0-byte LZMA2 would be the empty marker 0x00)
	const jump_comp = [_]u8{0x00}; // LZMA2 end marker = empty stream

	// Concatenate all 4 pack streams: main_comp | call_comp | jump_comp | rc_raw
	const total_packed = main_comp.len + call_comp.len + jump_comp.len + rc_raw.len;
	const pack_buf = try allocator.alloc(u8, total_packed);
	defer allocator.free(pack_buf);
	var off: usize = 0;
	@memcpy(pack_buf[off .. off + main_comp.len], main_comp);
	off += main_comp.len;
	@memcpy(pack_buf[off .. off + call_comp.len], call_comp);
	off += call_comp.len;
	@memcpy(pack_buf[off .. off + jump_comp.len], &jump_comp);
	off += jump_comp.len;
	@memcpy(pack_buf[off .. off + rc_raw.len], &rc_raw);

	// Pack sizes for each stream
	const ps = [_]u64{
		@intCast(main_comp.len),
		@intCast(call_comp.len),
		@intCast(jump_comp.len),
		@intCast(rc_raw.len),
	};

	// BCJ2 folder topology:
	// Coder 0: LZMA2 (1 in → 1 out)  — decompresses main stream
	// Coder 1: LZMA2 (1 in → 1 out)  — decompresses call stream
	// Coder 2: LZMA2 (1 in → 1 out)  — decompresses jump stream
	// Coder 3: BCJ2  (4 in → 1 out)  — recombines sub-streams
	//
	// Global input streams: 0(LZMA2-main), 1(LZMA2-call), 2(LZMA2-jump), 3,4,5,6(BCJ2)
	// Global output streams: 0(LZMA2-main), 1(LZMA2-call), 2(LZMA2-jump), 3(BCJ2)
	//
	// Bind pairs: LZMA2 outputs → BCJ2 inputs
	//   {in:3, out:0}  BCJ2 input 0 ← LZMA2[0] output (main)
	//   {in:4, out:1}  BCJ2 input 1 ← LZMA2[1] output (call)
	//   {in:5, out:2}  BCJ2 input 2 ← LZMA2[2] output (jump)
	//
	// BCJ2 input 6 is unbound → packed stream (RC data, stored raw)
	// Pack streams: inputs 0, 1, 2, 6

	const folder = TestFolder{
		.coders = &.{
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }, // LZMA2 (main)
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }, // LZMA2 (call)
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }, // LZMA2 (jump)
			.{ .method_id = &METHOD_BCJ2, .properties = &.{}, .num_in_streams = 4, .num_out_streams = 1 }, // BCJ2
		},
		.bind_pairs = &.{
			.{ .in_index = 3, .out_index = 0 }, // BCJ2 in[0] ← LZMA2[0]
			.{ .in_index = 4, .out_index = 1 }, // BCJ2 in[1] ← LZMA2[1]
			.{ .in_index = 5, .out_index = 2 }, // BCJ2 in[2] ← LZMA2[2]
		},
		.packed_indices = &.{ 0, 1, 2, 6 },
		.unpack_sizes = &.{ 28, 4, 0, 32 }, // LZMA2 main, call, jump unpack sizes + BCJ2 final output
	};

	const output = try decompressFolder(folder, pack_buf, &ps, 32, null, allocator);
	defer allocator.free(output);

	// Expected: NOP*10, E8, rel_addr(0x55,0,0,0), NOP*17 = 32 bytes
	var expected: [32]u8 = undefined;
	for (expected[0..10]) |*b| b.* = 0x90;
	expected[10] = 0xE8;
	expected[11] = 0x55;
	expected[12] = 0x00;
	expected[13] = 0x00;
	expected[14] = 0x00;
	for (expected[15..32]) |*b| b.* = 0x90;

	try std.testing.expectEqualSlices(u8, &expected, output);

    const Collector = struct {
        buffer: []u8,
        len: usize = 0,

        fn outputSink(self: *@This()) OutputSink {
            return .{ .ptr = self, .writeFn = writeThunk };
        }

        fn writeThunk(ctx: *anyopaque, data: []const u8) SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (data.len > self.buffer.len - self.len) return SinkError.StructuralError;
            @memcpy(self.buffer[self.len .. self.len + data.len], data);
            self.len += data.len;
        }
    };
    var streamed: [expected.len]u8 = undefined;
    var collector = Collector{ .buffer = &streamed };
    var sink = collector.outputSink();
    try decompressFolderToSink(folder, pack_buf, &ps, expected.len, null, &sink, allocator);
    try std.testing.expectEqual(expected.len, collector.len);
    try std.testing.expectEqualSlices(u8, &expected, streamed[0..collector.len]);
}

test "codec: streaming BCJ2 output allocation stays bounded" {
    const allocator = std.testing.allocator;
    const output_len = 4 * 1024 * 1024;

    const main_raw = try allocator.alloc(u8, output_len);
    defer allocator.free(main_raw);
    @memset(main_raw, 0x90);

    const p = LevelParams.fromLevel(0);
    const main_comp = try compressLzma2(main_raw, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(main_comp);
    const empty_lzma2 = [_]u8{0x00};
    const rc_raw = [_]u8{ 0, 0, 0, 0, 0 };

    const total_packed = main_comp.len + empty_lzma2.len * 2 + rc_raw.len;
    const pack_buf = try allocator.alloc(u8, total_packed);
    defer allocator.free(pack_buf);
    var off: usize = 0;
    @memcpy(pack_buf[off .. off + main_comp.len], main_comp);
    off += main_comp.len;
    @memcpy(pack_buf[off .. off + empty_lzma2.len], &empty_lzma2);
    off += empty_lzma2.len;
    @memcpy(pack_buf[off .. off + empty_lzma2.len], &empty_lzma2);
    off += empty_lzma2.len;
    @memcpy(pack_buf[off .. off + rc_raw.len], &rc_raw);

    const pack_sizes = [_]u64{
        @intCast(main_comp.len),
        empty_lzma2.len,
        empty_lzma2.len,
        rc_raw.len,
    };
    const folder = TestFolder{
        .coders = &.{
            .{ .method_id = &.{METHOD_LZMA2}, .properties = &.{8}, .num_in_streams = 1, .num_out_streams = 1 },
            .{ .method_id = &.{METHOD_LZMA2}, .properties = &.{8}, .num_in_streams = 1, .num_out_streams = 1 },
            .{ .method_id = &.{METHOD_LZMA2}, .properties = &.{8}, .num_in_streams = 1, .num_out_streams = 1 },
            .{ .method_id = &METHOD_BCJ2, .properties = &.{}, .num_in_streams = 4, .num_out_streams = 1 },
        },
        .bind_pairs = &.{
            .{ .in_index = 3, .out_index = 0 },
            .{ .in_index = 4, .out_index = 1 },
            .{ .in_index = 5, .out_index = 2 },
        },
        .packed_indices = &.{ 0, 1, 2, 6 },
        .unpack_sizes = &.{ output_len, 0, 0, output_len },
    };

    const CountingSink = struct {
        count: usize = 0,

        fn outputSink(self: *@This()) OutputSink {
            return .{ .ptr = self, .writeFn = writeThunk };
        }

        fn writeThunk(ctx: *anyopaque, data: []const u8) SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (data) |byte| if (byte != 0x90) return SinkError.ChecksumError;
            self.count += data.len;
        }
    };
    var counter = CountingSink{};
    var sink = counter.outputSink();
    var capped = TestMaxSingleAllocationAllocator.init(allocator, Lzma2Pull.max_chunk_output);

    try decompressFolderToSink(folder, pack_buf, &pack_sizes, output_len, null, &sink, capped.allocator());
    try std.testing.expectEqual(@as(usize, output_len), counter.count);
    try std.testing.expect(capped.max_observed_alloc < output_len);
}

test "codec: unsupported method" {
	const allocator = std.testing.allocator;
	const folder = TestFolder{
		.coders = &.{.{
			.method_id = &.{ 0x03, 0x04, 0x01 }, // PPMd (not yet supported)
			.properties = &.{},
			.num_in_streams = 1,
			.num_out_streams = 1,
		}},
	};

	try std.testing.expectError(CodecError.UnsupportedMethod, decompressFolder(folder, &.{}, &.{0}, 0, null, allocator));
}

test "codec: BCJ2 decompressFolder does not double-free on unpack_size mismatch" {
	// Regression: the BCJ2 branch of decompressFolder explicitly freed `out_buf`
	// AND had an errdefer for it on the `n != unpack_size` path -> double-free.
	// Drive that path by declaring the BCJ2 coder's unpack_size larger than what
	// bcj2Decode actually produces (32 bytes), so n (32) != declared (33).
	const allocator = std.testing.allocator;

	var main_raw: [28]u8 = undefined;
	for (main_raw[0..10]) |*b| b.* = 0x90;
	main_raw[10] = 0xE8;
	for (main_raw[11..28]) |*b| b.* = 0x90;

	const call_raw = [_]u8{ 0x00, 0x00, 0x00, 0x64 };
	const rc_raw = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF };

	const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
	const main_comp = try compressLzma2(&main_raw, p.dict_size, p.nice_len, .{}, allocator);
	defer allocator.free(main_comp);
	const call_comp = try compressLzma2(&call_raw, p.dict_size, p.nice_len, .{}, allocator);
	defer allocator.free(call_comp);
	const jump_comp = [_]u8{0x00};

	const total_packed = main_comp.len + call_comp.len + jump_comp.len + rc_raw.len;
	const pack_buf = try allocator.alloc(u8, total_packed);
	defer allocator.free(pack_buf);
	var off: usize = 0;
	@memcpy(pack_buf[off .. off + main_comp.len], main_comp);
	off += main_comp.len;
	@memcpy(pack_buf[off .. off + call_comp.len], call_comp);
	off += call_comp.len;
	@memcpy(pack_buf[off .. off + jump_comp.len], &jump_comp);
	off += jump_comp.len;
	@memcpy(pack_buf[off .. off + rc_raw.len], &rc_raw);

	const ps = [_]u64{
		@intCast(main_comp.len),
		@intCast(call_comp.len),
		@intCast(jump_comp.len),
		@intCast(rc_raw.len),
	};

	const folder = TestFolder{
		.coders = &.{
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 },
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 },
			.{ .method_id = &.{0x21}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 },
			.{ .method_id = &METHOD_BCJ2, .properties = &.{}, .num_in_streams = 4, .num_out_streams = 1 },
		},
		.bind_pairs = &.{
			.{ .in_index = 3, .out_index = 0 },
			.{ .in_index = 4, .out_index = 1 },
			.{ .in_index = 5, .out_index = 2 },
		},
		.packed_indices = &.{ 0, 1, 2, 6 },
		.unpack_sizes = &.{ 28, 4, 0, 33 }, // BCJ2 final declared 33, but produces 32 -> mismatch
	};

	try std.testing.expectError(CodecError.DecompressFailed, decompressFolder(folder, pack_buf, &ps, 33, null, allocator));
}

test "codec: lzma2 rejects declared-vs-actual unpack_size mismatch" {
	const allocator = std.testing.allocator;
	// Valid LZMA2 stream for "Hello\nWorld!\n" (13 bytes) but declare 999.
	const compressed = &[_]u8{
		0x01, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
		0x0A, 0x02, 0x00, 0x06, 0x57, 0x6F, 0x72, 0x6C,
		0x64, 0x21, 0x0A, 0x00,
	};
	const folder = TestFolder{
		.coders = &.{.{ .method_id = &.{METHOD_LZMA2}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }},
	};
	try std.testing.expectError(
		CodecError.DecompressFailed,
		decompressFolder(folder, compressed, &.{compressed.len}, 999, null, allocator),
	);
}

test "codec: lzma2 rejects truncated input" {
	const allocator = std.testing.allocator;
	const full = [_]u8{
		0x01, 0x00, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F,
		0x0A, 0x02, 0x00, 0x06, 0x57, 0x6F, 0x72, 0x6C,
		0x64, 0x21, 0x0A, 0x00,
	};
	const truncated = full[0..8]; // cut mid-stream
	const folder = TestFolder{
		.coders = &.{.{ .method_id = &.{METHOD_LZMA2}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }},
	};
	// Must not crash; must surface an error rather than silently returning short data.
	try std.testing.expectError(
		CodecError.DecompressFailed,
		decompressFolder(folder, truncated, &.{truncated.len}, 13, null, allocator),
	);
}

test "codec: zstd rejects declared-vs-actual unpack_size mismatch" {
	const allocator = std.testing.allocator;
	const compressed = &[_]u8{
		0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x58, 0x69, 0x00,
		0x00, 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x57,
		0x6F, 0x72, 0x6C, 0x64, 0x21, 0x0A, 0x91, 0xE2,
		0xB3, 0x20,
	};
	const folder = TestFolder{
		.coders = &.{.{ .method_id = &METHOD_ZSTD, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }},
	};
	try std.testing.expectError(
		CodecError.DecompressFailed,
		decompressFolder(folder, compressed, &.{compressed.len}, 999, null, allocator),
	);
}
