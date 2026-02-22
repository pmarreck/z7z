//! Three-way interop tests with the 7zz oracle.
//!
//! Tests that:
//! 1. z7z-created archives can be read by 7zz (our encoder → oracle decoder)
//! 2. 7zz-created archives can be read by z7z (oracle encoder → our decoder)
//! 3. Our encoder → our decoder roundtrip (covered in archive.zig)

const std = @import("std");
const archive = @import("archive.zig");
const Child = std.process.Child;

/// Run 7zz with arguments, returning stdout, stderr, and exit code.
/// Returns null if 7zz is not available.
fn run7zz(argv: []const []const u8, allocator: std.mem.Allocator) ?Child.RunResult {
	return Child.run(.{
		.allocator = allocator,
		.argv = argv,
		.max_output_bytes = 256 * 1024,
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

	const file = try tmp_dir.dir.createFile("test.7z", .{});
	try file.writeAll(archive_data);
	file.close();

	const path = try tmp_dir.dir.realpathAlloc(allocator, "test.7z");
	defer allocator.free(path);

	// Run 7zz l (list)
	const result = run7zz(&.{ "7zz", "l", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	// 7zz should exit successfully
	switch (result.term) {
		.Exited => |code| {
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

	const file = try tmp_dir.dir.createFile("test.7z", .{});
	try file.writeAll(archive_data);
	file.close();

	const path = try tmp_dir.dir.realpathAlloc(allocator, "test.7z");
	defer allocator.free(path);

	// Run 7zz t (test integrity)
	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
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

	const archive_file = try tmp_dir.dir.createFile("test.7z", .{});
	try archive_file.writeAll(archive_data);
	archive_file.close();

	const archive_path = try tmp_dir.dir.realpathAlloc(allocator, "test.7z");
	defer allocator.free(archive_path);

	// Extract with 7zz to the same temp dir
	const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	const output_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{dir_path});
	defer allocator.free(output_arg);

	const result = run7zz(&.{ "7zz", "x", "-y", archive_path, output_arg }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
			if (code != 0) {
				std.debug.print("7zz x failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	// Read the extracted file and compare
	const extracted = try tmp_dir.dir.readFileAlloc(allocator, "fox.txt", 1024 * 1024);
	defer allocator.free(extracted);

	try std.testing.expectEqualStrings(content, extracted);
}

test "interop: 7zz-created archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a source file
	const content = "Created by 7zz for z7z interop test.\n";
	const src_file = try tmp_dir.dir.createFile("oracle.txt", .{});
	try src_file.writeAll(content);
	src_file.close();

	const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realpathAlloc(allocator, "oracle.txt");
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/oracle.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Create archive with 7zz using Copy method (-m0=Copy)
	const result = run7zz(&.{ "7zz", "a", "-m0=Copy", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
			if (code != 0) {
				std.debug.print("7zz a failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
				return; // Skip if 7zz can't create
			}
		},
		else => return,
	}

	// Read the 7zz-created archive
	const archive_data = try tmp_dir.dir.readFileAlloc(allocator, "oracle.7z", 1024 * 1024);
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

	const file = try tmp_dir.dir.createFile("multi.7z", .{});
	try file.writeAll(archive_data);
	file.close();

	const path = try tmp_dir.dir.realpathAlloc(allocator, "multi.7z");
	defer allocator.free(path);

	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
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

	const file = try tmp_dir.dir.createFile("lzma2_z7z.7z", .{});
	try file.writeAll(archive_data);
	file.close();

	const path = try tmp_dir.dir.realpathAlloc(allocator, "lzma2_z7z.7z");
	defer allocator.free(path);

	// Run 7zz t (test integrity)
	const result = run7zz(&.{ "7zz", "t", path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
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

	const archive_file = try tmp_dir.dir.createFile("fox_lzma2.7z", .{});
	try archive_file.writeAll(archive_data);
	archive_file.close();

	const archive_path = try tmp_dir.dir.realpathAlloc(allocator, "fox_lzma2.7z");
	defer allocator.free(archive_path);

	const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	const output_arg = try std.fmt.allocPrint(allocator, "-o{s}", .{dir_path});
	defer allocator.free(output_arg);

	const result = run7zz(&.{ "7zz", "x", "-y", archive_path, output_arg }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
			if (code != 0) {
				std.debug.print("7zz x LZMA2 failed (exit {d}):\nstdout: {s}\nstderr: {s}\n", .{ code, result.stdout, result.stderr });
			}
			try std.testing.expectEqual(@as(u8, 0), code);
		},
		else => return error.TestUnexpectedResult,
	}

	// Read extracted file and compare
	const extracted = try tmp_dir.dir.readFileAlloc(allocator, "fox_lzma2.txt", 1024 * 1024);
	defer allocator.free(extracted);
	try std.testing.expectEqualStrings(content, extracted);
}

test "interop: 7zz LZMA2 archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create a source file
	const content = "LZMA2 interop test content from 7zz.\n";
	const src_file = try tmp_dir.dir.createFile("lzma2.txt", .{});
	try src_file.writeAll(content);
	src_file.close();

	const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	const src_path = try tmp_dir.dir.realpathAlloc(allocator, "lzma2.txt");
	defer allocator.free(src_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/lzma2.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Create archive with 7zz using LZMA2 (default method)
	const result = run7zz(&.{ "7zz", "a", "-m0=LZMA2", archive_path, src_path }, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
			if (code != 0) return; // Skip if 7zz can't create
		},
		else => return,
	}

	// Read the 7zz-created LZMA2 archive
	const archive_data = try tmp_dir.dir.readFileAlloc(allocator, "lzma2.7z", 1024 * 1024);
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

test "interop: 7zz encoded header archive readable by z7z" {
	const allocator = std.testing.allocator;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	// Create many files to force 7zz to use encoded header
	const file_count = 26;
	const contents_str = "Test content for encoded header interop.\n";

	var src_paths = std.ArrayListUnmanaged([]u8){};
	defer {
		for (src_paths.items) |p| allocator.free(p);
		src_paths.deinit(allocator);
	}

	for (0..file_count) |i| {
		const name = try std.fmt.allocPrint(allocator, "file_{c}.txt", .{@as(u8, @intCast('a' + i))});
		defer allocator.free(name);

		const f = try tmp_dir.dir.createFile(name, .{});
		try f.writeAll(contents_str);
		f.close();

		const path = try tmp_dir.dir.realpathAlloc(allocator, name);
		try src_paths.append(allocator, path);
	}

	const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	const archive_path = try std.fmt.allocPrint(allocator, "{s}/enchdr.7z", .{dir_path});
	defer allocator.free(archive_path);

	// Build argv: 7zz a -mhc=on archive_path file1 file2 ...
	var argv = std.ArrayListUnmanaged([]const u8){};
	defer argv.deinit(allocator);
	try argv.appendSlice(allocator, &.{ "7zz", "a", "-mhc=on", archive_path });
	for (src_paths.items) |p| {
		try argv.append(allocator, p);
	}

	const result = run7zz(argv.items, allocator) orelse return;
	defer allocator.free(result.stdout);
	defer allocator.free(result.stderr);

	switch (result.term) {
		.Exited => |code| {
			if (code != 0) return;
		},
		else => return,
	}

	// Read the 7zz archive — should have kEncodedHeader
	const archive_data = try tmp_dir.dir.readFileAlloc(allocator, "enchdr.7z", 2 * 1024 * 1024);
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
