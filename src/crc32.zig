//! CRC-32 as used by the 7z format.
//!
//! Polynomial: 0xEDB88320 (reflected)
//! Initial value: 0xFFFFFFFF
//! Final XOR: 0xFFFFFFFF
//!
//! This is standard IEEE CRC-32 (ISO 3309 / ITU-T V.42).
//! Delegates to Zig stdlib's Crc32IsoHdlc which uses the same parameters.

const std = @import("std");

pub const Hasher = std.hash.crc.Crc32;

/// Compute CRC-32 over a byte slice (one-shot).
pub fn hash(data: []const u8) u32 {
    return Hasher.hash(data);
}

/// Incremental CRC-32 computation.
pub const State = struct {
    inner: Hasher,

    pub fn init() State {
        return .{ .inner = Hasher.init() };
    }

    pub fn update(self: *State, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: State) u32 {
        return self.inner.final();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CRC-32: empty input" {
    try std.testing.expectEqual(@as(u32, 0x00000000), hash(&.{}));
}

test "CRC-32: known value - ASCII 123456789" {
    // The canonical CRC-32 check value for "123456789" is 0xCBF43926
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hash("123456789"));
}

test "CRC-32: single byte 0x00" {
    try std.testing.expectEqual(@as(u32, 0xD202EF8D), hash(&[_]u8{0x00}));
}

test "CRC-32: start header CRC from TV-A" {
    // From spec TV-A (plain-copy-nohdr.7z):
    // StartHeaderCRC covers bytes 0x0C..0x1F (20 bytes)
    const header_payload = [_]u8{
        0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // NextHeaderOffset
        0x4A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // NextHeaderSize
        0xDD, 0xC7, 0x47, 0xD5, // NextHeaderCRC
    };
    // StartHeaderCRC = bytes 0x08..0x0B = D1 47 FD 58 (little-endian 0x58FD47D1)
    try std.testing.expectEqual(@as(u32, 0x58FD47D1), hash(&header_payload));
}

test "CRC-32: incremental matches one-shot" {
    const data = "Hello, 7z world!";
    const full = hash(data);

    var state = State.init();
    state.update(data[0..7]);
    state.update(data[7..]);

    try std.testing.expectEqual(full, state.final());
}
