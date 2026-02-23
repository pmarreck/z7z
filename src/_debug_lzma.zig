const std = @import("std");
const lzma2 = @import("lzma2_encoder.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Minimal failing input
    const input = "quick the jumps fox fox brown quick and quick cat lazy";

    // Compress with our encoder
    const compressed = try lzma2.compress(input, alloc);
    defer alloc.free(compressed);

    std.debug.print("Input: {d} bytes\n", .{input.len});
    std.debug.print("Compressed: {d} bytes\n", .{compressed.len});
    std.debug.print("Hex: ", .{});
    for (compressed) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n\n", .{});

    // Try to decompress with stdlib
    var in_stream = std.io.fixedBufferStream(compressed);
    var out_buf: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    std.compress.lzma2.decompress(alloc, in_stream.reader(), out_stream.writer()) catch |e| {
        std.debug.print("Decompress error: {}\n", .{e});
        std.debug.print("Decompressed so far: {d} bytes: \"{s}\"\n", .{ out_stream.pos, out_stream.getWritten() });
        return;
    };
    std.debug.print("Decompressed: {d} bytes: \"{s}\"\n", .{ out_stream.pos, out_stream.getWritten() });

    // Compare
    if (std.mem.eql(u8, input, out_stream.getWritten())) {
        std.debug.print("MATCH!\n", .{});
    } else {
        std.debug.print("MISMATCH!\n", .{});
        std.debug.print("Expected: \"{s}\"\n", .{input});
    }
}
