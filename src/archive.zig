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
const nid = @import("nid.zig");
const varint = @import("varint.zig");
const range_source = @import("range_source.zig");
const Writer = @import("writer.zig").Writer;
pub const ProgressContext = @import("progress.zig").ProgressContext;
pub const RangeSource = range_source.RangeSource;
pub const RangeReadError = range_source.RangeReadError;

/// Zig 0.16: std.crypto.random was removed. Use io.randomSecure() with a
/// process-wide single-threaded Io (safe per the bzip2z firsthand note in
/// the migration doc — only Io.concurrent is unsupported on that handle).
/// Falls back to non-secure pseudo-random if entropy source unavailable.
fn fillRandomBytes(buf: []u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    io.randomSecure(buf) catch io.random(buf);
}

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
    PasswordRequired,
    ResourceLimitExceeded,
    InputReadFailed,
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

/// Metadata-derived resource summary for callers that need to budget archive
/// work before decompression. Sizes are unpacked payload sizes from 7z folder
/// and substream metadata, not retained output buffers.
pub const ArchiveStats = struct {
    file_count: u64 = 0,
    data_file_count: u64 = 0,
    folder_count: u64 = 0,
    substream_count: u64 = 0,
    total_pack_size: u64 = 0,
    total_unpack_size: u64 = 0,
    largest_folder_unpack_size: u64 = 0,
    max_file_unpack_size: u64 = 0,
};

/// Guardrails and progress for deep archive verification. Limits are checked
/// against metadata before any folder is decompressed, so callers can reject
/// expansion bombs while still using their own tracked allocator.
pub const VerifyOptions = struct {
    password: ?[]const u8 = null,
    progress: ProgressContext = .{},
    max_total_unpack_size: ?u64 = null,
    max_folder_unpack_size: ?u64 = null,
    max_file_unpack_size: ?u64 = null,
    max_expansion_ratio: ?u64 = null,
};

/// Re-export LevelParams for consumers.
pub const LevelParams = codec.LevelParams;

/// Options for archive creation with full control over threading and header encryption.
pub const CreateOptions = struct {
    method: Method = .lzma2,
    password: ?[]const u8 = null,
    level: u4 = LevelParams.DEFAULT_LEVEL,
    thread_count: u32 = 0, // 0 = auto, 1 = single-threaded, N = N threads
    encrypt_header: bool = false, // -mhe=on: encrypt the archive header too
    progress: ProgressContext = .{},
};

/// Create a .7z archive in memory with full control over all options.
pub fn createWithOptions(files: []const FileEntry, opts: CreateOptions, allocator: std.mem.Allocator) ![]u8 {
    // Check if multi-folder is needed (mixed group_indices among data files)
    const method = if (opts.password != null and opts.method == .lzma2) Method.lzma2_aes else opts.method;
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
            return createMultiFolder(files, method, opts.password, opts.level, opts.progress, allocator);
        }
    }

    const lp = LevelParams.fromLevel(opts.level);
    const archive_data = switch (method) {
        .copy => try createCopy(files, allocator),
        .lzma2 => try createLzma2WithThreads(files, lp.dict_size, lp.nice_len, opts.thread_count, opts.progress, allocator),
        .lzma2_aes => try createLzma2AesWithOptions(files, opts.password orelse return error.PasswordRequired, lp.dict_size, lp.nice_len, opts.thread_count, opts.encrypt_header, opts.progress, allocator),
    };
    return archive_data;
}

/// Create a .7z archive in memory using LZMA2 at the default compression level.
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

/// Create a .7z archive with progress reporting (uses default level 5).
/// Automatically dispatches to multi-folder creation when files have mixed group_indices.
pub fn createWithProgress(files: []const FileEntry, method: Method, password: ?[]const u8, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    return createWithLevel(files, method, password, LevelParams.DEFAULT_LEVEL, progress, allocator);
}

/// Create a .7z archive with progress reporting and explicit compression level (0-9).
pub fn createWithLevel(files: []const FileEntry, method: Method, password: ?[]const u8, level: u4, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
            return createMultiFolder(files, method, password, level, progress, allocator);
        }
    }

    const lp = LevelParams.fromLevel(level);
    return switch (method) {
        .copy => createCopy(files, allocator),
        .lzma2 => createLzma2(files, lp.dict_size, lp.nice_len, progress, allocator),
        .lzma2_aes => createLzma2Aes(files, password orelse return error.PasswordRequired, lp.dict_size, lp.nice_len, progress, allocator),
    };
}

/// Create a .7z archive in memory using LZMA2 compression.
fn createLzma2(files: []const FileEntry, dict_size: u32, nice_len: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    return createLzma2WithThreads(files, dict_size, nice_len, 0, progress, allocator);
}

