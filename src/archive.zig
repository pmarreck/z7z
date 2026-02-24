//! 7z archive-level operations.
//!
//! Creates and reads complete .7z archives in memory.
//! Supports Copy and LZMA2 methods for reading.

const std = @import("std");
const crc32 = @import("crc32.zig");
const sig_header = @import("header.zig");
const meta = @import("metadata.zig");
const encoder = @import("encoder.zig");
const codec = @import("codec.zig");
const aes_crypt = @import("aes_crypt.zig");

pub const ArchiveError = error{
    NotArchive,
    ChecksumError,
    TruncatedInput,
    StructuralError,
    UnsupportedFeature,
    EndOfStream,
    OutOfMemory,
};

/// Compression method for archive creation.
pub const Method = enum {
    copy,
    lzma2,
    lzma2_aes,
};

/// A file entry for creating an archive.
pub const FileEntry = struct {
    name: []const u8, // UTF-8 filename
    data: []const u8, // file content (empty for directories)
    is_dir: bool = false, // true for directory entries
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
    return createWithMethod(files, .lzma2, allocator);
}

/// Create a .7z archive in memory using the specified compression method.
pub fn createWithMethod(files: []const FileEntry, method: Method, allocator: std.mem.Allocator) ![]u8 {
    return createWithMethodAndPassword(files, method, null, allocator);
}

/// Create a .7z archive with optional password for encryption methods.
pub fn createWithMethodAndPassword(files: []const FileEntry, method: Method, password: ?[]const u8, allocator: std.mem.Allocator) ![]u8 {
    return switch (method) {
        .copy => createCopy(files, allocator),
        .lzma2 => createLzma2(files, allocator),
        .lzma2_aes => createLzma2Aes(files, password orelse return error.OutOfMemory, allocator),
    };
}

/// Create a .7z archive in memory using LZMA2 compression.
fn createLzma2(files: []const FileEntry, allocator: std.mem.Allocator) ![]u8 {
    // Concatenate all non-directory file data
    var total_unpack_size: u64 = 0;
    for (files) |f| {
        if (!f.is_dir) total_unpack_size += f.data.len;
    }

    var raw_data = try allocator.alloc(u8, @intCast(total_unpack_size));
    defer allocator.free(raw_data);
    {
        var offset: usize = 0;
        for (files) |f| {
            if (!f.is_dir) {
                @memcpy(raw_data[offset .. offset + f.data.len], f.data);
                offset += f.data.len;
            }
        }
    }

    // Compress with LZMA2
    const compressed = try codec.compressLzma2(raw_data, allocator);
    defer allocator.free(compressed);

    // Build metadata
    var coders = try allocator.alloc(meta.Coder, 1);
    errdefer allocator.free(coders);

    // LZMA2 method: CodecId = 0x21, properties = 1 byte (dict size indicator)
    const method_id = try allocator.alloc(u8, 1);
    method_id[0] = 0x21;

    // LZMA2 property byte: encodes dictionary size
    // Property byte p: dict_size = (2 | (p & 1)) << (p/2 + 11) for p >= 1
    // For small data, use a reasonable dict size indicator
    // p=24 → 16MB dict, p=20 → 4MB dict, p=16 → 1MB dict
    const props = try allocator.alloc(u8, 1);
    const data_len = @as(u32, @intCast(@min(total_unpack_size, 0xFFFFFFFF)));
    props[0] = calcLzma2DictProp(data_len);

    coders[0] = .{
        .method_id = method_id,
        .properties = props,
        .num_in_streams = 1,
        .num_out_streams = 1,
    };

    const unpack_sizes = try allocator.alloc(u64, 1);
    unpack_sizes[0] = total_unpack_size;

    var folders = try allocator.alloc(meta.Folder, 1);
    folders[0] = .{
        .coders = coders,
        .bind_pairs = &.{},
        .packed_indices = &.{},
        .unpack_sizes = unpack_sizes,
        .unpack_crc = null,
    };

    var pack_sizes = try allocator.alloc(u64, 1);
    pack_sizes[0] = compressed.len;

    // Build substream info (only for non-directory files with data)
    var data_file_count: usize = 0;
    for (files) |f| {
        if (!f.is_dir) data_file_count += 1;
    }
    var sub_sizes = try allocator.alloc(u64, data_file_count);
    var sub_digests = try allocator.alloc(?u32, data_file_count);
    {
        var si: usize = 0;
        for (files) |f| {
            if (!f.is_dir) {
                sub_sizes[si] = f.data.len;
                sub_digests[si] = crc32.hash(f.data);
                si += 1;
            }
        }
    }

    // Build file info (all entries: files AND directories)
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = f.mtime,
            .win_attrib = if (f.is_dir) (f.win_attrib orelse 0) | FILE_ATTRIBUTE_DIRECTORY else f.win_attrib,
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
        .next_header_offset = compressed.len,
        .next_header_size = next_header.len,
        .next_header_crc = next_header_crc,
    });

    // Assemble final archive: signature header + compressed data + next header
    const total_size = sig_header.HEADER_SIZE + compressed.len + next_header.len;
    const archive_out = try allocator.alloc(u8, total_size);
    @memcpy(archive_out[0..sig_header.HEADER_SIZE], &sig);
    @memcpy(archive_out[sig_header.HEADER_SIZE .. sig_header.HEADER_SIZE + compressed.len], compressed);
    @memcpy(archive_out[sig_header.HEADER_SIZE + compressed.len ..], next_header);

    return archive_out;
}

