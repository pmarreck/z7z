const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const exe_name = if (builtin.os.tag == .windows) "z7z.exe" else "z7z";
const exe_path = "zig-out/bin/" ++ exe_name;

const CliResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,

    fn deinit(self: CliResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run the z7z CLI with the given arguments and return stdout, stderr, and exit code.
fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !CliResult {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.appendSlice(allocator, args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_buf: std.ArrayList(u8) = .{};
    var stderr_buf: std.ArrayList(u8) = .{};
    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 1024 * 1024);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal => 255,
        else => 254,
    };

    return .{
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
        .exit_code = code,
    };
}

fn makeTmpDir() !std.fs.Dir {
    return std.fs.cwd().makeOpenPath(".zig-cache/cli-test-tmp", .{});
}

fn cleanTmpDir() void {
    std.fs.cwd().deleteTree(".zig-cache/cli-test-tmp") catch {};
}

fn writeTestFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

fn readTestFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ![]const u8 {
    const file = try dir.openFile(name, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn tmpPath(buf: []u8, name: []const u8) []const u8 {
    const prefix = ".zig-cache/cli-test-tmp/";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    return buf[0 .. prefix.len + name.len];
}

// ============================================================================
// Tests
// ============================================================================

test "cli: no args prints usage and exits non-zero" {
    cleanTmpDir();
    const result = try runCli(testing.allocator, &.{});
    defer result.deinit(testing.allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "Usage") != null);
}

test "cli: list on missing file fails" {
    cleanTmpDir();
    const result = try runCli(testing.allocator, &.{ "list", ".zig-cache/cli-test-tmp/nonexistent.7z" });
    defer result.deinit(testing.allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "error") != null);
}

test "cli: unknown command fails" {
    cleanTmpDir();
    const result = try runCli(testing.allocator, &.{ "frobnicate", "foo.7z" });
    defer result.deinit(testing.allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command") != null);
}

test "cli: create + list + extract single file roundtrip" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();

    try writeTestFile(dir, "hello.txt", "Hello from CLI integration test!");

    var path_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const input_path = tmpPath(&path_buf, "hello.txt");
    const archive_path = tmpPath(&arc_buf, "single.7z");
    const out_dir = tmpPath(&out_buf, "out_single");

    const create_result = try runCli(allocator, &.{ "create", archive_path, input_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    const list_result = try runCli(allocator, &.{ "list", archive_path });
    defer list_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "Files: 1") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "hello.txt") != null);

    const extract_result = try runCli(allocator, &.{ "extract", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();
    const extracted = try readTestFile(allocator, out_d, "hello.txt");
    defer allocator.free(extracted);
    try testing.expectEqualStrings("Hello from CLI integration test!", extracted);
}

test "cli: create + extract multi-file roundtrip" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();

    try writeTestFile(dir, "alpha.txt", "Alpha content");
    try writeTestFile(dir, "beta.txt", "Beta content here");
    try writeTestFile(dir, "gamma.bin", "\xDE\xAD\xBE\xEF");

    var a_buf: [256]u8 = undefined;
    var b_buf: [256]u8 = undefined;
    var c_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const a_path = tmpPath(&a_buf, "alpha.txt");
    const b_path = tmpPath(&b_buf, "beta.txt");
    const c_path = tmpPath(&c_buf, "gamma.bin");
    const archive_path = tmpPath(&arc_buf, "multi.7z");
    const out_dir = tmpPath(&out_buf, "out_multi");

    const create_result = try runCli(allocator, &.{ "create", archive_path, a_path, b_path, c_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    const list_result = try runCli(allocator, &.{ "list", archive_path });
    defer list_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "Files: 3") != null);

    const extract_result = try runCli(allocator, &.{ "extract", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();

    const got_a = try readTestFile(allocator, out_d, "alpha.txt");
    defer allocator.free(got_a);
    try testing.expectEqualStrings("Alpha content", got_a);

    const got_b = try readTestFile(allocator, out_d, "beta.txt");
    defer allocator.free(got_b);
    try testing.expectEqualStrings("Beta content here", got_b);

    const got_c = try readTestFile(allocator, out_d, "gamma.bin");
    defer allocator.free(got_c);
    try testing.expectEqualStrings("\xDE\xAD\xBE\xEF", got_c);
}

test "cli: rejects invalid archive" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "bad.7z", "this is not a 7z archive");

    var arc_buf: [256]u8 = undefined;
    const archive_path = tmpPath(&arc_buf, "bad.7z");

    const result = try runCli(allocator, &.{ "list", archive_path });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "error") != null);
}

test "cli: create with no input files fails" {
    cleanTmpDir();
    const allocator = testing.allocator;
    const result = try runCli(allocator, &.{ "create", ".zig-cache/cli-test-tmp/empty.7z" });
    defer result.deinit(allocator);

    try testing.expect(result.exit_code != 0);
}

