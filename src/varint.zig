//! 7z variable-length UINT64 encoding (spec section 2.2).
//!
//! First byte prefix determines length:
//!   0xxxxxxx         → 1 byte,  value = 7 payload bits
//!   10xxxxxx + 1B    → 2 bytes, value = (6 bits << 8) + extra[0]
//!   110xxxxx + 2B    → 3 bytes, value = (5 bits << 16) + extra[0..1] LE
//!   ...
//!   11111110 + 7B    → 8 bytes, value = extra[0..6] LE
//!   11111111 + 8B    → 9 bytes, value = extra[0..7] LE

const std = @import("std");

pub const DecodeError = error{
    EndOfStream,
};

pub const EncodeError = error{
    BufferTooSmall,
};

/// Decode a 7z variable UINT64 from a byte slice.
/// Returns the decoded value and the number of bytes consumed.
pub fn decode(data: []const u8) DecodeError!struct { value: u64, bytes_read: u8 } {
    if (data.len == 0) return DecodeError.EndOfStream;

    const b0 = data[0];

    // Count leading 1 bits in b0
    var extra_bytes: u8 = 0;
    {
        var mask: u8 = 0x80;
        while (mask != 0 and (b0 & mask) != 0) : (mask >>= 1) {
            extra_bytes += 1;
        }
    }

    // 0xFF → 8 extra bytes (full 64-bit value follows)
    if (extra_bytes == 8) {
        if (data.len < 9) return DecodeError.EndOfStream;
        var value: u64 = 0;
        for (0..8) |i| {
            value |= @as(u64, data[1 + i]) << @as(u6, @intCast(i * 8));
        }
        return .{ .value = value, .bytes_read = 9 };
    }

    const total_bytes: u8 = extra_bytes + 1;
    if (data.len < total_bytes) return DecodeError.EndOfStream;

    // Extract payload bits from b0 (7 - extra_bytes bits)
    const payload_bits: u3 = @intCast(7 - extra_bytes);
    const payload_mask: u8 = (@as(u8, 1) << payload_bits) - 1;
    var value: u64 = @as(u64, b0 & payload_mask);

    // Shift payload up to make room for extra bytes
    if (extra_bytes > 0) {
        value <<= @as(u6, @intCast(extra_bytes * 8));
    }

    // Add extra bytes (little-endian)
    for (0..extra_bytes) |i| {
        value |= @as(u64, data[1 + i]) << @as(u6, @intCast(i * 8));
    }

    return .{ .value = value, .bytes_read = total_bytes };
}

/// Returns the number of bytes needed to encode a value.
pub fn encodedSize(value: u64) u8 {
    if (value < 0x80) return 1; // 7 bits
    if (value < 0x4000) return 2; // 14 bits
    if (value < 0x200000) return 3; // 21 bits
    if (value < 0x10000000) return 4; // 28 bits
    if (value < 0x0800000000) return 5; // 35 bits
    if (value < 0x040000000000) return 6; // 42 bits
    if (value < 0x02000000000000) return 7; // 49 bits
    if (value < 0x0100000000000000) return 8; // 56 bits
    return 9;
}

/// Encode a u64 into 7z variable UINT64 format.
/// Returns the number of bytes written.
pub fn encode(value: u64, buf: []u8) EncodeError!u8 {
    const size = encodedSize(value);
    if (buf.len < size) return EncodeError.BufferTooSmall;

    if (size == 1) {
        buf[0] = @intCast(value);
        return 1;
    }

    if (size == 9) {
        buf[0] = 0xFF;
        for (0..8) |i| {
            buf[1 + i] = @intCast((value >> @as(u6, @intCast(i * 8))) & 0xFF);
        }
        return 9;
    }

    const extra_bytes: u8 = size - 1;

    // Write extra bytes (little-endian, low bytes of value)
    for (0..extra_bytes) |i| {
        buf[1 + i] = @intCast((value >> @as(u6, @intCast(i * 8))) & 0xFF);
    }

    // First byte: prefix (extra_bytes leading 1s + 0) | high payload bits
    const high_value: u8 = @intCast(value >> @as(u6, @intCast(extra_bytes * 8)));
    const prefix: u8 = @as(u8, 0xFF) << @as(u3, @intCast(8 - extra_bytes));
    buf[0] = prefix | high_value;

    return size;
}

