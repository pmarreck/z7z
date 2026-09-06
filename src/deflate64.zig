//! Allocator-owned raw Deflate64 decoder (7z method 04 01 09).
//! Input is borrowed until deinit. Properties must be empty. State and the
//! 64 KiB history occupy one fixed-size heap allocation; reads never allocate.
//! Reaching expected_size validates the final block and rejects trailing bytes.
//! Unused bits in the final byte are padding. A failed decoder cannot be reused.
const std = @import("std");
pub const Error = error{ DecompressFailed, OutOfMemory };
pub const window_size = 65536;

const Bits = struct {
	data: []const u8,
	pos: usize = 0,
	value: u32 = 0,
	count: u5 = 0,

	fn take(self: *Bits, n: u5) Error!u32 {
		while (self.count < n) {
			if (self.pos == self.data.len) return error.DecompressFailed;
			self.value |= @as(u32, self.data[self.pos]) << self.count;
			self.pos += 1;
			self.count += 8;
		}
		const result = self.value & ((@as(u32, 1) << n) - 1);
		self.value >>= n;
		self.count -= n;
		return result;
	}

	fn byteAlign(self: *Bits) void {
		self.value = 0;
		self.count = 0;
	}
};

const Huffman = struct {
	counts: [16]u16 = @splat(0),
	symbols: [288]u16 = undefined,
	const Kind = enum { codes, literal, distance };

	fn build(self: *Huffman, lengths: []const u8, kind: Kind) Error!void {
		self.counts = @splat(0);
		var used: usize = 0;
		for (lengths) |len| {
			if (len > 15) return error.DecompressFailed;
			if (len != 0) {
				self.counts[len] += 1;
				used += 1;
			}
		}
		if (used == 0) {
			if (kind == .distance) return;
			return error.DecompressFailed;
		}
		var available: i32 = 1;
		for (1..16) |len| {
			available = available * 2 - self.counts[len];
			if (available < 0) return error.DecompressFailed;
		}
		// A single one-bit literal/distance code is the permitted incomplete tree.
		if (available != 0 and !(kind != .codes and used == 1 and self.counts[1] == 1))
			return error.DecompressFailed;
		var offsets: [16]u16 = @splat(0);
		for (1..15) |len| offsets[len + 1] = offsets[len] + self.counts[len];
		for (lengths, 0..) |len, value| {
			if (len == 0) continue;
			self.symbols[offsets[len]] = @intCast(value);
			offsets[len] += 1;
		}
	}

	fn symbol(self: *const Huffman, bits: *Bits) Error!u16 {
		var code: u32 = 0;
		var first: u32 = 0;
		var offset: usize = 0;
		for (1..16) |len| {
			code = (code << 1) | try bits.take(1);
			const count = self.counts[len];
			if (code >= first and code - first < count)
				return self.symbols[offset + code - first];
			offset += count;
			first = (first + count) << 1;
		}
		return error.DecompressFailed;
	}
};

