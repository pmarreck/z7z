//! Pure adapter for bzip2z commit 6113a10a9073c4076a5be5409868b1c868192b38.
//! Uses the dependency's exported library module to share downstream identity.
const std = @import("std");
const bzip2 = @import("bzip2z").bzip2;

pub const default_decoder_memory_limit: usize = 128 * 1024 * 1024;

pub const Options = struct {
	expected_size: u64,
	max_output: u64 = std.math.maxInt(u64),
	/// Explicit total heap cap. Null adds retained output to the decoder budget.
	memory_limit: ?usize = null,
	expected_crc32: ?u32 = null,
};

pub const Stats = struct {
	input_consumed: usize,
	output_size: u64,
	crc32: u32,
	peak_memory: usize,
};

pub fn decodeToSink(allocator: std.mem.Allocator, input: []const u8, options: Options, sink: anytype) anyerror!Stats {
	if (options.expected_size > options.max_output) return error.ResourceLimitExceeded;
	var budget = Budget{ .backing = allocator, .limit = options.memory_limit orelse default_decoder_memory_limit };
	const bounded = budget.allocator();
	const decoder = bounded.create(bzip2.Decompressor) catch return budget.failure();
	defer bounded.destroy(decoder);
	decoder.* = bzip2.Decompressor.init(bounded) catch return budget.failure();
	defer decoder.deinit();
	var reader = SliceReader{ .bytes = input };
	var writer = CheckedWriter(@TypeOf(sink)){ .sink = sink, .options = options };
	decoder.decompress(&reader, &writer) catch |err| {
		if (writer.failure) |downstream| return downstream;
		if (err == error.OutOfMemory) return budget.failure();
		return err;
	};
	if (reader.pos != input.len or !hasExactFooter(input, decoder.stream_crc)) return error.TrailingData;
	if (writer.count != options.expected_size) return error.OutputSizeMismatch;
	const crc = writer.crc.final();
	if (options.expected_crc32) |expected| if (crc != expected) return error.ChecksumMismatch;
	return .{ .input_consumed = reader.pos, .output_size = writer.count, .crc32 = crc, .peak_memory = budget.peak };
}

/// Caller frees the returned slice with allocator. The budget includes this slice.
pub fn decode(allocator: std.mem.Allocator, input: []const u8, options: Options) anyerror![]u8 {
	if (options.expected_size > options.max_output) return error.ResourceLimitExceeded;
	const size = std.math.cast(usize, options.expected_size) orelse return error.ResourceLimitExceeded;
	const memory_limit = options.memory_limit orelse (std.math.add(usize, size, default_decoder_memory_limit) catch return error.ResourceLimitExceeded);
	if (size > memory_limit) return error.ResourceLimitExceeded;
	const output = try allocator.alloc(u8, size);
	errdefer allocator.free(output);
	var sink = RetainedSink{ .buffer = output };
	var bounded_options = options;
	bounded_options.memory_limit = memory_limit - size;
	_ = try decodeToSink(allocator, input, bounded_options, &sink);
	return output;
}

const RetainedSink = struct {
	buffer: []u8,
	pos: usize = 0,
	pub fn write(self: *@This(), bytes: []const u8) error{OutputSizeMismatch}!void {
		if (bytes.len > self.buffer.len - self.pos) return error.OutputSizeMismatch;
		@memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
		self.pos += bytes.len;
	}
};

const SliceReader = struct {
	bytes: []const u8,
	pos: usize = 0,
	pub fn read(self: *@This(), buffer: []u8) error{}!usize {
		const n = @min(buffer.len, self.bytes.len - self.pos);
		@memcpy(buffer[0..n], self.bytes[self.pos..][0..n]);
		self.pos += n;
		return n;
	}
};

