//! Three-way interop tests with the 7zz oracle.
//!
//! Tests that:
//! 1. z7z-created archives can be read by 7zz (our encoder → oracle decoder)
//! 2. 7zz-created archives can be read by z7z (oracle encoder → our decoder)
//! 3. Our encoder → our decoder roundtrip (covered in archive.zig)

const std = @import("std");
const archive = @import("archive.zig");

/// Run 7zz with arguments, returning stdout, stderr, and exit code.
/// Returns null if 7zz is not available.
/// Zig 0.16: std.process.Child.run replaced by std.process.run(alloc, io, opts);
/// max_output_bytes split into stdout_limit / stderr_limit Io.Limit values.
fn run7zz(argv: []const []const u8, allocator: std.mem.Allocator) ?std.process.RunResult {
	return std.process.run(allocator, std.testing.io, .{
		.argv = argv,
		.stdout_limit = .limited(256 * 1024),
		.stderr_limit = .limited(256 * 1024),
	}) catch return null;
}

test "interop: z7z archive accepted by 7zz (list)" {
	const allocator = std.testing.allocator;

	// Create a z7z archive
	const files = [_]archive.FileEntry{
		.{ .name = "greeting.txt", .data = "Hello from z7z!\n" },
	};

	const archive_data = try archive.create(&files, allocator);
	defer allocator.free(archive_data);

	// Write to temp file
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile(std.testing.io, "test.7z", .{});
	try file.writeStreamingAll(std.testing.io, archive_data);
	file.close(std.testing.io);

	const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test.7z", allocator);
	defer allocator.free(path);

	// Run 7zz l (list)
	const result = run7zz(&.{ "7zz", "l", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	// 7zz should exit successfully
	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz l failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => {
			std.debug.print("7zz l terminated abnormally\n", .{});
			return error.TestUnexpectedResult;
		},
	}

	// Verify output mentions our file
	try std.testing.expect(std.mem.indexOf(u8, result.stdout, "greeting.txt") != null);
}

test "interop: z7z archive passes 7zz integrity test" {
	const allocator = std.testing.allocator;

	const files = [_]archive.FileEntry{
		.{ .name = "data.bin", .data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE } },
	};

	const archive_data = try archive.create(&files, allocator);
	defer allocator.free(archive_data);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile(std.testing.io, "test.7z", .{});
	try file.writeStreamingAll(std.testing.io, archive_data);
	file.close(std.testing.io);

	const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test.7z", allocator);
	defer allocator.free(path);

	// Run 7zz t (test integrity)
	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz t failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	// 7zz should report "Everything is Ok"
	try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Everything is Ok") != null);
}

test "interop: z7z archive extraction matches original data via 7zz" {
	const allocator = std.testing.allocator;

	const content = "The quick brown fox jumps over the lazy dog.\n";
	const files = [_]archive.FileEntry{
		.{ .name = "fox.txt", .data = content },
	};

	const archive_data = try archive.create(&files, allocator);
	defer allocator.free(archive_data);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const archive_file = try tmp_dir.dir.createFile(std.testing.io, "test.7z", .{});
	try archive_file.writeStreamingAll(std.testing.io, archive_data);
	archive_file.close(std.testing.io);

	const archive_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test.7z", allocator);
	defer allocator.free(archive_path);

	// Extract with 7zz to the same temp dir
	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const output_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{dir_path});
	defer allocator.free(output_arg);

	const result = run7zz(&.{ "7zz", "x", "-y", archive_path, output_arg }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz x failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	// Read the extracted file and compare
	const extracted = try tmp_dir.dir.readFileAlloc(std.testing.io, "fox.txt", allocator, .limited(1024 * 1024));
	defer allocator.free(extracted);

	try std.testing.expectEqualStrings(content, extracted);
}

