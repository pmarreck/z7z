const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const linkage = b.option(std.builtin.LinkMode, "linkage", "Library linkage (default: static)") orelse .static;

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    lib_mod.addCMacro("HAVE_CONFIG_H", "");
    // POSIX/GNU extensions required for sigaction, vfork, asprintf, isascii, etc.
    lib_mod.addCMacro("_GNU_SOURCE", "");
    lib_mod.addIncludePath(b.path("src"));

    const flags: []const []const u8 = &.{
        "-std=gnu11",
        "-Wall",
        "-Wno-unused-parameter",
        "-Wno-sign-compare",
        "-Wno-format-truncation",
        "-Wno-tautological-constant-out-of-range-compare",
    };

    // Core library sources (always compiled)
    lib_mod.addCSourceFiles(.{
        .files = &.{
            "src/apprentice.c",
            "src/apptype.c",
            "src/ascmagic.c",
            "src/buffer.c",
            "src/cdf.c",
            "src/cdf_time.c",
            "src/compress.c",
            "src/der.c",
            "src/encoding.c",
            "src/fsmagic.c",
            "src/funcs.c",
            "src/is_csv.c",
            "src/is_json.c",
            "src/is_simh.c",
            "src/is_tar.c",
            "src/magic.c",
            "src/print.c",
            "src/readcdf.c",
            "src/readelf.c",
            "src/softmagic.c",
        },
        .flags = flags,
    });

    // Portable replacement functions — only compile those missing from the
    // target's libc. The upstream Makefile uses AC_REPLACE_FUNCS for this;
    // here we hard-code knowledge of what each platform provides.
    const os_tag = target.result.os.tag;
    const is_unix = os_tag != .windows;
    const is_linux = os_tag == .linux;
    const is_macos = os_tag == .macos;

    // On Unix (Linux/macOS/BSD): libc provides most of these.
    // strlcpy, strlcat: in macOS libc, musl, glibc 2.38+
    // strcasestr: in macOS libc, glibc, musl
    // fmtcheck: in macOS/BSD libc only — NOT in glibc or musl
    // Others (pread, getline, *_r, asprintf, vasprintf, dprintf): in all Unix libcs

    if (!is_unix) {
        // Windows: compile all compat sources
        lib_mod.addCSourceFiles(.{
            .files = &.{
                "src/strlcpy.c",
                "src/strlcat.c",
                "src/asprintf.c",
                "src/vasprintf.c",
                "src/fmtcheck.c",
                "src/getline.c",
                "src/ctime_r.c",
                "src/asctime_r.c",
                "src/localtime_r.c",
                "src/gmtime_r.c",
                "src/pread.c",
                "src/strcasestr.c",
                "src/dprintf.c",
            },
            .flags = flags,
        });
    } else if (is_linux) {
        // Linux (glibc/musl): only fmtcheck is missing
        lib_mod.addCSourceFiles(.{
            .files = &.{"src/fmtcheck.c"},
            .flags = flags,
        });
    } else if (!is_macos) {
        // Other BSDs: assume fmtcheck is available, nothing needed
        // (FreeBSD, OpenBSD, NetBSD all have fmtcheck in libc)
    }
    // macOS: everything is in libc, no compat sources needed

    const lib = b.addLibrary(.{
        .name = "magic",
        .root_module = lib_mod,
        .linkage = linkage,
    });

    // Public header
    lib.installHeader(b.path("src/magic.h"), "magic.h");

    b.installArtifact(lib);
}
