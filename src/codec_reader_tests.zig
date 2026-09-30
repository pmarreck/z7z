const std = @import("std");
const codec = @import("codec.zig");
const meta = @import("metadata.zig");

// xz --format=raw --lzma1=lc=3,lp=0,pb=2,dict=64KiB, input below.
const plain = "Hello streaming LZMA!\n";
const compressed = &[_]u8{
	0x00, 0x24, 0x19, 0x49, 0x98, 0x6f, 0x10, 0x18, 0xc7, 0xbe, 0x65, 0x4a, 0xc6, 0xfe, 0xd4, 0x1e,
	0x0b, 0x15, 0x8e, 0x0e, 0x04, 0xba, 0x35, 0x36, 0xeb, 0x0e, 0xed, 0x9f, 0xff, 0xf9, 0x42, 0x80, 0x00,
};
const coder: meta.Coder = .{ .method_id = &.{ 3, 1, 1 }, .properties = &.{ 0x5d, 0, 0, 1, 0 }, .num_in_streams = 1, .num_out_streams = 1 };

test "reader codec: LZMA exact output and compressed boundary" {
	var reader: std.Io.Reader = .fixed(compressed ++ "NEXT");
	var bytes: [plain.len]u8 = undefined;
	var writer: std.Io.Writer = .fixed(&bytes);
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(coder, &reader, &writer, compressed.len, plain.len, .{ .require_lzma_end_marker = true }, &diagnostic, std.testing.allocator);
	try std.testing.expectEqualStrings(plain, writer.buffered());
	try std.testing.expectEqual(compressed.len, diagnostic.input_byte_offset);
	try std.testing.expectEqualStrings("NEXT", reader.buffered());
}

test "reader codec: LZMA rejects every truncated prefix and output size mismatch" {
	for (0..compressed.len) |end| {
		var reader: std.Io.Reader = .fixed(compressed[0..end]);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var diagnostic: codec.CoderDiagnostic = .{};
		try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len, plain.len, .{ .require_lzma_end_marker = true }, &diagnostic, std.testing.allocator));
		try std.testing.expect(diagnostic.input_byte_offset <= end);
	}
	for ([_]u64{ 0, plain.len - 1, plain.len + 1 }) |size| {
		var reader: std.Io.Reader = .fixed(compressed);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var diagnostic: codec.CoderDiagnostic = .{};
		try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len, size, .{}, &diagnostic, std.testing.allocator));
	}
}

test "reader codec: LZMA trailing data and failing writer" {
	var reader: std.Io.Reader = .fixed(compressed ++ "x");
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var diagnostic: codec.CoderDiagnostic = .{};
	try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len + 1, plain.len, .{}, &diagnostic, std.testing.allocator));
	reader = .fixed(compressed);
	var failing = std.Io.Writer.failing;
	try std.testing.expectError(error.WriteFailed, codec.verifySingleCoder(coder, &reader, &failing, compressed.len, plain.len, .{}, &diagnostic, std.testing.allocator));
}

test "reader codec: LZMA marker policy and fragmented input" {
	// Raw 28-byte payload from 7zz 26.02: a -m0=LZMA -md=64k -mhc=off.
	const no_marker = compressed[0..24].* ++ [_]u8{ 0xd8, 0xf5, 0, 0 };
	for ([_]bool{ false, true }) |required| {
		var reader: std.Io.Reader = .fixed(&no_marker);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var diagnostic: codec.CoderDiagnostic = .{};
		const result = codec.verifySingleCoder(coder, &reader, &writer.writer, no_marker.len, plain.len, .{ .require_lzma_end_marker = required }, &diagnostic, std.testing.allocator);
		if (required) try std.testing.expectError(error.DecompressFailed, result) else {
			try result;
			try std.testing.expectEqual(plain.len, writer.fullCount());
		}
	}
	for ([_]usize{ 1, 2, 3, 7, 4096 }) |fragment| {
		var reader: std.testing.Reader = .init(&.{}, &.{.{ .buffer = compressed }});
		reader.artificial_limit = .limited(fragment);
		var output: [plain.len]u8 = undefined;
		var writer: std.Io.Writer = .fixed(&output);
		var diagnostic: codec.CoderDiagnostic = .{};
		try codec.verifySingleCoder(coder, &reader.interface, &writer, compressed.len, plain.len, .{}, &diagnostic, std.testing.allocator);
		try std.testing.expectEqualStrings(plain, writer.buffered());
	}
}

