//! Progress reporting for long-running archive operations.

/// Context for progress callbacks during create/read operations.
/// Default-initialized to no-op (null callback).
pub const ProgressContext = struct {
	callback: ?*const fn (bytes_done: u64, bytes_total: u64, user_data: ?*anyopaque) callconv(.c) void = null,
	user_data: ?*anyopaque = null,

	pub fn report(self: ProgressContext, done: u64, total: u64) void {
		if (self.callback) |cb| cb(done, total, self.user_data);
	}
};

const std = @import("std");

test "progress: report is a safe no-op when callback is null" {
	const ctx = ProgressContext{}; // default: null callback
	ctx.report(0, 0);
	ctx.report(42, 100); // must not crash / dereference null
}

test "progress: report forwards done/total/user_data to the callback" {
	const Captured = struct {
		var done: u64 = 0;
		var total: u64 = 0;
		var calls: u32 = 0;
		var seen_ud: ?*anyopaque = null;
		fn cb(d: u64, t: u64, ud: ?*anyopaque) callconv(.c) void {
			done = d;
			total = t;
			seen_ud = ud;
			calls += 1;
		}
	};
	var marker: u8 = 7;
	const ctx = ProgressContext{ .callback = Captured.cb, .user_data = &marker };
	ctx.report(30, 90);
	try std.testing.expectEqual(@as(u32, 1), Captured.calls);
	try std.testing.expectEqual(@as(u64, 30), Captured.done);
	try std.testing.expectEqual(@as(u64, 90), Captured.total);
	try std.testing.expectEqual(@as(?*anyopaque, &marker), Captured.seen_ud);
}
