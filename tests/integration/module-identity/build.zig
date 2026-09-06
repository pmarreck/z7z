const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .ReleaseFast;
	const options = .{ .target = target, .optimize = optimize };
	const z7z = b.dependency("z7z", options);
	const bzip2z = b.dependency("bzip2z", options);
	// Keep the direct consumer pin aligned with z7z's transitive dependency.
	if (bzip2z.module("bzip2z") != z7z.builder.dependency("bzip2z", options).module("bzip2z"))
		@panic("module identity fixture must pin the same bzip2z package as z7z");
	const consumer = b.addExecutable(.{
		.name = "module-identity",
		.root_module = b.createModule(.{
			.root_source_file = b.path("main.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "z7z", .module = z7z.module("z7z") },
				.{ .name = "bzip2z", .module = bzip2z.module("bzip2z") },
			},
		}),
	});
	const run = b.addRunArtifact(consumer);
	b.default_step.dependOn(&run.step);
}
