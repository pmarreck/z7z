//! 7z header metadata encoder.
//!
//! Encodes ArchiveMetadata into the next-header byte stream.

const std = @import("std");
const nid = @import("nid.zig");
const varint = @import("varint.zig");
const Writer = @import("writer.zig").Writer;
const meta = @import("metadata.zig");

/// Encode ArchiveMetadata into a next-header byte stream.
pub fn encodeNextHeader(metadata_val: meta.ArchiveMetadata, allocator: std.mem.Allocator) ![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();

    try w.writeNid(.header);

    // MainStreamsInfo (if we have pack info or folders)
    if (metadata_val.pack_info != null or metadata_val.folders.len > 0) {
        try w.writeNid(.main_streams_info);
        try encodeMainStreamsInfo(&w, metadata_val);
        try w.writeNid(.end); // end MainStreamsInfo
    }

    // FilesInfo
    if (metadata_val.files.len > 0) {
        try encodeFilesInfo(&w, metadata_val);
    }

    try w.writeNid(.end); // end kHeader

    return w.toOwnedSlice();
}

fn encodeMainStreamsInfo(w: *Writer, m: meta.ArchiveMetadata) !void {
    // PackInfo
    if (m.pack_info) |pi| {
        try encodePackInfo(w, pi);
    }

    // UnpackInfo
    if (m.folders.len > 0) {
        try encodeUnpackInfo(w, m);
    }

    // SubStreamsInfo
    if (m.sub_streams) |ss| {
        try encodeSubStreamsInfo(w, ss, m.folders);
    }
}

fn encodePackInfo(w: *Writer, pi: meta.PackInfo) !void {
    try w.writeNid(.pack_info);
    try w.writeUint64(pi.pack_pos);
    try w.writeUint64(@intCast(pi.pack_sizes.len));

    if (pi.pack_sizes.len > 0) {
        try w.writeNid(.size);
        for (pi.pack_sizes) |s| {
            try w.writeUint64(s);
        }
    }

    if (pi.pack_crcs) |crcs| {
        try w.writeNid(.crc);
        try writeDigestVector(w, crcs);
    }

    try w.writeNid(.end);
}

fn encodeUnpackInfo(w: *Writer, m: meta.ArchiveMetadata) !void {
    try w.writeNid(.unpack_info);
    try w.writeNid(.folder);
    try w.writeUint64(@intCast(m.folders.len));
    try w.writeByte(0); // External = 0 (inline)

    // Folder records
    for (m.folders) |folder| {
        try encodeFolderRecord(w, folder);
    }

    // kCodersUnpackSize
    try w.writeNid(.coders_unpack_size);
    for (m.folders) |folder| {
        for (folder.unpack_sizes) |s| {
            try w.writeUint64(s);
        }
    }

    // Folder CRCs (if any are defined)
    var has_crc = false;
    for (m.folders) |folder| {
        if (folder.unpack_crc != null) {
            has_crc = true;
            break;
        }
    }
    if (has_crc) {
        try w.writeNid(.crc);
        // Build digest vector
        var crcs: []?u32 = undefined;
        _ = &crcs;
        // Use inline allocation since we need it briefly
        const alloc_buf = try w.allocator.alloc(?u32, m.folders.len);
        defer w.allocator.free(alloc_buf);
        for (alloc_buf, 0..) |*c, i| {
            c.* = m.folders[i].unpack_crc;
        }
        try writeDigestVector(w, alloc_buf);
    }

    try w.writeNid(.end);
}

fn encodeFolderRecord(w: *Writer, folder: meta.Folder) !void {
    try w.writeUint64(@intCast(folder.coders.len));

    for (folder.coders) |coder| {
        // MainByte
        var main_byte: u8 = @intCast(coder.method_id.len & 0x0F);
        const is_complex = coder.num_in_streams != 1 or coder.num_out_streams != 1;
        if (is_complex) main_byte |= 0x10;
        if (coder.properties.len > 0) main_byte |= 0x20;
        try w.writeByte(main_byte);

        // CodecId
        try w.writeBytes(coder.method_id);

        // Complex streams
        if (is_complex) {
            try w.writeUint64(coder.num_in_streams);
            try w.writeUint64(coder.num_out_streams);
        }

        // Properties
        if (coder.properties.len > 0) {
            try w.writeUint64(@intCast(coder.properties.len));
            try w.writeBytes(coder.properties);
        }
    }

    // Bind pairs
    for (folder.bind_pairs) |bp| {
        try w.writeUint64(bp.in_index);
        try w.writeUint64(bp.out_index);
    }

    // Packed indices (only if > 1)
    if (folder.packed_indices.len > 0) {
        for (folder.packed_indices) |idx| {
            try w.writeUint64(idx);
        }
    }
}