/// Create a .7z archive in memory using LZMA2 compression with explicit thread count.
fn createLzma2WithThreads(files: []const FileEntry, dict_size: u32, nice_len: u32, thread_count: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
    const compressed = try codec.compressLzma2WithThreads(raw_data, dict_size, nice_len, thread_count, progress, allocator);
    defer allocator.free(compressed);

    // Build metadata. Attach each allocation to archive_meta as soon as it exists
    // so the single `defer archive_meta.deinit()` is the sole owner — this
    // closes the prior leak gap (only `coders` had an errdefer) and removes the
    // latent double-free where that lone errdefer coexisted with deinit().
    var data_file_count: usize = 0;
    for (files) |f| {
        if (!f.is_dir) data_file_count += 1;
    }
    const clamped_dict = @min(dict_size, @as(u32, @intCast(@min(total_unpack_size, 0xFFFFFFFF))));

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{ .pack_pos = 0, .pack_sizes = &.{}, .pack_crcs = null },
        .folders = &.{},
        .sub_streams = .{ .num_unpack_per_folder = &.{}, .unpack_sizes = &.{}, .digests = &.{} },
        .files = &.{},
        .allocator = allocator,
    };
    defer archive_meta.deinit();

    // pack_info
    const pack_sizes = try allocator.alloc(u64, 1);
    pack_sizes[0] = compressed.len;
    archive_meta.pack_info.?.pack_sizes = pack_sizes;

    // folder + single LZMA2 coder (attach each link before allocating the next)
    const folders = try allocator.alloc(meta.Folder, 1);
    folders[0] = .{ .coders = &.{}, .bind_pairs = &.{}, .packed_indices = &.{}, .unpack_sizes = &.{}, .unpack_crc = null };
    archive_meta.folders = folders;

    const coders = try allocator.alloc(meta.Coder, 1);
    // LZMA2 method: CodecId = 0x21, properties = 1 byte (dict size indicator)
    coders[0] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
    folders[0].coders = coders;

    const method_id = try allocator.alloc(u8, 1);
    method_id[0] = 0x21;
    coders[0].method_id = method_id;

    // LZMA2 property byte: encodes the actual dict_size used by the encoder.
    const props = try allocator.alloc(u8, 1);
    props[0] = calcLzma2DictProp(clamped_dict);
    coders[0].properties = props;

    const unpack_sizes = try allocator.alloc(u64, 1);
    unpack_sizes[0] = total_unpack_size;
    folders[0].unpack_sizes = unpack_sizes;

    // Substream info (only for non-directory files with data)
    const sub_sizes = try allocator.alloc(u64, data_file_count);
    archive_meta.sub_streams.?.unpack_sizes = sub_sizes;
    const sub_digests = try allocator.alloc(?u32, data_file_count);
    archive_meta.sub_streams.?.digests = sub_digests;
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

    const num_per_folder = try allocator.alloc(u64, 1);
    num_per_folder[0] = data_file_count;
    archive_meta.sub_streams.?.num_unpack_per_folder = num_per_folder;

    // File info (all entries: files, directories, AND symlinks). Pre-initialize
    // names/xattrs to null so deinit stays safe if a later dupe fails mid-loop.
    const file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (file_infos) |*fi| fi.* = .{
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
    archive_meta.files = file_infos;
    for (files, 0..) |f, i| {
        // dupe name first and store it before duping xattrs, so a failing xattr
        // dupe doesn't strand an already-allocated name.
        file_infos[i].name = try allocator.dupe(u8, f.name);
        file_infos[i].is_empty_stream = f.is_dir; // only dirs are empty streams; symlinks carry data
        file_infos[i].ctime = f.ctime;
        file_infos[i].atime = f.atime;
        file_infos[i].mtime = f.mtime;
        file_infos[i].win_attrib = computeWinAttrib(f);
        file_infos[i].xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null;
    }

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
fn createLzma2Aes(files: []const FileEntry, password: []const u8, dict_size: u32, nice_len: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    return createLzma2AesWithOptions(files, password, dict_size, nice_len, 0, false, progress, allocator);
}

/// Create a .7z archive with LZMA2+AES, explicit thread count, and optional header encryption.
fn createLzma2AesWithOptions(files: []const FileEntry, password: []const u8, dict_size: u32, nice_len: u32, thread_count: u32, encrypt_header: bool, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
    const compressed = try codec.compressLzma2WithThreads(raw_data, dict_size, nice_len, thread_count, progress, allocator);
    defer allocator.free(compressed);

    // Step 3: Encrypt with AES-256-CBC
    // Generate random salt and IV
    var salt: [8]u8 = undefined;
    var iv: [16]u8 = undefined;
    fillRandomBytes(&salt);
    fillRandomBytes(&iv);

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

    // Step 4: Build metadata with a 2-coder folder (LZMA2 + 7zAES). Attach each
    // allocation to archive_meta as it is created so the single
    // `defer archive_meta.deinit()` is the sole owner — no leak gap, no double-free.
    var data_file_count2: usize = 0;
    for (files) |f| {
        if (!f.is_dir) data_file_count2 += 1;
    }
    const clamped_dict = @min(dict_size, @as(u32, @intCast(@min(total_unpack_size, 0xFFFFFFFF))));
    const encoded_aes_props = aes_crypt.encodeProperties(aes_props);

    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{ .pack_pos = 0, .pack_sizes = &.{}, .pack_crcs = null },
        .folders = &.{},
        .sub_streams = .{ .num_unpack_per_folder = &.{}, .unpack_sizes = &.{}, .digests = &.{} },
        .files = &.{},
        .allocator = allocator,
    };
    defer archive_meta.deinit();

    // pack_info
    const pack_sizes = try allocator.alloc(u64, 1);
    pack_sizes[0] = encrypted.len;
    archive_meta.pack_info.?.pack_sizes = pack_sizes;

    // Folder with 2 coders; attach each link to its parent before the next alloc.
    const folders = try allocator.alloc(meta.Folder, 1);
    folders[0] = .{ .coders = &.{}, .bind_pairs = &.{}, .packed_indices = &.{}, .unpack_sizes = &.{}, .unpack_crc = null };
    archive_meta.folders = folders;

    const coders = try allocator.alloc(meta.Coder, 2);
    coders[0] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
    coders[1] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
    folders[0].coders = coders;

    // Coder 0: LZMA2
    const lzma2_mid = try allocator.alloc(u8, 1);
    lzma2_mid[0] = 0x21;
    coders[0].method_id = lzma2_mid;
    const lzma2_props = try allocator.alloc(u8, 1);
    lzma2_props[0] = calcLzma2DictProp(clamped_dict);
    coders[0].properties = lzma2_props;

    // Coder 1: 7zAES
    const aes_mid = try allocator.alloc(u8, 4);
    @memcpy(aes_mid, &[_]u8{ 0x06, 0xF1, 0x07, 0x01 });
    coders[1].method_id = aes_mid;
    const aes_prop_data = try allocator.alloc(u8, encoded_aes_props.len);
    @memcpy(aes_prop_data, encoded_aes_props.data[0..encoded_aes_props.len]);
    coders[1].properties = aes_prop_data;

    // Bind pair: AES output (stream 1) → LZMA2 input (stream 0)
    const bind_pairs = try allocator.alloc(meta.BindPair, 1);
    bind_pairs[0] = .{ .in_index = 0, .out_index = 1 };
    folders[0].bind_pairs = bind_pairs;

    // Unpack sizes: [0]=LZMA2 output (final), [1]=AES output (intermediate=compressed len)
    const unpack_sizes = try allocator.alloc(u64, 2);
    unpack_sizes[0] = total_unpack_size;
    unpack_sizes[1] = compressed.len;
    folders[0].unpack_sizes = unpack_sizes;

    // Substream info (only for non-directory files with data)
    const sub_sizes = try allocator.alloc(u64, data_file_count2);
    archive_meta.sub_streams.?.unpack_sizes = sub_sizes;
    const sub_digests = try allocator.alloc(?u32, data_file_count2);
    archive_meta.sub_streams.?.digests = sub_digests;
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

    const num_per_folder2 = try allocator.alloc(u64, 1);
    num_per_folder2[0] = data_file_count2;
    archive_meta.sub_streams.?.num_unpack_per_folder = num_per_folder2;

    // File info (all entries). Pre-initialize so deinit stays safe if a dupe fails.
    const file_infos = try allocator.alloc(meta.FileInfo, files.len);
    for (file_infos) |*fi| fi.* = .{
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
    archive_meta.files = file_infos;
    for (files, 0..) |f, i| {
        file_infos[i].name = try allocator.dupe(u8, f.name);
        file_infos[i].is_empty_stream = f.is_dir;
        file_infos[i].ctime = f.ctime;
        file_infos[i].atime = f.atime;
        file_infos[i].mtime = f.mtime;
        file_infos[i].win_attrib = computeWinAttrib(f);
        file_infos[i].xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null;
    }

    // Encode next-header (kHeader)
    const next_header = try encoder.encodeNextHeader(archive_meta, allocator);
    defer allocator.free(next_header);

    if (encrypt_header) {
        // -mhe=on: wrap the kHeader as kEncodedHeader (compress + encrypt the header itself)
        const enc_result = try encryptHeader(next_header, encrypted.len, password, allocator);
        defer allocator.free(enc_result.header_pack_data);
        defer allocator.free(enc_result.encoded_header_descriptor);

        const descriptor_crc = crc32.hash(enc_result.encoded_header_descriptor);

        // Archive layout: [sig][content_pack][header_pack][encoded_header_descriptor]
        const sig = sig_header.encode(.{
            .major_version = 0,
            .minor_version = 4,
            .next_header_offset = encrypted.len + enc_result.header_pack_data.len,
            .next_header_size = enc_result.encoded_header_descriptor.len,
            .next_header_crc = descriptor_crc,
        });

        const total_size = sig_header.HEADER_SIZE + encrypted.len + enc_result.header_pack_data.len + enc_result.encoded_header_descriptor.len;
        const archive_out = try allocator.alloc(u8, total_size);
        var off: usize = 0;
        @memcpy(archive_out[off .. off + sig_header.HEADER_SIZE], &sig);
        off += sig_header.HEADER_SIZE;
        @memcpy(archive_out[off .. off + encrypted.len], encrypted);
        off += encrypted.len;
        @memcpy(archive_out[off .. off + enc_result.header_pack_data.len], enc_result.header_pack_data);
        off += enc_result.header_pack_data.len;
        @memcpy(archive_out[off..], enc_result.encoded_header_descriptor);

        return archive_out;
    } else {
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
}

/// Create a multi-folder .7z archive where files are grouped by group_index.
/// Each unique group_index becomes a separate folder (solid block), enabling
/// MIME-type-aware grouping for better compression of heterogeneous file sets.
fn createMultiFolder(files: []const FileEntry, method: Method, password: ?[]const u8, level: u4, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    const is_encrypted = method == .lzma2_aes;
    const lp = LevelParams.fromLevel(level);

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
    var group_ids = std.ArrayListUnmanaged(u32).empty;
    defer group_ids.deinit(allocator);
    var files_per_group = std.ArrayListUnmanaged(usize).empty;
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
        return createLzma2(files, lp.dict_size, lp.nice_len, progress, allocator);
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
                .lzma2, .lzma2_aes => try codec.compressLzma2(raw, lp.dict_size, lp.nice_len, progress, allocator),
                .copy => try allocator.dupe(u8, raw),
            };

            // Encrypt if needed
            if (is_encrypted) {
                defer allocator.free(lzma2_compressed); // free the intermediate compressed data
                const pw = password orelse return error.PasswordRequired;

                // Record pre-encryption compressed size
                group_lzma2_sizes[gi] = lzma2_compressed.len;

                // Generate random salt and IV per group
                var salt: [8]u8 = undefined;
                var iv: [16]u8 = undefined;
                fillRandomBytes(&salt);
                fillRandomBytes(&iv);

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
        // Attach each allocation to folders[gi] as it is created so the
        // folders_owned errdefer (which frees every coder's method_id/properties
        // plus the arrays) covers partially-built folders — no intra-loop leak.
        if (is_encrypted) {
            // 2-coder pipeline: LZMA2 + 7zAES (same structure as createLzma2Aes)
            const coders = try allocator.alloc(meta.Coder, 2);
            coders[0] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
            coders[1] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
            folders[gi].coders = coders;

            // Coder 0: LZMA2
            const lzma2_mid = try allocator.alloc(u8, 1);
            lzma2_mid[0] = 0x21;
            coders[0].method_id = lzma2_mid;
            const lzma2_props = try allocator.alloc(u8, 1);
            const group_data_len = @as(u32, @intCast(@min(group_unpack_sizes[gi], 0xFFFFFFFF)));
            lzma2_props[0] = calcLzma2DictProp(@min(lp.dict_size, group_data_len));
            coders[0].properties = lzma2_props;

            // Coder 1: 7zAES
            const aes_mid = try allocator.alloc(u8, 4);
            @memcpy(aes_mid, &[_]u8{ 0x06, 0xF1, 0x07, 0x01 });
            coders[1].method_id = aes_mid;
            const encoded_aes_props = aes_crypt.encodeProperties(group_aes_props[gi]);
            const aes_prop_data = try allocator.alloc(u8, encoded_aes_props.len);
            @memcpy(aes_prop_data, encoded_aes_props.data[0..encoded_aes_props.len]);
            coders[1].properties = aes_prop_data;

            // Bind pair: AES output (stream 1) → LZMA2 input (stream 0)
            const bind_pairs = try allocator.alloc(meta.BindPair, 1);
            bind_pairs[0] = .{ .in_index = 0, .out_index = 1 };
            folders[gi].bind_pairs = bind_pairs;

            // Unpack sizes: [0]=LZMA2 output (final), [1]=AES output (intermediate=compressed len)
            const unpack_sizes = try allocator.alloc(u64, 2);
            unpack_sizes[0] = group_unpack_sizes[gi];
            unpack_sizes[1] = group_lzma2_sizes[gi];
            folders[gi].unpack_sizes = unpack_sizes;
        } else {
            // Single-coder folder (LZMA2 or Copy)
            const coders = try allocator.alloc(meta.Coder, 1);
            coders[0] = .{ .method_id = &.{}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 };
            folders[gi].coders = coders;

            const mid = try allocator.alloc(u8, 1);
            coders[0].method_id = mid;
            switch (method) {
                .lzma2 => {
                    mid[0] = 0x21; // LZMA2
                    const group_data_len = @as(u32, @intCast(@min(group_unpack_sizes[gi], 0xFFFFFFFF)));
                    const props = try allocator.alloc(u8, 1);
                    props[0] = calcLzma2DictProp(@min(lp.dict_size, group_data_len));
                    coders[0].properties = props;
                },
                .copy => {
                    mid[0] = 0x00; // Copy has no properties; leave &.{}
                },
                .lzma2_aes => unreachable,
            }

            const unpack_sizes = try allocator.alloc(u64, 1);
            unpack_sizes[0] = group_unpack_sizes[gi];
            folders[gi].unpack_sizes = unpack_sizes;
        }
    }

    // PackInfo — one pack_size per folder. These standalone arrays are owned by
    // archive_meta once it is built; until then a streams_owned-gated errdefer
    // frees them so a mid-build allocation failure cannot leak them.
    var streams_owned = true;
    var pack_sizes = try allocator.alloc(u64, num_groups);
    errdefer {
        if (streams_owned) allocator.free(pack_sizes);
    }
    for (0..num_groups) |gi| {
        pack_sizes[gi] = compressed_blocks[gi].len;
    }

    // SubStreamInfo
    var sub_sizes = try allocator.alloc(u64, num_data_files);
    errdefer {
        if (streams_owned) allocator.free(sub_sizes);
    }
    var sub_digests = try allocator.alloc(?u32, num_data_files);
    errdefer {
        if (streams_owned) allocator.free(sub_digests);
    }
    var num_per_folder = try allocator.alloc(u64, num_groups);
    errdefer {
        if (streams_owned) allocator.free(num_per_folder);
    }
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
        // dupe name first and store it before duping xattrs, so a failing xattr
        // dupe doesn't strand an already-allocated name (slot pre-init'd to null).
        file_infos[out_i].name = try allocator.dupe(u8, f.name);
        file_infos[out_i].is_empty_stream = f.is_dir;
        file_infos[out_i].ctime = f.ctime;
        file_infos[out_i].atime = f.atime;
        file_infos[out_i].mtime = f.mtime;
        file_infos[out_i].win_attrib = computeWinAttrib(f);
        file_infos[out_i].xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null;
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
    streams_owned = false;

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

/// Result of encrypting a header for -mhe=on support.
const EncryptedHeaderResult = struct {
    header_pack_data: []u8, // encrypted+compressed header data (the pack stream)
    encoded_header_descriptor: []u8, // kEncodedHeader descriptor bytes (what next_header points to)
};

/// Encrypt a kHeader into kEncodedHeader format for -mhe=on.
/// content_pack_size is the total size of the content pack streams (used to compute pack_pos).
fn encryptHeader(header_data: []const u8, content_pack_size: usize, password: []const u8, allocator: std.mem.Allocator) !EncryptedHeaderResult {
    // Step 1: Compress the header with LZMA2
    const lp = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const compressed_header = try codec.compressLzma2(header_data, lp.dict_size, lp.nice_len, .{}, allocator);
    defer allocator.free(compressed_header);

    // Step 2: Encrypt with AES-256-CBC
    var salt: [8]u8 = undefined;
    var iv: [16]u8 = undefined;
    fillRandomBytes(&salt);
    fillRandomBytes(&iv);

    const aes_props = aes_crypt.AesProperties{
        .num_cycles_power = 19,
        .salt = salt ++ ([_]u8{0} ** 8),
        .salt_size = 8,
        .iv = iv,
        .iv_size = 16,
    };

    const key = aes_crypt.deriveKey(password, aes_props);

    const padded_len = (compressed_header.len + 15) & ~@as(usize, 15);
    var enc_header = try allocator.alloc(u8, padded_len);
    errdefer allocator.free(enc_header);
    @memcpy(enc_header[0..compressed_header.len], compressed_header);
    if (padded_len > compressed_header.len) {
        @memset(enc_header[compressed_header.len..], 0);
    }

    aes_crypt.encryptCbc(enc_header, key, iv) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.StructuralError,
    };

    // Step 3: Build the kEncodedHeader descriptor
    // This is: kEncodedHeader + MainStreamsInfo (PackInfo + UnpackInfo) + kEnd
    var w = Writer.init(allocator);
    errdefer w.deinit();

    try w.writeNid(.encoded_header);

    // PackInfo: pack_pos = content_pack_size (header pack stream follows content pack streams)
    try w.writeNid(.pack_info);
    try w.writeUint64(@intCast(content_pack_size)); // pack_pos
    try w.writeUint64(1); // num_pack_streams = 1
    try w.writeNid(.size);
    try w.writeUint64(@intCast(enc_header.len)); // packed size
    try w.writeNid(.end); // end PackInfo

    // UnpackInfo
    try w.writeNid(.unpack_info);
    try w.writeNid(.folder);
    try w.writeUint64(1); // num_folders = 1
    try w.writeByte(0); // External = 0 (inline)

    // Folder record: 2 coders (LZMA2 + 7zAES), 1 bind pair
    // NumCoders
    try w.writeUint64(2);

    // Coder 0: LZMA2 (method_id = 0x21, 1 property byte)
    // Flags: (id_size & 0xF) | 0x20 (has properties)
    try w.writeByte(0x21); // id_size=1 | properties_flag=0x20 => 1 | 0x20 = 0x21
    try w.writeByte(0x21); // method_id = 0x21 (LZMA2)
    try w.writeUint64(1); // properties_size
    try w.writeByte(calcLzma2DictProp(@as(u32, @intCast(@min(header_data.len, 0xFFFFFFFF))))); // dict prop

    // Coder 1: 7zAES (method_id = 06 F1 07 01, properties)
    const encoded_aes_props = aes_crypt.encodeProperties(aes_props);
    const aes_props_len = encoded_aes_props.len;
    try w.writeByte(@as(u8, 4) | 0x20); // id_size=4 | properties_flag=0x20 = 0x24
    try w.writeByte(0x06);
    try w.writeByte(0xF1);
    try w.writeByte(0x07);
    try w.writeByte(0x01);
    try w.writeUint64(aes_props_len); // properties_size
    for (encoded_aes_props.data[0..aes_props_len]) |b| {
        try w.writeByte(b);
    }

    // BindPair: AES output (stream 1) → LZMA2 input (stream 0)
    try w.writeUint64(0); // in_index
    try w.writeUint64(1); // out_index

    // kCodersUnpackSize: 2 unpack sizes
    try w.writeNid(.coders_unpack_size);
    try w.writeUint64(header_data.len); // LZMA2 output = original header size
    try w.writeUint64(compressed_header.len); // AES output = compressed size

    try w.writeNid(.end); // end UnpackInfo

    try w.writeNid(.end); // end kEncodedHeader

    const descriptor = try w.toOwnedSlice();
    errdefer allocator.free(descriptor);

    return .{
        .header_pack_data = enc_header,
        .encoded_header_descriptor = descriptor,
    };
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

fn parseArchiveMetadata(archive_data: []const u8, password: ?[]const u8, allocator: std.mem.Allocator) ArchiveError!meta.ArchiveMetadata {
    // Parse signature header
    const hdr = sig_header.parse(archive_data) catch |e| switch (e) {
        error.NotArchive => return ArchiveError.NotArchive,
        error.ChecksumError => return ArchiveError.ChecksumError,
        error.TruncatedInput => return ArchiveError.TruncatedInput,
    };

    // Validate next-header bounds
    const nh_start_u64 = std.math.add(u64, sig_header.HEADER_SIZE, hdr.next_header_offset) catch
        return ArchiveError.TruncatedInput;
    const nh_end_u64 = std.math.add(u64, nh_start_u64, hdr.next_header_size) catch
        return ArchiveError.TruncatedInput;
    if (nh_end_u64 > archive_data.len) return ArchiveError.TruncatedInput;
    const nh_start: usize = @intCast(nh_start_u64);
    const nh_end: usize = @intCast(nh_end_u64);

    // Validate next-header CRC
    const nh_bytes = archive_data[nh_start..nh_end];
    if (crc32.hash(nh_bytes) != hdr.next_header_crc) return ArchiveError.ChecksumError;

    // Parse metadata (pass full archive for encoded header support)
    return meta.parseNextHeaderFull(nh_bytes, archive_data, password, allocator) catch |e| switch (e) {
        error.ChecksumError => return ArchiveError.ChecksumError,
        error.ResourceLimitExceeded => return ArchiveError.ResourceLimitExceeded,
        error.StructuralError => return ArchiveError.StructuralError,
        error.UnsupportedFeature => return ArchiveError.UnsupportedFeature,
        error.EndOfStream => return ArchiveError.EndOfStream,
        error.OutOfMemory => return ArchiveError.OutOfMemory,
        error.ReadFailed => return ArchiveError.InputReadFailed,
    };
}

fn mapRangeSourceError(err: range_source.Error) ArchiveError {
    return switch (err) {
        error.TruncatedInput => ArchiveError.TruncatedInput,
        error.ReadFailed => ArchiveError.InputReadFailed,
        error.OutOfMemory => ArchiveError.OutOfMemory,
    };
}

fn parseArchiveMetadataRange(source: RangeSource, password: ?[]const u8, allocator: std.mem.Allocator) ArchiveError!meta.ArchiveMetadata {
    var signature_bytes: [sig_header.HEADER_SIZE]u8 = undefined;
    source.readExact(0, &signature_bytes) catch |err| return mapRangeSourceError(err);
    const hdr = sig_header.parse(&signature_bytes) catch |err| switch (err) {
        error.NotArchive => return ArchiveError.NotArchive,
        error.ChecksumError => return ArchiveError.ChecksumError,
        error.TruncatedInput => return ArchiveError.TruncatedInput,
    };

    const next_header_start = std.math.add(u64, sig_header.HEADER_SIZE, hdr.next_header_offset) catch
        return ArchiveError.TruncatedInput;
    const next_header_end = std.math.add(u64, next_header_start, hdr.next_header_size) catch
        return ArchiveError.TruncatedInput;
    if (next_header_end > source.len) return ArchiveError.TruncatedInput;

    const next_header_range = source.readRange(next_header_start, hdr.next_header_size, allocator) catch |err|
        return mapRangeSourceError(err);
    defer next_header_range.deinit(allocator);
    const next_header = next_header_range.bytes;
    if (crc32.hash(next_header) != hdr.next_header_crc) return ArchiveError.ChecksumError;

    return meta.parseNextHeaderFromSource(next_header, source, password, allocator) catch |err| switch (err) {
        error.ChecksumError => return ArchiveError.ChecksumError,
        error.ResourceLimitExceeded => return ArchiveError.ResourceLimitExceeded,
        error.StructuralError => return ArchiveError.StructuralError,
        error.UnsupportedFeature => return ArchiveError.UnsupportedFeature,
        error.EndOfStream => return ArchiveError.EndOfStream,
        error.OutOfMemory => return ArchiveError.OutOfMemory,
        error.ReadFailed => return ArchiveError.InputReadFailed,
    };
}

fn metadataStats(metadata: meta.ArchiveMetadata) ArchiveStats {
    var stats = ArchiveStats{
        .file_count = metadata.files.len,
        .folder_count = metadata.folders.len,
    };

    if (metadata.pack_info) |pi| {
        for (pi.pack_sizes) |size| stats.total_pack_size += size;
    }

    for (metadata.folders) |folder| {
        const folder_size = folder.getFinalUnpackSize();
        stats.total_unpack_size += folder_size;
        stats.largest_folder_unpack_size = @max(stats.largest_folder_unpack_size, folder_size);
    }

    if (metadata.sub_streams) |ss| {
        stats.substream_count = ss.unpack_sizes.len;
        for (ss.unpack_sizes) |size| {
            stats.max_file_unpack_size = @max(stats.max_file_unpack_size, size);
        }
    } else {
        stats.substream_count = metadata.folders.len;
        stats.max_file_unpack_size = stats.largest_folder_unpack_size;
    }

    for (metadata.files) |file| {
        if (!file.is_empty_stream) stats.data_file_count += 1;
    }

    return stats;
}

fn validateResourceLimits(stats: ArchiveStats, archive_len: u64, opts: VerifyOptions) ArchiveError!void {
    if (opts.max_total_unpack_size) |limit| {
        if (stats.total_unpack_size > limit) return ArchiveError.ResourceLimitExceeded;
    }
    if (opts.max_folder_unpack_size) |limit| {
        if (stats.largest_folder_unpack_size > limit) return ArchiveError.ResourceLimitExceeded;
    }
    if (opts.max_file_unpack_size) |limit| {
        if (stats.max_file_unpack_size > limit) return ArchiveError.ResourceLimitExceeded;
    }
    if (opts.max_expansion_ratio) |ratio| {
        const denominator: u64 = @max(1, archive_len);
        if (ratio == 0) return ArchiveError.ResourceLimitExceeded;
        if (stats.total_unpack_size > denominator *| ratio) return ArchiveError.ResourceLimitExceeded;
    }
}

fn folderPackStreamCount(folder: meta.Folder) usize {
    var total_in: u64 = 0;
    for (folder.coders) |coder| {
        total_in += coder.num_in_streams;
    }
    return @intCast(total_in - folder.bind_pairs.len);
}

fn folderSubstreamCounts(metadata: meta.ArchiveMetadata, allocator: std.mem.Allocator) ArchiveError!struct {
    counts: []const u64,
    owned: ?[]u64,
} {
    if (metadata.sub_streams) |ss| {
        return .{ .counts = ss.num_unpack_per_folder, .owned = null };
    }

    const counts = try allocator.alloc(u64, metadata.folders.len);
    @memset(counts, 1);
    return .{ .counts = counts, .owned = counts };
}

fn expectedSubstreamCrc(metadata: meta.ArchiveMetadata, folder_idx: usize, folder_sub_count: usize, digest_idx: *usize) ?u32 {
    if (folder_sub_count == 1 and metadata.folders[folder_idx].unpack_crc != null) {
        return metadata.folders[folder_idx].unpack_crc;
    }
    const ss = metadata.sub_streams orelse return null;
    if (digest_idx.* >= ss.digests.len) return null;
    const digest = ss.digests[digest_idx.*];
    digest_idx.* += 1;
    return digest;
}

fn substreamUnpackSize(metadata: meta.ArchiveMetadata, sub_idx: usize, folder_unpack_size: u64) u64 {
    if (metadata.sub_streams) |ss| {
        if (sub_idx < ss.unpack_sizes.len) return ss.unpack_sizes[sub_idx];
        return 0;
    }
    return folder_unpack_size;
}

fn cleanupFileData(file_data: [][]const u8, allocator: std.mem.Allocator) void {
    for (file_data) |data| {
        allocator.free(data);
    }
    allocator.free(file_data);
}

/// Parse archive metadata without decompressing payloads, returning resource
/// estimates that callers can use for memory admission and scheduling.
pub fn inspect(archive_data: []const u8, password: ?[]const u8, allocator: std.mem.Allocator) ArchiveError!ArchiveStats {
    var metadata = try parseArchiveMetadata(archive_data, password, allocator);
    defer metadata.deinit();
    return metadataStats(metadata);
}

/// Deep-verify archive payloads without retaining extracted files. This still
/// decompresses one folder at a time with the current codec API, but it checks
/// metadata limits before decompression and discards each folder immediately
/// after CRC validation.
pub fn verify(archive_data: []const u8, opts: VerifyOptions, allocator: std.mem.Allocator) ArchiveError!ArchiveStats {
    var slice_source = range_source.SliceSource{ .data = archive_data };
    return verifyRange(slice_source.source(), opts, allocator);
}

/// Deep-verify through bounded random-access reads. The callback may return
/// short reads. Verification retains at most one packed folder at a time and
/// streams decoded output through the same CRC/resource-limit sink as verify().
pub fn verifyRange(source: RangeSource, opts: VerifyOptions, allocator: std.mem.Allocator) ArchiveError!ArchiveStats {
    var metadata = try parseArchiveMetadataRange(source, opts.password, allocator);
    defer metadata.deinit();

    const stats = metadataStats(metadata);
    try validateResourceLimits(stats, source.len, opts);

    try verifyPayloadsStreaming(source, metadata, opts, allocator);
    return stats;
}

const StreamingVerifySink = struct {
    metadata: meta.ArchiveMetadata,
    opts: VerifyOptions,
    folder_idx: usize,
    folder_sub_count: usize,
    unpack_size: u64,
    digest_idx: *usize,
    sub_idx: *usize,
    file_idx: *usize,
    total_decoded: *u64,
    folder_crc: crc32.State = crc32.State.init(),
    sub_crc: crc32.State = crc32.State.init(),
    folder_bytes: u64 = 0,
    sub_bytes: u64 = 0,
    sub_size: u64 = 0,
    subs_assigned: usize = 0,
    sub_expected_crc: ?u32 = null,
    active_substream: bool = false,

    fn outputSink(self: *StreamingVerifySink) codec.OutputSink {
        return .{
            .ptr = self,
            .writeFn = writeThunk,
        };
    }

    fn writeThunk(ctx: *anyopaque, data: []const u8) codec.SinkError!void {
        const self: *StreamingVerifySink = @ptrCast(@alignCast(ctx));
        try self.write(data);
    }

    fn checkedAdd(a: u64, b: u64) codec.SinkError!u64 {
        return std.math.add(u64, a, b) catch return codec.SinkError.ResourceLimitExceeded;
    }

    fn folderCrcMirrorsSubstream(self: StreamingVerifySink) bool {
        return self.folder_sub_count == 1;
    }

    fn enforceWholeChunkLimits(self: StreamingVerifySink, chunk_len: u64) codec.SinkError!void {
        const next_total = try checkedAdd(self.total_decoded.*, chunk_len);
        const next_folder = try checkedAdd(self.folder_bytes, chunk_len);
        if (next_folder > self.unpack_size) return codec.SinkError.StructuralError;
        if (self.opts.max_total_unpack_size) |limit| {
            if (next_total > limit) return codec.SinkError.ResourceLimitExceeded;
        }
        if (self.opts.max_folder_unpack_size) |limit| {
            if (next_folder > limit) return codec.SinkError.ResourceLimitExceeded;
        }
    }

    fn ensureSubstream(self: *StreamingVerifySink) codec.SinkError!bool {
        while (true) {
            while (self.file_idx.* < self.metadata.files.len and self.metadata.files[self.file_idx.*].is_empty_stream) {
                self.file_idx.* += 1;
            }
            if (self.subs_assigned >= self.folder_sub_count) return false;
            if (self.file_idx.* >= self.metadata.files.len) return codec.SinkError.StructuralError;

            self.sub_size = substreamUnpackSize(self.metadata, self.sub_idx.*, self.unpack_size);
            self.sub_expected_crc = expectedSubstreamCrc(self.metadata, self.folder_idx, self.folder_sub_count, self.digest_idx);
            self.sub_crc = crc32.State.init();
            self.sub_bytes = 0;
            self.active_substream = true;

            if (self.sub_size != 0) return true;
            try self.finishSubstream();
        }
    }

    fn finishSubstream(self: *StreamingVerifySink) codec.SinkError!void {
        if (self.sub_expected_crc) |expected| {
            if (self.sub_crc.final() != expected) return codec.SinkError.ChecksumError;
        }
        self.sub_idx.* += 1;
        self.subs_assigned += 1;
        self.file_idx.* += 1;
        self.active_substream = false;
    }

    fn write(self: *StreamingVerifySink, data: []const u8) codec.SinkError!void {
        const chunk_len: u64 = @intCast(data.len);
        try self.enforceWholeChunkLimits(chunk_len);

        if (!self.folderCrcMirrorsSubstream()) {
            self.folder_crc.update(data);
        }
        self.folder_bytes += chunk_len;
        self.total_decoded.* += chunk_len;

        var offset: usize = 0;
        while (offset < data.len) {
            if (!self.active_substream and !try self.ensureSubstream()) {
                return codec.SinkError.StructuralError;
            }

            const remaining_sub: usize = @intCast(self.sub_size - self.sub_bytes);
            const n = @min(remaining_sub, data.len - offset);
            const next_sub_bytes = try checkedAdd(self.sub_bytes, @intCast(n));
            if (self.opts.max_file_unpack_size) |limit| {
                if (next_sub_bytes > limit) return codec.SinkError.ResourceLimitExceeded;
            }

            self.sub_crc.update(data[offset .. offset + n]);
            self.sub_bytes = next_sub_bytes;
            offset += n;

            if (self.sub_bytes == self.sub_size) {
                try self.finishSubstream();
            }
        }
    }

    fn finish(self: *StreamingVerifySink) ArchiveError!void {
        while (!self.active_substream and self.subs_assigned < self.folder_sub_count) {
            if (!(self.ensureSubstream() catch |e| return mapSinkError(e))) break;
        }
        if (self.active_substream) return ArchiveError.StructuralError;
        if (self.folder_bytes != self.unpack_size) return ArchiveError.StructuralError;
        if (self.subs_assigned != self.folder_sub_count) return ArchiveError.StructuralError;
        if (self.metadata.folders[self.folder_idx].unpack_crc) |expected| {
            const actual = if (self.folderCrcMirrorsSubstream())
                self.sub_crc.final()
            else
                self.folder_crc.final();
            if (actual != expected) return ArchiveError.ChecksumError;
        }
    }
};

fn mapSinkError(err: codec.SinkError) ArchiveError {
    return switch (err) {
        error.OutOfMemory => ArchiveError.OutOfMemory,
        error.ResourceLimitExceeded => ArchiveError.ResourceLimitExceeded,
        error.ChecksumError => ArchiveError.ChecksumError,
        error.StructuralError => ArchiveError.StructuralError,
    };
}

fn mapStreamingCodecError(err: codec.StreamingError) ArchiveError {
    return switch (err) {
        error.UnsupportedMethod => ArchiveError.UnsupportedFeature,
        error.DecompressFailed => ArchiveError.StructuralError,
        error.OutOfMemory => ArchiveError.OutOfMemory,
        error.ResourceLimitExceeded => ArchiveError.ResourceLimitExceeded,
        error.ChecksumError => ArchiveError.ChecksumError,
        error.StructuralError => ArchiveError.StructuralError,
    };
}

fn verifyPayloadsStreaming(
    source: RangeSource,
    metadata: meta.ArchiveMetadata,
    opts: VerifyOptions,
    allocator: std.mem.Allocator,
) ArchiveError!void {
    if (metadata.pack_info == null or metadata.folders.len == 0) return;

    const pi = metadata.pack_info.?;
    const folder_counts = try folderSubstreamCounts(metadata, allocator);
    defer if (folder_counts.owned) |owned| allocator.free(owned);
    const subs_per_folder = folder_counts.counts;

    var pack_stream_idx: usize = 0;
    var sub_idx: usize = 0;
    var digest_idx: usize = 0;
    var file_idx: usize = 0;
    var total_decoded: u64 = 0;

    var total_pack_size: u64 = 0;
    for (pi.pack_sizes) |ps| total_pack_size += ps;
    var pack_bytes_done: u64 = 0;

    for (0..metadata.folders.len) |fi| {
        const folder = metadata.folders[fi];
        const num_pack_streams = folderPackStreamCount(folder);

        var folder_pack_size: u64 = 0;
        for (0..num_pack_streams) |pi_offset| {
            const idx = pack_stream_idx + pi_offset;
            if (idx < pi.pack_sizes.len) {
                folder_pack_size = std.math.add(u64, folder_pack_size, pi.pack_sizes[idx]) catch
                    return ArchiveError.TruncatedInput;
            }
        }

        var pack_offset = pi.pack_pos;
        for (0..pack_stream_idx) |prev| {
            if (prev < pi.pack_sizes.len) {
                pack_offset = std.math.add(u64, pack_offset, pi.pack_sizes[prev]) catch
                    return ArchiveError.TruncatedInput;
            }
        }
        const pack_start = std.math.add(u64, sig_header.HEADER_SIZE, pack_offset) catch
            return ArchiveError.TruncatedInput;

        const folder_pack_sizes = if (pack_stream_idx + num_pack_streams <= pi.pack_sizes.len)
            pi.pack_sizes[pack_stream_idx .. pack_stream_idx + num_pack_streams]
        else
            pi.pack_sizes[pack_stream_idx..];

        pack_stream_idx += num_pack_streams;

        const unpack_size: u64 = folder.getFinalUnpackSize();
        {
            const packed_range = source.readRange(pack_start, folder_pack_size, allocator) catch |err|
                return mapRangeSourceError(err);
            defer packed_range.deinit(allocator);
            const packed_data = packed_range.bytes;

            try pi.checkCrcs(pack_stream_idx - num_pack_streams, num_pack_streams, packed_data);

            var sink_state = StreamingVerifySink{
                .metadata = metadata,
                .opts = opts,
                .folder_idx = fi,
                .folder_sub_count = if (fi < subs_per_folder.len) @intCast(subs_per_folder[fi]) else 1,
                .unpack_size = unpack_size,
                .digest_idx = &digest_idx,
                .sub_idx = &sub_idx,
                .file_idx = &file_idx,
                .total_decoded = &total_decoded,
            };
            var sink = sink_state.outputSink();
            codec.decompressFolderToSink(folder, packed_data, folder_pack_sizes, unpack_size, opts.password, &sink, allocator) catch |e| {
                return mapStreamingCodecError(e);
            };
            try sink_state.finish();
        }

        pack_bytes_done += folder_pack_size;
        opts.progress.report(pack_bytes_done, total_pack_size);
    }
}

fn verifyPayloads(
    archive_data: []const u8,
    metadata: meta.ArchiveMetadata,
    password: ?[]const u8,
    progress: ProgressContext,
    allocator: std.mem.Allocator,
    maybe_file_data: ?[][]const u8,
) ArchiveError!void {
    if (metadata.pack_info == null or metadata.folders.len == 0) return;

    const pi = metadata.pack_info.?;
    const folder_counts = try folderSubstreamCounts(metadata, allocator);
    defer if (folder_counts.owned) |owned| allocator.free(owned);
    const subs_per_folder = folder_counts.counts;

    // Track position across all folders.
    var pack_stream_idx: usize = 0; // index into pi.pack_sizes
    var sub_idx: usize = 0; // index into sub_streams.unpack_sizes
    var digest_idx: usize = 0; // index into sub_streams.digests (excludes inherited folder CRCs)
    var file_idx: usize = 0; // index into metadata.files (skipping empty streams)

    // Compute total packed size for progress reporting.
    var total_pack_size: u64 = 0;
    for (pi.pack_sizes) |ps| total_pack_size += ps;
    var pack_bytes_done: u64 = 0;

    for (0..metadata.folders.len) |fi| {
        const folder = metadata.folders[fi];
        const num_pack_streams = folderPackStreamCount(folder);

        // Calculate total packed size for this folder (sum of its pack streams).
        var folder_pack_size: usize = 0;
        for (0..num_pack_streams) |pi_offset| {
            const idx = pack_stream_idx + pi_offset;
            if (idx < pi.pack_sizes.len) {
                folder_pack_size += @intCast(pi.pack_sizes[idx]);
            }
        }

        // Calculate pack offset (base + sum of all previous pack sizes).
        var pack_offset: usize = @intCast(pi.pack_pos);
        for (0..pack_stream_idx) |prev| {
            if (prev < pi.pack_sizes.len) {
                pack_offset += @intCast(pi.pack_sizes[prev]);
            }
        }
        const pack_start = sig_header.HEADER_SIZE + pack_offset;

        const folder_pack_sizes = if (pack_stream_idx + num_pack_streams <= pi.pack_sizes.len)
            pi.pack_sizes[pack_stream_idx .. pack_stream_idx + num_pack_streams]
        else
            pi.pack_sizes[pack_stream_idx..];

        pack_stream_idx += num_pack_streams;

        const unpack_size: u64 = folder.getFinalUnpackSize();

        if (pack_start + folder_pack_size > archive_data.len) {
            return ArchiveError.TruncatedInput;
        }
        const packed_data = archive_data[pack_start .. pack_start + folder_pack_size];

        try pi.checkCrcs(pack_stream_idx - num_pack_streams, num_pack_streams, packed_data);

        const unpacked = codec.decompressFolder(folder, packed_data, folder_pack_sizes, unpack_size, password, allocator) catch |e| switch (e) {
            error.UnsupportedMethod => return ArchiveError.UnsupportedFeature,
            error.DecompressFailed => return ArchiveError.StructuralError,
            error.OutOfMemory => return ArchiveError.OutOfMemory,
            error.ResourceLimitExceeded => return ArchiveError.ResourceLimitExceeded,
        };
        defer allocator.free(unpacked);

        if (folder.unpack_crc) |expected| {
            if (crc32.hash(unpacked) != expected) return ArchiveError.ChecksumError;
        }

        pack_bytes_done += @as(u64, @intCast(folder_pack_size));
        progress.report(pack_bytes_done, total_pack_size);

        const folder_sub_count: usize = if (fi < subs_per_folder.len) @intCast(subs_per_folder[fi]) else 1;
        var data_offset: usize = 0;
        var subs_assigned: usize = 0;

        while (subs_assigned < folder_sub_count and file_idx < metadata.files.len) {
            if (metadata.files[file_idx].is_empty_stream) {
                file_idx += 1;
                continue;
            }

            const file_size_u64 = substreamUnpackSize(metadata, sub_idx, unpack_size);
            const file_size: usize = @intCast(file_size_u64);
            if (data_offset + file_size > unpacked.len) {
                return ArchiveError.StructuralError;
            }
            const file_slice = unpacked[data_offset .. data_offset + file_size];

            if (expectedSubstreamCrc(metadata, fi, folder_sub_count, &digest_idx)) |expected| {
                if (crc32.hash(file_slice) != expected) return ArchiveError.ChecksumError;
            }

            if (maybe_file_data) |file_data| {
                allocator.free(@constCast(file_data[file_idx]));
                file_data[file_idx] = try allocator.dupe(u8, file_slice);
            }

            data_offset += file_size;
            sub_idx += 1;
            subs_assigned += 1;
            file_idx += 1;
        }

        if (data_offset != unpacked.len) {
            return ArchiveError.StructuralError;
        }
    }
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
    var metadata = try parseArchiveMetadata(archive_data, password, allocator);
    errdefer metadata.deinit();

    // Extract file data via codec dispatch — iterate ALL folders
    const file_data = try allocator.alloc([]const u8, metadata.files.len);
    errdefer cleanupFileData(file_data, allocator);

    for (file_data) |*d| {
        d.* = &.{};
    }

    // Initialize all entries to empty (directories/empty streams stay empty)
    for (file_data) |*d| {
        d.* = try allocator.dupe(u8, &.{});
    }

    try verifyPayloads(archive_data, metadata, password, progress, allocator, file_data);

    return .{
        .metadata = metadata,
        .file_data = file_data,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

const MaxSingleAllocationAllocator = struct {
    backing: std.mem.Allocator,
    max_single_alloc: usize,
    max_observed_alloc: usize = 0,

    fn init(backing: std.mem.Allocator, max_single_alloc: usize) MaxSingleAllocationAllocator {
        return .{
            .backing = backing,
            .max_single_alloc = max_single_alloc,
        };
    }

    fn allocator(self: *MaxSingleAllocationAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn fromContext(ctx: *anyopaque) *MaxSingleAllocationAllocator {
        return @ptrCast(@alignCast(ctx));
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, len);
        if (len > self.max_single_alloc) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, new_len);
        if (new_len > self.max_single_alloc) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = fromContext(ctx);
        self.max_observed_alloc = @max(self.max_observed_alloc, new_len);
        if (new_len > self.max_single_alloc) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = fromContext(ctx);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const TestChunkedRangeSource = struct {
    data: []const u8,
    next_header_start: u64,
    max_chunk: usize = 7,
    calls: usize = 0,
    saw_start_header: bool = false,
    saw_payload: bool = false,
    saw_next_header: bool = false,

    fn readAt(ctx: *anyopaque, offset: u64, dest: []u8) RangeReadError!usize {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (offset == 0) self.saw_start_header = true;
        if (offset >= sig_header.HEADER_SIZE and offset < self.next_header_start) self.saw_payload = true;
        if (offset >= self.next_header_start) self.saw_next_header = true;
        if (offset >= self.data.len or dest.len == 0) return 0;
        const start: usize = @intCast(offset);
        const len = @min(self.max_chunk, @min(dest.len, self.data.len - start));
        @memcpy(dest[0..len], self.data[start .. start + len]);
        return len;
    }

    fn source(self: *@This()) RangeSource {
        return .{
            .ptr = self,
            .len = self.data.len,
            .readFn = readAt,
        };
    }
};

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

test "archive: verify rejects corrupted copy payload via substream CRC" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "crc.txt", .data = "crc protected payload" },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    const corrupted = try allocator.dupe(u8, archive_data);
    defer allocator.free(corrupted);
    corrupted[sig_header.HEADER_SIZE] ^= 0x55;

    try std.testing.expectError(ArchiveError.ChecksumError, verify(corrupted, .{}, allocator));
    try std.testing.expectError(ArchiveError.ChecksumError, read(corrupted, allocator));
}

fn packedCrcFixture(allocator: std.mem.Allocator, corrupt: bool) ![]u8 {
    const data = try createWithMethod(&.{.{ .name = "crc.txt", .data = "packed CRC fixture" }}, .copy, allocator);
    defer allocator.free(data);
    const header = try sig_header.parse(data);
    const offset: usize = @intCast(header.nextHeaderAbsoluteOffset());
    var metadata = try meta.parseNextHeader(data[offset..], allocator);
    defer metadata.deinit();
    const digests = try allocator.alloc(?u32, 1);
    digests[0] = crc32.hash("packed CRC fixture") ^ @as(u32, if (corrupt) 1 else 0);
    metadata.pack_info.?.pack_crcs = digests;
    const next = try encoder.encodeNextHeader(metadata, allocator);
    defer allocator.free(next);
    var updated = header;
    updated.next_header_size = next.len;
    updated.next_header_crc = crc32.hash(next);
    const signature = sig_header.encode(updated);
    return std.mem.concat(allocator, u8, &.{ &signature, data[sig_header.HEADER_SIZE..offset], next });
}

test "archive: packed CRC mismatch rejects slice and range verification" {
    const allocator = std.testing.allocator;
    const good = try packedCrcFixture(allocator, false);
    defer allocator.free(good);
    const stats = try verify(good, .{}, allocator);
    try std.testing.expectEqual(@as(u64, 18), stats.total_unpack_size);
    const bad = try packedCrcFixture(allocator, true);
    defer allocator.free(bad);
    try std.testing.expectError(ArchiveError.ChecksumError, verify(bad, .{}, allocator));
    const header = try sig_header.parse(bad);
    var source = TestChunkedRangeSource{ .data = bad, .next_header_start = header.nextHeaderAbsoluteOffset() };
    try std.testing.expectError(ArchiveError.ChecksumError, verifyRange(source.source(), .{}, allocator));
}

test "archive: packed CRC mismatch rejects retained extraction" {
    const allocator = std.testing.allocator;
    const good = try packedCrcFixture(allocator, false);
    defer allocator.free(good);
    var contents = try read(good, allocator);
    defer contents.deinit();
    try std.testing.expectEqualStrings("packed CRC fixture", contents.file_data[0]);
    const bad = try packedCrcFixture(allocator, true);
    defer allocator.free(bad);
    if (read(bad, allocator)) |result| {
        var unexpected = result;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(ArchiveError.ChecksumError, err);
}

fn encodedHeaderCrcFixture(allocator: std.mem.Allocator, bad_pack: bool, bad_folder: bool) ![]u8 {
    const original = try createWithMethod(&.{.{ .name = "header.txt", .data = "header CRC fixture" }}, .copy, allocator);
    defer allocator.free(original);
    const header = try sig_header.parse(original);
    const offset: usize = @intCast(header.nextHeaderAbsoluteOffset());
    const decoded = original[offset..];
    var sizes = [_]u64{decoded.len};
    var digests = [_]?u32{crc32.hash(decoded) ^ @as(u32, if (bad_pack) 1 else 0)};
    var coders = [_]meta.Coder{.{ .method_id = &.{0}, .properties = &.{}, .num_in_streams = 1, .num_out_streams = 1 }};
    var folders = [_]meta.Folder{.{
        .coders = &coders, .bind_pairs = &.{}, .packed_indices = &.{}, .unpack_sizes = &sizes,
        .unpack_crc = crc32.hash(decoded) ^ @as(u32, if (bad_folder) 1 else 0),
    }};
    const description = try encoder.encodeNextHeader(.{
        .pack_info = .{ .pack_pos = offset - sig_header.HEADER_SIZE, .pack_sizes = &sizes, .pack_crcs = &digests },
        .folders = &folders, .sub_streams = null, .files = &.{}, .allocator = allocator,
    }, allocator);
    defer allocator.free(description);
    // Replace Header/MainStreamsInfo wrappers with EncodedHeader/StreamsInfo.
    const next = try std.mem.concat(allocator, u8, &.{ &.{0x17}, description[2 .. description.len - 1] });
    defer allocator.free(next);
    const signature = sig_header.encode(.{
        .major_version = 0, .minor_version = 4,
        .next_header_offset = offset - sig_header.HEADER_SIZE + decoded.len,
        .next_header_size = next.len, .next_header_crc = crc32.hash(next),
    });
    return std.mem.concat(allocator, u8, &.{ &signature, original[sig_header.HEADER_SIZE..offset], decoded, next });
}

test "archive: encoded header packed CRC mismatch rejected" {
    const allocator = std.testing.allocator;
    const good = try encodedHeaderCrcFixture(allocator, false, false);
    defer allocator.free(good);
    const stats = try verify(good, .{}, allocator);
    try std.testing.expectEqual(@as(u64, 18), stats.total_unpack_size);
    const bad = try encodedHeaderCrcFixture(allocator, true, false);
    defer allocator.free(bad);
    try std.testing.expectError(ArchiveError.ChecksumError, verify(bad, .{}, allocator));
}

test "archive: encoded header folder CRC mismatch rejected" {
    const allocator = std.testing.allocator;
    const bad = try encodedHeaderCrcFixture(allocator, false, true);
    defer allocator.free(bad);
    try std.testing.expectError(ArchiveError.ChecksumError, inspect(bad, null, allocator));
}

test "archive: permanent oracle-audited CRC fixtures preserve validity classification" {
    const allocator = std.testing.allocator;
    inline for (.{ "packed-good", "encoded-good" }) |name| {
        const data = @embedFile("fixtures/crc/" ++ name ++ ".7z");
        const stats = try verify(data, .{}, allocator);
        try std.testing.expectEqual(@as(u64, 18), stats.total_unpack_size);
        var contents = try read(data, allocator);
        defer contents.deinit();
        try std.testing.expectEqualStrings(if (comptime std.mem.startsWith(u8, name, "packed")) "packed CRC fixture" else "header CRC fixture", contents.file_data[0]);
    }
    inline for (.{ "packed-bad", "encoded-bad-pack", "encoded-bad-folder" }) |name| {
        const data = @embedFile("fixtures/crc/" ++ name ++ ".7z");
        try std.testing.expectError(ArchiveError.ChecksumError, verify(data, .{}, allocator));
        const header = try sig_header.parse(data);
        var source = TestChunkedRangeSource{ .data = data, .next_header_start = header.nextHeaderAbsoluteOffset() };
        try std.testing.expectError(ArchiveError.ChecksumError, verifyRange(source.source(), .{}, allocator));
    }
}

test "archive: BZip2 retained allocation budget overflow stays a resource error" {
    const allocator = std.testing.allocator;
    const original = @embedFile("fixtures/bzip2/small.7z");
    var good = try read(original, allocator);
    defer good.deinit();
    try std.testing.expectEqual(@as(usize, 49), good.file_data[0].len);

    var header = try sig_header.parse(original);
    const offset: usize = @intCast(header.nextHeaderAbsoluteOffset());
    var metadata = try meta.parseNextHeader(original[offset..], allocator);
    defer metadata.deinit();
    metadata.folders[0].unpack_sizes[0] = std.math.maxInt(usize);
    const next = try encoder.encodeNextHeader(metadata, allocator);
    defer allocator.free(next);
    header.next_header_size = next.len;
    header.next_header_crc = crc32.hash(next);
    const signature = sig_header.encode(header);
    const oversized = try std.mem.concat(allocator, u8, &.{ &signature, original[sig_header.HEADER_SIZE..offset], next });
    defer allocator.free(oversized);
    try std.testing.expectError(ArchiveError.ResourceLimitExceeded, read(oversized, allocator));
}

test "archive: inspect reports unpacked work from metadata" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "alpha" },
        .{ .name = "b.bin", .data = "bravo-bravo" },
        .{ .name = "empty-dir", .data = "", .is_dir = true },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    const stats = try inspect(archive_data, null, allocator);
    try std.testing.expectEqual(@as(u64, 3), stats.file_count);
    try std.testing.expectEqual(@as(u64, 2), stats.data_file_count);
    try std.testing.expectEqual(@as(u64, 1), stats.folder_count);
    try std.testing.expectEqual(@as(u64, 2), stats.substream_count);
    try std.testing.expectEqual(@as(u64, "alpha".len + "bravo-bravo".len), stats.total_unpack_size);
    try std.testing.expectEqual(@as(u64, "alpha".len + "bravo-bravo".len), stats.largest_folder_unpack_size);
    try std.testing.expectEqual(@as(u64, "bravo-bravo".len), stats.max_file_unpack_size);
}

test "archive: verify guardrails reject unpack sizes before extraction" {
    const allocator = std.testing.allocator;

    const data = [_]u8{'x'} ** 4096;
    const files = [_]FileEntry{
        .{ .name = "large.txt", .data = &data },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    try std.testing.expectError(
        ArchiveError.ResourceLimitExceeded,
        verify(archive_data, .{ .max_total_unpack_size = data.len - 1 }, allocator),
    );
    try std.testing.expectError(
        ArchiveError.ResourceLimitExceeded,
        verify(archive_data, .{ .max_folder_unpack_size = data.len - 1 }, allocator),
    );
    try std.testing.expectError(
        ArchiveError.ResourceLimitExceeded,
        verify(archive_data, .{ .max_file_unpack_size = data.len - 1 }, allocator),
    );
}

test "archive: verify copy payload does not allocate full folder output" {
    const allocator = std.testing.allocator;

    const large = [_]u8{'x'} ** (16 * 1024);
    const files = [_]FileEntry{
        .{ .name = "large-copy.bin", .data = &large },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    var capped = MaxSingleAllocationAllocator.init(allocator, 4096);
    const stats = try verify(archive_data, .{}, capped.allocator());

    try std.testing.expectEqual(@as(u64, large.len), stats.total_unpack_size);
    try std.testing.expect(capped.max_observed_alloc < large.len);
}

test "archive: Deflate fixtures extract and verify through bounded range input" {
    const allocator = std.testing.allocator;
    const fixtures = [_][]const u8{
        @embedFile("fixtures/deflate/plain.7z"),
        @embedFile("fixtures/deflate/bcj.7z"),
        @embedFile("fixtures/deflate/bcj2.7z"),
        @embedFile("fixtures/deflate/encrypted.7z"),
    };
    const expected_a = "Deflate fixture: " ** 16384;
    const expected_b = [_]u8{ 0x90, 0xe8, 0x10, 0, 0, 0, 0xe9, 0x20, 0, 0, 0 } ** 8192;
    for (fixtures) |bytes| {
        var contents = try readWithPassword(bytes, "fixture-password", allocator);
        defer contents.deinit();
        try std.testing.expectEqual(@as(usize, 2), contents.file_data.len);
        try std.testing.expectEqualSlices(u8, expected_a, contents.file_data[0]);
        try std.testing.expectEqualSlices(u8, &expected_b, contents.file_data[1]);

        var capped = MaxSingleAllocationAllocator.init(allocator, 96 * 1024);
        const opts = VerifyOptions{ .password = "fixture-password" };
        const stats = try verify(bytes, opts, capped.allocator());
        try std.testing.expectEqual(@as(u64, expected_a.len + expected_b.len), stats.total_unpack_size);
        try std.testing.expect(capped.max_observed_alloc < expected_a.len);

        const sig = try sig_header.parse(bytes);
        var input = TestChunkedRangeSource{ .data = bytes, .next_header_start = sig.nextHeaderAbsoluteOffset() };
        const ranged = try verifyRange(input.source(), opts, capped.allocator());
        try std.testing.expectEqual(stats.total_unpack_size, ranged.total_unpack_size);
        try std.testing.expect(input.calls > 3);
        try std.testing.expectError(ArchiveError.ResourceLimitExceeded, verify(bytes, .{
            .password = "fixture-password", .max_total_unpack_size = stats.total_unpack_size - 1,
        }, allocator));
    }
}

test "archive: Deflate corruption is rejected by extraction and verification" {
    const allocator = std.testing.allocator;
    const original = @embedFile("fixtures/deflate/plain.7z");
    const bytes = try allocator.dupe(u8, original);
    defer allocator.free(bytes);
    bytes[sig_header.HEADER_SIZE] |= 0x06; // Reserved Deflate block type.
    if (read(bytes, allocator)) |result| {
        var contents = result;
        contents.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    if (verify(bytes, .{}, allocator)) |_| return error.TestUnexpectedResult else |_| {}
}

test "archive: verify lzma2 payload is bounded by decoder window, not folder output" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 192 * 1024);
    defer allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @truncate((i * 37) ^ (i >> 3));
    }
    const files = [_]FileEntry{
        .{ .name = "large-lzma2.bin", .data = data },
    };

    const archive_data = try createWithLevel(&files, .lzma2, null, 0, .{}, allocator);
    defer allocator.free(archive_data);

    var capped = MaxSingleAllocationAllocator.init(allocator, 96 * 1024);
    const stats = try verify(archive_data, .{}, capped.allocator());

    try std.testing.expectEqual(@as(u64, data.len), stats.total_unpack_size);
    try std.testing.expect(capped.max_observed_alloc < data.len);
}

test "archive: streaming verify counts lzma2 output across dictionary resets" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(data);
    const pattern = "abcabcabcabcabcabcabcabcabcabcabcabc";
    for (data, 0..) |*b, i| {
        b.* = pattern[i % pattern.len];
    }
    const files = [_]FileEntry{
        .{ .name = "multi-block-lzma2.txt", .data = data },
    };

    const archive_data = try createWithMethod(&files, .lzma2, allocator);
    defer allocator.free(archive_data);

    const stats = try verify(archive_data, .{}, allocator);
    try std.testing.expectEqual(@as(u64, data.len), stats.total_unpack_size);
}

test "archive: streaming verify honors multi-file substream CRC boundaries" {
    const allocator = std.testing.allocator;

    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "alpha-alpha-alpha" },
        .{ .name = "b.txt", .data = "bravo-bravo-bravo" },
    };

    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    _ = try verify(archive_data, .{}, allocator);

    const corrupted = try allocator.dupe(u8, archive_data);
    defer allocator.free(corrupted);
    corrupted[sig_header.HEADER_SIZE + files[0].data.len] ^= 0x33;

    try std.testing.expectError(ArchiveError.ChecksumError, verify(corrupted, .{}, allocator));
}

