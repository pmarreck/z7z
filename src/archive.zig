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
pub const ProgressContext = @import("progress.zig").ProgressContext;

// POSIX and Windows attribute constants for kWinAttrib encoding.
// See SPEC_7Z_CLEANROOM.md section 2.6.
const S_IFLNK: u32 = 0xA000; // POSIX symlink file type
const POSIX_PRESENT_FLAG: u32 = 0x8000; // low word: POSIX attrs in high word
const ARCHIVE_FLAG: u32 = 0x0020; // low word: Windows Archive bit
const DEFAULT_SYMLINK_ATTRIB: u32 = (0xA1FF << 16) | POSIX_PRESENT_FLAG | ARCHIVE_FLAG; // lrwxrwxrwx

/// Compute win_attrib for a FileEntry based on its type.
fn computeWinAttrib(f: FileEntry) ?u32 {
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    if (f.is_dir) {
        return (f.win_attrib orelse 0) | FILE_ATTRIBUTE_DIRECTORY;
    } else if (f.is_symlink) {
        return f.win_attrib orelse DEFAULT_SYMLINK_ATTRIB;
    } else {
        return f.win_attrib;
    }
}

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
    data: []const u8, // file content (empty for directories, target path for symlinks)
    is_dir: bool = false, // true for directory entries
    is_symlink: bool = false, // true for symbolic link entries
    mtime: ?u64 = null, // optional NTFS FILETIME
    ctime: ?u64 = null, // optional NTFS FILETIME for creation/birth time
    atime: ?u64 = null, // optional NTFS FILETIME for access time
    win_attrib: ?u32 = null, // optional Windows attributes
    xattrs: ?[]const u8 = null, // optional serialized xattr blob
    group_index: u32 = 0, // solid block group (0 = default, all files in one group)
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
    return createWithProgress(files, method, password, .{}, allocator);
}

/// Create a .7z archive with progress reporting.
/// Automatically dispatches to multi-folder creation when files have mixed group_indices.
pub fn createWithProgress(files: []const FileEntry, method: Method, password: ?[]const u8, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    // Check if multi-folder is needed (mixed group_indices among data files)
    if (method != .copy) {
        var needs_multi = false;
        var first_group: ?u32 = null;
        for (files) |f| {
            if (f.is_dir) continue;
            if (first_group == null) {
                first_group = f.group_index;
            } else if (f.group_index != first_group.?) {
                needs_multi = true;
                break;
            }
        }
        if (needs_multi) {
            return createMultiFolder(files, method, password, progress, allocator);
        }
    }

    return switch (method) {
        .copy => createCopy(files, allocator),
        .lzma2 => createLzma2(files, progress, allocator),
        .lzma2_aes => createLzma2Aes(files, password orelse return error.OutOfMemory, progress, allocator),
    };
}

