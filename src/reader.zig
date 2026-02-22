//! Sequential byte reader over a slice.
//! Used for parsing 7z header structures from in-memory buffers.

const std = @import("std");
const varint = @import("varint.zig");
const nid_mod = @import("nid.zig");

pub const ReadError = error{
    EndOfStream,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn remaining(self: Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn readByte(self: *Reader) ReadError!u8 {
        if (self.pos >= self.data.len) return ReadError.EndOfStream;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.pos + n > self.data.len) return ReadError.EndOfStream;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    pub fn readU32Le(self: *Reader) ReadError!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    pub fn readU64Le(self: *Reader) ReadError!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    /// Read a 7z variable-length UINT64.
    pub fn readUint64(self: *Reader) ReadError!u64 {
        if (self.pos >= self.data.len) return ReadError.EndOfStream;
        const result = varint.decode(self.data[self.pos..]) catch return ReadError.EndOfStream;
        self.pos += result.bytes_read;
        return result.value;
    }

    /// Read a single byte and interpret as NID.
    pub fn readNid(self: *Reader) ReadError!nid_mod.Nid {
        const b = try self.readByte();
        return nid_mod.Nid.fromByte(b);
    }

    /// Skip `n` bytes.
    pub fn skip(self: *Reader, n: usize) ReadError!void {
        if (self.pos + n > self.data.len) return ReadError.EndOfStream;
        self.pos += n;
    }

    /// Read a BOOL_VECTOR(count) — count booleans packed MSB-first.
    pub fn readBoolVector(self: *Reader, count: usize, allocator: std.mem.Allocator) (ReadError || std.mem.Allocator.Error)![]bool {
        const byte_count = (count + 7) / 8;
        const bytes = try self.readBytes(byte_count);
        const result = try allocator.alloc(bool, count);
        for (0..count) |i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(7 - (i % 8));
            result[i] = (bytes[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
        }
        return result;
    }

    /// Read BOOL_VECTOR2(count) — prefix byte + optional BOOL_VECTOR.
    pub fn readBoolVector2(self: *Reader, count: usize, allocator: std.mem.Allocator) (ReadError || std.mem.Allocator.Error)![]bool {
        const all_defined = try self.readByte();
        if (all_defined != 0) {
            const result = try allocator.alloc(bool, count);
            @memset(result, true);
            return result;
        }
        return self.readBoolVector(count, allocator);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "reader: basic reads" {
    var r = Reader.init(&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 });

    try std.testing.expectEqual(@as(u8, 0x01), try r.readByte());
    try std.testing.expectEqual(@as(usize, 4), r.remaining());

    const bytes = try r.readBytes(2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x03 }, bytes);

    try std.testing.expectEqual(@as(usize, 2), r.remaining());
}

test "reader: readUint64 varint" {
    // 0x7F = 127 (single byte), 0x80 0x01 = 1 (two byte)
    var r = Reader.init(&[_]u8{ 0x7F, 0x80, 0x01 });

    try std.testing.expectEqual(@as(u64, 127), try r.readUint64());
    try std.testing.expectEqual(@as(u64, 1), try r.readUint64());
}

test "reader: readNid" {
    var r = Reader.init(&[_]u8{ 0x01, 0x06, 0x00 });

    try std.testing.expectEqual(nid_mod.Nid.header, try r.readNid());
    try std.testing.expectEqual(nid_mod.Nid.pack_info, try r.readNid());
    try std.testing.expectEqual(nid_mod.Nid.end, try r.readNid());
}

test "reader: EndOfStream" {
    var r = Reader.init(&[_]u8{0x01});
    _ = try r.readByte();
    try std.testing.expectError(ReadError.EndOfStream, r.readByte());
}

test "reader: readBoolVector" {
    const allocator = std.testing.allocator;
    // 3 bools packed in 1 byte: 0b10100000 = true, false, true
    var r = Reader.init(&[_]u8{0xA0});
    const bools = try r.readBoolVector(3, allocator);
    defer allocator.free(bools);

    try std.testing.expectEqual(true, bools[0]);
    try std.testing.expectEqual(false, bools[1]);
    try std.testing.expectEqual(true, bools[2]);
}

test "reader: readBoolVector2 all defined" {
    const allocator = std.testing.allocator;
    var r = Reader.init(&[_]u8{0x01}); // prefix != 0 → all true
    const bools = try r.readBoolVector2(4, allocator);
    defer allocator.free(bools);

    for (bools) |b| {
        try std.testing.expectEqual(true, b);
    }
}
