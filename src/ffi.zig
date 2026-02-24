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

/// Close an archive and free all associated memory.
export fn z7z_close(handle: ?*ArchiveHandle) void {
	const h = handle orelse return;
	h.deinit();
}

/// File entry for archive creation (C-compatible).
pub const Z7zFileEntry = extern struct {
	name: [*:0]const u8,
	data: [*]const u8,
	data_len: usize,
};

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
		zig_files[i] = .{
			.name = cf.name[0..name_len],
			.data = cf.data[0..cf.data_len],
		};
	}

	const result = archive.create(zig_files, allocator) catch |e| return mapCreateError(e);
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
	z7z_close(null); // should not crash
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