/// Create a .7z archive with LZMA2 compression + AES-256-CBC encryption.
fn createLzma2Aes(files: []const FileEntry, password: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Step 1: Concatenate all non-directory file data
    var total_unpack_size: u64 = 0;
    for (files) |f| {
        if (!f.is_dir) total_unpack_size += f.data.len;
    }

    var raw_data = try allocator.alloc(u8, @intCast(total_unpack_size));
    defer allocator.free(raw_data);
    {
        var offset: usize = 0;
        for (files) |f| {
            if (f.is_dir) continue;
            @memcpy(raw_data[offset .. offset + f.data.len], f.data);
            offset += f.data.len;
        }
    }

    // Step 2: Compress with LZMA2
    const compressed = try codec.compressLzma2(raw_data, allocator);
    defer allocator.free(compressed);

    // Step 3: Encrypt with AES-256-CBC
    // Generate random salt and IV
    var salt: [8]u8 = undefined;
    var iv: [16]u8 = undefined;
    std.crypto.random.bytes(&salt);
    std.crypto.random.bytes(&iv);

    const aes_props = aes_crypt.AesProperties{
        .num_cycles_power = 19, // 2^19 = 524288 iterations (7zz default)
        .salt = salt ++ ([_]u8{0} ** 8),
        .salt_size = 8,
        .iv = iv,
        .iv_size = 16,
    };

    const key = aes_crypt.deriveKey(password, aes_props);

    // Pad compressed data to 16-byte boundary for AES-CBC
    const padded_len = (compressed.len + 15) & ~@as(usize, 15);
    var encrypted = try allocator.alloc(u8, padded_len);
    defer allocator.free(encrypted);
    @memcpy(encrypted[0..compressed.len], compressed);
    if (padded_len > compressed.len) {
        @memset(encrypted[compressed.len..], 0);
    }

    aes_crypt.encryptCbc(encrypted, key, iv) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.StructuralError,
    };

    // Step 4: Build metadata with 2-coder folder (LZMA2 + 7zAES)
    // Coder 0: LZMA2
    const lzma2_mid = try allocator.alloc(u8, 1);
    lzma2_mid[0] = 0x21;
    const lzma2_props = try allocator.alloc(u8, 1);
    lzma2_props[0] = calcLzma2DictProp(@intCast(@min(total_unpack_size, 0xFFFFFFFF)));

    // Coder 1: 7zAES
    const aes_mid = try allocator.alloc(u8, 4);
    @memcpy(aes_mid, &[_]u8{ 0x06, 0xF1, 0x07, 0x01 });
    const encoded_aes_props = aes_crypt.encodeProperties(aes_props);
    const aes_prop_data = try allocator.alloc(u8, encoded_aes_props.len);
    @memcpy(aes_prop_data, encoded_aes_props.data[0..encoded_aes_props.len]);

    var coders = try allocator.alloc(meta.Coder, 2);
    coders[0] = .{
        .method_id = lzma2_mid,
        .properties = lzma2_props,
        .num_in_streams = 1,
        .num_out_streams = 1,
    };
    coders[1] = .{
        .method_id = aes_mid,
        .properties = aes_prop_data,
        .num_in_streams = 1,
        .num_out_streams = 1,
    };

    // Bind pair: AES output (stream 1) → LZMA2 input (stream 0)
    var bind_pairs = try allocator.alloc(meta.BindPair, 1);
    bind_pairs[0] = .{ .in_index = 0, .out_index = 1 };

    // Unpack sizes: [0]=LZMA2 output (final), [1]=AES output (intermediate=compressed len)
    var unpack_sizes = try allocator.alloc(u64, 2);
    unpack_sizes[0] = total_unpack_size;
    unpack_sizes[1] = compressed.len;

    var folders = try allocator.alloc(meta.Folder, 1);
    folders[0] = .{
        .coders = coders,
        .bind_pairs = bind_pairs,
        .packed_indices = &.{},
        .unpack_sizes = unpack_sizes,
        .unpack_crc = null,
    };

    var pack_sizes = try allocator.alloc(u64, 1);
    pack_sizes[0] = encrypted.len;

    // Build substream info (only for non-directory files with data)
    var data_file_count2: usize = 0;
    for (files) |f| {
        if (!f.is_dir) data_file_count2 += 1;
    }
    var sub_sizes = try allocator.alloc(u64, data_file_count2);
    var sub_digests = try allocator.alloc(?u32, data_file_count2);
    {
        var si: usize = 0;
        for (files) |f| {
            if (!f.is_dir) {
                sub_sizes[si] = f.data.len;
                sub_digests[si] = crc32.hash(f.data);
                si += 1;
            }
        }
    }

    // Build file info (all entries: files AND directories)
    const FILE_ATTRIBUTE_DIRECTORY2: u32 = 0x10;
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = f.mtime,
            .win_attrib = if (f.is_dir) (f.win_attrib orelse 0) | FILE_ATTRIBUTE_DIRECTORY2 else f.win_attrib,
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
        .next_header_offset = encrypted.len,
        .next_header_size = next_header.len,
        .next_header_crc = next_header_crc,
    });

    // Assemble final archive
    const total_size = sig_header.HEADER_SIZE + encrypted.len + next_header.len;
    const archive_out = try allocator.alloc(u8, total_size);
    @memcpy(archive_out[0..sig_header.HEADER_SIZE], &sig);
    @memcpy(archive_out[sig_header.HEADER_SIZE .. sig_header.HEADER_SIZE + encrypted.len], encrypted);
    @memcpy(archive_out[sig_header.HEADER_SIZE + encrypted.len ..], next_header);

    return archive_out;
}

