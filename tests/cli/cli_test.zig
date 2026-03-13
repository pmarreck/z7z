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

// ============================================================================
// New feature tests: test command, flat extract, selective, -o, -y, -mmt, -mhe
// ============================================================================

test "cli: test command verifies archive integrity" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "verify.txt", "data to verify");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "verify.txt");
    const archive_path = tmpPath(&arc_buf, "test_verify.7z");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    // test command should succeed
    const tr = try runCli(allocator, &.{ "test", "--no-progress", archive_path });
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), tr.exit_code);
    try testing.expect(std.mem.indexOf(u8, tr.stderr, "Everything is Ok") != null);
}

test "cli: 't' alias for test command" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "talias.txt", "t alias data");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "talias.txt");
    const archive_path = tmpPath(&arc_buf, "test_talias.7z");

    const cr = try runCli(allocator, &.{ "a", "--no-progress", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    const tr = try runCli(allocator, &.{ "t", "--no-progress", archive_path });
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), tr.exit_code);
    try testing.expect(std.mem.indexOf(u8, tr.stderr, "Everything is Ok") != null);
}

test "cli: test on corrupt data fails" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "corrupt.7z", "this is not a 7z archive");

    var arc_buf: [256]u8 = undefined;
    const archive_path = tmpPath(&arc_buf, "corrupt.7z");

    const tr = try runCli(allocator, &.{ "t", "--no-progress", archive_path });
    defer tr.deinit(allocator);
    try testing.expect(tr.exit_code != 0);
    try testing.expect(std.mem.indexOf(u8, tr.stderr, "FAILED") != null or
        std.mem.indexOf(u8, tr.stderr, "ERROR") != null or
        std.mem.indexOf(u8, tr.stderr, "error") != null);
}

test "cli: flat extract (e) strips directory structure" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try dir.makePath("flatdir");
    {
        const f = try dir.createFile("flatdir/deep.txt", .{});
        defer f.close();
        try f.writeAll("deep file");
    }

    var d_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const dir_path = tmpPath(&d_buf, "flatdir");
    const archive_path = tmpPath(&arc_buf, "flat_test.7z");
    const out_dir = tmpPath(&out_buf, "out_flat");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, dir_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    // Use 'e' for flat extract with -o
    var o_buf: [256]u8 = undefined;
    const o_prefix = "-o";
    @memcpy(o_buf[0..o_prefix.len], o_prefix);
    @memcpy(o_buf[o_prefix.len .. o_prefix.len + out_dir.len], out_dir);
    const o_flag = o_buf[0 .. o_prefix.len + out_dir.len];

    const er = try runCli(allocator, &.{ "e", "--no-progress", "-y", o_flag, archive_path });
    defer er.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er.exit_code);

    // deep.txt should be in out_dir root, not in out_dir/flatdir/
    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();
    const got = try readTestFile(allocator, out_d, "deep.txt");
    defer allocator.free(got);
    try testing.expectEqualStrings("deep file", got);

    // flatdir/ subdirectory should NOT exist (flat extract)
    const sub_result = out_d.openDir("flatdir", .{});
    try testing.expect(sub_result == error.FileNotFound);
}

test "cli: -o flag sets output directory" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "oflag.txt", "output dir test");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "oflag.txt");
    const archive_path = tmpPath(&arc_buf, "oflag_test.7z");
    const out_dir = tmpPath(&out_buf, "out_oflag");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    var o_buf: [256]u8 = undefined;
    const o_prefix = "-o";
    @memcpy(o_buf[0..o_prefix.len], o_prefix);
    @memcpy(o_buf[o_prefix.len .. o_prefix.len + out_dir.len], out_dir);
    const o_flag = o_buf[0 .. o_prefix.len + out_dir.len];

    const er = try runCli(allocator, &.{ "x", "--no-progress", "-y", o_flag, archive_path });
    defer er.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();
    const got = try readTestFile(allocator, out_d, "oflag.txt");
    defer allocator.free(got);
    try testing.expectEqualStrings("output dir test", got);
}

