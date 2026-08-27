//! Bounded random-access input for archive verification.

const std = @import("std");

pub const RangeReadError = error{ReadFailed};

pub const Error = RangeReadError || error{
    TruncatedInput,
    OutOfMemory,
};

pub const RangeSource = struct {
    /// Opaque caller-owned context. It must outlive the synchronous operation.
    ptr: *anyopaque,
    /// Total readable length, used to reject range arithmetic overflow up front.
    len: u64,
    /// Read at `offset`. Short reads are allowed; zero before the declared end is truncation.
    readFn: *const fn (*anyopaque, u64, []u8) RangeReadError!usize,
    /// Optional zero-copy range. Returned bytes must remain valid through the operation.
    borrowFn: ?*const fn (*anyopaque, u64, usize) ?[]const u8 = null,

    pub const Data = struct {
        bytes: []const u8,
        owned: bool,

        pub fn deinit(self: Data, allocator: std.mem.Allocator) void {
            if (self.owned) allocator.free(self.bytes);
        }
    };

    pub fn readExact(self: RangeSource, offset: u64, dest: []u8) Error!void {
        const end = std.math.add(u64, offset, dest.len) catch return error.TruncatedInput;
        if (end > self.len) return error.TruncatedInput;

        var filled: usize = 0;
        while (filled < dest.len) {
            const read_offset = std.math.add(u64, offset, filled) catch return error.TruncatedInput;
            const n = try self.readFn(self.ptr, read_offset, dest[filled..]);
            if (n == 0) return error.TruncatedInput;
            if (n > dest.len - filled) return error.ReadFailed;
            filled += n;
        }
    }

    pub fn readRange(self: RangeSource, offset: u64, len: u64, allocator: std.mem.Allocator) Error!Data {
        const end = std.math.add(u64, offset, len) catch return error.TruncatedInput;
        if (end > self.len) return error.TruncatedInput;
        if (len > std.math.maxInt(usize)) return error.OutOfMemory;
        const native_len: usize = @intCast(len);
        if (self.borrowFn) |borrowFn| {
            if (borrowFn(self.ptr, offset, native_len)) |borrowed| {
                if (borrowed.len != native_len) return error.ReadFailed;
                return .{ .bytes = borrowed, .owned = false };
            }
        }

        const result = allocator.alloc(u8, native_len) catch return error.OutOfMemory;
        errdefer allocator.free(result);
        try self.readExact(offset, result);
        return .{ .bytes = result, .owned = true };
    }
};

pub const SliceSource = struct {
    data: []const u8,

    pub fn source(self: *SliceSource) RangeSource {
        return .{
            .ptr = self,
            .len = self.data.len,
            .readFn = readAt,
            .borrowFn = borrow,
        };
    }

    fn readAt(ctx: *anyopaque, offset: u64, dest: []u8) RangeReadError!usize {
        const self: *SliceSource = @ptrCast(@alignCast(ctx));
        if (offset >= self.data.len or dest.len == 0) return 0;
        const start: usize = @intCast(offset);
        const len = @min(dest.len, self.data.len - start);
        @memcpy(dest[0..len], self.data[start .. start + len]);
        return len;
    }

    fn borrow(ctx: *anyopaque, offset: u64, len: usize) ?[]const u8 {
        const self: *SliceSource = @ptrCast(@alignCast(ctx));
        if (offset > std.math.maxInt(usize)) return null;
        const start: usize = @intCast(offset);
        if (start > self.data.len or len > self.data.len - start) return null;
        return self.data[start .. start + len];
    }
};

test "range source rejects overflow, premature EOF, and read failure" {
    const TestSource = struct {
        mode: enum { eof, fail },

        fn readAt(ctx: *anyopaque, offset: u64, dest: []u8) RangeReadError!usize {
            _ = offset;
            _ = dest;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return switch (self.mode) {
                .eof => 0,
                .fail => error.ReadFailed,
            };
        }

        fn source(self: *@This(), len: u64) RangeSource {
            return .{ .ptr = self, .len = len, .readFn = readAt };
        }
    };

    var eof_source = TestSource{ .mode = .eof };
    var byte: [1]u8 = undefined;
    try std.testing.expectError(error.TruncatedInput, eof_source.source(1).readExact(0, &byte));
    try std.testing.expectError(error.TruncatedInput, eof_source.source(std.math.maxInt(u64)).readExact(std.math.maxInt(u64), &byte));

    var failed_source = TestSource{ .mode = .fail };
    try std.testing.expectError(error.ReadFailed, failed_source.source(1).readExact(0, &byte));
}