test "interop: 7zz-created archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a source file
	const content = "Created by 7zz for z7z interop test.\n";
	const src_file = try tmp_dir.dir.createFile(std.testing.io, "oracle.txt", .{});
	try src_file.writeStreamingAll(std.testing.io, content);
	src_file.close(std.testing.io);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "oracle.txt", allocator);
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/oracle.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Create archive with 7zz using Copy method (-m0=Copy)
	const result = run7zz(&.{ "7zz", "a", "-m0=Copy", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz a failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
				return; // Skip if 7zz can't create
			}
		},
		else => return,
	}

	// Read the 7zz-created archive
	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "oracle.7z", allocator, .limited(1024 * 1024));
	defer allocator.free(archive_data);

	// Parse with z7z
	var contents = archive.read(archive_data, allocator) catch |e| {
		std.debug.print("z7z read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	// Verify file count
	try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);

	// Verify file data matches
	try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "interop: multi-file roundtrip through z7z and 7zz" {
	const allocator = std.testing.allocator;

	// Create multi-file archive with z7z
	const files = [_]archive.FileEntry{
		.{ .name = "alpha.txt", .data = "First file\n" },
		.{ .name = "beta.txt", .data = "Second file\n" },
		.{ .name = "gamma.bin", .data = &[_]u8{ 0x00, 0x01, 0x02, 0x03 } },
	};

	const archive_data = try archive.create(&files, allocator);
	defer allocator.free(archive_data);

	// Verify z7z can read its own output
	var contents = try archive.read(archive_data, allocator);
	defer contents.deinit();

	try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);
	try std.testing.expectEqualStrings("alpha.txt", contents.metadata.files[0].name.?);
	try std.testing.expectEqualStrings("beta.txt", contents.metadata.files[1].name.?);
	try std.testing.expectEqualStrings("gamma.bin", contents.metadata.files[2].name.?);
	try std.testing.expectEqualStrings("First file\n", contents.file_data[0]);
	try std.testing.expectEqualStrings("Second file\n", contents.file_data[1]);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03 }, contents.file_data[2]);

	// Verify 7zz accepts it
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile(std.testing.io, "multi.7z", .{});
	try file.writeStreamingAll(std.testing.io, archive_data);
	file.close(std.testing.io);

	const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "multi.7z", allocator);
	defer allocator.free(path);

	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz t multi failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Everything is Ok") != null);
}

test "interop: z7z LZMA2 archive accepted by 7zz" {
	const allocator = std.testing.allocator;

	const files = [_]archive.FileEntry{
		.{ .name = "compressed.txt", .data = "Hello from z7z LZMA2 encoder!\n" },
	};

	const archive_data = try archive.createWithMethod(&files, .lzma2, allocator);
	defer allocator.free(archive_data);

	// Write to temp file
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile(std.testing.io, "lzma2_z7z.7z", .{});
	try file.writeStreamingAll(std.testing.io, archive_data);
	file.close(std.testing.io);

	const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "lzma2_z7z.7z", allocator);
	defer allocator.free(path);

	// Run 7zz t (test integrity)
	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz t LZMA2 failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Everything is Ok") != null);
}

test "interop: z7z LZMA2 extraction matches via 7zz" {
	const allocator = std.testing.allocator;

	const content = "The quick brown fox jumps over the lazy dog.\n" ** 10;
	const files = [_]archive.FileEntry{
		.{ .name = "fox_lzma2.txt", .data = content },
	};

	const archive_data = try archive.createWithMethod(&files, .lzma2, allocator);
	defer allocator.free(archive_data);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const archive_file = try tmp_dir.dir.createFile(std.testing.io, "fox_lzma2.7z", .{});
	try archive_file.writeStreamingAll(std.testing.io, archive_data);
	archive_file.close(std.testing.io);

	const archive_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "fox_lzma2.7z", allocator);
	defer allocator.free(archive_path);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const output_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{dir_path});
	defer allocator.free(output_arg);

	const result = run7zz(&.{ "7zz", "x", "-y", archive_path, output_arg }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz x LZMA2 failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	// Read extracted file and compare
	const extracted = try tmp_dir.dir.readFileAlloc(std.testing.io, "fox_lzma2.txt", allocator, .limited(1024 * 1024));
	defer allocator.free(extracted);
	try std.testing.expectEqualStrings(content, extracted);
}