pub const Decoder = struct {
	bits: Bits,
	expected_size: u64,
	total: u64 = 0,
	window: [window_size]u8 = undefined,
	write_pos: usize = 0,
	literals: Huffman = .{},
	distances: Huffman = .{},
	codes: Huffman = .{},
	lengths: [320]u8 = undefined,
	code_lengths: [19]u8 = undefined,
	state: enum { block, stored, compressed, done } = .block,
	last: bool = false,
	failed: bool = false,
	remaining: u32 = 0,
	distance: u32 = 0,

	pub fn create(data: []const u8, expected_size: u64, properties: []const u8, allocator: std.mem.Allocator) Error!*Decoder {
		if (properties.len != 0) return error.DecompressFailed;
		const self = try allocator.create(Decoder);
		errdefer allocator.destroy(self);
		self.* = .{ .bits = .{ .data = data }, .expected_size = expected_size };
		if (expected_size == 0) try self.finish();
		return self;
	}

	pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
		allocator.destroy(self);
	}

	pub fn read(self: *Decoder, output: []u8) Error!usize {
		if (self.failed) return error.DecompressFailed;
		errdefer self.failed = true;
		if (output.len == 0) return 0;
		var n: usize = 0;
		while (n < output.len and self.total < self.expected_size) {
			output[n] = (try self.next()) orelse return error.DecompressFailed;
			n += 1;
		}
		if (self.total == self.expected_size) try self.finish();
		return n;
	}

	pub fn readByte(self: *Decoder) (Error || error{EndOfStream})!u8 {
		var byte: [1]u8 = undefined;
		if (try self.read(&byte) == 0) return error.EndOfStream;
		return byte[0];
	}

	fn finish(self: *Decoder) Error!void {
		if (self.total != self.expected_size or try self.next() != null) return error.DecompressFailed;
		if (self.bits.pos != self.bits.data.len) return error.DecompressFailed;
	}

	fn emit(self: *Decoder, byte: u8) Error!u8 {
		if (self.total == self.expected_size) return error.DecompressFailed;
		self.window[self.write_pos] = byte;
		self.write_pos = (self.write_pos + 1) & (window_size - 1);
		self.total += 1;
		return byte;
	}

	fn endBlock(self: *Decoder) void {
		self.state = if (self.last) .done else .block;
	}

	fn next(self: *Decoder) Error!?u8 {
		while (true) switch (self.state) {
			.done => return null,
			.block => {
				self.last = try self.bits.take(1) != 0;
				switch (try self.bits.take(2)) {
					0 => {
						self.bits.byteAlign();
						const len = try self.bits.take(16);
						if (len ^ try self.bits.take(16) != 65535) return error.DecompressFailed;
						if (len > self.expected_size - self.total) return error.DecompressFailed;
						self.remaining = len;
						self.state = .stored;
					},
					1 => {
						@memset(self.lengths[0..144], 8);
						@memset(self.lengths[144..256], 9);
						@memset(self.lengths[256..280], 7);
						@memset(self.lengths[280..288], 8);
						try self.literals.build(self.lengths[0..288], .literal);
						@memset(self.lengths[0..32], 5);
						try self.distances.build(self.lengths[0..32], .distance);
						self.state = .compressed;
					},
					2 => {
						try self.dynamic();
						self.state = .compressed;
					},
					else => return error.DecompressFailed,
				}
			},
			.stored => {
				if (self.remaining == 0) {
					self.endBlock();
					continue;
				}
				self.remaining -= 1;
				return try self.emit(@intCast(try self.bits.take(8)));
			},
			.compressed => {
				if (self.remaining != 0) {
					const from = (self.write_pos + window_size - self.distance) & (window_size - 1);
					self.remaining -= 1;
					return try self.emit(self.window[from]);
				}
				const symbol = try self.literals.symbol(&self.bits);
				if (symbol < 256) return try self.emit(@intCast(symbol));
				if (symbol == 256) {
					self.endBlock();
					continue;
				}
				if (symbol > 285) return error.DecompressFailed;
				const index = symbol - 257;
				const len = length_base[index] + try self.bits.take(length_extra[index]);
				const dist_symbol = try self.distances.symbol(&self.bits);
				if (dist_symbol >= 32) return error.DecompressFailed;
				const dist = distance_base[dist_symbol] + try self.bits.take(distance_extra[dist_symbol]);
				if (dist > self.total or dist > window_size or len > self.expected_size - self.total)
					return error.DecompressFailed;
				self.distance = dist;
				self.remaining = len;
			},
		};
	}

	fn dynamic(self: *Decoder) Error!void {
		const literal_count = 257 + try self.bits.take(5);
		const distance_count = 1 + try self.bits.take(5);
		const code_count = 4 + try self.bits.take(4);
		if (literal_count > 286) return error.DecompressFailed;
		self.code_lengths = @splat(0);
		for (code_order[0..code_count]) |index| self.code_lengths[index] = @intCast(try self.bits.take(3));
		try self.codes.build(&self.code_lengths, .codes);
		const count = literal_count + distance_count;
		var i: usize = 0;
		while (i < count) {
			const symbol = try self.codes.symbol(&self.bits);
			if (symbol < 16) {
				self.lengths[i] = @intCast(symbol);
				i += 1;
				continue;
			}
			var value: u8 = 0;
			const repeat = switch (symbol) {
				16 => repeat: {
					if (i == 0) return error.DecompressFailed;
					value = self.lengths[i - 1];
					break :repeat 3 + try self.bits.take(2);
				},
				17 => 3 + try self.bits.take(3),
				18 => 11 + try self.bits.take(7),
				else => return error.DecompressFailed,
			};
			if (repeat > count - i) return error.DecompressFailed;
			@memset(self.lengths[i..][0..repeat], value);
			i += repeat;
		}
		if (self.lengths[256] == 0) return error.DecompressFailed;
		try self.literals.build(self.lengths[0..literal_count], .literal);
		try self.distances.build(self.lengths[literal_count..count], .distance);
	}
};