const BrokenReader = struct {
	fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
		return error.ReadFailed;
	}
};

test "reader codec: errors and prefetch independent failure locations" {
	var reader: std.Io.Reader = .{ .vtable = &.{ .stream = BrokenReader.stream }, .buffer = &.{}, .seek = 0, .end = 0 };
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var diagnostic: codec.CoderDiagnostic = .{ .input_byte_offset = 999 };
	try std.testing.expectError(error.ReadFailed, codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len, plain.len, .{}, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(0, diagnostic.input_byte_offset);
	var bad = compressed.*;
	bad[0] = 1;
	reader = .fixed(&bad);
	try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(coder, &reader, &writer.writer, bad.len, plain.len, .{}, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(1, diagnostic.input_byte_offset);
	try std.testing.expectEqual(0, diagnostic.input_bit_offset);
	reader = .fixed(compressed);
	try std.testing.expectError(error.ResourceLimitExceeded, codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len, plain.len, .{ .max_dictionary_size = 1 }, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(0, reader.seek);
}

fn allocationProbe(allocator: std.mem.Allocator) !void {
	var reader: std.Io.Reader = .fixed(compressed);
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(coder, &reader, &writer.writer, compressed.len, plain.len, .{}, &diagnostic, allocator);
}

test "reader codec: all LZMA allocation failures release ownership" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}

test "reader codec: LZMA dictionaries below 4 KiB use the format minimum" {
	// xz 5.8.3, raw LZMA1, 4 KiB dictionary, input "abc" repeated 100 times.
	const repeated = &[_]u8{ 0x00, 0x30, 0x98, 0x88, 0xad, 0x4b, 0x36, 0xed, 0x2f, 0x80, 0x7b, 0xff, 0xff, 0xf6, 0xb0, 0x40, 0x00 };
	var small_dictionary = coder;
	small_dictionary.properties = &.{ 0x5d, 0, 0, 0, 0 };
	var reader: std.Io.Reader = .fixed(repeated);
	var output: [300]u8 = undefined;
	var writer: std.Io.Writer = .fixed(&output);
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(small_dictionary, &reader, &writer, repeated.len, 300, .{}, &diagnostic, std.testing.allocator);
	try std.testing.expectEqualStrings("abc" ** 100, writer.buffered());
}

test "reader codec: LZMA exceeds old decoded ceiling with bounded allocation" {
	const data = @embedFile("fixtures/reader-codec/zeros-257m.lzma");
	const budget = try std.testing.allocator.alloc(u8, 128 * 1024);
	defer std.testing.allocator.free(budget);
	var fixed: std.heap.FixedBufferAllocator = .init(budget);
	var reader: std.testing.Reader = .init(&.{}, &.{.{ .buffer = data }});
	reader.artificial_limit = .limited(127);
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var crc_writer: std.Io.Writer.Hashed(std.hash.Crc32) = .initHasher(&writer.writer, .init(), &.{});
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(coder, &reader.interface, &crc_writer.writer, data.len, 257 * 1024 * 1024, .{ .require_lzma_end_marker = true }, &diagnostic, fixed.allocator());
	try std.testing.expectEqual(257 * 1024 * 1024, writer.fullCount());
	// Independently obtained from gzip's CRC trailer for 269484032 zero bytes.
	try std.testing.expectEqual(@as(u32, 0xc43bd235), crc_writer.hasher.final());
	try std.testing.expectEqual(data.len, diagnostic.input_byte_offset);
}

const deflate_coder: meta.Coder = .{ .method_id = &.{ 4, 1, 9 }, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };

const empty_lzma = &[_]u8{ 0, 0x83, 0xff, 0xfb, 0xff, 0xff, 0xc0, 0, 0, 0 };

test "reader codec: classify all LZMA property bytes" {
	for (0..256) |property| {
		var properties = [_]u8{ @intCast(property), 0, 0x10, 0, 0 };
		var variant = coder;
		variant.properties = &properties;
		var reader: std.Io.Reader = .fixed(empty_lzma);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var diagnostic: codec.CoderDiagnostic = .{};
		const result = codec.verifySingleCoder(variant, &reader, &writer.writer, empty_lzma.len, 0, .{ .require_lzma_end_marker = true }, &diagnostic, std.testing.allocator);
		if (property < 225) try result else try std.testing.expectError(error.DecompressFailed, result);
		try std.testing.expectEqual(0, writer.fullCount());
	}
}

fn largePropertiesProbe(allocator: std.mem.Allocator) !void {
	// 7zz 26.02: a -m0=LZMA:lc=8:lp=4 -md=4k -mhc=off, same plain text.
	const raw = &[_]u8{
		0, 0x24, 0x19, 0x49, 0x98, 0x6f, 0x10, 0x1c, 0xce, 0x13, 0x21, 0x7a, 0x0b, 0x24, 0x50, 0x1e,
		0x53, 0x7f, 0xbe, 0x44, 0x87, 0xf3, 0x5e, 0x5c, 0x3b, 0x21, 0x80, 0,
	};
	var variant = coder;
	variant.properties = &.{ 0x86, 0, 0x10, 0, 0 };
	var reader: std.Io.Reader = .fixed(raw);
	var output: [plain.len]u8 = undefined;
	var writer: std.Io.Writer = .fixed(&output);
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(variant, &reader, &writer, raw.len, plain.len, .{}, &diagnostic, allocator);
	try std.testing.expectEqualStrings(plain, writer.buffered());
}

test "reader codec: large LZMA literal tables decode and release allocation failures" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, largePropertiesProbe, .{});
}