// ============================================================================
// Tests
// ============================================================================

test "varint decode: single byte (0..127)" {
    const r0 = try decode(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u64, 0), r0.value);
    try std.testing.expectEqual(@as(u8, 1), r0.bytes_read);

    const r127 = try decode(&[_]u8{0x7F});
    try std.testing.expectEqual(@as(u64, 127), r127.value);
    try std.testing.expectEqual(@as(u8, 1), r127.bytes_read);

    const r1 = try decode(&[_]u8{0x01});
    try std.testing.expectEqual(@as(u64, 1), r1.value);
    try std.testing.expectEqual(@as(u8, 1), r1.bytes_read);
}

test "varint decode: two bytes (10xxxxxx)" {
    // 0x80 0x01 → (0 << 8) + 1 = 1
    const r1 = try decode(&[_]u8{ 0x80, 0x01 });
    try std.testing.expectEqual(@as(u64, 1), r1.value);
    try std.testing.expectEqual(@as(u8, 2), r1.bytes_read);

    // 0x80 0x80 → (0 << 8) + 0x80 = 128
    const r128 = try decode(&[_]u8{ 0x80, 0x80 });
    try std.testing.expectEqual(@as(u64, 128), r128.value);
    try std.testing.expectEqual(@as(u8, 2), r128.bytes_read);

    // 0xBF 0xFF → (0x3F << 8) + 0xFF = 0x3FFF = 16383
    const rmax2 = try decode(&[_]u8{ 0xBF, 0xFF });
    try std.testing.expectEqual(@as(u64, 0x3FFF), rmax2.value);
    try std.testing.expectEqual(@as(u8, 2), rmax2.bytes_read);
}

test "varint decode: nine bytes (0xFF prefix)" {
    const data = [_]u8{ 0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const r = try decode(&data);
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), r.value);
    try std.testing.expectEqual(@as(u8, 9), r.bytes_read);
}

test "varint decode: max value (0xFFFFFFFFFFFFFFFF)" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const r = try decode(&data);
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), r.value);
    try std.testing.expectEqual(@as(u8, 9), r.bytes_read);
}

test "varint decode: EndOfStream on truncated input" {
    const result = decode(&[_]u8{0x80});
    try std.testing.expectError(DecodeError.EndOfStream, result);
}

test "varint decode: EndOfStream on empty input" {
    const result = decode(&[_]u8{});
    try std.testing.expectError(DecodeError.EndOfStream, result);
}

test "varint encode: roundtrip" {
    var buf: [9]u8 = undefined;

    const test_values = [_]u64{
        0,
        1,
        127,
        128,
        255,
        256,
        16383,
        16384,
        0xFFFF,
        0xFFFFFF,
        0xFFFFFFFF,
        0xFFFFFFFFFF,
        0xFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
    };

    for (test_values) |val| {
        const n = try encode(val, &buf);
        const decoded = try decode(buf[0..n]);
        try std.testing.expectEqual(val, decoded.value);
        try std.testing.expectEqual(n, decoded.bytes_read);
    }
}

test "varint encodedSize: correct sizes" {
    try std.testing.expectEqual(@as(u8, 1), encodedSize(0));
    try std.testing.expectEqual(@as(u8, 1), encodedSize(127));
    try std.testing.expectEqual(@as(u8, 2), encodedSize(128));
    try std.testing.expectEqual(@as(u8, 2), encodedSize(0x3FFF));
    try std.testing.expectEqual(@as(u8, 3), encodedSize(0x4000));
    try std.testing.expectEqual(@as(u8, 3), encodedSize(0x1FFFFF));
    try std.testing.expectEqual(@as(u8, 4), encodedSize(0x200000));
    try std.testing.expectEqual(@as(u8, 9), encodedSize(0xFFFFFFFFFFFFFFFF));
}

test "varint encode: buffer too small" {
    var buf: [0]u8 = .{};
    try std.testing.expectError(EncodeError.BufferTooSmall, encode(0, &buf));
}