const code_order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
const length_base = [_]u32{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 3 };
const length_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 16 };
const distance_base = [_]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153 };
const distance_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14 };

fn checkFixture(comptime name: []const u8, chunk: usize) !void {
	const data = @embedFile("fixtures/deflate64/" ++ name ++ ".raw");
	const plain = @embedFile("fixtures/deflate64/" ++ name ++ ".plain");
	const decoder = try Decoder.create(data, plain.len, "", std.testing.allocator);
	defer decoder.deinit(std.testing.allocator);
	const buffer = try std.testing.allocator.alloc(u8, chunk);
	defer std.testing.allocator.free(buffer);
	var offset: usize = 0;
	while (true) {
		const n = try decoder.read(buffer);
		if (n == 0) break;
		try std.testing.expect(n <= chunk);
		try std.testing.expect(offset + n <= plain.len);
		try std.testing.expectEqualSlices(u8, plain[offset..][0..n], buffer[0..n]);
		offset += n;
	}
	try std.testing.expectEqual(plain.len, offset);
	try std.testing.expectError(error.EndOfStream, decoder.readByte());
}

test "Deflate64 oracle stored fixed dynamic and long history" {
	inline for (.{ "stored", "fixed", "dynamic", "history49152", "length285" }) |name| {
		try checkFixture(name, 997);
		try checkFixture(name, 1);
	}
}

test "Deflate64 extended code285 and maximum distance oracle vectors" {
	inline for (.{ "extended-0", "extended-255", "extended-65535", "distance65536" }) |name| {
		try checkFixture(name, 113);
	}
}

test "Deflate64 empty stored and fixed blocks" {
	for ([_][]const u8{ &.{ 1, 0, 0, 255, 255 }, &.{ 3, 0 } }) |data| {
		const decoder = try Decoder.create(data, 0, "", std.testing.allocator);
		defer decoder.deinit(std.testing.allocator);
		try std.testing.expectError(error.EndOfStream, decoder.readByte());
	}
}

test "Deflate64 exact output size and trailing data" {
	const data = @embedFile("fixtures/deflate64/fixed.raw");
	const plain = @embedFile("fixtures/deflate64/fixed.plain");
	for ([_]u64{ 0, plain.len - 1, plain.len + 1 }) |size| {
		try expectInvalid(data, size);
	}
	try expectInvalid(data ++ "\x00", plain.len);
	try expectInvalid(data ++ data, plain.len);
}

fn expectInvalid(data: []const u8, size: u64) !void {
	const decoder = Decoder.create(data, size, "", std.testing.allocator) catch |err| {
		try std.testing.expectEqual(error.DecompressFailed, err);
		return;
	};
	defer decoder.deinit(std.testing.allocator);
	var buffer: [8192]u8 = undefined;
	while (true) {
		const n = decoder.read(&buffer) catch |err| {
			try std.testing.expectEqual(error.DecompressFailed, err);
			return;
		};
		if (n == 0) return error.TestExpectedError;
	}
}

