const std = @import("std");
const z7z = @import("z7z");

const max_archive_bytes = 512 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next(); // executable name
    const archive_path = args.next() orelse {
        std.debug.print("usage: z7z-verify-bench <archive.7z> [iterations]\n", .{});
        std.process.exit(2);
    };
    const iterations_arg = args.next();
    const iterations = if (iterations_arg) |s|
        try std.fmt.parseInt(usize, s, 10)
    else
        50;
    if (iterations == 0) {
        std.debug.print("iterations must be > 0\n", .{});
        std.process.exit(2);
    }

    const file = try std.Io.Dir.cwd().openFile(init.io, archive_path, .{});
    defer file.close(init.io);

    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(init.io, &read_buf);
    const archive_data = try reader.interface.allocRemaining(init.gpa, .limited(max_archive_bytes));
    defer init.gpa.free(archive_data);

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    var last_stats: z7z.archive.ArchiveStats = .{};
    for (0..iterations) |_| {
        last_stats = try z7z.archive.verify(archive_data, .{}, init.gpa);
    }
    const elapsed_ns = start.untilNow(init.io).raw.nanoseconds;

    std.debug.print(
        "verified {d} iterations: files={d} unpacked={d} elapsed_ns={d}\n",
        .{ iterations, last_stats.file_count, last_stats.total_unpack_size, elapsed_ns },
    );
}
