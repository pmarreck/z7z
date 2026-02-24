//! Codec dispatch: decompress packed data for a folder's coder pipeline.
//!
//! Wraps Zig stdlib decompressors (std.compress.lzma2, etc.)
//! to keep the archive module codec-agnostic.

const std = @import("std");
const meta = @import("metadata.zig");
const lzma2_enc = @import("lzma2_encoder.zig");
const aes = @import("aes_crypt.zig");

pub const CodecError = error{
	UnsupportedMethod,
	DecompressFailed,
	OutOfMemory,
};

/// Known method IDs.
const METHOD_COPY: u8 = 0x00;
const METHOD_LZMA2: u8 = 0x21;
const METHOD_LZMA: [3]u8 = .{ 0x03, 0x01, 0x01 };
const METHOD_BCJ_X86: [4]u8 = .{ 0x03, 0x03, 0x01, 0x03 };
const METHOD_7ZAES: [4]u8 = .{ 0x06, 0xF1, 0x07, 0x01 };

/// Decompress packed data for a folder's coder pipeline.
/// Supports single-coder and multi-coder (filter + compressor, AES + compressor) folders.
/// Pass password for encrypted archives, null otherwise.
/// Returns owned slice of decompressed bytes.
pub fn decompressFolder(
	folder: anytype,
	packed_data: []const u8,
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
		return decompressMultiCoderPipeline(folder, packed_data, unpack_size, password, allocator);
	}
	return CodecError.UnsupportedMethod;
}

/// Decompress with a single coder (Copy, LZMA2, or LZMA).
fn decompressSingleCoder(coder: anytype, packed_data: []const u8, unpack_size: u64, allocator: std.mem.Allocator) CodecError![]u8 {
	const mid = coder.method_id;
	if (mid.len == 1 and mid[0] == METHOD_COPY) {
		return decodeCopy(packed_data, allocator);
	} else if (mid.len == 1 and mid[0] == METHOD_LZMA2) {
		return decodeLzma2(packed_data, unpack_size, allocator);
	} else if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) {
		return decodeLzma(packed_data, unpack_size, coder.properties, allocator);
	}
	return CodecError.UnsupportedMethod;
}

/// Decompress a multi-coder pipeline (e.g. BCJ+LZMA2, 7zAES+LZMA2, 7zAES+BCJ+LZMA2).
/// Processes coders in reverse order: decrypt → decompress → filter.
fn decompressMultiCoderPipeline(
	folder: anytype,
	packed_data: []const u8,
	unpack_size: u64,
	password: ?[]const u8,
	allocator: std.mem.Allocator,
) CodecError![]u8 {
	// Classify coders
	var aes_idx: ?usize = null;
	var compressor_idx: ?usize = null;
	var filter_idx: ?usize = null;

	for (folder.coders, 0..) |coder, i| {
		const mid = coder.method_id;
		if (is7zAesMethod(mid)) {
			aes_idx = i;
		} else if (isCompressorMethod(mid)) {
			compressor_idx = i;
		} else if (isFilterMethod(mid)) {
			filter_idx = i;
		}
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

fn isCompressorMethod(mid: []const u8) bool {
	if (mid.len == 1 and mid[0] == METHOD_LZMA2) return true;
	if (mid.len == 3 and std.mem.eql(u8, mid, &METHOD_LZMA)) return true;
	if (mid.len == 1 and mid[0] == METHOD_COPY) return true;
	return false;
}

fn isFilterMethod(mid: []const u8) bool {
	return isBcjX86Method(mid);
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

	// Decompress using stdlib LZMA
	var input_stream = std.io.fixedBufferStream(synth);
	var decomp = std.compress.lzma.decompress(allocator, input_stream.reader()) catch
		return CodecError.DecompressFailed;
	defer decomp.deinit();

	const out_buf = allocator.alloc(u8, @intCast(unpack_size)) catch return CodecError.OutOfMemory;
	errdefer allocator.free(out_buf);

	const n = decomp.reader().readAll(out_buf) catch {
		allocator.free(out_buf);
		return CodecError.DecompressFailed;
	};
	if (n != @as(usize, @intCast(unpack_size))) {
		allocator.free(out_buf);
		return CodecError.DecompressFailed;
	}

	return out_buf;
}

fn decodeLzma2(packed_data: []const u8, unpack_size: u64, allocator: std.mem.Allocator) CodecError![]u8 {
	// Allocate output buffer
	const out_buf = allocator.alloc(u8, @intCast(unpack_size)) catch return CodecError.OutOfMemory;
	errdefer allocator.free(out_buf);

	// Use Zig's stdlib LZMA2 decompressor
	var input_stream = std.io.fixedBufferStream(packed_data);
	var output_stream = std.io.fixedBufferStream(out_buf);

	std.compress.lzma2.decompress(allocator, input_stream.reader(), output_stream.writer()) catch {
		return CodecError.DecompressFailed;
	};

	// Verify we got exactly the expected amount
	const written = output_stream.pos;
	if (written != @as(usize, @intCast(unpack_size))) {
		allocator.free(out_buf);
		return CodecError.DecompressFailed;
	}

	return out_buf;
}

/// Compress data using LZMA2.
/// Returns owned slice of LZMA2-compressed bytes.
pub fn compressLzma2(data: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
	return lzma2_enc.compress(data, allocator) catch |e| switch (e) {
		error.OutOfMemory => return error.OutOfMemory,
		else => unreachable, // encoder only allocates; no other runtime errors
	};
}

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

	const output = try decompressFolder(folder, input, 11, null, allocator);
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

	const output = try decompressFolder(folder, compressed, 13, null, allocator);
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
	const lzma2_data = try compressLzma2(&bcj_buf, allocator);
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

	const output = try decompressFolder(folder, lzma2_data, 64, null, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualSlices(u8, &input, output);
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

	try std.testing.expectError(CodecError.UnsupportedMethod, decompressFolder(folder, &.{}, 0, null, allocator));
}