test "Deflate64 rejects every truncated prefix of short oracle fixtures" {
	inline for (.{ "fixed", "dynamic", "extended-65535" }) |name| {
		const data = @embedFile("fixtures/deflate64/" ++ name ++ ".raw");
		const plain = @embedFile("fixtures/deflate64/" ++ name ++ ".plain");
		for (0..data.len) |n| try expectInvalid(data[0..n], plain.len);
	}
}

test "Deflate64 rejects properties and invalid stored blocks" {
	try std.testing.expectError(error.DecompressFailed, Decoder.create(&.{ 3, 0 }, 0, "x", std.testing.allocator));
	try expectInvalid(&.{7}, 0);
	try expectInvalid(&.{ 1, 1, 0, 255, 255, 65 }, 1);
	try expectInvalid(&.{ 1, 1, 0, 254, 255 }, 1);
}

const TestBits = struct {
	bytes: [1024]u8 = @splat(0),
	count: usize = 0,

	fn put(self: *TestBits, value: u32, width: u5) void {
		for (0..width) |i| {
			self.bytes[self.count / 8] |= @as(u8, @intCast((value >> @intCast(i)) & 1)) << @intCast(self.count % 8);
			self.count += 1;
		}
	}

	fn code(self: *TestBits, value: u32, width: u5) void {
		var i = width;
		while (i != 0) {
			i -= 1;
			self.put((value >> i) & 1, 1);
		}
	}

	fn literal(self: *TestBits, value: u16) void {
		if (value < 144) self.code(0x30 + @as(u32, value), 8) else if (value < 256) self.code(0x190 + @as(u32, value) - 144, 9) else if (value < 280) self.code(value - 256, 7) else self.code(0xc0 + @as(u32, value) - 280, 8);
	}

	fn data(self: *const TestBits) []const u8 {
		return self.bytes[0 .. (self.count + 7) / 8];
	}

	// Explicit code-length alphabet: 0 -> 0, 1 -> 10, 2 -> 11.
	fn dynamic(self: *TestBits, literals: []const u8, distances: []const u8) void {
		self.put(5, 3);
		self.put(@intCast(literals.len - 257), 5);
		self.put(@intCast(distances.len - 1), 5);
		self.put(14, 4);
		for ([_]u8{ 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2 }) |len| self.put(len, 3);
		for ([_][]const u8{ literals, distances }) |lengths| {
			for (lengths) |len| switch (len) {
				0 => self.put(0, 1),
				1 => self.code(2, 2),
				2 => self.code(3, 2),
				else => unreachable,
			};
		}
	}
};

test "Deflate64 rejects missing history and reserved literals" {
	for ([_]u16{ 257, 286, 287 }) |literal| {
		var bits: TestBits = .{};
		bits.put(3, 3);
		bits.literal(literal);
		bits.code(0, 5);
		bits.literal(256);
		try expectInvalid(bits.data(), 3);
	}
	var bits: TestBits = .{};
	bits.put(3, 3);
	bits.literal(65);
	bits.literal(257);
	bits.code(1, 5); // Distance two with only one byte of history.
	bits.literal(256);
	try expectInvalid(bits.data(), 4);
}