test "cli: -y flag allows overwriting existing files" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "overwrite.txt", "original");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "overwrite.txt");
    const archive_path = tmpPath(&arc_buf, "overwrite_test.7z");
    const out_dir = tmpPath(&out_buf, "out_overwrite");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    // First extract
    const er1 = try runCli(allocator, &.{ "x", "--no-progress", "-y", archive_path, out_dir });
    defer er1.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er1.exit_code);

    // Second extract without -y should skip existing files (warning)
    const er2 = try runCli(allocator, &.{ "x", "--no-progress", archive_path, out_dir });
    defer er2.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er2.exit_code);
    try testing.expect(std.mem.indexOf(u8, er2.stderr, "skipping existing file") != null);

    // Third extract with -y should succeed without skipping
    const er3 = try runCli(allocator, &.{ "x", "--no-progress", "-y", archive_path, out_dir });
    defer er3.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er3.exit_code);
    try testing.expect(std.mem.indexOf(u8, er3.stderr, "skipping") == null);
}

test "cli: selective extraction by filename" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "keep.txt", "keep me");
    try writeTestFile(dir, "skip.txt", "skip me");

    var f1_buf: [256]u8 = undefined;
    var f2_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;
    const f1_path = tmpPath(&f1_buf, "keep.txt");
    const f2_path = tmpPath(&f2_buf, "skip.txt");
    const archive_path = tmpPath(&arc_buf, "selective_test.7z");
    const out_dir = tmpPath(&out_buf, "out_selective");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, f1_path, f2_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    // Extract only keep.txt using -o and selective filter
    var o_buf: [256]u8 = undefined;
    const o_prefix = "-o";
    @memcpy(o_buf[0..o_prefix.len], o_prefix);
    @memcpy(o_buf[o_prefix.len .. o_prefix.len + out_dir.len], out_dir);
    const o_flag = o_buf[0 .. o_prefix.len + out_dir.len];

    const er = try runCli(allocator, &.{ "x", "--no-progress", "-y", o_flag, archive_path, "keep.txt" });
    defer er.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), er.exit_code);

    var out_d = try std.fs.cwd().openDir(out_dir, .{});
    defer out_d.close();

    // keep.txt should exist
    const got = try readTestFile(allocator, out_d, "keep.txt");
    defer allocator.free(got);
    try testing.expectEqualStrings("keep me", got);

    // skip.txt should NOT exist
    const skip_result = out_d.openFile("skip.txt", .{});
    try testing.expect(skip_result == error.FileNotFound);
}

test "cli: -mhe=on warns without password" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "mhe.txt", "header encrypt test");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "mhe.txt");
    const archive_path = tmpPath(&arc_buf, "mhe_test.7z");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", "-mhe=on", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);
    try testing.expect(std.mem.indexOf(u8, cr.stderr, "-mhe=on has no effect") != null);
}

test "cli: -mmt=1 single-threaded create" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "mmt.txt", "threading test data");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "mmt.txt");
    const archive_path = tmpPath(&arc_buf, "mmt_test.7z");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", "-mmt=1", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    // Verify the archive is valid
    const tr = try runCli(allocator, &.{ "t", "--no-progress", archive_path });
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), tr.exit_code);
    try testing.expect(std.mem.indexOf(u8, tr.stderr, "Everything is Ok") != null);
}

test "cli: test with verbose shows file names" {
    cleanTmpDir();
    const allocator = testing.allocator;

    var dir = try makeTmpDir();
    defer dir.close();
    try writeTestFile(dir, "verbose_test.txt", "verbose check");

    var f_buf: [256]u8 = undefined;
    var arc_buf: [256]u8 = undefined;
    const file_path = tmpPath(&f_buf, "verbose_test.txt");
    const archive_path = tmpPath(&arc_buf, "verbose_test.7z");

    const cr = try runCli(allocator, &.{ "create", "--no-progress", archive_path, file_path });
    defer cr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), cr.exit_code);

    const tr = try runCli(allocator, &.{ "t", "--no-progress", "-v", archive_path });
    defer tr.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), tr.exit_code);
    try testing.expect(std.mem.indexOf(u8, tr.stdout, "verbose_test.txt") != null);
}
