//! 7z archive-level operations.
//!
//! Creates and reads complete .7z archives in memory.
//! Currently supports Copy method only (no compression).

const std = @import("std");
const crc32 = @import("crc32.zig");
const sig_header = @import("header.zig");
const meta = @import("metadata.zig");
const encoder = @import("encoder.zig");

pub const ArchiveError = error{
    NotArchive,
    ChecksumError,
    TruncatedInput,
    StructuralError,
    UnsupportedFeature,
    EndOfStream,
    OutOfMemory,
};

/// A file entry for creating an archive.
pub const FileEntry = struct {
    name: []const u8, // UTF-8 filename
    data: []const u8, // file content
    mtime: ?u64 = null, // optional NTFS FILETIME
    win_attrib: ?u32 = null, // optional Windows attributes
};

/// Result of reading an archive: metadata + extracted file data.
pub const ArchiveContents = struct {
    metadata: meta.ArchiveMetadata,
    file_data: [][]const u8, // extracted data per file (owned)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ArchiveContents) void {
        for (self.file_data) |data| {
            self.allocator.free(data);
        }
        self.allocator.free(self.file_data);
        self.metadata.deinit();
    }
};

/// Create a .7z archive in memory using Copy method (no compression).
pub fn create(files: []const FileEntry, allocator: std.mem.Allocator) ![]u8 {
    // Build packed data (concatenated file contents for Copy method)
    var total_pack_size: u64 = 0;
    for (files) |f| {
        total_pack_size += f.data.len;
    }

    // Build metadata
    var coders = try allocator.alloc(meta.Coder, 1);
    errdefer allocator.free(coders);

    // Copy method: CodecId = 0x00
    const method_id = try allocator.alloc(u8, 1);
    method_id[0] = 0x00;
    coders[0] = .{
        .method_id = method_id,
        .properties = &.{},
        .num_in_streams = 1,
        .num_out_streams = 1,
    };

    const unpack_sizes = try allocator.alloc(u64, 1);
    unpack_sizes[0] = total_pack_size;

    // Compute CRC of all packed data
    var pack_data = try allocator.alloc(u8, @intCast(total_pack_size));
    defer allocator.free(pack_data);
    {
        var offset: usize = 0;
        for (files) |f| {
            @memcpy(pack_data[offset .. offset + f.data.len], f.data);
            offset += f.data.len;
        }
    }
    const data_crc = crc32.hash(pack_data);

    var folders = try allocator.alloc(meta.Folder, 1);
    folders[0] = .{
        .coders = coders,
        .bind_pairs = &.{},
        .packed_indices = &.{},
        .unpack_sizes = unpack_sizes,
        .unpack_crc = null,
    };

    var pack_sizes = try allocator.alloc(u64, 1);
    pack_sizes[0] = total_pack_size;

    // Build substream info
    var sub_sizes: []u64 = undefined;
    var sub_digests: []?u32 = undefined;
    if (files.len == 1) {
        sub_sizes = try allocator.alloc(u64, 1);
        sub_sizes[0] = files[0].data.len;
        sub_digests = try allocator.alloc(?u32, 1);
        sub_digests[0] = data_crc;
    } else {
        sub_sizes = try allocator.alloc(u64, files.len);
        sub_digests = try allocator.alloc(?u32, files.len);
        for (files, 0..) |f, i| {
            sub_sizes[i] = f.data.len;
            sub_digests[i] = crc32.hash(f.data);
        }
    }

    // Build file info
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = false,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = f.mtime,
            .win_attrib = f.win_attrib,
            .start_pos = null,
        };
    }

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{
            .pack_pos = 0,
            .pack_sizes = pack_sizes,
            .pack_crcs = null,
        },
        .folders = folders,
        .sub_streams = .{
            .unpack_sizes = sub_sizes,
            .digests = sub_digests,
        },
        .files = file_infos,
        .allocator = allocator,
    };
    defer archive_meta.deinit();

    // Encode next-header
    const next_header = try encoder.encodeNextHeader(archive_meta, allocator);
    defer allocator.free(next_header);

    const next_header_crc = crc32.hash(next_header);

    // Build signature header
    const sig = sig_header.encode(.{
        .major_version = 0,
        .minor_version = 4,
        .next_header_offset = total_pack_size,
        .next_header_size = next_header.len,
        .next_header_crc = next_header_crc,
    });

    // Assemble final archive: signature header + packed data + next header
    const total_size = sig_header.HEADER_SIZE + @as(usize, @intCast(total_pack_size)) + next_header.len;
    const archive = try allocator.alloc(u8, total_size);
    @memcpy(archive[0..sig_header.HEADER_SIZE], &sig);
    @memcpy(archive[sig_header.HEADER_SIZE .. sig_header.HEADER_SIZE + @as(usize, @intCast(total_pack_size))], pack_data);
    @memcpy(archive[sig_header.HEADER_SIZE + @as(usize, @intCast(total_pack_size)) ..], next_header);

    return archive;
}