test "cli: extract to current dir (no output dir)" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();

    try writeTestFile(dir, "nodir.txt", "extract without dir arg");

    var in_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const input_path = tmpPath(&in_buf, "nodir.txt");
    const archive_path = tmpPath(&arc_buf, "nodir.7z");

    const create_result = try runCli(allocator, &.{ "create", archive_path, input_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    const extract_result = try runCli(allocator, &.{ "extract", archive_path });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    // Clean up the extracted file from CWD
    std.fs.cwd().deleteFile("nodir.txt") catch {};
}

test "cli: path with spaces in filename" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();

    try writeTestFile(dir, "file with spaces.txt", "spaces are tricky");

    var in_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const input_path = tmpPath(&in_buf, "file with spaces.txt");
    const archive_path = tmpPath(&arc_buf, "spaces.7z");
    const out_dir = tmpPath(&out_buf, "out_spaces");

    const create_result = try runCli(allocator, &.{ "create", archive_path, input_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    const extract_result = try runCli(allocator, &.{ "extract", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();
    const extracted = try readTestFile(allocator, out_d, "file with spaces.txt");
    defer allocator.free(extracted);
    try testing.expectEqualStrings("spaces are tricky", extracted);
}

test "cli: command aliases (l, x, a)" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "alias.txt", "testing aliases");

    var in_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const input_path = tmpPath(&in_buf, "alias.txt");
    const archive_path = tmpPath(&arc_buf, "alias.7z");
    const out_dir = tmpPath(&out_buf, "out_alias");

    // 'a' alias for create
    const create_result = try runCli(allocator, &.{ "a", archive_path, input_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    // 'l' alias for list
    const list_result = try runCli(allocator, &.{ "l", archive_path });
    defer list_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "Files: 1") != null);

    // 'x' alias for extract
    const extract_result = try runCli(allocator, &.{ "x", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);
}

test "cli: create + list + extract directory" {
    cleanTmpDir();
    const allocator = testing.allocator;

    // Create a directory structure
    var dir = try makeTmpDir();
    defer dir.close();
    try dir.makePath("mydir/sub");
    {
        const f = try dir.createFile("mydir/top.txt", .{});
        defer f.close();
        try f.writeAll("Top-level file");
    }
    {
        const f = try dir.createFile("mydir/sub/nested.txt", .{});
        defer f.close();
        try f.writeAll("Nested file");
    }

    var dir_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const dir_path = tmpPath(&dir_buf, "mydir");
    const archive_path = tmpPath(&arc_buf, "dir_test.7z");
    const out_dir = tmpPath(&out_buf, "out_dir_test");

    // Create archive from directory
    const create_result = try runCli(allocator, &.{ "create", archive_path, dir_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    // List should show directory entries and files
    const list_result = try runCli(allocator, &.{ "list", archive_path });
    defer list_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "mydir/") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "mydir/top.txt") != null);
    try testing.expect(std.mem.indexOf(u8, list_result.stdout, "mydir/sub/nested.txt") != null);

    // Extract and verify
    const extract_result = try runCli(allocator, &.{ "extract", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();

    const got_top = try readTestFile(allocator, out_d, "mydir/top.txt");
    defer allocator.free(got_top);
    try testing.expectEqualStrings("Top-level file", got_top);

    const got_nested = try readTestFile(allocator, out_d, "mydir/sub/nested.txt");
    defer allocator.free(got_nested);
    try testing.expectEqualStrings("Nested file", got_nested);
}

test "cli: mixed files and directory" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();

    try writeTestFile(dir, "standalone.txt", "Standalone content");
    try dir.makePath("testdir");
    {
        const f = try dir.createFile("testdir/inner.txt", .{});
        defer f.close();
        try f.writeAll("Inner content");
    }

    var s_buf: [256]u8 = undefined;
    var d_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const standalone_path = tmpPath(&s_buf, "standalone.txt");
    const dir_path = tmpPath(&d_buf, "testdir");
    const archive_path = tmpPath(&arc_buf, "mixed.7z");
    const out_dir = tmpPath(&out_buf, "out_mixed");

    const create_result = try runCli(allocator, &.{ "create", archive_path, standalone_path, dir_path });
    defer create_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), create_result.exit_code);

    const extract_result = try runCli(allocator, &.{ "extract", archive_path, out_dir });
    defer extract_result.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), extract_result.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();

    const got_s = try readTestFile(allocator, out_d, "standalone.txt");
    defer allocator.free(got_s);
    try testing.expectEqualStrings("Standalone content", got_s);

    const got_i = try readTestFile(allocator, out_d, "testdir/inner.txt");
    defer allocator.free(got_i);
    try testing.expectEqualStrings("Inner content", got_i);
}
