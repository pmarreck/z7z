//! C FFI boundary for z7z.
//!
//! All functions use C calling convention and C-compatible types.
//! Memory management: z7z_open allocates; z7z_close frees.
//! z7z_create allocates output; z7z_free frees it.

const std = @import("std");
const archive = @import("archive.zig");

// ============================================================================
// Error codes (must match z7z.h enum)
// ============================================================================

pub const Z7Z_OK: c_int = 0;
pub const Z7Z_ERR_NOT_ARCHIVE: c_int = 1;
pub const Z7Z_ERR_CHECKSUM: c_int = 2;
pub const Z7Z_ERR_TRUNCATED: c_int = 3;
pub const Z7Z_ERR_STRUCTURAL: c_int = 4;
pub const Z7Z_ERR_UNSUPPORTED: c_int = 5;
pub const Z7Z_ERR_OUT_OF_MEMORY: c_int = 6;
pub const Z7Z_ERR_INVALID_ARG: c_int = 7;
pub const Z7Z_ERR_INDEX_OUT_OF_BOUNDS: c_int = 8;

// ============================================================================
// Opaque archive handle
// ============================================================================

const ArchiveHandle = struct {
	contents: archive.ArchiveContents,
	/// Null-terminated copies of file names for C consumers.
	name_cstrs: []?[*:0]u8,
	allocator: std.mem.Allocator,

	fn init(contents: archive.ArchiveContents, allocator: std.mem.Allocator) !*ArchiveHandle {
		const n = contents.metadata.files.len;
		const cstrs = try allocator.alloc(?[*:0]u8, n);
		errdefer allocator.free(cstrs);

		var initialized: usize = 0;
		errdefer {
			for (cstrs[0..initialized]) |cs| {
				if (cs) |ptr| allocator.free(std.mem.span(ptr));
			}
		}

		for (0..n) |i| {
			if (contents.metadata.files[i].name) |name| {
				const buf = try allocator.alloc(u8, name.len + 1);
				@memcpy(buf[0..name.len], name);
				buf[name.len] = 0;
				cstrs[i] = buf[0..name.len :0].ptr;
			} else {
				cstrs[i] = null;
			}
			initialized = i + 1;
		}

		const handle = try allocator.create(ArchiveHandle);
		handle.* = .{
			.contents = contents,
			.name_cstrs = cstrs,
			.allocator = allocator,
		};
		return handle;
	}

	fn deinit(self: *ArchiveHandle) void {
		for (self.name_cstrs) |cs| {
			if (cs) |ptr| self.allocator.free(std.mem.span(ptr));
		}
		self.allocator.free(self.name_cstrs);
		self.contents.deinit();
		self.allocator.destroy(self);
	}
};

fn ffiAllocator() std.mem.Allocator {
	return std.heap.c_allocator;
}

// ============================================================================
// FFI exports
// ============================================================================

/// Open a .7z archive from a memory buffer.
/// On success, writes opaque handle to `out` and returns Z7Z_OK.
export fn z7z_open(data: ?[*]const u8, len: usize, out: ?*?*ArchiveHandle) c_int {
	const out_ptr = out orelse return Z7Z_ERR_INVALID_ARG;
	const data_ptr = data orelse return Z7Z_ERR_INVALID_ARG;

	const allocator = ffiAllocator();
	const slice = data_ptr[0..len];

	const contents = archive.read(slice, allocator) catch |e| {
		return mapArchiveError(e);
	};

	const handle = ArchiveHandle.init(contents, allocator) catch return Z7Z_ERR_OUT_OF_MEMORY;
	out_ptr.* = handle;
	return Z7Z_OK;
}

/// Get the number of files in the archive.
export fn z7z_file_count(handle: ?*const ArchiveHandle) usize {
	const h = handle orelse return 0;
	return h.contents.metadata.files.len;
}

/// Get a file's name (UTF-8, null-terminated).
/// Returns null if index is out of bounds or name is not set.
export fn z7z_file_name(handle: ?*const ArchiveHandle, index: usize) ?[*:0]const u8 {
	const h = handle orelse return null;
	if (index >= h.name_cstrs.len) return null;
	return h.name_cstrs[index];
}

/// Get a file's uncompressed data pointer.
/// Returns null if index is out of bounds or file is empty.
export fn z7z_file_data(handle: ?*const ArchiveHandle, index: usize) ?[*]const u8 {
	const h = handle orelse return null;
	if (index >= h.contents.file_data.len) return null;
	const d = h.contents.file_data[index];
	if (d.len == 0) return null;
	return d.ptr;
}

/// Get a file's uncompressed size.
export fn z7z_file_size(handle: ?*const ArchiveHandle, index: usize) usize {
	const h = handle orelse return 0;
	if (index >= h.contents.file_data.len) return 0;
	return h.contents.file_data[index].len;
}