test "reader codec: LZMA read failures after every prefix retain logical cursor" {
	for (0..compressed.len) |n| {
		var bytes = compressed.*;
		var failing: std.Io.Reader = .failing;
		failing.buffer = &bytes;
		failing.end = n;
		var truncated: std.Io.Reader = .fixed(compressed[0..n]);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var first: codec.CoderDiagnostic = .{};
		var second: codec.CoderDiagnostic = .{};
		try std.testing.expectError(error.ReadFailed, codec.verifySingleCoder(coder, &failing, &writer.writer, compressed.len, plain.len, .{ .require_lzma_end_marker = true }, &first, std.testing.allocator));
		try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(coder, &truncated, &writer.writer, compressed.len, plain.len, .{ .require_lzma_end_marker = true }, &second, std.testing.allocator));
		try std.testing.expectEqual(second, first);
	}
}

test "reader codec: LZMA late writer failure stops before decoded size" {
	const data = @embedFile("fixtures/reader-codec/zeros-257m.lzma");
	const output = try std.testing.allocator.alloc(u8, 16 * 1024);
	defer std.testing.allocator.free(output);
	var writer: std.Io.Writer = .fixed(output);
	var reader: std.Io.Reader = .fixed(data);
	var diagnostic: codec.CoderDiagnostic = .{};
	try std.testing.expectError(error.WriteFailed, codec.verifySingleCoder(coder, &reader, &writer, data.len, 257 * 1024 * 1024, .{}, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(output.len, writer.end);
	try std.testing.expect(diagnostic.input_byte_offset > 5);
	try std.testing.expect(diagnostic.input_byte_offset < data.len);
}

const StoredBlocks = struct {
	const block = [_]u8{ 0, 255, 255, 0, 0 } ++ [_]u8{0} ** 65535;
	const blocks = 1025;
	const packed_size = block.len * blocks;
	position: usize = 0,
	reader: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },

	fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
		const self: *@This() = @fieldParentPtr("reader", r);
		if (self.position == packed_size) return error.EndOfStream;
		const offset = self.position % block.len;
		const bytes: []const u8 = if (self.position == packed_size - block.len) &.{1} else block[offset..];
		const n = try w.write(limit.sliceConst(bytes));
		self.position += n;
		return n;
	}
};

