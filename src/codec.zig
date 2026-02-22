//! Codec dispatch: decompress packed data for a folder's coder pipeline.
//!
//! Wraps Zig stdlib decompressors (std.compress.lzma2, etc.)
//! to keep the archive module codec-agnostic.

const std = @import("std");
const meta = @import("metadata.zig");
const lzma2_enc = @import("lzma2_encoder.zig");

pub const CodecError = error{
	UnsupportedMethod,
	DecompressFailed,
	OutOfMemory,
};

/// Known method IDs.
const METHOD_COPY: u8 = 0x00;
const METHOD_LZMA2: u8 = 0x21;
const METHOD_LZMA: [3]u8 = .{ 0x03, 0x01, 0x01 };

/// Decompress packed data for a single-coder folder.
/// Returns owned slice of decompressed bytes.
pub fn decompressFolder(
	folder: anytype,
	packed_data: []const u8,
	unpack_size: u64,
	allocator: std.mem.Allocator,
) CodecError![]u8 {
	if (folder.coders.len != 1) return CodecError.UnsupportedMethod;

	const coder = folder.coders[0];
	const mid = coder.method_id;

	if (mid.len == 1 and mid[0] == METHOD_COPY) {
		return decodeCopy(packed_data, allocator);
	} else if (mid.len == 1 and mid[0] == METHOD_LZMA2) {
		return decodeLzma2(packed_data, unpack_size, allocator);
	} else if (mid.len == 3 and mid[0] == METHOD_LZMA[0] and mid[1] == METHOD_LZMA[1] and mid[2] == METHOD_LZMA[2]) {
		return decodeLzma(packed_data, unpack_size, coder.properties, allocator);
	} else {
		return CodecError.UnsupportedMethod;
	}
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

	const n = decomp.reader().readAll(out_buf) catch return CodecError.DecompressFailed;
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
pub fn compressLzma2(data: []const u8, allocator: std.mem.Allocator) CodecError![]u8 {
	return lzma2_enc.compress(data, allocator) catch return CodecError.OutOfMemory;
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

	const output = try decompressFolder(folder, input, 11, allocator);
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

	const output = try decompressFolder(folder, compressed, 13, allocator);
	defer allocator.free(output);
	try std.testing.expectEqualStrings(expected, output);
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

	try std.testing.expectError(CodecError.UnsupportedMethod, decompressFolder(folder, &.{}, 0, allocator));
}