test "archive: range verify loops over short reads and preserves substream CRCs" {
    const allocator = std.testing.allocator;
    const files = [_]FileEntry{
        .{ .name = "alpha.txt", .data = "alpha-alpha-alpha" },
        .{ .name = "bravo.txt", .data = "bravo-bravo-bravo" },
    };
    const archive_data = try createWithMethod(&files, .copy, allocator);
    defer allocator.free(archive_data);

    const hdr = try sig_header.parse(archive_data);
    const next_header_start = sig_header.HEADER_SIZE + hdr.next_header_offset;
    var source_ctx = TestChunkedRangeSource{ .data = archive_data, .next_header_start = next_header_start };
    const stats = try verifyRange(source_ctx.source(), .{}, allocator);
    try std.testing.expectEqual(@as(u64, files[0].data.len + files[1].data.len), stats.total_unpack_size);
    try std.testing.expect(source_ctx.calls > 3);
    try std.testing.expect(source_ctx.saw_start_header);
    try std.testing.expect(source_ctx.saw_payload);
    try std.testing.expect(source_ctx.saw_next_header);

    var limited_ctx = TestChunkedRangeSource{ .data = archive_data, .next_header_start = next_header_start };
    try std.testing.expectError(
        ArchiveError.ResourceLimitExceeded,
        verifyRange(limited_ctx.source(), .{ .max_total_unpack_size = stats.total_unpack_size - 1 }, allocator),
    );
    try std.testing.expect(!limited_ctx.saw_payload);

    const corrupted = try allocator.dupe(u8, archive_data);
    defer allocator.free(corrupted);
    corrupted[sig_header.HEADER_SIZE + files[0].data.len] ^= 0x33;
    var corrupted_ctx = TestChunkedRangeSource{ .data = corrupted, .next_header_start = next_header_start };
    try std.testing.expectError(ArchiveError.ChecksumError, verifyRange(corrupted_ctx.source(), .{}, allocator));

    const FailedSource = struct {
        fn readAt(ctx: *anyopaque, offset: u64, dest: []u8) RangeReadError!usize {
            _ = ctx;
            _ = offset;
            _ = dest;
            return error.ReadFailed;
        }
    };
    var failed_ctx: u8 = 0;
    const failed_source = RangeSource{
        .ptr = &failed_ctx,
        .len = archive_data.len,
        .readFn = FailedSource.readAt,
    };
    try std.testing.expectError(ArchiveError.InputReadFailed, verifyRange(failed_source, .{}, allocator));
}

