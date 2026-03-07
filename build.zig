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
        .name = "libz7z",
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
        .flags = &.{ "-std=gnu11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli.root_module.addIncludePath(b.path("include"));
    cli.linkLibrary(lib);

    // progrez progress bar library (all platforms)
    const progrez_dep = b.dependency("progrez", .{
        .target = target,
        .optimize = optimize,
    });
    cli.root_module.addIncludePath(progrez_dep.path("include"));
    cli.linkLibrary(progrez_dep.artifact("progrez"));

    // libmagic + POSIX extensions: non-Windows only
    const is_windows = target.result.os.tag == .windows;
    if (!is_windows) {
        // _GNU_SOURCE needed for statx(), asprintf(), etc. on Linux musl
        cli.root_module.addCMacro("_GNU_SOURCE", "");
        const magic_dep = b.dependency("libmagic", .{
            .target = target,
            .optimize = optimize,
            .linkage = .static,
        });
        const magic_lib = magic_dep.artifact("magic");
        cli.root_module.addIncludePath(magic_lib.getEmittedIncludeTree());
        cli.linkLibrary(magic_lib);
    }

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