// Upstream ignores short counts and collapses writer errors to CorruptData.
// A void-returning sink and a saved error preserve the caller's contract.
fn CheckedWriter(comptime Sink: type) type {
	return struct {
		sink: Sink,
		options: Options,
		count: u64 = 0,
		crc: std.hash.Crc32 = .init(),
		failure: ?anyerror = null,
		pub fn write(self: *@This(), bytes: []const u8) anyerror!usize {
			self.writeAll(bytes) catch |err| {
				self.failure = err;
				return err;
			};
			return bytes.len;
		}
		fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
			if (bytes.len > self.options.max_output - self.count) return error.ResourceLimitExceeded;
			if (bytes.len > self.options.expected_size - self.count) return error.OutputSizeMismatch;
			const accepted: void = try self.sink.write(bytes);
			_ = accepted;
			self.crc.update(bytes);
			self.count += bytes.len;
		}
	};
}

// Upstream treats EOF within a following 4-byte header as successful completion.
// Require its verified final footer to end exactly at the supplied byte boundary.
// Unused bits in that final byte may be nonzero in a 7z packed stream.
fn hasExactFooter(input: []const u8, stream_crc: u32) bool {
	if (input.len < 10) return false;
	var tail: u128 = 0;
	for (input[input.len - @min(input.len, 11) ..]) |byte| tail = (tail << 8) | byte;
	const expected = (@as(u128, bzip2.FOOTER_MAGIC) << 32) | stream_crc;
	const mask = (@as(u128, 1) << 80) - 1;
	for (0..8) |padding| {
		const shift: u7 = @intCast(padding);
		if (((tail >> shift) & mask) == expected) return true;
	}
	return false;
}

/// Limits live requested heap bytes, including realloc's temporary old/new pair.
/// Allocator metadata, caller input, and downstream allocations are excluded.
const Budget = struct {
	backing: std.mem.Allocator,
	limit: usize,
	live: usize = 0,
	peak: usize = 0,
	denied: bool = false,
	fn allocator(self: *@This()) std.mem.Allocator {
		return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = std.mem.Allocator.noRemap, .free = free } };
	}
	fn failure(self: *@This()) anyerror {
		return if (self.denied) error.ResourceLimitExceeded else error.OutOfMemory;
	}
	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
		const self: *@This() = @ptrCast(@alignCast(ctx));
		self.denied = len > self.limit - self.live;
		if (self.denied) return null;
		const result = self.backing.rawAlloc(len, alignment, ret) orelse return null;
		self.live += len;
		self.peak = @max(self.peak, self.live);
		return result;
	}
	fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
		const self: *@This() = @ptrCast(@alignCast(ctx));
		self.denied = len > self.limit - (self.live - bytes.len);
		if (self.denied) return false;
		if (!self.backing.rawResize(bytes, alignment, len, ret)) return false;
		self.live = self.live - bytes.len + len;
		self.peak = @max(self.peak, self.live);
		return true;
	}
	fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
		const self: *@This() = @ptrCast(@alignCast(ctx));
		self.backing.rawFree(bytes, alignment, ret);
		self.live -= bytes.len;
	}
};

const small = @embedFile("fixtures/bzip2/small.bz2");
const small_plain = "BZip2 from independent 7-Zip 26.03.\nBinary: \x00\x01\x7f\xff\n";

const TestSink = struct {
	count: usize = 0,
	calls: usize = 0,
	failure: ?anyerror = null,
	pub fn write(self: *@This(), bytes: []const u8) anyerror!void {
		self.calls += 1;
		if (self.failure) |err| return err;
		self.count += bytes.len;
	}
};

test "bzip2 adapter retained independent 7z payload" {
	const output = try decode(std.testing.allocator, small, .{ .expected_size = small_plain.len });
	defer std.testing.allocator.free(output);
	try std.testing.expectEqualSlices(u8, small_plain, output);
}

test "bzip2 adapter sink exact size input and CRC" {
	var sink = TestSink{};
	const result = try decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len, .expected_crc32 = 0x34E73C90 }, &sink);
	try std.testing.expectEqual(small.len, result.input_consumed);
	try std.testing.expectEqual(small_plain.len, result.output_size);
	try std.testing.expectEqual(std.hash.Crc32.hash(small_plain), result.crc32);
	try std.testing.expectEqual(small_plain.len, sink.count);
}