test "Deflate64 rejects oversubscribed incomplete and EOB-less dynamic trees" {
	const bad_literals = [_][257]u8{
		lit: {
			var lens: [257]u8 = @splat(0);
			lens[65] = 1;
			break :lit lens;
		},
		lit: {
			var lens: [257]u8 = @splat(0);
			lens[65] = 1;
			lens[66] = 1;
			lens[256] = 1;
			break :lit lens;
		},
		lit: {
			var lens: [257]u8 = @splat(0);
			lens[65] = 2;
			lens[256] = 2;
			break :lit lens;
		},
	};
	for (bad_literals) |lens| {
		var bits: TestBits = .{};
		bits.dynamic(&lens, &.{0});
		try expectInvalid(bits.data(), 1);
	}
	var lens: [257]u8 = @splat(0);
	lens[256] = 1;
	for ([_][]const u8{ &.{ 1, 1, 1 }, &.{2}, &.{ 2, 2 } }) |distances| {
		var bits: TestBits = .{};
		bits.dynamic(&lens, distances);
		bits.put(0, 1);
		try expectInvalid(bits.data(), 0);
	}
}

test "Deflate64 permits single-symbol EOB and empty or single-symbol distance trees" {
	var lens: [257]u8 = @splat(0);
	lens[256] = 1;
	for ([_][]const u8{ &.{0}, &.{1} }) |distances| {
		var bits: TestBits = .{};
		bits.dynamic(&lens, distances);
		bits.put(0, 1);
		const decoder = try Decoder.create(bits.data(), 0, "", std.testing.allocator);
		defer decoder.deinit(std.testing.allocator);
		try std.testing.expectError(error.EndOfStream, decoder.readByte());
	}
	lens[65] = 1;
	var bits: TestBits = .{};
	bits.dynamic(&lens, &.{0});
	bits.put(0, 1); // A
	bits.put(1, 1); // EOB
	const decoder = try Decoder.create(bits.data(), 1, "", std.testing.allocator);
	defer decoder.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(u8, 65), try decoder.readByte());
	try std.testing.expectError(error.EndOfStream, decoder.readByte());
}

test "Deflate64 rejects bad code-length alphabets and repeat overruns" {
	for ([_][4]u8{ .{ 1, 1, 1, 1 }, .{ 2, 0, 0, 0 }, .{ 0, 0, 0, 0 } }) |lengths| {
		var bits: TestBits = .{};
		bits.put(5, 3);
		bits.put(0, 5);
		bits.put(0, 5);
		bits.put(0, 4);
		for (lengths) |len| bits.put(len, 3);
		try expectInvalid(bits.data(), 0);
	}
	var previous: TestBits = .{};
	previous.put(5, 3);
	previous.put(0, 5);
	previous.put(0, 5);
	previous.put(0, 4);
	for ([_]u8{ 1, 0, 0, 1 }) |len| previous.put(len, 3);
	previous.put(1, 1); // Repeat previous (16) before any previous length exists.
	previous.put(0, 2);
	try expectInvalid(previous.data(), 0);
	var overrun: TestBits = .{};
	overrun.put(5, 3);
	overrun.put(0, 5);
	overrun.put(0, 5);
	overrun.put(0, 4);
	for ([_]u8{ 0, 0, 1, 1 }) |len| overrun.put(len, 3);
	overrun.put(1, 1);
	overrun.put(127, 7);
	overrun.put(1, 1);
	overrun.put(127, 7); // 276 lengths for a 258-entry header.
	try expectInvalid(overrun.data(), 0);
	for ([_]u32{ 30, 31 }) |hlit| {
		var bits: TestBits = .{};
		bits.put(5, 3);
		bits.put(hlit, 5);
		bits.put(0, 5);
		bits.put(0, 4);
		try expectInvalid(bits.data(), 0);
	}
}

test "Deflate64 zero reads do not consume input and errors remain errors" {
	const decoder = try Decoder.create(@embedFile("fixtures/deflate64/fixed.raw"), 17, "", std.testing.allocator);
	defer decoder.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(usize, 0), try decoder.read(&.{}));
	for (@embedFile("fixtures/deflate64/fixed.plain")) |byte| try std.testing.expectEqual(byte, try decoder.readByte());
	const bad = try Decoder.create(&.{7}, 1, "", std.testing.allocator);
	defer bad.deinit(std.testing.allocator);
	try std.testing.expectError(error.DecompressFailed, bad.readByte());
	try std.testing.expectError(error.DecompressFailed, bad.readByte());
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
	const decoder = try Decoder.create(@embedFile("fixtures/deflate64/history49152.raw"), 98304, "", allocator);
	defer decoder.deinit(allocator);
	var bytes: [997]u8 = undefined;
	var size: usize = 0;
	while (true) {
		const n = try decoder.read(&bytes);
		if (n == 0) break;
		size += n;
	}
	try std.testing.expectEqual(@as(usize, 98304), size);
}

