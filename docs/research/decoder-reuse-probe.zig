const std = @import("std");
const meta = @import("seven").metadata;
const header = @import("seven").header;
const fingerprint = @import("fingerprint");
const bzip2 = @import("bzip2");
const a = std.testing.allocator;
const io = std.testing.io;

fn oracle(argv: []const []const u8) !void {
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

fn pack(data: []const u8, method: []const u8) ![]u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "data", .data = data });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const input = try std.fmt.allocPrint(a, "{s}/data", .{root});
    defer a.free(input);
    const output = try std.fmt.allocPrint(a, "{s}/data.7z", .{root});
    defer a.free(output);
    const option = try std.fmt.allocPrint(a, "-m0={s}", .{method});
    defer a.free(option);
    try oracle(&.{ "7zz", "a", "-t7z", "-mhc=off", "-mmt=1", option, output, input });
    try oracle(&.{ "7zz", "t", output });
    const bytes = try tmp.dir.readFileAlloc(io, "data.7z", a, .limited(16 * 1024 * 1024));
    defer a.free(bytes);
    const sig = try header.parse(bytes);
    const start: usize = @intCast(sig.nextHeaderAbsoluteOffset());
    var metadata = try meta.parseNextHeader(bytes[start..], a);
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 1), metadata.folders.len);
    try std.testing.expectEqual(@as(usize, 1), metadata.folders[0].coders.len);
    const expected_id: []const u8 = if (std.mem.eql(u8, method, "Deflate")) &.{ 4, 1, 8 } else if (std.mem.eql(u8, method, "Deflate64")) &.{ 4, 1, 9 } else &.{ 4, 2, 2 };
    try std.testing.expectEqualSlices(u8, expected_id, metadata.folders[0].coders[0].method_id);
    const info = metadata.pack_info.?;
    try std.testing.expectEqual(@as(usize, 1), info.pack_sizes.len);
    const offset: usize = @intCast(32 + info.pack_pos);
    return a.dupe(u8, bytes[offset..][0..@intCast(info.pack_sizes[0])]);
}

fn stdDecode(compressed: []const u8, expected: []const u8, indirect: bool, chunk_size: usize) !void {
    var input = std.Io.Reader.fixed(compressed);
    const window = try a.alloc(u8, if (indirect) std.compress.flate.max_window_len else 0);
    defer a.free(window);
    var dec = std.compress.flate.Decompress.init(&input, .raw, window);
    if (!indirect) {
        const actual = try dec.reader.allocRemaining(a, .limited(expected.len + 1));
        defer a.free(actual);
        try std.testing.expectEqualSlices(u8, expected, actual);
    } else {
        const chunk = try a.alloc(u8, chunk_size);
        defer a.free(chunk);
        var offset: usize = 0;
        while (true) {
            const n = try dec.reader.readSliceShort(chunk);
            if (n == 0) break;
            try std.testing.expect(offset + n <= expected.len);
            try std.testing.expectEqualSlices(u8, expected[offset..][0..n], chunk[0..n]);
            offset += n;
        }
        try std.testing.expectEqual(expected.len, offset);
    }
}

test "probe: std Deflate direct and bounded indirect match oracle" {
    for ([_]usize{ 1, 257, 32768, 65536, 262144, 1048576 }) |len| {
        const data = try a.alloc(u8, len);
        defer a.free(data);
        for (0..3) |kind| {
            var prng = std.Random.DefaultPrng.init(0x7def1a7e);
            prng.random().bytes(data);
            if (kind == 0) @memset(data, 'A');
            if (kind == 1) for (data, 0..) |*byte, i| { if (i % 256 < 240) byte.* = @truncate(i % 13); };
            const compressed = try pack(data, "Deflate");
            defer a.free(compressed);
            try stdDecode(compressed, data, false, 0);
            for ([_]usize{ 1, 257, 4096, 65536 }) |chunk| try stdDecode(compressed, data, true, chunk);
        }
    }
}

test "probe: std rejects malformed raw Deflate and all hello truncations" {
    const hello = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    try stdDecode(&hello, "hello", false, 0);
    for (0..hello.len) |n| {
        if (stdDecode(hello[0..n], "hello", false, 0)) |_| return error.AcceptedTruncatedStream else |_| {}
    }
    // Fixed Huffman length=3, distance=1 before any literal: invalid history.
    for ([_][]const u8{ &.{0x07}, &.{ 0x03, 0x02, 0x00 } }) |bad| {
        var input = std.Io.Reader.fixed(bad);
        var dec = std.compress.flate.Decompress.init(&input, .raw, &.{});
        if (dec.reader.allocRemaining(a, .limited(64))) |bytes| {
            a.free(bytes);
            return error.AcceptedInvalidStream;
        } else |_| {}
    }
}

test "probe: fingerprint inspector rejects an impossible backreference" {
    const tokens = fingerprint.inspectTokens(a, &.{ 0x03, 0x02, 0x00 }) catch return;
    defer a.free(tokens);
    return error.AcceptedInvalidBackreference;
}

