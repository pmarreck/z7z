//! Sequential byte writer into a growable buffer.
//! Used for encoding 7z header structures into memory.

const std = @import("std");
const varint_mod = @import("varint.zig");
const nid_mod = @import("nid.zig");

pub const Writer = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .buf = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn writeByte(self: *Writer, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    pub fn writeBytes(self: *Writer, data: []const u8) !void {
        try self.buf.appendSlice(self.allocator, data);
    }

    pub fn writeNid(self: *Writer, n: nid_mod.Nid) !void {
        try self.writeByte(@intFromEnum(n));
    }

    pub fn writeU32Le(self: *Writer, val: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, val, .little);
        try self.writeBytes(&bytes);
    }

    pub fn writeU64Le(self: *Writer, val: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, val, .little);
        try self.writeBytes(&bytes);
    }

    /// Write a 7z variable-length UINT64.
    pub fn writeUint64(self: *Writer, val: u64) !void {
        var encode_buf: [9]u8 = undefined;
        const n = varint_mod.encode(val, &encode_buf) catch unreachable;
        try self.writeBytes(encode_buf[0..n]);
    }

    /// Write a BOOL_VECTOR(count) — packed MSB-first.
    pub fn writeBoolVector(self: *Writer, flags: []const bool) !void {
        const byte_count = (flags.len + 7) / 8;
        for (0..byte_count) |bi| {
            var byte_val: u8 = 0;
            for (0..8) |bit| {
                const idx = bi * 8 + bit;
                if (idx < flags.len and flags[idx]) {
                    byte_val |= @as(u8, 1) << @as(u3, @intCast(7 - bit));
                }
            }
            try self.writeByte(byte_val);
        }
    }

    /// Write BOOL_VECTOR2(count) — prefix byte + optional BOOL_VECTOR.
    pub fn writeBoolVector2(self: *Writer, flags: []const bool) !void {
        // Check if all are true
        var all_true = true;
        for (flags) |f| {
            if (!f) {
                all_true = false;
                break;
            }
        }

        if (all_true) {
            try self.writeByte(1); // all defined
        } else {
            try self.writeByte(0);
            try self.writeBoolVector(flags);
        }
    }

    pub fn written(self: Writer) []const u8 {
        return self.buf.items;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "writer: basic writes" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    try w.writeByte(0x42);
    try w.writeBytes(&[_]u8{ 0x01, 0x02 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x42, 0x01, 0x02 }, w.written());
}

test "writer: writeUint64" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    try w.writeUint64(0);
    try w.writeUint64(127);
    try w.writeUint64(128);

    // 0 = 0x00, 127 = 0x7F, 128 = 0x80 0x80
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x7F, 0x80, 0x80 }, w.written());
}

test "writer: writeNid" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    try w.writeNid(.header);
    try w.writeNid(.end);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00 }, w.written());
}

test "writer: writeBoolVector2 all true" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    try w.writeBoolVector2(&[_]bool{ true, true, true });
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, w.written());
}

test "writer: writeBoolVector2 mixed" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();

    // false, true, true → prefix 0x00, then bool vector 0b01100000 = 0x60
    try w.writeBoolVector2(&[_]bool{ false, true, true });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x60 }, w.written());
}