test "interop: 7zz LZMA2 archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a source file
	const content = "LZMA2 interop test content from 7zz.\n";
	const src_file = try tmp_dir.dir.createFile(std.testing.io, "lzma2.txt", .{});
	try src_file.writeStreamingAll(std.testing.io, content);
	src_file.close(std.testing.io);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "lzma2.txt", allocator);
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/lzma2.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Create archive with 7zz using LZMA2 (default method)
	const result = run7zz(&.{ "7zz", "a", "-m0=LZMA2", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) return; // Skip if 7zz can't create
		},
		else => return,
	}

	// Read the 7zz-created LZMA2 archive
	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "lzma2.7z", allocator, .limited(1024 * 1024));
	defer allocator.free(archive_data);

	// Parse with z7z — this should decompress LZMA2
	var contents = archive.read(archive_data, allocator) catch |e| {
		std.debug.print("z7z LZMA2 read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
	try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "interop: 7zz BCJ+LZMA2 archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a file with data that looks like x86 code (CALL/JMP instructions)
	// This will trigger BCJ filter usage in 7zz
	var fake_exe: [256]u8 = undefined;
	for (&fake_exe, 0..) |*b, i| {
		b.* = @intCast(i & 0xFF);
	}
	// Insert some E8 (CALL) instructions to make BCJ worthwhile
	fake_exe[10] = 0xE8;
	fake_exe[30] = 0xE8;
	fake_exe[50] = 0xE8;

	const src_file = try tmp_dir.dir.createFile(std.testing.io, "test.bin", .{});
	try src_file.writeStreamingAll(std.testing.io, &fake_exe);
	src_file.close(std.testing.io);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test.bin", allocator);
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/bcj.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Force BCJ+LZMA2 pipeline
	const result = run7zz(&.{ "7zz", "a", "-m0=BCJ", "-m1=LZMA2", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) return; // Skip if 7zz can't create
		},
		else => return,
	}

	// Read the 7zz-created BCJ+LZMA2 archive
	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "bcj.7z", allocator, .limited(1024 * 1024));
	defer allocator.free(archive_data);

	// Parse with z7z — should handle multi-coder pipeline
	var contents = archive.read(archive_data, allocator) catch |e| {
		std.debug.print("z7z BCJ+LZMA2 read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
	try std.testing.expectEqualSlices(u8, &fake_exe, contents.file_data[0]);
}

test "interop: 7zz encoded header archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create many files to force 7zz to use encoded header
	const file_count = 26;
	const contents_str = "Test content for encoded header interop.\n";

	var src_paths = std.ArrayListUnmanaged([]u8).empty;
	defer {
		for (src_paths.items) |p| allocator.free(p);
		src_paths.deinit(allocator);
	}

	for (0..file_count) |i| {
		const name = try std.fmt.allocPrint(allocator, "file_{c}.txt", .{@as(u8, @intCast('a' + i))});
		defer allocator.free(name);

		const f = try tmp_dir.dir.createFile(std.testing.io, name, .{});
		try f.writeStreamingAll(std.testing.io, contents_str);
		f.close(std.testing.io);

		const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, name, allocator);
		try src_paths.append(allocator, path);
	}

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/enchdr.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Build argv: 7zz a -mhc=on archive_path file1 file2 ...
	var argv = std.ArrayListUnmanaged([]const u8).empty;
	defer argv.deinit(allocator);
	try argv.appendSlice(allocator, &.{ "7zz", "a", "-mhc=on", archive_path });
	for (src_paths.items) |p| {
		try argv.append(allocator, p);
	}

	const result = run7zz(argv.items, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) return;
		},
		else => return,
	}

	// Read the 7zz archive — should have kEncodedHeader
	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "enchdr.7z", allocator, .limited(2 * 1024 * 1024));
	defer allocator.free(archive_data);

	var contents = archive.read(archive_data, allocator) catch |e| {
		std.debug.print("z7z encoded header read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	// Verify we got all 26 files
	try std.testing.expectEqual(@as(usize, file_count), contents.metadata.files.len);

	// Verify first file's content
	try std.testing.expectEqualStrings(contents_str, contents.file_data[0]);
}

test "interop: 7zz encrypted archive decryptable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const content = "Secret data for encryption interop test.\n";
	const password = "testpass123";

	const src_file = try tmp_dir.dir.createFile(std.testing.io, "secret.txt", .{});
	try src_file.writeStreamingAll(std.testing.io, content);
	src_file.close(std.testing.io);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "secret.txt", allocator);
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/encrypted.7z", .{dir_path});
	defer allocator.free(archive_path);

	const pw_arg = try std.fmt.allocPrint(allocator, "-p{s}", .{password});
	defer allocator.free(pw_arg);

	// Create encrypted archive with 7zz
	// -mhe=on encrypts the header too
	const result = run7zz(&.{ "7zz", "a", "-m0=LZMA2", pw_arg, "-mhe=on", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) return; // Skip if 7zz can't create
		},
		else => return,
	}

	// Read the encrypted archive with z7z
	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "encrypted.7z", allocator, .limited(1024 * 1024));
	defer allocator.free(archive_data);

	var contents = archive.readWithPassword(archive_data, password, allocator) catch |e| {
		std.debug.print("z7z encrypted read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
	try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "interop: 7zz encrypted content (no header encryption) readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const content = "Encrypted content, plain header.\n";
	const password = "pass456";

	const src_file = try tmp_dir.dir.createFile(std.testing.io, "enc_content.txt", .{});
	try src_file.writeStreamingAll(std.testing.io, content);
	src_file.close(std.testing.io);

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "enc_content.txt", allocator);
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/enc_content.7z", .{dir_path});
	defer allocator.free(archive_path);

	const pw_arg = try std.fmt.allocPrint(allocator, "-p{s}", .{password});
	defer allocator.free(pw_arg);

	// -mhe=off: encrypt content only, not the header
	const result = run7zz(&.{ "7zz", "a", "-m0=LZMA2", pw_arg, "-mhe=off", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) return;
		},
		else => return,
	}

	const archive_data = try tmp_dir.dir.readFileAlloc(std.testing.io, "enc_content.7z", allocator, .limited(1024 * 1024));
	defer allocator.free(archive_data);

	var contents = archive.readWithPassword(archive_data, password, allocator) catch |e| {
		std.debug.print("z7z enc_content read failed: {}\n", .{e});
		return e;
	};
	defer contents.deinit();

	try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
	try std.testing.expectEqualStrings(content, contents.file_data[0]);
}

