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