fn encodeSubStreamsInfo(w: *Writer, ss: meta.SubStreamInfo, _: []const meta.Folder) !void {
    try w.writeNid(.sub_streams_info);

    // Use the per-folder substream counts from metadata
    var all_default = true;
    for (ss.num_unpack_per_folder) |n| {
        if (n != 1) {
            all_default = false;
            break;
        }
    }

    // kNumUnpackStream — write if not all default (1 per folder)
    if (!all_default) {
        try w.writeNid(.num_unpack_stream);
        for (ss.num_unpack_per_folder) |n| {
            try w.writeUint64(n);
        }
    }

    // kSize — write (n-1) sizes per folder when n > 1
    if (!all_default) {
        try w.writeNid(.size);
        var si: usize = 0;
        for (ss.num_unpack_per_folder) |n| {
            const count: usize = @intCast(n);
            // Write first (count-1) sizes; last is inferred
            for (0..count) |j| {
                if (j < count - 1) {
                    try w.writeUint64(ss.unpack_sizes[si]);
                }
                si += 1;
            }
        }
    }

    // kCRC
    if (ss.digests.len > 0) {
        var has_any = false;
        for (ss.digests) |d| {
            if (d != null) {
                has_any = true;
                break;
            }
        }
        if (has_any) {
            try w.writeNid(.crc);
            try writeDigestVector(w, ss.digests);
        }
    }

    try w.writeNid(.end);
}

fn encodeFilesInfo(w: *Writer, m: meta.ArchiveMetadata) !void {
    try w.writeNid(.files_info);
    try w.writeUint64(@intCast(m.files.len));

    // kEmptyStream
    var has_empty = false;
    for (m.files) |f| {
        if (f.is_empty_stream) {
            has_empty = true;
            break;
        }
    }
    if (has_empty) {
        try w.writeNid(.empty_stream);
        // Compute property size
        const bool_byte_count = (m.files.len + 7) / 8;
        try w.writeUint64(@intCast(bool_byte_count));
        const flags = try w.allocator.alloc(bool, m.files.len);
        defer w.allocator.free(flags);
        for (flags, 0..) |*f, i| f.* = m.files[i].is_empty_stream;
        try w.writeBoolVector(flags);
    }

    // kName
    var has_names = false;
    for (m.files) |f| {
        if (f.name != null) {
            has_names = true;
            break;
        }
    }
    if (has_names) {
        try encodeFileNames(w, m.files);
    }

    // kMTime
    try encodeTimeProperty(w, m.files, .m_time);

    // kCTime
    try encodeTimeProperty(w, m.files, .c_time);

    // kATime
    try encodeTimeProperty(w, m.files, .a_time);

    // kWinAttrib
    try encodeWinAttrib(w, m.files);

    // kXattr (custom 0x7A)
    try encodeXattrProperty(w, m.files);

    try w.writeNid(.end); // end FilesInfo
}

fn encodeFileNames(w: *Writer, files: []const meta.FileInfo) !void {
    try w.writeNid(.name);

    // Compute property size: External(1) + UTF-16LE names with NUL terminators
    var name_bytes: usize = 1; // External byte
    for (files) |file| {
        if (file.name) |utf8_name| {
            // Each UTF-8 char → UTF-16LE (2 bytes per code unit) + 2 bytes for NUL
            var len: usize = 0;
            var i: usize = 0;
            while (i < utf8_name.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(utf8_name[i]) catch 1;
                const cp = std.unicode.utf8Decode(utf8_name[i..@min(i + cp_len, utf8_name.len)]) catch 0xFFFD;
                if (cp > 0xFFFF) {
                    len += 4; // surrogate pair
                } else {
                    len += 2;
                }
                i += cp_len;
            }
            name_bytes += len + 2; // +2 for NUL terminator
        } else {
            name_bytes += 2; // just NUL
        }
    }

    try w.writeUint64(@intCast(name_bytes));
    try w.writeByte(0); // External = 0

    for (files) |file| {
        if (file.name) |utf8_name| {
            var i: usize = 0;
            while (i < utf8_name.len) {
                const cp_len = std.unicode.utf8ByteSequenceLength(utf8_name[i]) catch 1;
                const cp = std.unicode.utf8Decode(utf8_name[i..@min(i + cp_len, utf8_name.len)]) catch 0xFFFD;
                if (cp > 0xFFFF) {
                    // Surrogate pair
                    const adj = cp - 0x10000;
                    const hi: u16 = @intCast(0xD800 + (adj >> 10));
                    const lo: u16 = @intCast(0xDC00 + (adj & 0x3FF));
                    try w.writeByte(@intCast(hi & 0xFF));
                    try w.writeByte(@intCast(hi >> 8));
                    try w.writeByte(@intCast(lo & 0xFF));
                    try w.writeByte(@intCast(lo >> 8));
                } else {
                    const cu: u16 = @intCast(cp);
                    try w.writeByte(@intCast(cu & 0xFF));
                    try w.writeByte(@intCast(cu >> 8));
                }
                i += cp_len;
            }
        }
        // NUL terminator (UTF-16LE)
        try w.writeByte(0x00);
        try w.writeByte(0x00);
    }
}