/// Check if a file entry is a directory.
/// Returns 1 if directory, 0 otherwise (including invalid handle/index).
export fn z7z_file_is_dir(handle: ?*const ArchiveHandle, index: usize) c_int {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	const fi = h.contents.metadata.files[index];
	return if (fi.is_empty_stream and !fi.is_empty_file) 1 else 0;
}

/// Check if a file entry is a symbolic link.
/// Detection: (win_attrib >> 16) & 0xF000 == 0xA000 (POSIX S_IFLNK).
/// Returns 1 if symlink, 0 otherwise (including invalid handle/index).
export fn z7z_file_is_symlink(handle: ?*const ArchiveHandle, index: usize) c_int {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	const fi = h.contents.metadata.files[index];
	const attr = fi.win_attrib orelse return 0;
	return if ((attr >> 16) & 0xF000 == 0xA000) 1 else 0;
}

// NTFS FILETIME epoch offset: 100ns intervals between 1601-01-01 and 1970-01-01
const FILETIME_EPOCH_OFFSET: u64 = 11644473600;

/// Get file's modification time as Unix timestamp (seconds since epoch).
/// Returns 0 if mtime not stored or on error.
export fn z7z_file_mtime(handle: ?*const ArchiveHandle, index: usize) i64 {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	const ft = h.contents.metadata.files[index].mtime orelse return 0;
	// Convert NTFS FILETIME (100ns since 1601) to Unix timestamp (seconds since 1970)
	const ticks_per_sec: u64 = 10_000_000;
	if (ft < FILETIME_EPOCH_OFFSET * ticks_per_sec) return 0;
	return @intCast((ft / ticks_per_sec) - FILETIME_EPOCH_OFFSET);
}

/// Get file's creation/birth time as Unix timestamp (seconds since epoch).
/// Returns 0 if ctime not stored or on error.
export fn z7z_file_ctime(handle: ?*const ArchiveHandle, index: usize) i64 {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	const ft = h.contents.metadata.files[index].ctime orelse return 0;
	const ticks_per_sec: u64 = 10_000_000;
	if (ft < FILETIME_EPOCH_OFFSET * ticks_per_sec) return 0;
	return @intCast((ft / ticks_per_sec) - FILETIME_EPOCH_OFFSET);
}

/// Get file's access time as Unix timestamp (seconds since epoch).
/// Returns 0 if atime not stored or on error.
export fn z7z_file_atime(handle: ?*const ArchiveHandle, index: usize) i64 {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	const ft = h.contents.metadata.files[index].atime orelse return 0;
	const ticks_per_sec: u64 = 10_000_000;
	if (ft < FILETIME_EPOCH_OFFSET * ticks_per_sec) return 0;
	return @intCast((ft / ticks_per_sec) - FILETIME_EPOCH_OFFSET);
}

/// Get file's win_attrib (POSIX mode in upper 16, Windows attrs in lower 16).
/// Returns 0 if not stored or on error.
export fn z7z_file_attrib(handle: ?*const ArchiveHandle, index: usize) u32 {
	const h = handle orelse return 0;
	if (index >= h.contents.metadata.files.len) return 0;
	return h.contents.metadata.files[index].win_attrib orelse 0;
}

/// Get file's xattr blob pointer and length.
/// Returns null if no xattrs stored. Sets *out_len to blob length.
export fn z7z_file_xattrs(handle: ?*const ArchiveHandle, index: usize, out_len: ?*usize) ?[*]const u8 {
	const h = handle orelse return null;
	if (index >= h.contents.metadata.files.len) return null;
	const xattrs = h.contents.metadata.files[index].xattrs orelse return null;
	if (out_len) |ol| ol.* = xattrs.len;
	return xattrs.ptr;
}

/// Close an archive and free all associated memory.
export fn z7z_close(handle: ?*ArchiveHandle) void {
	const h = handle orelse return;
	h.deinit();
}

/// File entry for archive creation (C-compatible).
pub const Z7zFileEntry = extern struct {
	name: [*:0]const u8,
	data: ?[*]const u8,
	data_len: usize,
	flags: u32,
	mtime: i64, // Unix timestamp (0 = not set)
	win_attrib: u32, // POSIX mode<<16 | win_flags (0 = not set)
	ctime: i64, // Unix timestamp for creation/birth time (0 = not set)
	atime: i64, // Unix timestamp for access time (0 = not set)
	xattrs: ?[*]const u8, // serialized xattr blob (NULL if none)
	xattrs_len: usize, // length of xattr blob
	group_index: u32, // solid block group (0 = default)
};

const Z7Z_FLAG_DIRECTORY: u32 = 0x01;
const Z7Z_FLAG_SYMLINK: u32 = 0x02;