/// Read a .7z archive from memory, extracting file contents.
/// Currently supports Copy method only.
pub fn read(archive_data: []const u8, allocator: std.mem.Allocator) ArchiveError!ArchiveContents {
    // Parse signature header
    const hdr = sig_header.parse(archive_data) catch |e| switch (e) {
        error.NotArchive => return ArchiveError.NotArchive,
        error.ChecksumError => return ArchiveError.ChecksumError,
        error.TruncatedInput => return ArchiveError.TruncatedInput,
    };

    // Validate next-header bounds
    const nh_start = sig_header.HEADER_SIZE + hdr.next_header_offset;
    const nh_end = nh_start + hdr.next_header_size;
    if (nh_end > archive_data.len) return ArchiveError.TruncatedInput;

    // Validate next-header CRC
    const nh_bytes = archive_data[@intCast(nh_start)..@intCast(nh_end)];
    if (crc32.hash(nh_bytes) != hdr.next_header_crc) return ArchiveError.ChecksumError;

    // Parse metadata
    var metadata = meta.parseNextHeader(nh_bytes, allocator) catch |e| switch (e) {
        error.StructuralError => return ArchiveError.StructuralError,
        error.UnsupportedFeature => return ArchiveError.UnsupportedFeature,
        error.EndOfStream => return ArchiveError.EndOfStream,
        error.OutOfMemory => return ArchiveError.OutOfMemory,
    };
    errdefer metadata.deinit();

    // Extract file data (Copy method only for now)
    const file_data = try allocator.alloc([]const u8, metadata.files.len);
    errdefer allocator.free(file_data);

    if (metadata.pack_info) |pi| {
        if (metadata.folders.len > 0) {
            const folder = metadata.folders[0];

            // Verify it's Copy method
            if (folder.coders.len != 1) return ArchiveError.UnsupportedFeature;
            const coder = folder.coders[0];
            if (coder.method_id.len == 1 and coder.method_id[0] == 0x00) {
                // Copy method — data is uncompressed
                const pack_start = sig_header.HEADER_SIZE + @as(usize, @intCast(pi.pack_pos));
                var offset: usize = 0;

                for (0..metadata.files.len) |fi| {
                    const file_size = if (metadata.sub_streams) |ss|
                        (if (fi < ss.unpack_sizes.len) @as(usize, @intCast(ss.unpack_sizes[fi])) else 0)
                    else if (fi == 0)
                        @as(usize, @intCast(folder.unpack_sizes[0]))
                    else
                        0;

                    const src = archive_data[pack_start + offset .. pack_start + offset + file_size];
                    file_data[fi] = try allocator.dupe(u8, src);
                    offset += file_size;
                }
            } else {
                return ArchiveError.UnsupportedFeature;
            }
        }
    } else {
        // No pack info — all files are empty
        for (file_data) |*d| {
            d.* = &.{};
        }
    }

    return .{
        .metadata = metadata,
        .file_data = file_data,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "archive: create and read back single file" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "test.txt", .data = "hello world" },
    };

    const archive = try create(&files, allocator);
    defer allocator.free(archive);

    // Read it back
    var contents = try read(archive, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("test.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings("hello world", contents.file_data[0]);
}

test "archive: read TV-A" {
    const allocator = std.testing.allocator;

    const tv_a = [112]u8{
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0xD1, 0x47, 0xFD, 0x58, 0x06, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x4A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xDD, 0xC7, 0x47, 0xD5,
        0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x06, 0x00, 0x07, 0x0B,
        0x01, 0x00, 0x01, 0x01, 0x00, 0x0C, 0x06, 0x00, 0x08, 0x0A, 0x01, 0x20, 0x30, 0x3A, 0x36, 0x00,
        0x00, 0x05, 0x01, 0x11, 0x15, 0x00, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00,
        0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x14, 0x0A, 0x01, 0x00, 0x80, 0xCA,
        0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01, 0x15, 0x06, 0x01, 0x00, 0x20, 0x80, 0xA4, 0x81, 0x00, 0x00,
    };

    var contents = try read(&tv_a, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("hello.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings("hello\n", contents.file_data[0]);
}

test "archive: created archive has valid CRCs" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "data.bin", .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } },
    };

    const archive = try create(&files, allocator);
    defer allocator.free(archive);

    // Verify signature header CRC
    const hdr = try sig_header.parse(archive);

    // Verify next-header CRC
    const nh_start = sig_header.HEADER_SIZE + hdr.next_header_offset;
    const nh_end = nh_start + hdr.next_header_size;
    const nh_bytes = archive[@intCast(nh_start)..@intCast(nh_end)];
    try std.testing.expectEqual(hdr.next_header_crc, crc32.hash(nh_bytes));
}

test "archive: reject bad signature" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{0} ** 32;
    try std.testing.expectError(ArchiveError.NotArchive, read(&bad, allocator));
}