fn encodeTimeProperty(w: *Writer, files: []const meta.FileInfo, prop_type: nid.Nid) !void {
    var has_any = false;
    for (files) |f| {
        const val = switch (prop_type) {
            .m_time => f.mtime,
            .c_time => f.ctime,
            .a_time => f.atime,
            .start_pos => f.start_pos,
            else => null,
        };
        if (val != null) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    try w.writeNid(prop_type);

    // Compute property size: BOOL_VECTOR2 + External(1) + REAL_UINT64 per defined
    var defined_count: usize = 0;
    const flags = try w.allocator.alloc(bool, files.len);
    defer w.allocator.free(flags);
    for (flags, 0..) |*fl, i| {
        const val = switch (prop_type) {
            .m_time => files[i].mtime,
            .c_time => files[i].ctime,
            .a_time => files[i].atime,
            .start_pos => files[i].start_pos,
            else => null,
        };
        fl.* = val != null;
        if (val != null) defined_count += 1;
    }

    // Property size = BOOL_VECTOR2 size + External byte + 8 * defined_count
    var all_defined = true;
    for (flags) |f| {
        if (!f) {
            all_defined = false;
            break;
        }
    }
    const bv2_size: usize = if (all_defined) 1 else 1 + (files.len + 7) / 8;
    const prop_size = bv2_size + 1 + 8 * defined_count;
    try w.writeUint64(@intCast(prop_size));

    try w.writeBoolVector2(flags);
    try w.writeByte(0); // External = 0

    for (files) |f| {
        const val = switch (prop_type) {
            .m_time => f.mtime,
            .c_time => f.ctime,
            .a_time => f.atime,
            .start_pos => f.start_pos,
            else => null,
        };
        if (val) |v| {
            try w.writeU64Le(v);
        }
    }
}

fn encodeWinAttrib(w: *Writer, files: []const meta.FileInfo) !void {
    var has_any = false;
    for (files) |f| {
        if (f.win_attrib != null) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    try w.writeNid(.win_attrib);

    var defined_count: usize = 0;
    const flags = try w.allocator.alloc(bool, files.len);
    defer w.allocator.free(flags);
    for (flags, 0..) |*fl, i| {
        fl.* = files[i].win_attrib != null;
        if (fl.*) defined_count += 1;
    }

    var all_defined = true;
    for (flags) |f| {
        if (!f) {
            all_defined = false;
            break;
        }
    }
    const bv2_size: usize = if (all_defined) 1 else 1 + (files.len + 7) / 8;
    const prop_size = bv2_size + 1 + 4 * defined_count;
    try w.writeUint64(@intCast(prop_size));

    try w.writeBoolVector2(flags);
    try w.writeByte(0); // External = 0

    for (files) |f| {
        if (f.win_attrib) |attr| {
            try w.writeU32Le(attr);
        }
    }
}

/// Encode per-file xattr blobs (custom property 0x7A).
/// Format: NID | PropertySize | BOOL_VECTOR2 | External(0) | for each defined: varint blob_len + blob_bytes
fn encodeXattrProperty(w: *Writer, files: []const meta.FileInfo) !void {
    var has_any = false;
    for (files) |f| {
        if (f.xattrs != null) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    try w.writeNid(.xattr);

    // Build defined flags and count
    var defined_count: usize = 0;
    const flags = try w.allocator.alloc(bool, files.len);
    defer w.allocator.free(flags);
    for (flags, 0..) |*fl, i| {
        fl.* = files[i].xattrs != null;
        if (fl.*) defined_count += 1;
    }

    // Compute property size: BOOL_VECTOR2 + External(1) + sum(varint_len + blob_len)
    var all_defined = true;
    for (flags) |f| {
        if (!f) {
            all_defined = false;
            break;
        }
    }
    const bv2_size: usize = if (all_defined) 1 else 1 + (files.len + 7) / 8;
    var blob_total: usize = 0;
    for (files) |f| {
        if (f.xattrs) |x| {
            blob_total += varint.encodedSize(@intCast(x.len)) + x.len;
        }
    }
    const prop_size = bv2_size + 1 + blob_total;
    try w.writeUint64(@intCast(prop_size));

    try w.writeBoolVector2(flags);
    try w.writeByte(0); // External = 0

    for (files) |f| {
        if (f.xattrs) |x| {
            try w.writeUint64(@intCast(x.len));
            try w.writeBytes(x);
        }
    }
}

fn writeDigestVector(w: *Writer, digests: []const ?u32) !void {
    const flags = try w.allocator.alloc(bool, digests.len);
    defer w.allocator.free(flags);
    for (flags, 0..) |*f, i| {
        f.* = digests[i] != null;
    }
    try w.writeBoolVector2(flags);

    for (digests) |d| {
        if (d) |crc_val| {
            try w.writeU32Le(crc_val);
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const metadata_mod = @import("metadata.zig");

test "encoder: roundtrip TV-A next-header" {
    const allocator = std.testing.allocator;

    // TV-A next-header bytes
    const tv_a_nh = [74]u8{
        0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x06, 0x00,
        0x07, 0x0B, 0x01, 0x00, 0x01, 0x01, 0x00, 0x0C,
        0x06, 0x00, 0x08, 0x0A, 0x01, 0x20, 0x30, 0x3A,
        0x36, 0x00, 0x00, 0x05, 0x01, 0x11, 0x15, 0x00,
        0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00,
        0x6F, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00,
        0x74, 0x00, 0x00, 0x00, 0x14, 0x0A, 0x01, 0x00,
        0x80, 0xCA, 0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01,
        0x15, 0x06, 0x01, 0x00, 0x20, 0x80, 0xA4, 0x81,
        0x00, 0x00,
    };

    // Parse original
    var parsed = try metadata_mod.parseNextHeader(&tv_a_nh, allocator);
    defer parsed.deinit();

    // Re-encode
    const encoded = try encodeNextHeader(parsed, allocator);
    defer allocator.free(encoded);

    // Parse the re-encoded version
    var reparsed = try metadata_mod.parseNextHeader(encoded, allocator);
    defer reparsed.deinit();

    // Verify structural equivalence
    try std.testing.expectEqual(@as(usize, 1), reparsed.folders.len);
    try std.testing.expectEqual(@as(u8, 0x00), reparsed.folders[0].coders[0].method_id[0]);
    try std.testing.expectEqual(@as(u64, 6), reparsed.folders[0].unpack_sizes[0]);
    try std.testing.expectEqualStrings("hello.txt", reparsed.files[0].name.?);
}

test "encoder: roundtrip produces byte-identical output for TV-A" {
    const allocator = std.testing.allocator;

    const tv_a_nh = [74]u8{
        0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x06, 0x00,
        0x07, 0x0B, 0x01, 0x00, 0x01, 0x01, 0x00, 0x0C,
        0x06, 0x00, 0x08, 0x0A, 0x01, 0x20, 0x30, 0x3A,
        0x36, 0x00, 0x00, 0x05, 0x01, 0x11, 0x15, 0x00,
        0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00,
        0x6F, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00,
        0x74, 0x00, 0x00, 0x00, 0x14, 0x0A, 0x01, 0x00,
        0x80, 0xCA, 0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01,
        0x15, 0x06, 0x01, 0x00, 0x20, 0x80, 0xA4, 0x81,
        0x00, 0x00,
    };

    var parsed = try metadata_mod.parseNextHeader(&tv_a_nh, allocator);
    defer parsed.deinit();

    const encoded = try encodeNextHeader(parsed, allocator);
    defer allocator.free(encoded);

    // Byte-identical roundtrip
    try std.testing.expectEqualSlices(u8, &tv_a_nh, encoded);
}