test "reader codec: Deflate64 exceeds old packed ceiling with bounded allocation" {
	const budget = try std.testing.allocator.alloc(u8, 128 * 1024);
	defer std.testing.allocator.free(budget);
	var fixed: std.heap.FixedBufferAllocator = .init(budget);
	var source: StoredBlocks = .{};
	source.reader.buffer = try fixed.allocator().alloc(u8, 4096);
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var crc_writer: std.Io.Writer.Hashed(std.hash.Crc32) = .initHasher(&writer.writer, .init(), &.{});
	var diagnostic: codec.CoderDiagnostic = .{};
	try codec.verifySingleCoder(deflate_coder, &source.reader, &crc_writer.writer, 67178500, 67173375, .{}, &diagnostic, fixed.allocator());
	try std.testing.expectEqual(67173375, writer.fullCount());
	// Independently obtained from gzip's CRC trailer for 67173375 zero bytes.
	try std.testing.expectEqual(@as(u32, 0x9ff16341), crc_writer.hasher.final());
	try std.testing.expectEqual(67178500, diagnostic.input_byte_offset);
	try std.testing.expectEqual(0, diagnostic.input_bit_offset);
}

test "reader codec: Deflate64 errors retain bit locations and IO errors" {
	var reader: std.Io.Reader = .fixed(&.{7});
	var writer: std.Io.Writer.Discarding = .init(&.{});
	var diagnostic: codec.CoderDiagnostic = .{};
	try std.testing.expectError(error.DecompressFailed, codec.verifySingleCoder(deflate_coder, &reader, &writer.writer, 1, 0, .{}, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(0, diagnostic.input_byte_offset);
	try std.testing.expectEqual(3, diagnostic.input_bit_offset);
	reader = .failing;
	try std.testing.expectError(error.ReadFailed, codec.verifySingleCoder(deflate_coder, &reader, &writer.writer, 1, 0, .{}, &diagnostic, std.testing.allocator));
	try std.testing.expectEqual(0, diagnostic.input_bit_offset);
	const raw = @embedFile("fixtures/deflate64/fixed.raw");
	const expected = @embedFile("fixtures/deflate64/fixed.plain");
	reader = .fixed(raw);
	var failing = std.Io.Writer.failing;
	try std.testing.expectError(error.WriteFailed, codec.verifySingleCoder(deflate_coder, &reader, &failing, raw.len, expected.len, .{}, &diagnostic, std.testing.allocator));
}

test "reader codec: unsupported methods and coder graphs do not read input" {
	for ([_]meta.Coder{
		.{ .method_id = &.{0xff}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 },
		.{ .method_id = coder.method_id, .properties = coder.properties, .num_in_streams = 2, .num_out_streams = 1 },
	}) |unsupported| {
		var reader: std.Io.Reader = .fixed(compressed);
		var writer: std.Io.Writer.Discarding = .init(&.{});
		var diagnostic: codec.CoderDiagnostic = .{};
		try std.testing.expectError(error.UnsupportedMethod, codec.verifySingleCoder(unsupported, &reader, &writer.writer, compressed.len, plain.len, .{}, &diagnostic, std.testing.allocator));
		try std.testing.expectEqual(0, reader.seek);
	}
}