test "interop: z7z encrypted archive decryptable by 7zz" {
	const allocator = std.testing.allocator;

	const password = "z7z_encrypt_test_pw";
	const content = "Encrypted by z7z, decrypted by 7zz.\n";
	const files = [_]archive.FileEntry{
		.{ .name = "z7z_enc.txt", .data = content },
	};

	// Create encrypted archive with z7z
	const archive_data = archive.createWithMethodAndPassword(&files, .lzma2_aes, password, allocator) catch |e| {
		std.debug.print("z7z encrypted create failed: {}\n", .{e});
		return e;
	};
	defer allocator.free(archive_data);

	// Write to temp dir
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	try tmp_dir.dir.writeFile(std.testing.io, .{ .sub_path = "z7z_enc.7z", .data = archive_data });

	const dir_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
	defer allocator.free(dir_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/z7z_enc.7z", .{dir_path});
	defer allocator.free(archive_path);

	const extract_dir = try std.fmt.allocPrint(allocator, "-o{s}/out", .{dir_path});
	defer allocator.free(extract_dir);

	const pw_arg = try std.fmt.allocPrint(allocator, "-p{s}", .{password});
	defer allocator.free(pw_arg);

	// Extract with 7zz
	const result = run7zz(&.{ "7zz", "x", pw_arg, extract_dir, archive_path, "-y" }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.exited => |code| {
			if (code != 0) {
				std.debug.print("7zz extraction failed (exit code {d}):\n{s}\n{s}\n", .{ code, result.stdout, result.stderr });
				return error.ExtractionFailed;
			}
		},
		else => {
			std.debug.print("7zz terminated abnormally\n", .{});
			return error.ExtractionFailed;
		},
	}

	// Verify extracted content matches
	const extracted = tmp_dir.dir.readFileAlloc(std.testing.io, "out/z7z_enc.txt", allocator, .limited(1024 * 1024)) catch |e| {
		std.debug.print("Could not read extracted file: {}\n", .{e});
		return e;
	};
	defer allocator.free(extracted);

	try std.testing.expectEqualStrings(content, extracted);
}
