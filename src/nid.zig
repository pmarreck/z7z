//! 7z Node/Property IDs (spec section 2.3).

pub const Nid = enum(u8) {
    end = 0x00,
    header = 0x01,
    archive_properties = 0x02,
    additional_streams_info = 0x03,
    main_streams_info = 0x04,
    files_info = 0x05,
    pack_info = 0x06,
    unpack_info = 0x07,
    sub_streams_info = 0x08,
    size = 0x09,
    crc = 0x0A,
    folder = 0x0B,
    coders_unpack_size = 0x0C,
    num_unpack_stream = 0x0D,
    empty_stream = 0x0E,
    empty_file = 0x0F,
    anti = 0x10,
    name = 0x11,
    c_time = 0x12,
    a_time = 0x13,
    m_time = 0x14,
    win_attrib = 0x15,
    comment = 0x16,
    encoded_header = 0x17,
    start_pos = 0x18,
    dummy = 0x19,
    _,

    pub fn fromByte(b: u8) Nid {
        return @enumFromInt(b);
    }
};

const std = @import("std");

test "nid: known values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Nid.end));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(Nid.header));
    try std.testing.expectEqual(@as(u8, 0x17), @intFromEnum(Nid.encoded_header));
    try std.testing.expectEqual(@as(u8, 0x19), @intFromEnum(Nid.dummy));
}

test "nid: unknown value preserved" {
    const unknown = Nid.fromByte(0xFE);
    try std.testing.expectEqual(@as(u8, 0xFE), @intFromEnum(unknown));
}
