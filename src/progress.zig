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