test "bzip2 adapter preserves downstream errors" {
	for ([_]anyerror{ error.OutOfMemory, error.ResourceLimitExceeded, error.ChecksumError, error.StructuralError, error.CustomSinkFailure }) |err| {
		var sink = TestSink{ .failure = err };
		try std.testing.expectError(err, decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len }, &sink));
		try std.testing.expectEqual(1, sink.calls);
	}
}

test "bzip2 adapter enforces size and output limit before sink" {
	var sink = TestSink{};
	try std.testing.expectError(error.ResourceLimitExceeded, decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len, .max_output = 1 }, &sink));
	try std.testing.expectError(error.OutputSizeMismatch, decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len - 1 }, &sink));
	try std.testing.expectEqual(0, sink.calls);
	try std.testing.expectError(error.OutputSizeMismatch, decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len + 1 }, &sink));
}

test "bzip2 adapter rejects incomplete trailing headers and truncations" {
	for (1..4) |n| {
		var extra: [small.len + 3]u8 = undefined;
		@memcpy(extra[0..small.len], small);
		@memset(extra[small.len..], 'B');
		var sink = TestSink{};
		try std.testing.expectError(error.TrailingData, decodeToSink(std.testing.allocator, extra[0 .. small.len + n], .{ .expected_size = small_plain.len }, &sink));
	}
	for (0..small.len) |n| {
		var sink = TestSink{};
		if (decodeToSink(std.testing.allocator, small[0..n], .{ .expected_size = small_plain.len }, &sink)) |_| return error.AcceptedTruncation else |_| {}
	}
}

test "bzip2 adapter verifies CRC independently" {
	var sink = TestSink{};
	try std.testing.expectError(error.ChecksumMismatch, decodeToSink(std.testing.allocator, small, .{ .expected_size = small_plain.len, .expected_crc32 = 0 }, &sink));
	var damaged: [small.len]u8 = small.*;
	damaged[10] ^= 1;
	try std.testing.expectError(error.BlockCrcMismatch, decodeToSink(std.testing.allocator, &damaged, .{ .expected_size = small_plain.len }, &sink));
}

test "bzip2 adapter accepts oracle 7z nonzero padding but rejects trailing bytes" {
	// 7-Zip 26.03 t and x -so accept these last-packed-byte mutations inside
	// the provenance .7z archives with unchanged output; adjacent CRC bits fail.
	const cases = .{
		.{ @embedFile("fixtures/bzip2/rle-expansion.bz2"), 1_200_000, @as(u32, 0x69DFAE60), &[_]u8{ 1, 2, 4, 8, 16, 32, 63 } },
		.{ @embedFile("fixtures/bzip2/filter-swap4.bz2"), 1031, @as(u32, 0x256881DA), &[_]u8{ 1, 2, 4, 8, 15 } },
	};
	inline for (cases) |case| {
		const compressed = case[0];
		const options = Options{ .expected_size = case[1], .expected_crc32 = case[2] };
		const expected = try decode(std.testing.allocator, compressed, options);
		defer std.testing.allocator.free(expected);
		for (case[3]) |mask| {
			var mutated: [compressed.len + 3]u8 = undefined;
			@memcpy(mutated[0..compressed.len], compressed);
			mutated[compressed.len - 1] ^= mask;
			const output = try decode(std.testing.allocator, mutated[0..compressed.len], options);
			defer std.testing.allocator.free(output);
			try std.testing.expectEqualSlices(u8, expected, output);
			var sink = TestSink{};
			const stats = try decodeToSink(std.testing.allocator, mutated[0..compressed.len], options, &sink);
			try std.testing.expectEqual(compressed.len, stats.input_consumed);
			try std.testing.expectEqual(case[1], stats.output_size);
			try std.testing.expectEqual(case[2], stats.crc32);
			@memset(mutated[compressed.len..], 0);
			for (1..4) |extra| {
				try std.testing.expectError(error.TrailingData, decodeToSink(std.testing.allocator, mutated[0 .. compressed.len + extra], options, &sink));
			}
		}
	}
}

