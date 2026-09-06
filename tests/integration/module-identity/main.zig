const std = @import("std");
const z7z = @import("z7z");
const bzip2 = @import("bzip2z").bzip2;

pub fn main() !void {
	// Empty bzip2 stream, independently specified header and end marker.
	const compressed = "BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00";
	const allocator = std.heap.page_allocator;
	const decoder = try allocator.create(bzip2.Decompressor);
	defer allocator.destroy(decoder);
	decoder.* = try bzip2.Decompressor.init(allocator);
	defer decoder.deinit();
	const coder = .{ .method_id = @as([]const u8, &.{ 4, 2, 2 }), .properties = @as([]const u8, &.{}), .num_in_streams = @as(u64, 1), .num_out_streams = @as(u64, 1) };
	const folder = .{ .coders = &.{coder} };
	const output = try z7z.codec.decompressFolder(folder, compressed, &.{compressed.len}, 0, null, allocator);
	defer allocator.free(output);
	if (output.len != 0) return error.UnexpectedOutput;
}