/// Create a .7z archive from file entries.
/// On success, writes archive bytes to `out_data`/`out_len` and returns Z7Z_OK.
/// Caller must free with z7z_free().
export fn z7z_create(
	files: ?[*]const Z7zFileEntry,
	count: usize,
	out_data: ?*?[*]u8,
	out_len: ?*usize,
) c_int {
	const out_d = out_data orelse return Z7Z_ERR_INVALID_ARG;
	const out_l = out_len orelse return Z7Z_ERR_INVALID_ARG;
	const files_ptr = files orelse {
		if (count == 0) {
			out_d.* = null;
			out_l.* = 0;
			return Z7Z_OK;
		}
		return Z7Z_ERR_INVALID_ARG;
	};

	const allocator = ffiAllocator();

	const zig_files = allocator.alloc(archive.FileEntry, count) catch return Z7Z_ERR_OUT_OF_MEMORY;
	defer allocator.free(zig_files);

	for (0..count) |i| {
		const cf = files_ptr[i];
		const name_len = std.mem.len(cf.name);
		const is_dir = (cf.flags & Z7Z_FLAG_DIRECTORY) != 0;
		const is_symlink = (cf.flags & Z7Z_FLAG_SYMLINK) != 0;
		const data_slice: []const u8 = if (cf.data) |d| d[0..cf.data_len] else &.{};
		// Convert Unix timestamps to NTFS FILETIME (or null if 0)
		const mtime: ?u64 = if (cf.mtime > 0)
			(@as(u64, @intCast(cf.mtime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const ctime: ?u64 = if (cf.ctime > 0)
			(@as(u64, @intCast(cf.ctime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const atime: ?u64 = if (cf.atime > 0)
			(@as(u64, @intCast(cf.atime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		// Map win_attrib (0 = not set)
		const attrib: ?u32 = if (cf.win_attrib != 0) cf.win_attrib else null;
		// Map xattrs (null pointer = not set)
		const xattr_data: ?[]const u8 = if (cf.xattrs) |xp|
			xp[0..cf.xattrs_len]
		else
			null;
		zig_files[i] = .{
			.name = cf.name[0..name_len],
			.data = data_slice,
			.is_dir = is_dir,
			.is_symlink = is_symlink,
			.mtime = mtime,
			.ctime = ctime,
			.atime = atime,
			.win_attrib = attrib,
			.xattrs = xattr_data,
			.group_index = cf.group_index,
		};
	}

	const result = archive.create(zig_files, allocator) catch |e| return mapCreateError(e);
	out_d.* = result.ptr;
	out_l.* = result.len;
	return Z7Z_OK;
}

/// C-compatible progress callback type.
pub const z7z_progress_fn = *const fn (u64, u64, ?*anyopaque) callconv(.c) void;

/// Open a .7z archive with progress reporting during decompression.
/// The callback fires per-folder with (packed_bytes_done, packed_bytes_total, user_data).
export fn z7z_open_ex(
	data: ?[*]const u8,
	len: usize,
	progress_cb: ?z7z_progress_fn,
	user_data: ?*anyopaque,
	out: ?*?*ArchiveHandle,
) c_int {
	const out_ptr = out orelse return Z7Z_ERR_INVALID_ARG;
	const data_ptr = data orelse return Z7Z_ERR_INVALID_ARG;

	const allocator = ffiAllocator();
	const slice = data_ptr[0..len];

	const progress = archive.ProgressContext{
		.callback = progress_cb,
		.user_data = user_data,
	};

	const contents = archive.readWithProgress(slice, null, progress, allocator) catch |e| {
		return mapArchiveError(e);
	};

	const handle = ArchiveHandle.init(contents, allocator) catch return Z7Z_ERR_OUT_OF_MEMORY;
	out_ptr.* = handle;
	return Z7Z_OK;
}

/// Open a .7z archive with password and progress reporting.
export fn z7z_open_ex_pw(
	data: ?[*]const u8,
	len: usize,
	password: ?[*:0]const u8,
	progress_cb: ?z7z_progress_fn,
	user_data: ?*anyopaque,
	out: ?*?*ArchiveHandle,
) c_int {
	const out_ptr = out orelse return Z7Z_ERR_INVALID_ARG;
	const data_ptr = data orelse return Z7Z_ERR_INVALID_ARG;

	const allocator = ffiAllocator();
	const slice = data_ptr[0..len];

	const pw: ?[]const u8 = if (password) |p| std.mem.span(p) else null;

	const progress = archive.ProgressContext{
		.callback = progress_cb,
		.user_data = user_data,
	};

	const contents = archive.readWithProgress(slice, pw, progress, allocator) catch |e| {
		return mapArchiveError(e);
	};

	const handle = ArchiveHandle.init(contents, allocator) catch return Z7Z_ERR_OUT_OF_MEMORY;
	out_ptr.* = handle;
	return Z7Z_OK;
}

/// Create a .7z archive with progress reporting during compression.
/// The callback fires per-chunk/block with (bytes_compressed, bytes_total, user_data).
export fn z7z_create_ex(
	files: ?[*]const Z7zFileEntry,
	count: usize,
	progress_cb: ?z7z_progress_fn,
	user_data: ?*anyopaque,
	out_data: ?*?[*]u8,
	out_len: ?*usize,
) c_int {
	const out_d = out_data orelse return Z7Z_ERR_INVALID_ARG;
	const out_l = out_len orelse return Z7Z_ERR_INVALID_ARG;
	const files_ptr = files orelse {
		if (count == 0) {
			out_d.* = null;
			out_l.* = 0;
			return Z7Z_OK;
		}
		return Z7Z_ERR_INVALID_ARG;
	};

	const allocator = ffiAllocator();

	const zig_files = allocator.alloc(archive.FileEntry, count) catch return Z7Z_ERR_OUT_OF_MEMORY;
	defer allocator.free(zig_files);

	for (0..count) |i| {
		const cf = files_ptr[i];
		const name_len = std.mem.len(cf.name);
		const is_dir = (cf.flags & Z7Z_FLAG_DIRECTORY) != 0;
		const is_symlink = (cf.flags & Z7Z_FLAG_SYMLINK) != 0;
		const data_slice: []const u8 = if (cf.data) |d| d[0..cf.data_len] else &.{};
		const mtime: ?u64 = if (cf.mtime > 0)
			(@as(u64, @intCast(cf.mtime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const ctime: ?u64 = if (cf.ctime > 0)
			(@as(u64, @intCast(cf.ctime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const atime: ?u64 = if (cf.atime > 0)
			(@as(u64, @intCast(cf.atime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const attrib: ?u32 = if (cf.win_attrib != 0) cf.win_attrib else null;
		const xattr_data: ?[]const u8 = if (cf.xattrs) |xp|
			xp[0..cf.xattrs_len]
		else
			null;
		zig_files[i] = .{
			.name = cf.name[0..name_len],
			.data = data_slice,
			.is_dir = is_dir,
			.is_symlink = is_symlink,
			.mtime = mtime,
			.ctime = ctime,
			.atime = atime,
			.win_attrib = attrib,
			.xattrs = xattr_data,
			.group_index = cf.group_index,
		};
	}

	const progress = archive.ProgressContext{
		.callback = progress_cb,
		.user_data = user_data,
	};

	const result = archive.createWithProgress(zig_files, .lzma2, null, progress, allocator) catch |e| return mapCreateError(e);
	out_d.* = result.ptr;
	out_l.* = result.len;
	return Z7Z_OK;
}

/// Create a .7z archive with password encryption, compression level, and progress reporting.
/// Uses LZMA2+AES when password is non-null, plain LZMA2 otherwise.
/// Level 0-9 (5 = default). Values > 9 are clamped to 9.
export fn z7z_create_ex_pw(
	files: ?[*]const Z7zFileEntry,
	count: usize,
	password: ?[*:0]const u8,
	level: u8,
	progress_cb: ?z7z_progress_fn,
	user_data: ?*anyopaque,
	out_data: ?*?[*]u8,
	out_len: ?*usize,
) c_int {
	const out_d = out_data orelse return Z7Z_ERR_INVALID_ARG;
	const out_l = out_len orelse return Z7Z_ERR_INVALID_ARG;
	const files_ptr = files orelse {
		if (count == 0) {
			out_d.* = null;
			out_l.* = 0;
			return Z7Z_OK;
		}
		return Z7Z_ERR_INVALID_ARG;
	};

	const allocator = ffiAllocator();

	const zig_files = allocator.alloc(archive.FileEntry, count) catch return Z7Z_ERR_OUT_OF_MEMORY;
	defer allocator.free(zig_files);

	for (0..count) |i| {
		const cf = files_ptr[i];
		const name_len = std.mem.len(cf.name);
		const is_dir = (cf.flags & Z7Z_FLAG_DIRECTORY) != 0;
		const is_symlink = (cf.flags & Z7Z_FLAG_SYMLINK) != 0;
		const data_slice: []const u8 = if (cf.data) |d| d[0..cf.data_len] else &.{};
		const mtime: ?u64 = if (cf.mtime > 0)
			(@as(u64, @intCast(cf.mtime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const ctime: ?u64 = if (cf.ctime > 0)
			(@as(u64, @intCast(cf.ctime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const atime: ?u64 = if (cf.atime > 0)
			(@as(u64, @intCast(cf.atime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
		else
			null;
		const attrib: ?u32 = if (cf.win_attrib != 0) cf.win_attrib else null;
		const xattr_data: ?[]const u8 = if (cf.xattrs) |xp|
			xp[0..cf.xattrs_len]
		else
			null;
		zig_files[i] = .{
			.name = cf.name[0..name_len],
			.data = data_slice,
			.is_dir = is_dir,
			.is_symlink = is_symlink,
			.mtime = mtime,
			.ctime = ctime,
			.atime = atime,
			.win_attrib = attrib,
			.xattrs = xattr_data,
			.group_index = cf.group_index,
		};
	}

	const pw: ?[]const u8 = if (password) |p| std.mem.span(p) else null;
	const method: archive.Method = if (pw != null) .lzma2_aes else .lzma2;

	const progress = archive.ProgressContext{
		.callback = progress_cb,
		.user_data = user_data,
	};

	// Clamp level to 0-9, map to u4
	const clamped_level: u4 = @intCast(@min(level, 9));
	const result = archive.createWithLevel(zig_files, method, pw, clamped_level, progress, allocator) catch |e| return mapCreateError(e);
	out_d.* = result.ptr;
	out_l.* = result.len;
	return Z7Z_OK;
}

/// Create a .7z archive with full options: password, level, thread count, header encryption, progress.
/// thread_count: 0 = auto-detect, 1 = single-threaded, N = use N threads.
/// encrypt_header: 1 = encrypt header (-mhe=on), 0 = plaintext header.
export fn z7z_create_ex2(
    files: ?[*]const Z7zFileEntry,
    count: usize,
    password: ?[*:0]const u8,
    level: u8,
    thread_count: u32,
    encrypt_header: c_int,
    progress_cb: ?z7z_progress_fn,
    user_data: ?*anyopaque,
    out_data: ?*?[*]u8,
    out_len: ?*usize,
) c_int {
    const out_d = out_data orelse return Z7Z_ERR_INVALID_ARG;
    const out_l = out_len orelse return Z7Z_ERR_INVALID_ARG;
    const files_ptr = files orelse {
        if (count == 0) {
            out_d.* = null;
            out_l.* = 0;
            return Z7Z_OK;
        }
        return Z7Z_ERR_INVALID_ARG;
    };

    const allocator = ffiAllocator();

    const zig_files = allocator.alloc(archive.FileEntry, count) catch return Z7Z_ERR_OUT_OF_MEMORY;
    defer allocator.free(zig_files);

    for (0..count) |i| {
        const cf = files_ptr[i];
        const name_len = std.mem.len(cf.name);
        const is_dir = (cf.flags & Z7Z_FLAG_DIRECTORY) != 0;
        const is_symlink = (cf.flags & Z7Z_FLAG_SYMLINK) != 0;
        const data_slice: []const u8 = if (cf.data) |d| d[0..cf.data_len] else &.{};
        const mtime: ?u64 = if (cf.mtime > 0)
            (@as(u64, @intCast(cf.mtime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
        else
            null;
        const ctime: ?u64 = if (cf.ctime > 0)
            (@as(u64, @intCast(cf.ctime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
        else
            null;
        const atime: ?u64 = if (cf.atime > 0)
            (@as(u64, @intCast(cf.atime)) + FILETIME_EPOCH_OFFSET) * 10_000_000
        else
            null;
        const attrib: ?u32 = if (cf.win_attrib != 0) cf.win_attrib else null;
        const xattr_data: ?[]const u8 = if (cf.xattrs) |xp|
            xp[0..cf.xattrs_len]
        else
            null;
        zig_files[i] = .{
            .name = cf.name[0..name_len],
            .data = data_slice,
            .is_dir = is_dir,
            .is_symlink = is_symlink,
            .mtime = mtime,
            .ctime = ctime,
            .atime = atime,
            .win_attrib = attrib,
            .xattrs = xattr_data,
            .group_index = cf.group_index,
        };
    }

    const pw: ?[]const u8 = if (password) |p| std.mem.span(p) else null;

    const progress = archive.ProgressContext{
        .callback = progress_cb,
        .user_data = user_data,
    };

    const clamped_level: u4 = @intCast(@min(level, 9));
    const opts = archive.CreateOptions{
        .method = if (pw != null) .lzma2_aes else .lzma2,
        .password = pw,
        .level = clamped_level,
        .thread_count = thread_count,
        .encrypt_header = encrypt_header != 0,
        .progress = progress,
    };

    const result = archive.createWithOptions(zig_files, opts, allocator) catch |e| return mapCreateError(e);
    out_d.* = result.ptr;
    out_l.* = result.len;
    return Z7Z_OK;
}

/// Free memory allocated by z7z_create.
export fn z7z_free(data: ?[*]u8, len: usize) void {
	const ptr = data orelse return;
	ffiAllocator().free(ptr[0..len]);
}

/// Get the error message string for an error code.
export fn z7z_error_string(code: c_int) [*:0]const u8 {
	return switch (code) {
		Z7Z_OK => "success",
		Z7Z_ERR_NOT_ARCHIVE => "not a 7z archive",
		Z7Z_ERR_CHECKSUM => "checksum mismatch",
		Z7Z_ERR_TRUNCATED => "truncated input",
		Z7Z_ERR_STRUCTURAL => "structural error in archive",
		Z7Z_ERR_UNSUPPORTED => "unsupported feature",
		Z7Z_ERR_OUT_OF_MEMORY => "out of memory",
		Z7Z_ERR_INVALID_ARG => "invalid argument",
		Z7Z_ERR_INDEX_OUT_OF_BOUNDS => "index out of bounds",
		else => "unknown error",
	};
}

fn mapArchiveError(e: archive.ArchiveError) c_int {
	return switch (e) {
		error.NotArchive => Z7Z_ERR_NOT_ARCHIVE,
		error.ChecksumError => Z7Z_ERR_CHECKSUM,
		error.TruncatedInput => Z7Z_ERR_TRUNCATED,
		error.StructuralError => Z7Z_ERR_STRUCTURAL,
		error.UnsupportedFeature => Z7Z_ERR_UNSUPPORTED,
		error.OutOfMemory => Z7Z_ERR_OUT_OF_MEMORY,
		error.EndOfStream => Z7Z_ERR_TRUNCATED,
	};
}

/// Map errors from archive creation. The create path returns anyerror
/// (inferred), so we match known errors and treat the rest as structural.
fn mapCreateError(e: anyerror) c_int {
	return switch (e) {
		error.OutOfMemory => Z7Z_ERR_OUT_OF_MEMORY,
		error.NotArchive => Z7Z_ERR_NOT_ARCHIVE,
		error.ChecksumError => Z7Z_ERR_CHECKSUM,
		error.TruncatedInput => Z7Z_ERR_TRUNCATED,
		error.StructuralError => Z7Z_ERR_STRUCTURAL,
		error.UnsupportedFeature => Z7Z_ERR_UNSUPPORTED,
		error.EndOfStream => Z7Z_ERR_TRUNCATED,
		else => Z7Z_ERR_STRUCTURAL,
	};
}

// ============================================================================
// Tests
// ============================================================================

test "ffi: error mapping covers all archive errors" {
	try std.testing.expectEqual(Z7Z_ERR_NOT_ARCHIVE, mapArchiveError(error.NotArchive));
	try std.testing.expectEqual(Z7Z_ERR_CHECKSUM, mapArchiveError(error.ChecksumError));
	try std.testing.expectEqual(Z7Z_ERR_TRUNCATED, mapArchiveError(error.TruncatedInput));
	try std.testing.expectEqual(Z7Z_ERR_STRUCTURAL, mapArchiveError(error.StructuralError));
	try std.testing.expectEqual(Z7Z_ERR_UNSUPPORTED, mapArchiveError(error.UnsupportedFeature));
	try std.testing.expectEqual(Z7Z_ERR_OUT_OF_MEMORY, mapArchiveError(error.OutOfMemory));
	try std.testing.expectEqual(Z7Z_ERR_TRUNCATED, mapArchiveError(error.EndOfStream));
}

test "ffi: error strings are non-empty" {
	const codes = [_]c_int{
		Z7Z_OK,                    Z7Z_ERR_NOT_ARCHIVE,
		Z7Z_ERR_CHECKSUM,         Z7Z_ERR_TRUNCATED,
		Z7Z_ERR_STRUCTURAL,       Z7Z_ERR_UNSUPPORTED,
		Z7Z_ERR_OUT_OF_MEMORY,    Z7Z_ERR_INVALID_ARG,
		Z7Z_ERR_INDEX_OUT_OF_BOUNDS,
	};
	for (codes) |code| {
		const msg = z7z_error_string(code);
		try std.testing.expect(std.mem.len(msg) > 0);
	}
}

test "ffi: null handle safety" {
	try std.testing.expectEqual(@as(usize, 0), z7z_file_count(null));
	try std.testing.expectEqual(@as(?[*:0]const u8, null), z7z_file_name(null, 0));
	try std.testing.expectEqual(@as(?[*]const u8, null), z7z_file_data(null, 0));
	try std.testing.expectEqual(@as(usize, 0), z7z_file_size(null, 0));
	try std.testing.expectEqual(@as(c_int, 0), z7z_file_is_dir(null, 0));
	try std.testing.expectEqual(@as(c_int, 0), z7z_file_is_symlink(null, 0));
	try std.testing.expectEqual(@as(i64, 0), z7z_file_mtime(null, 0));
	try std.testing.expectEqual(@as(i64, 0), z7z_file_ctime(null, 0));
	try std.testing.expectEqual(@as(i64, 0), z7z_file_atime(null, 0));
	try std.testing.expectEqual(@as(u32, 0), z7z_file_attrib(null, 0));
	try std.testing.expectEqual(@as(?[*]const u8, null), z7z_file_xattrs(null, 0, null));
	z7z_close(null); // should not crash
}

test "ffi: symlink create and query via FFI" {
	// Create archive with a symlink entry via z7z_create
	const target = "target.txt";
	var entries = [_]Z7zFileEntry{
		.{
			.name = "link.txt",
			.data = target,
			.data_len = target.len,
			.flags = Z7Z_FLAG_SYMLINK,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
		.{
			.name = "real.txt",
			.data = "hello",
			.data_len = 5,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create(&entries, 2, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	// Open the created archive and query
	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open(out_data.?, out_len, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	try std.testing.expectEqual(@as(usize, 2), z7z_file_count(handle));

	// First entry: symlink
	try std.testing.expectEqual(@as(c_int, 1), z7z_file_is_symlink(handle, 0));
	try std.testing.expectEqual(@as(c_int, 0), z7z_file_is_dir(handle, 0));
	// Symlink target data should be readable
	try std.testing.expectEqual(@as(usize, target.len), z7z_file_size(handle, 0));

	// Second entry: regular file
	try std.testing.expectEqual(@as(c_int, 0), z7z_file_is_symlink(handle, 1));
	try std.testing.expectEqual(@as(c_int, 0), z7z_file_is_dir(handle, 1));
}

test "ffi: metadata roundtrip via FFI" {
	const test_mtime: i64 = 1705320000; // 2024-01-15 12:00:00 UTC
	const test_attrib: u32 = 0x81A48020; // POSIX 0644 regular file

	var entries = [_]Z7zFileEntry{
		.{
			.name = "meta.txt",
			.data = "data",
			.data_len = 4,
			.flags = 0,
			.mtime = test_mtime,
			.win_attrib = test_attrib,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create(&entries, 1, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open(out_data.?, out_len, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	// mtime should roundtrip through FILETIME conversion
	try std.testing.expectEqual(test_mtime, z7z_file_mtime(handle, 0));
	// win_attrib should roundtrip exactly
	try std.testing.expectEqual(test_attrib, z7z_file_attrib(handle, 0));
}

test "ffi: ctime and atime roundtrip via FFI" {
	const test_ctime: i64 = 1705320000; // 2024-01-15 12:00:00 UTC
	const test_atime: i64 = 1717200000; // 2024-06-01 00:00:00 UTC

	var entries = [_]Z7zFileEntry{
		.{
			.name = "times.txt",
			.data = "data",
			.data_len = 4,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = test_ctime,
			.atime = test_atime,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create(&entries, 1, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open(out_data.?, out_len, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	try std.testing.expectEqual(test_ctime, z7z_file_ctime(handle, 0));
	try std.testing.expectEqual(test_atime, z7z_file_atime(handle, 0));
}

test "ffi: xattr roundtrip via FFI" {
	const xattr_blob = "test_xattr_data_blob";
	var entries = [_]Z7zFileEntry{
		.{
			.name = "xattr.txt",
			.data = "data",
			.data_len = 4,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = xattr_blob,
			.xattrs_len = xattr_blob.len,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create(&entries, 1, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open(out_data.?, out_len, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	var xlen: usize = 0;
	const xptr = z7z_file_xattrs(handle, 0, &xlen);
	try std.testing.expect(xptr != null);
	try std.testing.expectEqual(xattr_blob.len, xlen);
	try std.testing.expectEqualSlices(u8, xattr_blob, xptr.?[0..xlen]);
}

test "ffi: open with invalid data returns error" {
	const bad = [_]u8{0} ** 32;
	var handle: ?*ArchiveHandle = null;
	const rc = z7z_open(&bad, bad.len, &handle);
	try std.testing.expectEqual(Z7Z_ERR_NOT_ARCHIVE, rc);
	try std.testing.expectEqual(@as(?*ArchiveHandle, null), handle);
}

test "ffi: open null args returns INVALID_ARG" {
	var handle: ?*ArchiveHandle = null;
	try std.testing.expectEqual(Z7Z_ERR_INVALID_ARG, z7z_open(null, 0, &handle));
	try std.testing.expectEqual(Z7Z_ERR_INVALID_ARG, z7z_open(null, 0, null));
}

test "ffi: create_ex with progress callback fires" {
	const State = struct {
		call_count: u32 = 0,
		fn callback(done: u64, total: u64, user_data: ?*anyopaque) callconv(.c) void {
			_ = done;
			_ = total;
			const self: *@This() = @ptrCast(@alignCast(user_data.?));
			self.call_count += 1;
		}
	};

	var state = State{};

	// Create a small file (Copy method won't fire progress, but LZMA2 via create_ex will)
	var entries = [_]Z7zFileEntry{
		.{
			.name = "p.txt",
			.data = "test data for progress",
			.data_len = 22,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create_ex(&entries, 1, &State.callback, @ptrCast(&state), &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	// Progress should have been called at least once (compress fires at completion for small data)
	try std.testing.expect(state.call_count > 0);
}

test "ffi: open_ex with progress callback fires" {
	const State = struct {
		call_count: u32 = 0,
		fn callback(done: u64, total: u64, user_data: ?*anyopaque) callconv(.c) void {
			_ = done;
			_ = total;
			const self: *@This() = @ptrCast(@alignCast(user_data.?));
			self.call_count += 1;
		}
	};

	// First create an archive
	var entries = [_]Z7zFileEntry{
		.{
			.name = "p.txt",
			.data = "test data for progress extraction",
			.data_len = 33,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create(&entries, 1, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	// Now open with progress
	var state = State{};
	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open_ex(out_data.?, out_len, &State.callback, @ptrCast(&state), &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	// Progress should have been called for the folder decompression
	try std.testing.expect(state.call_count > 0);
}

test "ffi: encrypted roundtrip via create_ex_pw + open_ex_pw" {
	const password = "secret123";
	const file_content = "encrypted data roundtrip test";

	var entries = [_]Z7zFileEntry{
		.{
			.name = "secret.txt",
			.data = file_content,
			.data_len = file_content.len,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	// Create encrypted archive
	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create_ex_pw(&entries, 1, password, 5, null, null, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	// Opening without password should fail
	var handle_bad: ?*ArchiveHandle = null;
	const rc_bad = z7z_open(out_data.?, out_len, &handle_bad);
	try std.testing.expect(rc_bad != Z7Z_OK);

	// Opening with correct password should succeed
	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open_ex_pw(out_data.?, out_len, password, null, null, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	// Verify content
	try std.testing.expectEqual(@as(usize, 1), z7z_file_count(handle));
	try std.testing.expectEqualStrings("secret.txt", std.mem.span(z7z_file_name(handle, 0).?));
	try std.testing.expectEqual(file_content.len, z7z_file_size(handle, 0));
	const data = z7z_file_data(handle, 0).?;
	try std.testing.expectEqualStrings(file_content, data[0..file_content.len]);
}

test "ffi: create_ex2 with thread_count and header encryption" {
	const password = "ex2_test";
	const file_content = "create_ex2 roundtrip test";

	var entries = [_]Z7zFileEntry{
		.{
			.name = "ex2.txt",
			.data = file_content,
			.data_len = file_content.len,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	// Create with thread_count=1, header encryption on
	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	const rc = z7z_create_ex2(&entries, 1, password, 3, 1, 1, null, null, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	// Without password — should fail (header is encrypted, so even parsing fails)
	var handle_bad: ?*ArchiveHandle = null;
	const rc_bad = z7z_open(out_data.?, out_len, &handle_bad);
	try std.testing.expect(rc_bad != Z7Z_OK);

	// With password — should succeed
	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open_ex_pw(out_data.?, out_len, password, null, null, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	try std.testing.expectEqual(@as(usize, 1), z7z_file_count(handle));
	try std.testing.expectEqualStrings("ex2.txt", std.mem.span(z7z_file_name(handle, 0).?));
	try std.testing.expectEqual(file_content.len, z7z_file_size(handle, 0));
	const data = z7z_file_data(handle, 0).?;
	try std.testing.expectEqualStrings(file_content, data[0..file_content.len]);
}

test "ffi: create_ex2 without password uses plain LZMA2" {
	const file_content = "plain lzma2 via create_ex2";

	var entries = [_]Z7zFileEntry{
		.{
			.name = "plain.txt",
			.data = file_content,
			.data_len = file_content.len,
			.flags = 0,
			.mtime = 0,
			.win_attrib = 0,
			.ctime = 0,
			.atime = 0,
			.xattrs = null,
			.xattrs_len = 0,
			.group_index = 0,
		},
	};

	var out_data: ?[*]u8 = null;
	var out_len: usize = 0;
	// No password, thread_count=1, no header encryption
	const rc = z7z_create_ex2(&entries, 1, null, 5, 1, 0, null, null, &out_data, &out_len);
	try std.testing.expectEqual(Z7Z_OK, rc);
	defer z7z_free(out_data, out_len);

	var handle: ?*ArchiveHandle = null;
	const rc2 = z7z_open(out_data.?, out_len, &handle);
	try std.testing.expectEqual(Z7Z_OK, rc2);
	defer z7z_close(handle);

	try std.testing.expectEqual(@as(usize, 1), z7z_file_count(handle));
	try std.testing.expectEqualStrings("plain.txt", std.mem.span(z7z_file_name(handle, 0).?));
	try std.testing.expectEqualStrings(file_content, z7z_file_data(handle, 0).?[0..file_content.len]);
}
