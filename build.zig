const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Default to ReleaseFast per project conventions
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // --- Zig core library (static, with C FFI) ---
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "z7z",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Expose named module for downstream Zig consumers:
    //   dep.module("z7z") — full z7z API (lzma2_encoder, codec, etc.)
    _ = b.addModule("z7z", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- C CLI executable ---
    const cli = b.addExecutable(.{
        .name = "z7z",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    cli.root_module.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli.root_module.addIncludePath(b.path("include"));
    cli.linkLibrary(lib);
    cli.root_module.linkSystemLibrary("magic", .{});
    b.installArtifact(cli);
    const install_cli = b.addInstallArtifact(cli, .{});

    // --- Unit tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // --- CLI integration tests (cross-platform, spawns the CLI binary) ---
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/cli_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    // CLI tests need the CLI binary to be installed first
    run_cli_tests.step.dependOn(&install_cli.step);

    const test_step = b.step("test", "Run unit tests and CLI integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