/// Calculate LZMA2 dictionary size property byte for a given data length.
fn calcLzma2DictProp(data_len: u32) u8 {
    // Property byte p encodes dict size:
    // p=0: dict_size not specified (use default)
    // p>=1: dict_size = (2 | (p & 1)) << (p/2 + 11)
    // We want the smallest dict that covers the data.
    if (data_len <= 4096) return 0; // 4KB default
    var p: u8 = 1;
    while (p < 40) : (p += 1) {
        const ds = @as(u64, 2 | (p & 1)) << @intCast(p / 2 + 11);
        if (ds >= data_len) return p;
    }
    return 40; // max
}

/// Create a .7z archive in memory using Copy method (no compression).
fn createCopy(files: []const FileEntry, allocator: std.mem.Allocator) ![]u8 {
    // Build packed data (concatenated non-directory file contents for Copy method)
    var total_pack_size: u64 = 0;
    for (files) |f| {
        if (!f.is_dir) total_pack_size += f.data.len;
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
            if (!f.is_dir) {
                @memcpy(pack_data[offset .. offset + f.data.len], f.data);
                offset += f.data.len;
            }
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

    // Build substream info (only for non-directory files with data)
    var copy_data_count: usize = 0;
    for (files) |f| {
        if (!f.is_dir) copy_data_count += 1;
    }
    var sub_sizes: []u64 = undefined;
    var sub_digests: []?u32 = undefined;
    if (copy_data_count == 1) {
        sub_sizes = try allocator.alloc(u64, 1);
        sub_digests = try allocator.alloc(?u32, 1);
        for (files) |f| {
            if (!f.is_dir) {
                sub_sizes[0] = f.data.len;
                sub_digests[0] = data_crc;
                break;
            }
        }
    } else {
        sub_sizes = try allocator.alloc(u64, copy_data_count);
        sub_digests = try allocator.alloc(?u32, copy_data_count);
        var si: usize = 0;
        for (files) |f| {
            if (!f.is_dir) {
                sub_sizes[si] = f.data.len;
                sub_digests[si] = crc32.hash(f.data);
                si += 1;
            }
        }
    }

    // Build file info (all entries: files AND directories)
    const COPY_DIR_ATTRIB: u32 = 0x10;
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = f.mtime,
            .win_attrib = if (f.is_dir) (f.win_attrib orelse 0) | COPY_DIR_ATTRIB else f.win_attrib,
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
pub fn read(archive_data: []const u8, allocator: std.mem.Allocator) ArchiveError!ArchiveContents {
    return readWithPassword(archive_data, null, allocator);
}

/// Read a .7z archive from memory with optional password for encrypted archives.
pub fn readWithPassword(archive_data: []const u8, password: ?[]const u8, allocator: std.mem.Allocator) ArchiveError!ArchiveContents {
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

    // Parse metadata (pass full archive for encoded header support)
    var metadata = meta.parseNextHeaderFull(nh_bytes, archive_data, password, allocator) catch |e| switch (e) {
        error.StructuralError => return ArchiveError.StructuralError,
        error.UnsupportedFeature => return ArchiveError.UnsupportedFeature,
        error.EndOfStream => return ArchiveError.EndOfStream,
        error.OutOfMemory => return ArchiveError.OutOfMemory,
    };
    errdefer metadata.deinit();

    // Extract file data via codec dispatch
    const file_data = try allocator.alloc([]const u8, metadata.files.len);
    errdefer allocator.free(file_data);

    if (metadata.pack_info) |pi| {
        if (metadata.folders.len > 0) {
            const folder = metadata.folders[0];
            const pack_start = sig_header.HEADER_SIZE + @as(usize, @intCast(pi.pack_pos));

            // Get total packed size for this folder
            const pack_size: usize = if (pi.pack_sizes.len > 0)
                @intCast(pi.pack_sizes[0])
            else
                0;

            // Get folder unpack size (unbound output stream)
            const unpack_size: u64 = folder.getFinalUnpackSize();

            const packed_data = archive_data[pack_start .. pack_start + pack_size];

            // Decompress entire folder
            const unpacked = codec.decompressFolder(folder, packed_data, unpack_size, password, allocator) catch |e| switch (e) {
                error.UnsupportedMethod => return ArchiveError.UnsupportedFeature,
                error.DecompressFailed => return ArchiveError.StructuralError,
                error.OutOfMemory => return ArchiveError.OutOfMemory,
            };
            defer allocator.free(unpacked);

            // Split decompressed data into per-file slices.
            // Empty stream entries (directories) have no substream data —
            // the substream sizes array only covers data-bearing files.
            var offset: usize = 0;
            var sub_idx: usize = 0;
            for (0..metadata.files.len) |fi| {
                if (metadata.files[fi].is_empty_stream) {
                    // Directory or empty stream: no data
                    file_data[fi] = try allocator.dupe(u8, &.{});
                } else {
                    const file_size = if (metadata.sub_streams) |ss|
                        (if (sub_idx < ss.unpack_sizes.len) @as(usize, @intCast(ss.unpack_sizes[sub_idx])) else 0)
                    else if (sub_idx == 0)
                        @as(usize, @intCast(unpack_size))
                    else
                        0;

                    file_data[fi] = try allocator.dupe(u8, unpacked[offset .. offset + file_size]);
                    offset += file_size;
                    sub_idx += 1;
                }
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

test "archive: read TV-B (LZMA2)" {
    const allocator = std.testing.allocator;

    // TV-B: LZMA2-compressed archive containing "hello\n"
    const tv_b = [132]u8{
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x6D, 0xE0, 0xCC, 0x1D, 0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xDA, 0x13, 0xAD, 0xAC,
        0x01, 0x00, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x00, 0x01, 0x04, 0x06, 0x00, 0x01, 0x09,
        0x0A, 0x00, 0x07, 0x0B, 0x01, 0x00, 0x01, 0x21, 0x21, 0x01, 0x00, 0x0C, 0x06, 0x00, 0x08, 0x0A,
        0x01, 0x20, 0x30, 0x3A, 0x36, 0x00, 0x00, 0x05, 0x01, 0x19, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x15, 0x00, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x14, 0x0A,
        0x01, 0x00, 0x80, 0xCA, 0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01, 0x15, 0x06, 0x01, 0x00, 0x20, 0x80,
        0xA4, 0x81, 0x00, 0x00,
    };

    var contents = try read(&tv_b, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("hello.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings("hello\n", contents.file_data[0]);
}

test "archive: create LZMA2 and read back single file" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "test.txt", .data = "hello world" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    // Should be smaller than or comparable to the Copy version
    // (for small data LZMA2 may be slightly larger due to headers, that's ok)

    // Read it back — exercises our LZMA2 decoder too
    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("test.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings("hello world", contents.file_data[0]);
}

test "archive: create LZMA2 multi-file roundtrip" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "alpha.txt", .data = "First file content\n" },
        .{ .name = "beta.txt", .data = "Second file content\n" },
        .{ .name = "gamma.bin", .data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF } },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);
    try std.testing.expectEqualStrings("First file content\n", contents.file_data[0]);
    try std.testing.expectEqualStrings("Second file content\n", contents.file_data[1]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF }, contents.file_data[2]);
}

test "archive: LZMA2 compresses repetitive data" {
    const allocator = std.testing.allocator;

    // Highly repetitive data should compress well
    const repeated = "ABCDEFGHIJ" ** 100; // 1000 bytes of repetitive content
    const files = [_]FileEntry{
        .{ .name = "repeat.txt", .data = repeated },
    };

    const lzma2_archive = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(lzma2_archive);

    const copy_archive = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(copy_archive);

    // LZMA2 should be meaningfully smaller for repetitive data
    try std.testing.expect(lzma2_archive.len < copy_archive.len);

    // Verify roundtrip
    var contents = try read(lzma2_archive, allocator);
    defer contents.deinit();
    try std.testing.expectEqualStrings(repeated, contents.file_data[0]);
}

test "archive: create encrypted and read back" {
    const allocator = std.testing.allocator;
    const password = "test_password_123";
    const content = "Secret data for z7z AES roundtrip test.\n";
    const files = [_]FileEntry{
        .{ .name = "secret.txt", .data = content },
    };

    const archive_data = try createWithMethodAndPassword(&files, .lzma2_aes, password, allocator);
    defer allocator.free(archive_data);

    // Should NOT be readable without password
    try std.testing.expectError(ArchiveError.UnsupportedFeature, read(archive_data, allocator));

    // Should be readable WITH correct password
    var contents = try readWithPassword(archive_data, password, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("secret.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "archive: encrypted multi-file roundtrip" {
    const allocator = std.testing.allocator;
    const password = "multi_file_pass";
    const files = [_]FileEntry{
        .{ .name = "alpha.txt", .data = "First secret file\n" },
        .{ .name = "beta.txt", .data = "Second secret file\n" },
    };

    const archive_data = try createWithMethodAndPassword(&files, .lzma2_aes, password, allocator);
    defer allocator.free(archive_data);

    var contents = try readWithPassword(archive_data, password, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 2), contents.metadata.files.len);
    try std.testing.expectEqualStrings("First secret file\n", contents.file_data[0]);
    try std.testing.expectEqualStrings("Second secret file\n", contents.file_data[1]);
}

test "archive: default create compresses data" {
    const allocator = std.testing.allocator;

    // 10K of highly compressible repeated text
    const repeated = "ABCDEFGHIJ" ** 1000;
    const files = [_]FileEntry{
        .{ .name = "repeated.txt", .data = repeated },
    };

    const archive_data = try create(&files, allocator);
    defer allocator.free(archive_data);

    // Archive MUST be significantly smaller than raw data.
    // 10K of 10-byte repeated pattern should compress to well under 1K.
    try std.testing.expect(archive_data.len < repeated.len / 2);

    // Must still roundtrip correctly
    var contents = try read(archive_data, allocator);
    defer contents.deinit();
    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings(repeated, contents.file_data[0]);
}

test "archive: directory entries roundtrip" {
    const allocator = std.testing.allocator;

    // Create archive with files AND directory entries
    const files = [_]FileEntry{
        .{ .name = "subdir", .data = "", .is_dir = true },
        .{ .name = "subdir/hello.txt", .data = "Hello from subdir\n" },
        .{ .name = "root.txt", .data = "Root file\n" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // Should have 3 entries (1 dir + 2 files)
    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);

    // Directory entry: empty stream, not empty file, has directory attribute
    const dir_info = contents.metadata.files[0];
    try std.testing.expectEqualStrings("subdir", dir_info.name.?);
    try std.testing.expect(dir_info.is_empty_stream);
    try std.testing.expect(!dir_info.is_empty_file); // dirs are empty_stream but NOT empty_file
    if (dir_info.win_attrib) |attr| {
        try std.testing.expect(attr & 0x10 != 0); // FILE_ATTRIBUTE_DIRECTORY
    }

    // File entries: should have their data intact
    try std.testing.expectEqualStrings("Hello from subdir\n", contents.file_data[1]);
    try std.testing.expectEqualStrings("Root file\n", contents.file_data[2]);
}

test "archive: reject bad signature" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{0} ** 32;
    try std.testing.expectError(ArchiveError.NotArchive, read(&bad, allocator));
}