test "bzip2 adapter permits valid RLE expansion above 900k" {
	const compressed = @embedFile("fixtures/bzip2/rle-expansion.bz2");
	const output = try decode(std.testing.allocator, compressed, .{ .expected_size = 1_200_000, .expected_crc32 = 0x69DFAE60 });
	defer std.testing.allocator.free(output);
	try std.testing.expectEqual(1_200_000, output.len);
	try std.testing.expect(std.mem.allEqual(u8, output, 'A'));
}

test "bzip2 adapter memory budget stops expansion before sink" {
	var sink = TestSink{};
	try std.testing.expectError(error.ResourceLimitExceeded, decodeToSink(std.testing.allocator, @embedFile("fixtures/bzip2/rle-expansion.bz2"), .{ .expected_size = 1_200_000, .memory_limit = 6_000_000 }, &sink));
	try std.testing.expectEqual(0, sink.calls);
}

test "bzip2 adapter independent multiblock payload" {
	const compressed = @embedFile("fixtures/bzip2/multiblock.bz2");
	const output = try decode(std.testing.allocator, compressed, .{ .expected_size = 210_000, .expected_crc32 = 0xA05D9824 });
	defer std.testing.allocator.free(output);
	for (output, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @intCast(i % 251)), byte);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
	const output = try decode(allocator, small, .{ .expected_size = small_plain.len });
	defer allocator.free(output);
	try std.testing.expectEqualSlices(u8, small_plain, output);
}

test "bzip2 adapter allocation failures release all ownership" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "bzip2 adapter retained default permits declared output above decoder budget" {
	var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
	try std.testing.expectError(error.OutOfMemory, decode(failing.allocator(), small, .{ .expected_size = 128 * 1024 * 1024 + 1 }));
}

test "bzip2 adapter retained default total budget uses checked arithmetic" {
	var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
	try std.testing.expectError(error.ResourceLimitExceeded, decode(failing.allocator(), small, .{ .expected_size = std.math.maxInt(usize) }));
	try std.testing.expect(!failing.has_induced_failure);
}

test "bzip2 adapter explicit retained total budget is preserved" {
	var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
	try std.testing.expectError(error.ResourceLimitExceeded, decode(failing.allocator(), small, .{ .expected_size = small_plain.len, .memory_limit = small_plain.len - 1 }));
	try std.testing.expect(!failing.has_induced_failure);
}

fn allocationExpansionCase(allocator: std.mem.Allocator) !void {
	var sink = TestSink{};
	_ = try decodeToSink(allocator, @embedFile("fixtures/bzip2/rle-expansion.bz2"), .{ .expected_size = 1_200_000 }, &sink);
	try std.testing.expectEqual(1_200_000, sink.count);
}

test "bzip2 adapter expansion allocation failures release all ownership" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExpansionCase, .{});
}

test "bzip2 adapter multiblock sink budget and emission count" {
	var sink = TestSink{};
	const stats = try decodeToSink(std.testing.allocator, @embedFile("fixtures/bzip2/multiblock.bz2"), .{ .expected_size = 210_000, .memory_limit = 6_000_000, .expected_crc32 = 0xA05D9824 }, &sink);
	try std.testing.expectEqual(3, sink.calls);
	try std.testing.expectEqual(210_000, sink.count);
	try std.testing.expect(stats.peak_memory <= 6_000_000);
}

test "bzip2 adapter single-bit corruption cannot silently alter output" {
	for (0..small.len * 8) |bit| {
		var damaged: [small.len]u8 = small.*;
		damaged[bit / 8] ^= @as(u8, 1) << @as(u3, @intCast(bit % 8));
		const output = decode(std.testing.allocator, &damaged, .{ .expected_size = small_plain.len }) catch continue;
		defer std.testing.allocator.free(output);
		try std.testing.expectEqualSlices(u8, small_plain, output);
	}
}