fn invalidEmptyAllocationScenario(allocator: std.mem.Allocator) !void {
	const decoder = Decoder.create(&.{7}, 0, "", allocator) catch |err| switch (err) {
		error.OutOfMemory => return err,
		error.DecompressFailed => return,
	};
	decoder.deinit(allocator);
	return error.TestExpectedError;
}

test "Deflate64 allocation failures and fixed memory cap" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
	try std.testing.checkAllAllocationFailures(std.testing.allocator, invalidEmptyAllocationScenario, .{});
	try std.testing.expect(@sizeOf(Decoder) < 70 * 1024);
	const memory = try std.testing.allocator.alloc(u8, 70 * 1024);
	defer std.testing.allocator.free(memory);
	var fixed = std.heap.FixedBufferAllocator.init(memory);
	try allocationScenario(fixed.allocator());
	const decoder = try Decoder.create(&.{ 3, 0 }, std.math.maxInt(u64), "", fixed.allocator());
	defer decoder.deinit(fixed.allocator());
	try std.testing.expectError(error.DecompressFailed, decoder.readByte());
}

test "Deflate64 final padding and empty following blocks" {
	// EOB ends at bit 10. The other six bits need not be zero.
	for ([_][]const u8{ &.{ 3, 252 }, &.{ 2, 12, 0 } }) |data| {
		const decoder = try Decoder.create(data, 0, "", std.testing.allocator);
		defer decoder.deinit(std.testing.allocator);
		try std.testing.expectError(error.EndOfStream, decoder.readByte());
	}
	try expectInvalid(&.{ 2, 0 }, 0); // Nonfinal empty fixed block without next block.
	var bits: TestBits = .{};
	bits.put(2, 3);
	bits.literal(65);
	bits.literal(256);
	bits.put(1, 3);
	while (bits.count % 8 != 0) bits.put(0, 1);
	bits.put(0, 16);
	bits.put(65535, 16);
	const decoder = try Decoder.create(bits.data(), 1, "", std.testing.allocator);
	defer decoder.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(u8, 65), try decoder.readByte());
	try std.testing.expectError(error.EndOfStream, decoder.readByte());
	try expectInvalid(bits.data()[0 .. bits.data().len - 1], 1);
}

test "Deflate64 exact-sized reads validate EOB immediately and do not overwrite tail" {
	const data = @embedFile("fixtures/deflate64/fixed.raw");
	const decoder = try Decoder.create(data, 17, "", std.testing.allocator);
	defer decoder.deinit(std.testing.allocator);
	var buffer: [64]u8 = @splat(0xaa);
	try std.testing.expectEqual(@as(usize, 17), try decoder.read(&buffer));
	try std.testing.expectEqualSlices(u8, @embedFile("fixtures/deflate64/fixed.plain"), buffer[0..17]);
	try std.testing.expectEqualSlices(u8, &(@as([47]u8, @splat(0xaa))), buffer[17..]);
	const bad = try Decoder.create(data ++ "\x00", 17, "", std.testing.allocator);
	defer bad.deinit(std.testing.allocator);
	try std.testing.expectError(error.DecompressFailed, bad.read(buffer[0..17]));
	const truncated = try Decoder.create(data[0 .. data.len - 1], 17, "", std.testing.allocator);
	defer truncated.deinit(std.testing.allocator);
	try std.testing.expectError(error.DecompressFailed, truncated.read(buffer[0..17]));
}