test "archive: inspect rejects overflowing next-header bounds" {
    const hdr = sig_header.encode(.{
        .major_version = 0,
        .minor_version = 4,
        .next_header_offset = std.math.maxInt(u64),
        .next_header_size = 1,
        .next_header_crc = 0,
    });

    try std.testing.expectError(ArchiveError.TruncatedInput, inspect(&hdr, null, std.testing.allocator));
    try std.testing.expectError(ArchiveError.TruncatedInput, verify(&hdr, .{}, std.testing.allocator));
}

test "archive: createMultiFolder groups files into separate folders" {
    const allocator = std.testing.allocator;

    // 3 files in 2 groups
    var files = [_]FileEntry{
        .{ .name = "a.txt", .data = "hello from group 0", .group_index = 0 },
        .{ .name = "b.bin", .data = "binary group 1 data", .group_index = 1 },
        .{ .name = "c.txt", .data = "more text group 0", .group_index = 0 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, allocator);
    defer allocator.free(archive_data);

    const range_header = try sig_header.parse(archive_data);
    var range_ctx = TestChunkedRangeSource{
        .data = archive_data,
        .next_header_start = sig_header.HEADER_SIZE + range_header.next_header_offset,
    };
    const range_stats = try verifyRange(range_ctx.source(), .{}, allocator);
    try std.testing.expectEqual(@as(u64, files[0].data.len + files[1].data.len + files[2].data.len), range_stats.total_unpack_size);

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

    const archive_data = try createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, allocator);
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

    const archive_data = try createMultiFolder(&files, .lzma2_aes, "password123", LevelParams.DEFAULT_LEVEL, .{}, allocator);
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

    const data = try createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, allocator);
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

    const data = try createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, allocator);
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

    const data = try createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, allocator);
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