/// Create a .7z archive in memory using LZMA2 compression.
fn createLzma2(files: []const FileEntry, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
    const compressed = try codec.compressLzma2(raw_data, progress, allocator);
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

    // Build file info (all entries: files, directories, AND symlinks)
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir, // only dirs are empty streams; symlinks carry data
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
        };
    }

    var num_per_folder = try allocator.alloc(u64, 1);
    num_per_folder[0] = data_file_count;

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{
            .pack_pos = 0,
            .pack_sizes = pack_sizes,
            .pack_crcs = null,
        },
        .folders = folders,
        .sub_streams = .{
            .num_unpack_per_folder = num_per_folder,
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
fn createLzma2Aes(files: []const FileEntry, password: []const u8, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
    const compressed = try codec.compressLzma2(raw_data, progress, allocator);
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

    // Build file info (all entries: files, directories, AND symlinks)
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
        };
    }

    var num_per_folder2 = try allocator.alloc(u64, 1);
    num_per_folder2[0] = data_file_count2;

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{
            .pack_pos = 0,
            .pack_sizes = pack_sizes,
            .pack_crcs = null,
        },
        .folders = folders,
        .sub_streams = .{
            .num_unpack_per_folder = num_per_folder2,
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

/// Create a multi-folder .7z archive where files are grouped by group_index.
/// Each unique group_index becomes a separate folder (solid block), enabling
/// MIME-type-aware grouping for better compression of heterogeneous file sets.
fn createMultiFolder(files: []const FileEntry, method: Method, password: ?[]const u8, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    const is_encrypted = method == .lzma2_aes;

    // Step 1: Build a sorted index array — sort by (is_dir last, group_index asc, original order)
    const num_files = files.len;
    const sorted_indices = try allocator.alloc(usize, num_files);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;

    const SortCtx = struct {
        files: []const FileEntry,
    };
    const sort_ctx = SortCtx{ .files = files };

    std.mem.sortUnstable(usize, sorted_indices, sort_ctx, struct {
        fn lessThan(ctx: SortCtx, a: usize, b: usize) bool {
            const fa = ctx.files[a];
            const fb = ctx.files[b];
            // Dirs sort last
            if (fa.is_dir != fb.is_dir) return !fa.is_dir;
            // Among non-dirs, sort by group_index
            if (!fa.is_dir and !fb.is_dir) {
                if (fa.group_index != fb.group_index) return fa.group_index < fb.group_index;
            }
            // Preserve original order within same group
            return a < b;
        }
    }.lessThan);

    // Step 2: Identify groups and count data files per group
    // Walk sorted indices (dirs are at the end, skip them for group computation)
    var num_data_files: usize = 0;
    for (sorted_indices) |si| {
        if (!files[si].is_dir) num_data_files += 1;
    }

    // Collect unique group indices in order
    var group_ids = std.ArrayListUnmanaged(u32){};
    defer group_ids.deinit(allocator);
    var files_per_group = std.ArrayListUnmanaged(usize){};
    defer files_per_group.deinit(allocator);

    {
        var cur_group: ?u32 = null;
        for (sorted_indices) |si| {
            if (files[si].is_dir) continue;
            const gi = files[si].group_index;
            if (cur_group == null or cur_group.? != gi) {
                try group_ids.append(allocator, gi);
                try files_per_group.append(allocator, 1);
                cur_group = gi;
            } else {
                files_per_group.items[files_per_group.items.len - 1] += 1;
            }
        }
    }

    const num_groups = group_ids.items.len;
    if (num_groups == 0) {
        // No data files — fall back to single-folder empty archive
        return createLzma2(files, progress, allocator);
    }

    // Step 3: For each group, concatenate data, compress, and optionally encrypt
    var compressed_blocks = try allocator.alloc([]u8, num_groups);
    @memset(compressed_blocks, &.{}); // sentinel: empty slice means "not yet allocated"
    defer {
        for (compressed_blocks) |block| {
            if (block.len > 0) allocator.free(block);
        }
        allocator.free(compressed_blocks);
    }
    const group_unpack_sizes = try allocator.alloc(u64, num_groups);
    defer allocator.free(group_unpack_sizes);

    // For encrypted archives, track the LZMA2-compressed size (pre-encryption) per group
    // and the AES properties per group (each group gets its own IV/salt/key)
    var group_lzma2_sizes: []u64 = if (is_encrypted) try allocator.alloc(u64, num_groups) else &[_]u64{};
    defer if (is_encrypted) allocator.free(group_lzma2_sizes);
    var group_aes_props: []aes_crypt.AesProperties = if (is_encrypted) try allocator.alloc(aes_crypt.AesProperties, num_groups) else &[_]aes_crypt.AesProperties{};
    defer if (is_encrypted) allocator.free(group_aes_props);

    {
        var data_idx: usize = 0; // tracks position in sorted data-file order
        for (0..num_groups) |gi| {
            const count = files_per_group.items[gi];
            // Calculate total unpack size for this group
            var total: u64 = 0;
            for (0..count) |j| {
                const si = sorted_indices[data_idx + j];
                total += files[si].data.len;
            }
            group_unpack_sizes[gi] = total;

            // Concatenate data
            const raw = try allocator.alloc(u8, @intCast(total));
            defer allocator.free(raw);
            {
                var off: usize = 0;
                for (0..count) |j| {
                    const si = sorted_indices[data_idx + j];
                    const d = files[si].data;
                    @memcpy(raw[off .. off + d.len], d);
                    off += d.len;
                }
            }

            // Compress
            const lzma2_compressed = switch (method) {
                .lzma2, .lzma2_aes => try codec.compressLzma2(raw, progress, allocator),
                .copy => try allocator.dupe(u8, raw),
            };

            // Encrypt if needed
            if (is_encrypted) {
                defer allocator.free(lzma2_compressed); // free the intermediate compressed data
                const pw = password orelse return error.OutOfMemory;

                // Record pre-encryption compressed size
                group_lzma2_sizes[gi] = lzma2_compressed.len;

                // Generate random salt and IV per group
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
                group_aes_props[gi] = aes_props;

                const key = aes_crypt.deriveKey(pw, aes_props);

                // Pad to 16-byte boundary for AES-CBC
                const padded_len = (lzma2_compressed.len + 15) & ~@as(usize, 15);
                var encrypted = try allocator.alloc(u8, padded_len);
                @memcpy(encrypted[0..lzma2_compressed.len], lzma2_compressed);
                if (padded_len > lzma2_compressed.len) {
                    @memset(encrypted[lzma2_compressed.len..], 0);
                }

                aes_crypt.encryptCbc(encrypted, key, iv) catch |e| {
                    allocator.free(encrypted);
                    return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.StructuralError,
                    };
                };

                compressed_blocks[gi] = encrypted;
            } else {
                compressed_blocks[gi] = lzma2_compressed;
            }
            data_idx += count;
        }
    }

    // Step 4: Build metadata
    // Folders — one per group
    var folders = try allocator.alloc(meta.Folder, num_groups);
    var folders_owned = true; // tracks whether we still own folders (false after archive_meta takes over)
    // Initialize all entries to safe defaults so errdefer never touches uninitialized memory
    for (folders) |*f| {
        f.* = .{
            .coders = &.{},
            .bind_pairs = &.{},
            .packed_indices = &.{},
            .unpack_sizes = &.{},
            .unpack_crc = null,
        };
    }
    errdefer {
        if (folders_owned) {
            for (folders) |folder| {
                for (folder.coders) |coder| {
                    allocator.free(coder.method_id);
                    allocator.free(coder.properties);
                }
                if (folder.coders.len > 0) allocator.free(folder.coders);
                if (folder.bind_pairs.len > 0) allocator.free(folder.bind_pairs);
                if (folder.unpack_sizes.len > 0) allocator.free(folder.unpack_sizes);
            }
            allocator.free(folders);
        }
    }
    for (0..num_groups) |gi| {
        if (is_encrypted) {
            // 2-coder pipeline: LZMA2 + 7zAES (same structure as createLzma2Aes)

            // Coder 0: LZMA2
            const lzma2_mid = try allocator.alloc(u8, 1);
            lzma2_mid[0] = 0x21;
            const lzma2_props = try allocator.alloc(u8, 1);
            const data_len = @as(u32, @intCast(@min(group_unpack_sizes[gi], 0xFFFFFFFF)));
            lzma2_props[0] = calcLzma2DictProp(data_len);

            // Coder 1: 7zAES
            const aes_mid = try allocator.alloc(u8, 4);
            @memcpy(aes_mid, &[_]u8{ 0x06, 0xF1, 0x07, 0x01 });
            const encoded_aes_props = aes_crypt.encodeProperties(group_aes_props[gi]);
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
            unpack_sizes[0] = group_unpack_sizes[gi];
            unpack_sizes[1] = group_lzma2_sizes[gi];

            folders[gi] = .{
                .coders = coders,
                .bind_pairs = bind_pairs,
                .packed_indices = &.{},
                .unpack_sizes = unpack_sizes,
                .unpack_crc = null,
            };
        } else {
            // Single-coder folder (LZMA2 or Copy)
            var coders = try allocator.alloc(meta.Coder, 1);
            const mid = try allocator.alloc(u8, 1);
            const props = try allocator.alloc(u8, 1);

            switch (method) {
                .lzma2 => {
                    mid[0] = 0x21; // LZMA2
                    const data_len = @as(u32, @intCast(@min(group_unpack_sizes[gi], 0xFFFFFFFF)));
                    props[0] = calcLzma2DictProp(data_len);
                },
                .copy => {
                    mid[0] = 0x00;
                    props[0] = 0;
                },
                .lzma2_aes => unreachable,
            }

            coders[0] = .{
                .method_id = mid,
                .properties = if (method == .copy) blk: {
                    allocator.free(props);
                    break :blk &.{};
                } else props,
                .num_in_streams = 1,
                .num_out_streams = 1,
            };

            const unpack_sizes = try allocator.alloc(u64, 1);
            unpack_sizes[0] = group_unpack_sizes[gi];

            folders[gi] = .{
                .coders = coders,
                .bind_pairs = &.{},
                .packed_indices = &.{},
                .unpack_sizes = unpack_sizes,
                .unpack_crc = null,
            };
        }
    }

    // PackInfo — one pack_size per folder
    var pack_sizes = try allocator.alloc(u64, num_groups);
    for (0..num_groups) |gi| {
        pack_sizes[gi] = compressed_blocks[gi].len;
    }

    // SubStreamInfo
    var sub_sizes = try allocator.alloc(u64, num_data_files);
    var sub_digests = try allocator.alloc(?u32, num_data_files);
    var num_per_folder = try allocator.alloc(u64, num_groups);
    {
        var si: usize = 0;
        var data_idx: usize = 0;
        for (0..num_groups) |gi| {
            const count = files_per_group.items[gi];
            num_per_folder[gi] = count;
            for (0..count) |j| {
                const fi = sorted_indices[data_idx + j];
                sub_sizes[si] = files[fi].data.len;
                sub_digests[si] = crc32.hash(files[fi].data);
                si += 1;
            }
            data_idx += count;
        }
    }

    // FileInfo — data files in sorted order, then dirs
    var file_infos = try allocator.alloc(meta.FileInfo, num_files);
    var file_infos_owned = true; // tracks whether we still own file_infos
    // Initialize all entries to safe defaults so errdefer never touches uninitialized memory
    for (file_infos) |*fi| {
        fi.* = .{
            .name = null,
            .is_empty_stream = false,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = null,
            .win_attrib = null,
            .start_pos = null,
            .xattrs = null,
        };
    }
    errdefer {
        if (file_infos_owned) {
            for (file_infos) |fi| {
                if (fi.name) |n| allocator.free(n);
                if (fi.xattrs) |x| allocator.free(x);
            }
            allocator.free(file_infos);
        }
    }
    for (sorted_indices, 0..) |si, out_i| {
        const f = files[si];
        file_infos[out_i] = .{
            .name = try allocator.dupe(u8, f.name),
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
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
            .num_unpack_per_folder = num_per_folder,
            .unpack_sizes = sub_sizes,
            .digests = sub_digests,
        },
        .files = file_infos,
        .allocator = allocator,
    };
    defer archive_meta.deinit();

    // archive_meta now owns these arrays — neutralize errdefers to prevent double-free
    folders_owned = false;
    file_infos_owned = false;

    // Step 5: Encode next-header
    const next_header = try encoder.encodeNextHeader(archive_meta, allocator);
    defer allocator.free(next_header);

    const next_header_crc = crc32.hash(next_header);

    // Total packed size (sum of all compressed blocks)
    var total_pack: usize = 0;
    for (compressed_blocks) |block| total_pack += block.len;

    // Build signature header
    const sig = sig_header.encode(.{
        .major_version = 0,
        .minor_version = 4,
        .next_header_offset = total_pack,
        .next_header_size = next_header.len,
        .next_header_crc = next_header_crc,
    });

    // Step 6: Assemble: sig header + all compressed blocks concatenated + next header
    const total_size = sig_header.HEADER_SIZE + total_pack + next_header.len;
    const archive_out = try allocator.alloc(u8, total_size);
    @memcpy(archive_out[0..sig_header.HEADER_SIZE], &sig);
    {
        var off: usize = sig_header.HEADER_SIZE;
        for (compressed_blocks) |block| {
            @memcpy(archive_out[off .. off + block.len], block);
            off += block.len;
        }
    }
    @memcpy(archive_out[sig_header.HEADER_SIZE + total_pack ..], next_header);

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

    // Build file info (all entries: files, directories, AND symlinks)
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (files, 0..) |f, i| {
        const name_copy = try allocator.dupe(u8, f.name);
        file_infos[i] = .{
            .name = name_copy,
            .is_empty_stream = f.is_dir,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
        };
    }

    var copy_num_per_folder = try allocator.alloc(u64, 1);
    copy_num_per_folder[0] = copy_data_count;

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{
            .pack_pos = 0,
            .pack_sizes = pack_sizes,
            .pack_crcs = null,
        },
        .folders = folders,
        .sub_streams = .{
            .num_unpack_per_folder = copy_num_per_folder,
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
    return readWithProgress(archive_data, password, .{}, allocator);
}

/// Read a .7z archive from memory with progress reporting.
/// Progress reports packed bytes decompressed per folder.
pub fn readWithProgress(archive_data: []const u8, password: ?[]const u8, progress: ProgressContext, allocator: std.mem.Allocator) ArchiveError!ArchiveContents {
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

    // Extract file data via codec dispatch — iterate ALL folders
    const file_data = try allocator.alloc([]const u8, metadata.files.len);
    errdefer allocator.free(file_data);

    // Initialize all entries to empty (directories/empty streams stay empty)
    for (file_data) |*d| {
        d.* = try allocator.dupe(u8, &.{});
    }

    if (metadata.pack_info) |pi| {
        if (metadata.folders.len > 0) {
            // Determine per-folder substream counts
            const num_folders = metadata.folders.len;
            var subs_per_folder: []const u64 = undefined;
            var subs_per_folder_alloc: ?[]u64 = null;
            defer if (subs_per_folder_alloc) |a| allocator.free(a);

            if (metadata.sub_streams) |ss| {
                subs_per_folder = ss.num_unpack_per_folder;
            } else {
                // Default: 1 substream per folder
                subs_per_folder_alloc = try allocator.alloc(u64, num_folders);
                @memset(subs_per_folder_alloc.?, 1);
                subs_per_folder = subs_per_folder_alloc.?;
            }

            // Track position across all folders
            var pack_stream_idx: usize = 0; // index into pi.pack_sizes
            var sub_idx: usize = 0; // index into sub_streams.unpack_sizes
            var file_idx: usize = 0; // index into metadata.files (skipping empty streams)

            // Compute total packed size for progress reporting
            var total_pack_size: u64 = 0;
            for (pi.pack_sizes) |ps| total_pack_size += ps;
            var pack_bytes_done: u64 = 0;

            for (0..num_folders) |fi| {
                const folder = metadata.folders[fi];

                // Calculate number of pack streams this folder consumes
                var total_in: u64 = 0;
                for (folder.coders) |coder| {
                    total_in += coder.num_in_streams;
                }
                const num_pack_streams: usize = @intCast(total_in - folder.bind_pairs.len);

                // Calculate total packed size for this folder (sum of its pack streams)
                var folder_pack_size: usize = 0;
                for (0..num_pack_streams) |pi_offset| {
                    const idx = pack_stream_idx + pi_offset;
                    if (idx < pi.pack_sizes.len) {
                        folder_pack_size += @intCast(pi.pack_sizes[idx]);
                    }
                }

                // Calculate pack offset (base + sum of all previous pack sizes)
                var pack_offset: usize = @intCast(pi.pack_pos);
                for (0..pack_stream_idx) |prev| {
                    if (prev < pi.pack_sizes.len) {
                        pack_offset += @intCast(pi.pack_sizes[prev]);
                    }
                }
                const pack_start = sig_header.HEADER_SIZE + pack_offset;

                pack_stream_idx += num_pack_streams;

                // Get folder unpack size (unbound output stream)
                const unpack_size: u64 = folder.getFinalUnpackSize();

                if (pack_start + folder_pack_size > archive_data.len) {
                    return ArchiveError.TruncatedInput;
                }
                const packed_data = archive_data[pack_start .. pack_start + folder_pack_size];

                // Decompress this folder
                const unpacked = codec.decompressFolder(folder, packed_data, unpack_size, password, allocator) catch |e| switch (e) {
                    error.UnsupportedMethod => return ArchiveError.UnsupportedFeature,
                    error.DecompressFailed => return ArchiveError.StructuralError,
                    error.OutOfMemory => return ArchiveError.OutOfMemory,
                };
                defer allocator.free(unpacked);

                // Report progress: this folder's packed data has been decompressed
                pack_bytes_done += @as(u64, @intCast(folder_pack_size));
                progress.report(pack_bytes_done, total_pack_size);

                // Split decompressed data among this folder's substreams
                const folder_sub_count: usize = if (fi < subs_per_folder.len) @intCast(subs_per_folder[fi]) else 1;
                var data_offset: usize = 0;
                var subs_assigned: usize = 0;

                while (subs_assigned < folder_sub_count and file_idx < metadata.files.len) {
                    if (metadata.files[file_idx].is_empty_stream) {
                        // Skip empty stream entries (directories) — they don't consume substreams
                        file_idx += 1;
                        continue;
                    }

                    const file_size: usize = if (metadata.sub_streams) |ss|
                        (if (sub_idx < ss.unpack_sizes.len) @intCast(ss.unpack_sizes[sub_idx]) else 0)
                    else
                        @intCast(unpack_size);

                    // Free the initial empty allocation and replace with actual data
                    allocator.free(@constCast(file_data[file_idx]));
                    if (data_offset + file_size > unpacked.len) {
                        return ArchiveError.StructuralError;
                    }
                    file_data[file_idx] = try allocator.dupe(u8, unpacked[data_offset .. data_offset + file_size]);
                    data_offset += file_size;
                    sub_idx += 1;
                    subs_assigned += 1;
                    file_idx += 1;
                }
            }
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

test "archive: symlink entry roundtrip" {
    const allocator = std.testing.allocator;

    // Symlink entries carry data (the target path) and are NOT empty streams.
    // They must have S_IFLNK (0xA000) in the upper 16 bits of win_attrib.
    const files = [_]FileEntry{
        .{ .name = "link.txt", .data = "target.txt", .is_symlink = true },
        .{ .name = "real.txt", .data = "Hello world\n" },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 2), contents.metadata.files.len);

    // Symlink entry: must NOT be empty stream, must have data = target path
    const link_info = contents.metadata.files[0];
    try std.testing.expectEqualStrings("link.txt", link_info.name.?);
    try std.testing.expect(!link_info.is_empty_stream); // symlinks carry data
    try std.testing.expectEqualStrings("target.txt", contents.file_data[0]);

    // Verify S_IFLNK in win_attrib upper bits
    if (link_info.win_attrib) |attr| {
        try std.testing.expectEqual(@as(u32, 0xA000), (attr >> 16) & 0xF000);
    } else {
        return error.TestUnexpectedResult; // win_attrib must be set for symlinks
    }

    // Regular file: unaffected
    try std.testing.expectEqualStrings("real.txt", contents.metadata.files[1].name.?);
    try std.testing.expectEqualStrings("Hello world\n", contents.file_data[1]);
}

test "archive: symlink LZMA2 roundtrip" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "dir/", .data = "", .is_dir = true },
        .{ .name = "dir/link", .data = "../other.txt", .is_symlink = true },
        .{ .name = "dir/file.txt", .data = "content" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);

    // Directory
    try std.testing.expect(contents.metadata.files[0].is_empty_stream);

    // Symlink — data-bearing, not empty stream
    const link_info = contents.metadata.files[1];
    try std.testing.expect(!link_info.is_empty_stream);
    try std.testing.expectEqualStrings("../other.txt", contents.file_data[1]);
    if (link_info.win_attrib) |attr| {
        try std.testing.expectEqual(@as(u32, 0xA000), (attr >> 16) & 0xF000);
    } else {
        return error.TestUnexpectedResult;
    }

    // Regular file
    try std.testing.expectEqualStrings("content", contents.file_data[2]);
}

test "archive: metadata roundtrip — mtime preserved" {
    const allocator = std.testing.allocator;

    // 2024-01-15 12:00:00 UTC as NTFS FILETIME
    // FILETIME = (unix_ts + 11644473600) * 10_000_000
    const test_mtime: u64 = (1705320000 + 11644473600) * 10_000_000;

    const files = [_]FileEntry{
        .{ .name = "timestamped.txt", .data = "hello", .mtime = test_mtime },
        .{ .name = "no_mtime.txt", .data = "world" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 2), contents.metadata.files.len);

    // File with mtime: must be preserved
    const f0 = contents.metadata.files[0];
    try std.testing.expectEqualStrings("timestamped.txt", f0.name.?);
    if (f0.mtime) |m| {
        try std.testing.expectEqual(test_mtime, m);
    } else {
        return error.TestUnexpectedResult; // mtime must round-trip
    }

    // File without mtime: should remain null
    // (or be set to something — just verify it doesn't crash)
    _ = contents.metadata.files[1].mtime;
}

test "archive: metadata roundtrip — win_attrib preserved for regular files" {
    const allocator = std.testing.allocator;

    // POSIX 0644 regular file: (0x81A4 << 16) | 0x8020
    const test_attrib: u32 = 0x81A48020;

    const files = [_]FileEntry{
        .{ .name = "perms.txt", .data = "data", .win_attrib = test_attrib },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    const f0 = contents.metadata.files[0];
    if (f0.win_attrib) |attr| {
        try std.testing.expectEqual(test_attrib, attr);
    } else {
        return error.TestUnexpectedResult; // win_attrib must round-trip
    }
}

test "archive: metadata roundtrip — ctime and atime preserved" {
    const allocator = std.testing.allocator;

    // 2024-01-15 12:00:00 UTC as NTFS FILETIME
    const test_ctime: u64 = (1705320000 + 11644473600) * 10_000_000;
    // 2024-06-01 00:00:00 UTC as NTFS FILETIME
    const test_atime: u64 = (1717200000 + 11644473600) * 10_000_000;

    const files = [_]FileEntry{
        .{ .name = "both_times.txt", .data = "hello", .ctime = test_ctime, .atime = test_atime },
        .{ .name = "ctime_only.txt", .data = "world", .ctime = test_ctime },
        .{ .name = "no_times.txt", .data = "bare" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);

    // File with both ctime and atime
    const f0 = contents.metadata.files[0];
    try std.testing.expectEqual(test_ctime, f0.ctime.?);
    try std.testing.expectEqual(test_atime, f0.atime.?);

    // File with ctime only
    const f1 = contents.metadata.files[1];
    try std.testing.expectEqual(test_ctime, f1.ctime.?);
    try std.testing.expectEqual(@as(?u64, null), f1.atime);

    // File with neither
    const f2 = contents.metadata.files[2];
    try std.testing.expectEqual(@as(?u64, null), f2.ctime);
    try std.testing.expectEqual(@as(?u64, null), f2.atime);
}

test "archive: reject bad signature" {
    const allocator = std.testing.allocator;
    const bad = [_]u8{0} ** 32;
    try std.testing.expectError(ArchiveError.NotArchive, read(&bad, allocator));
}

test "archive: createWithProgress fires callback" {
    const allocator = std.testing.allocator;

    const State = struct {
        call_count: u32 = 0,
        last_done: u64 = 0,
        last_total: u64 = 0,

        fn callback(done: u64, total: u64, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.call_count += 1;
            self.last_done = done;
            self.last_total = total;
        }
    };

    var state = State{};
    const progress = ProgressContext{
        .callback = &State.callback,
        .user_data = @ptrCast(&state),
    };

    // Create enough data to trigger compression progress (>64KB for chunked reporting)
    const big_data = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(big_data);
    @memset(big_data, 'A');

    const files = [_]FileEntry{
        .{ .name = "big.txt", .data = big_data },
    };

    const archive_data = try createWithProgress(&files, .lzma2, null, progress, allocator);
    defer allocator.free(archive_data);

    // Progress must have been called at least once
    try std.testing.expect(state.call_count > 0);
    // Final callback should report done == total (compression complete)
    try std.testing.expectEqual(state.last_done, state.last_total);
    try std.testing.expect(state.last_total > 0);
}

test "archive: readWithProgress fires callback on extraction" {
    const allocator = std.testing.allocator;

    // Create an LZMA2 archive first
    const data = "hello progress world";
    const files = [_]FileEntry{
        .{ .name = "test.txt", .data = data },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    // Now read it back with progress
    const State = struct {
        call_count: u32 = 0,
        last_done: u64 = 0,
        last_total: u64 = 0,

        fn callback(done: u64, total: u64, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.call_count += 1;
            self.last_done = done;
            self.last_total = total;
        }
    };

    var state = State{};
    const progress = ProgressContext{
        .callback = &State.callback,
        .user_data = @ptrCast(&state),
    };

    var contents = try readWithProgress(archive_data, null, progress, allocator);
    defer contents.deinit();

    // Should have called progress for the single folder
    try std.testing.expect(state.call_count > 0);
    // Final report should show done == total
    try std.testing.expectEqual(state.last_done, state.last_total);
    try std.testing.expect(state.last_total > 0);
    // Data should still be correct
    try std.testing.expectEqualStrings(data, contents.file_data[0]);
}

test "archive: FileEntry accepts group_index field" {
    const f = FileEntry{
        .name = "test.txt",
        .data = "hello",
        .group_index = 2,
    };
    try std.testing.expectEqual(@as(u32, 2), f.group_index);

    // Default should be 0
    const g = FileEntry{
        .name = "default.txt",
        .data = "world",
    };
    try std.testing.expectEqual(@as(u32, 0), g.group_index);
}

test "archive: createMultiFolder groups files into separate folders" {
    const allocator = std.testing.allocator;

    // 3 files in 2 groups
    var files = [_]FileEntry{
        .{ .name = "a.txt", .data = "hello from group 0", .group_index = 0 },
        .{ .name = "b.bin", .data = "binary group 1 data", .group_index = 1 },
        .{ .name = "c.txt", .data = "more text group 0", .group_index = 0 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(archive_data);

    // Read it back
    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // Should have 3 files
    try std.testing.expectEqual(@as(usize, 3), contents.file_data.len);

    // Files are reordered by group in the archive, so extraction
    // returns them in group order: group 0 files first, then group 1
    try std.testing.expectEqualStrings("hello from group 0", contents.file_data[0]);
    try std.testing.expectEqualStrings("more text group 0", contents.file_data[1]);
    try std.testing.expectEqualStrings("binary group 1 data", contents.file_data[2]);
}

test "archive: createMultiFolder with directories" {
    const allocator = std.testing.allocator;

    // Mix of files in different groups plus a directory
    var files = [_]FileEntry{
        .{ .name = "dir/", .data = "", .is_dir = true },
        .{ .name = "dir/text.txt", .data = "text content", .group_index = 0 },
        .{ .name = "dir/image.bin", .data = "fake image data", .group_index = 1 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // 3 entries total (2 data files + 1 dir)
    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);

    // Data files come first (group 0, then group 1), dir at end
    try std.testing.expectEqualStrings("text content", contents.file_data[0]);
    try std.testing.expectEqualStrings("fake image data", contents.file_data[1]);
    // Dir entry has empty data
    try std.testing.expectEqualStrings("", contents.file_data[2]);

    // Verify the dir is marked as empty stream
    try std.testing.expect(contents.metadata.files[2].is_empty_stream);
}

test "archive: createWithProgress auto-dispatches to multi-folder" {
    const allocator = std.testing.allocator;

    // Mixed group_indices should trigger multi-folder path
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "group zero", .group_index = 0 },
        .{ .name = "b.txt", .data = "group one", .group_index = 1 },
    };

    // This goes through createWithProgress, which should auto-detect mixed groups
    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // Verify the archive has 2 folders (one per group)
    try std.testing.expectEqual(@as(usize, 2), contents.metadata.folders.len);

    // Data should roundtrip in group order
    try std.testing.expectEqualStrings("group zero", contents.file_data[0]);
    try std.testing.expectEqualStrings("group one", contents.file_data[1]);
}

test "archive: single group_index does NOT trigger multi-folder" {
    const allocator = std.testing.allocator;

    // All files have the same group_index (default 0) — should use single-folder
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "aaa" },
        .{ .name = "b.txt", .data = "bbb" },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // Single folder path
    try std.testing.expectEqual(@as(usize, 1), contents.metadata.folders.len);
    try std.testing.expectEqualStrings("aaa", contents.file_data[0]);
    try std.testing.expectEqualStrings("bbb", contents.file_data[1]);
}

test "archive: createMultiFolder with encryption groups files into separate encrypted folders" {
    const allocator = std.testing.allocator;

    var files = [_]FileEntry{
        .{ .name = "secret.txt", .data = "classified text", .group_index = 0 },
        .{ .name = "secret.bin", .data = "classified binary", .group_index = 1 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2_aes, "password123", .{}, allocator);
    defer allocator.free(archive_data);

    // Must NOT be readable without password (encrypted)
    try std.testing.expectError(ArchiveError.UnsupportedFeature, read(archive_data, allocator));

    // Read with correct password
    var contents = try readWithPassword(archive_data, "password123", allocator);
    defer contents.deinit();

    // Should have 2 folders (one per group)
    try std.testing.expectEqual(@as(usize, 2), contents.metadata.folders.len);

    // Each folder should have 2 coders (LZMA2 + 7zAES)
    for (contents.metadata.folders) |folder| {
        try std.testing.expectEqual(@as(usize, 2), folder.coders.len);
        try std.testing.expectEqual(@as(usize, 1), folder.bind_pairs.len);
    }

    try std.testing.expectEqual(@as(usize, 2), contents.file_data.len);
    try std.testing.expectEqualStrings("classified text", contents.file_data[0]);
    try std.testing.expectEqualStrings("classified binary", contents.file_data[1]);
}

test "archive: createMultiFolder single group creates one folder" {
    const allocator = std.testing.allocator;

    // All files have default group_index=0 — createMultiFolder should still work,
    // producing exactly one folder (degenerate case).
    var files = [_]FileEntry{
        .{ .name = "a.txt", .data = "aaa" },
        .{ .name = "b.txt", .data = "bbb" },
    };

    const data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(data);

    var contents = try read(data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 2), contents.file_data.len);
    try std.testing.expectEqual(@as(usize, 1), contents.metadata.folders.len);
    try std.testing.expectEqualStrings("aaa", contents.file_data[0]);
    try std.testing.expectEqualStrings("bbb", contents.file_data[1]);
}

test "archive: createMultiFolder with 3 groups" {
    const allocator = std.testing.allocator;

    var files = [_]FileEntry{
        .{ .name = "a.txt", .data = "text data", .group_index = 0 },
        .{ .name = "b.bin", .data = "\x00\x01\x02", .group_index = 1 },
        .{ .name = "c.json", .data = "{\"k\":1}", .group_index = 2 },
        .{ .name = "d.txt", .data = "more text", .group_index = 0 },
    };

    const data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(data);

    var contents = try read(data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 4), contents.file_data.len);
    try std.testing.expectEqual(@as(usize, 3), contents.metadata.folders.len);

    // Group 0 files first (a.txt, d.txt), then group 1 (b.bin), then group 2 (c.json)
    try std.testing.expectEqualStrings("text data", contents.file_data[0]);
    try std.testing.expectEqualStrings("more text", contents.file_data[1]);
    try std.testing.expectEqualStrings("\x00\x01\x02", contents.file_data[2]);
    try std.testing.expectEqualStrings("{\"k\":1}", contents.file_data[3]);
}

test "archive: createMultiFolder preserves symlinks across groups" {
    const allocator = std.testing.allocator;

    var files = [_]FileEntry{
        .{ .name = "real.txt", .data = "real content", .group_index = 0 },
        .{ .name = "link.txt", .data = "target.txt", .is_symlink = true, .group_index = 1 },
        .{ .name = "other.bin", .data = "binary", .group_index = 1 },
    };

    const data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(data);

    var contents = try read(data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 3), contents.file_data.len);

    // Group 0 first (real.txt), then group 1 (link.txt symlink + other.bin)
    try std.testing.expectEqualStrings("real content", contents.file_data[0]);
    try std.testing.expectEqualStrings("target.txt", contents.file_data[1]);
    try std.testing.expectEqualStrings("binary", contents.file_data[2]);

    // Verify the symlink has S_IFLNK in win_attrib
    // The symlink is file index 1 (after sorting by group)
    const link_info = contents.metadata.files[1];
    if (link_info.win_attrib) |attr| {
        try std.testing.expectEqual(@as(u32, 0xA000), (attr >> 16) & 0xF000);
    } else {
        return error.TestUnexpectedResult;
    }
}