test "probe: std rejects a Deflate64 long-distance witness" {
    const data = try a.alloc(u8, 98304);
    defer a.free(data);
    var prng = std.Random.DefaultPrng.init(0x7def1a7e);
    prng.random().bytes(data[0..49152]);
    @memcpy(data[49152..], data[0..49152]);
    const compressed = try pack(data, "Deflate64");
    defer a.free(compressed);
    try std.testing.expect(compressed.len < data.len * 3 / 4);
    var input = std.Io.Reader.fixed(compressed);
    var dec = std.compress.flate.Decompress.init(&input, .raw, &.{});
    if (dec.reader.allocRemaining(a, .limited(data.len + 1))) |decoded| {
        defer a.free(decoded);
        try std.testing.expect(!std.mem.eql(u8, data, decoded));
    } else |_| {}
}

test "probe: original Zig issue 24963 ZIP extracts on pinned toolchain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture_path = std.mem.span(std.c.getenv("Z7Z_PROBE_QSV_ZIP") orelse return error.MissingRegressionFixture);
    const file = try std.Io.Dir.cwd().openFile(io, fixture_path, .{});
    defer file.close(io);
    const buffer = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(buffer);
    var reader = file.reader(io, buffer);
    try std.zip.extract(tmp.dir, &reader, .{});
}

const ComparingSink = struct {
    expected: []const u8,
    offset: usize = 0,
    max_write: usize = std.math.maxInt(usize),

    pub fn write(self: *@This(), data: []const u8) !usize {
        const n = @min(data.len, self.max_write);
        try std.testing.expect(self.offset + n <= self.expected.len);
        try std.testing.expectEqualSlices(u8, self.expected[self.offset..][0..n], data[0..n]);
        self.offset += n;
        return n;
    }
};

const ShortSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    chunk_size: usize,
    reader: std.Io.Reader,

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *@This() = @fieldParentPtr("reader", r);
        if (self.offset == self.bytes.len) return error.EndOfStream;
        const n = limit.minInt(@min(self.chunk_size, self.bytes.len - self.offset));
        try w.writeAll(self.bytes[self.offset..][0..n]);
        self.offset += n;
        return n;
    }
};

test "probe: std supports short compressed-input refills with bounded output" {
    const data = try a.alloc(u8, 131072);
    defer a.free(data);
    var prng = std.Random.DefaultPrng.init(0x7def1a7e);
    prng.random().bytes(data[0..32768]);
    for (1..4) |i| @memcpy(data[i * 32768 ..][0..32768], data[0..32768]);
    const compressed = try pack(data, "Deflate");
    defer a.free(compressed);
    const input_buffer = try a.alloc(u8, 32);
    defer a.free(input_buffer);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    const output_buffer = try a.alloc(u8, 257);
    defer a.free(output_buffer);
    for ([_]usize{ 1, 7, 31 }) |n| {
        var input = ShortSource{
            .bytes = compressed,
            .chunk_size = n,
            .reader = .{ .vtable = &.{ .stream = ShortSource.stream }, .buffer = input_buffer, .seek = 0, .end = 0 },
        };
        var decoder = std.compress.flate.Decompress.init(&input.reader, .raw, window);
        var sink = ComparingSink{ .expected = data };
        while (true) {
            const read = try decoder.reader.readSliceShort(output_buffer);
            if (read == 0) break;
            _ = try sink.write(output_buffer[0..read]);
        }
        try std.testing.expectEqual(data.len, sink.offset);
    }
}

test "probe: bzip2z reads oracle 7z BZip2 payload" {
    const data = try a.alloc(u8, 2 * 1024 * 1024);
    defer a.free(data);
    var prng = std.Random.DefaultPrng.init(0x7def1a7e);
    prng.random().bytes(data);
    const compressed = try pack(data, "BZip2");
    defer a.free(compressed);
    var reader = std.Io.Reader.fixed(compressed);
    var sink = ComparingSink{ .expected = data };
    var decoder = try bzip2.Decompressor.init(a);
    defer decoder.deinit();
    try decoder.decompress(&reader, &sink);
    try std.testing.expectEqual(data.len, sink.offset);
}

test "probe: bzip2z retries short sink writes" {
    const data = "short output must not be lost" ** 1024;
    const compressed = try pack(data, "BZip2");
    defer a.free(compressed);
    var reader = std.Io.Reader.fixed(compressed);
    var sink = ComparingSink{ .expected = data, .max_write = 7 };
    var decoder = try bzip2.Decompressor.init(a);
    defer decoder.deinit();
    try decoder.decompress(&reader, &sink);
    try std.testing.expectEqual(data.len, sink.offset);
}

test "probe: bzip2z repeated data expands its block allocation" {
    const data = try a.alloc(u8, 4 * 1024 * 1024);
    defer a.free(data);
    @memset(data, 'A');
    const compressed = try pack(data, "BZip2");
    defer a.free(compressed);
    var reader = std.Io.Reader.fixed(compressed);
    var sink = ComparingSink{ .expected = data };
    var decoder = try bzip2.Decompressor.init(a);
    defer decoder.deinit();
    try decoder.decompress(&reader, &sink);
    try std.testing.expectEqual(data.len, sink.offset);
    try std.testing.expect(decoder.block.len >= data.len);
    try std.testing.expect(decoder.output.len >= data.len);
}