test "archive: createWithOptions thread_count=1 roundtrip" {
    const allocator = std.testing.allocator;
    const content = "Single-threaded compression test data.\n" ** 10;
    const files = [_]FileEntry{
        .{ .name = "threaded.txt", .data = content },
    };

    const opts = CreateOptions{
        .method = .lzma2,
        .level = 3,
        .thread_count = 1, // force single-threaded
    };
    const archive_data = try createWithOptions(&files, opts, allocator);
    defer allocator.free(archive_data);

    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("threaded.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "archive: createWithOptions encrypted with header encryption roundtrip" {
    const allocator = std.testing.allocator;
    const password = "header_encrypt_test";
    const content = "Header encryption (-mhe=on) test content.\n";
    const files = [_]FileEntry{
        .{ .name = "secret_hdr.txt", .data = content },
    };

    const opts = CreateOptions{
        .method = .lzma2_aes,
        .password = password,
        .level = 3,
        .encrypt_header = true,
    };
    const archive_data = try createWithOptions(&files, opts, allocator);
    defer allocator.free(archive_data);

    const range_header = try sig_header.parse(archive_data);
    const next_header_start = sig_header.HEADER_SIZE + range_header.next_header_offset;
    var range_ctx = TestChunkedRangeSource{
        .data = archive_data,
        .next_header_start = next_header_start,
        .max_chunk = 11,
    };
    const range_stats = try verifyRange(range_ctx.source(), .{ .password = password }, allocator);
    try std.testing.expectEqual(@as(u64, content.len), range_stats.total_unpack_size);
    try std.testing.expect(range_ctx.saw_payload);
    try std.testing.expect(range_ctx.saw_next_header);

    var no_password_ctx = TestChunkedRangeSource{
        .data = archive_data,
        .next_header_start = next_header_start,
        .max_chunk = 11,
    };
    try std.testing.expectError(ArchiveError.UnsupportedFeature, verifyRange(no_password_ctx.source(), .{}, allocator));

    // Opening without password should fail
    const bad_result = read(archive_data, allocator);
    try std.testing.expectError(ArchiveError.UnsupportedFeature, bad_result);

    // Opening with correct password should succeed and decrypt the header + content
    var contents = try readWithPassword(archive_data, password, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("secret_hdr.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "archive: createWithOptions encrypted without header encryption" {
    const allocator = std.testing.allocator;
    const password = "no_header_encrypt";
    const content = "Encrypted content, plain header.\n";
    const files = [_]FileEntry{
        .{ .name = "enc_plain_hdr.txt", .data = content },
    };

    // Without header encryption, the header is still readable without password
    const opts = CreateOptions{
        .method = .lzma2_aes,
        .password = password,
        .level = 3,
        .encrypt_header = false,
    };
    const archive_data = try createWithOptions(&files, opts, allocator);
    defer allocator.free(archive_data);

    // Without password, we can still parse the header (see file names)
    // but decompression of content should fail
    const bad_result = read(archive_data, allocator);
    try std.testing.expectError(ArchiveError.UnsupportedFeature, bad_result);

    // With password, full roundtrip works
    var contents = try readWithPassword(archive_data, password, allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
    try std.testing.expectEqualStrings("enc_plain_hdr.txt", contents.metadata.files[0].name.?);
    try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "archive: create (LZMA2) leaks nothing and never double-frees under allocation failure" {
    // Regression for the errdefer-gap: createLzma2WithThreads performed ~8
    // allocations but only `coders` had an errdefer, so a failure mid-build leaked
    // everything before it. Worse, that lone errdefer coexisted with the later
    // `defer archive_meta.deinit()`, so a failure AFTER archive_meta construction
    // double-freed `coders`. Drive every allocation index to failure and rely on
    // the backing testing.allocator to flag any leak or double-free.
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "hello world hello world hello world" },
        .{ .name = "dir", .data = "", .is_dir = true },
        .{ .name = "b.txt", .data = "second file body" },
    };
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = failing.allocator();
        if (create(&files, a)) |archive_data| {
            allocator_free: {
                a.free(archive_data);
                break :allocator_free;
            }
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "archive: encrypted (LZMA2+AES) leaks nothing and never double-frees under allocation failure" {
    const files = [_]FileEntry{
        .{ .name = "secret.txt", .data = "top secret payload data here" },
        .{ .name = "more.bin", .data = "another secret blob" },
    };
    const lp = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    var i: usize = 0;
    while (i < 96) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = failing.allocator();
        if (createLzma2Aes(&files, "pw123456", lp.dict_size, lp.nice_len, .{}, a)) |archive_data| {
            a.free(archive_data);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "archive: createMultiFolder leaks nothing and never double-frees under allocation failure" {
    // The multi-folder path uses the _owned-flag idiom for folders/file_infos;
    // this verifies the standalone arrays (pack_sizes, sub_sizes, etc.) are also
    // leak-free across every allocation-failure index.
    const files = [_]FileEntry{
        .{ .name = "x.txt", .data = "alpha beta gamma delta", .group_index = 0 },
        .{ .name = "y.txt", .data = "second group payload", .group_index = 1 },
        .{ .name = "d", .data = "", .is_dir = true, .group_index = 0 },
    };
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = failing.allocator();
        if (createMultiFolder(&files, .lzma2, null, LevelParams.DEFAULT_LEVEL, .{}, a)) |archive_data| {
            a.free(archive_data);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "archive: encrypted create without password reports PasswordRequired, not OutOfMemory" {
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "data" },
    };
    // Public path via method+password helper (null password).
    try std.testing.expectError(
        error.PasswordRequired,
        createWithMethodAndPassword(&files, .lzma2_aes, null, std.testing.allocator),
    );
    // Public path via options struct (null password).
    try std.testing.expectError(
        error.PasswordRequired,
        createWithOptions(&files, .{ .method = .lzma2_aes, .password = null }, std.testing.allocator),
    );
}

test "archive: decrypting with the wrong password fails rather than returning garbage" {
    const allocator = std.testing.allocator;
    const files = [_]FileEntry{
        .{ .name = "secret.txt", .data = "the eagle lands at midnight" },
    };
    const archive_data = try createWithMethodAndPassword(&files, .lzma2_aes, "correct horse", allocator);
    defer allocator.free(archive_data);

    // Wrong password must surface an error (CRC/structure mismatch), not silently
    // produce corrupted plaintext.
    try std.testing.expectError(error.StructuralError, readWithPassword(archive_data, "battery staple", allocator));

    // Correct password still round-trips.
    var contents = try readWithPassword(archive_data, "correct horse", allocator);
    defer contents.deinit();
    try std.testing.expectEqualStrings("the eagle lands at midnight", contents.file_data[0]);
}
