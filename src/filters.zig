const std = @import("std");

pub fn supports(method_id: []const u8) bool {
	return identify(method_id) != null;
}

const Kind = enum { delta, swap2, swap4, arm, armt, ppc, sparc, arm64, ia64, riscv };
const methods = .{
	.{ "\x03", Kind.delta },
	.{ "\x02\x03\x02", Kind.swap2 },
	.{ "\x02\x03\x04", Kind.swap4 },
	.{ "\x03\x03\x05\x01", Kind.arm },
	.{ "\x03\x03\x07\x01", Kind.armt },
	.{ "\x03\x03\x02\x05", Kind.ppc },
	.{ "\x03\x03\x08\x05", Kind.sparc },
	.{ "\x0a", Kind.arm64 },
	.{ "\x03\x03\x04\x01", Kind.ia64 },
	.{ "\x0b", Kind.riscv },
};

fn identify(method_id: []const u8) ?Kind {
	inline for (methods) |entry| {
		if (std.mem.eql(u8, method_id, entry[0])) return entry[1];
	}
	return null;
}

/// No allocations or I/O. The sink's write(slice) must consume the whole slice
/// or return an error, and must not retain the borrowed slice. Discard this
/// decoder after any sink error. finish preserves an incomplete final unit.
pub const Decoder = struct {
	kind: Kind,
	position: u32 = 0,
	pending: [16]u8 = undefined,
	pending_len: usize = 0,
	history: [256]u8 = @splat(0),
	distance: usize = 1,
	history_pos: usize = 0,
	finished: bool = false,
	failed: bool = false,

	pub fn init(method_id: []const u8, props: []const u8) !Decoder {
		const kind = identify(method_id) orelse return error.UnsupportedMethod;
		var result: Decoder = .{ .kind = kind };
		switch (kind) {
			.delta => {
				if (props.len != 1) return error.InvalidProperties;
				result.distance = @as(usize, props[0]) + 1;
			},
			.arm64, .riscv => {
				if (props.len != 0 and props.len != 4) return error.InvalidProperties;
				if (props.len == 4) result.position = std.mem.readInt(u32, props[0..4], .little);
				const alignment: u32 = if (kind == .arm64) 4 else 2;
				if (result.position % alignment != 0) return error.InvalidProperties;
			},
			else => if (props.len != 0) return error.InvalidProperties,
		}
		return result;
	}

	pub fn write(self: *Decoder, bytes: []const u8, sink: anytype) !void {
		if (self.failed) return error.DecoderFailed;
		if (self.finished) return error.DecoderFinished;
		errdefer self.failed = true;
		const unit: usize = switch (self.kind) {
			.delta => 1,
			.swap2 => 2,
			.ia64 => 16,
			.riscv => 8,
			else => 4,
		};
		for (bytes) |b| {
			self.pending[self.pending_len] = b;
			self.pending_len += 1;
			if (self.pending_len < unit) continue;
			const consumed = self.transform();
			try sink.write(self.pending[0..consumed]);
			self.position +%= @intCast(consumed);
			self.pending_len -= consumed;
			std.mem.copyForwards(u8, self.pending[0..self.pending_len], self.pending[consumed..][0..self.pending_len]);
		}
	}

	pub fn finish(self: *Decoder, sink: anytype) !void {
		if (self.failed) return error.DecoderFailed;
		if (self.finished) return;
		errdefer self.failed = true;
		if (self.pending_len != 0) try sink.write(self.pending[0..self.pending_len]);
		self.pending_len = 0;
		self.finished = true;
	}

	fn transform(self: *Decoder) usize {
		const p = &self.pending;
		switch (self.kind) {
			.delta => {
				p[0] +%= self.history[self.history_pos];
				self.history[self.history_pos] = p[0];
				self.history_pos = (self.history_pos + 1) % self.distance;
				return 1;
			},
			.swap2 => {
				std.mem.reverse(u8, p[0..2]);
				return 2;
			},
			.swap4 => std.mem.reverse(u8, p[0..4]),
			.arm => {
				const word = std.mem.readInt(u32, p[0..4], .little);
				if (word >> 24 == 0xeb) {
					const address = (word & 0xffffff) -% ((self.position +% 8) >> 2);
					std.mem.writeInt(u32, p[0..4], 0xeb000000 | (address & 0xffffff), .little);
				}
			},
			.armt => {
				const first = std.mem.readInt(u16, p[0..2], .little);
				const second = std.mem.readInt(u16, p[2..4], .little);
				if (first & 0xf800 != 0xf000 or second & 0xf800 != 0xf800) return 2;
				const address = ((@as(u32, first & 0x7ff) << 11) | (second & 0x7ff)) -% ((self.position +% 4) >> 1);
				std.mem.writeInt(u16, p[0..2], 0xf000 | @as(u16, @truncate((address >> 11) & 0x7ff)), .little);
				std.mem.writeInt(u16, p[2..4], 0xf800 | @as(u16, @truncate(address & 0x7ff)), .little);
			},
			.ppc => {
				const word = std.mem.readInt(u32, p[0..4], .big);
				if (word & 0xfc000003 == 0x48000001)
					std.mem.writeInt(u32, p[0..4], (word & 0xfc000003) | ((word -% self.position) & 0x03fffffc), .big);
			},
			.sparc => {
				const word = std.mem.readInt(u32, p[0..4], .big);
				if (word & 0xffc00000 == 0x40000000 or word & 0xffc00000 == 0x7fc00000) {
					const address = word -% (self.position >> 2);
					const sign = @as(u32, 0) -% ((address >> 22) & 1);
					std.mem.writeInt(u32, p[0..4], 0x40000000 | (address & 0x3fffff) | (sign & 0x3fc00000), .big);
				}
			},
			.arm64 => {
				const word = std.mem.readInt(u32, p[0..4], .little);
				if (word & 0xfc000000 == 0x94000000) {
					std.mem.writeInt(u32, p[0..4], 0x94000000 | ((word -% (self.position >> 2)) & 0x03ffffff), .little);
				} else if (word & 0x9f000000 == 0x90000000) {
					const address = ((word >> 29) & 3) | ((word >> 3) & 0x1ffffc);
					if ((address +% 0x20000) & 0x1c0000 != 0) return 4;
					const relative = address -% (self.position >> 12);
					const sign = @as(u32, 0) -% (relative & 0x20000);
					std.mem.writeInt(u32, p[0..4], (word & 0x9000001f) | ((relative & 3) << 29) | ((relative & 0x3fffc) << 3) | ((sign & 0x1c0000) << 3), .little);
				}
			},
			.ia64 => {
				var bundle = std.mem.readInt(u128, p, .little);
				const slots: u3 = switch (@as(u5, @truncate(bundle))) {
					16, 17, 24, 25, 28, 29 => 4,
					18, 19 => 6,
					22, 23 => 7,
					else => 0,
				};
				for (0..3) |slot| {
					if (slots & (@as(u3, 1) << @intCast(slot)) == 0) continue;
					const shift: u7 = @intCast(5 + slot * 41);
					const instruction: u64 = @truncate(bundle >> shift);
					if ((instruction >> 37) & 0xf != 5 or (instruction >> 9) & 7 != 0) continue;
					const address: u32 = @intCast(((instruction >> 13) & 0xfffff) | ((instruction >> 16) & 0x100000));
					const relative = address -% (self.position >> 4);
					const mask: u128 = (@as(u128, 0xfffff) << 13) | (@as(u128, 1) << 36);
					const replacement: u128 = (@as(u128, relative & 0xfffff) << 13) | (@as(u128, relative & 0x100000) << 16);
					bundle = (bundle & ~(mask << shift)) | (replacement << shift);
				}
				std.mem.writeInt(u128, p, bundle, .little);
				return 16;
			},
			.riscv => {
				const word = std.mem.readInt(u32, p[0..4], .little);
				if (p[0] == 0xef and p[1] & 0x0d == 0) {
					const absolute = (@as(u32, p[1] >> 4) << 16) | (@as(u32, p[2]) << 8) | p[3];
					const relative = (absolute << 1) -% self.position;
					const immediate = ((relative & 0x100000) << 11) | ((relative & 0x7fe) << 20) | ((relative & 0x800) << 9) | (relative & 0xff000);
					std.mem.writeInt(u32, p[0..4], (word & 0xfff) | immediate, .little);
					return 4;
				}
				if (word & 0x7f != 0x17) return 2;
				const rd = (word >> 7) & 31;
				if (rd == 2) {
					const original_rd = word >> 27;
					if (word & 0x3000 != 0x3000 or original_rd == 0 or original_rd == 2) return 2;
					const absolute = std.mem.readInt(u32, p[4..8], .big);
					const relative = absolute -% self.position;
					const upper = ((relative +% 0x800) & 0xfffff000) | (original_rd << 7) | 0x17;
					const lower = (word >> 12) | (relative << 20);
					std.mem.writeInt(u32, p[0..4], upper, .little);
					std.mem.writeInt(u32, p[4..8], lower, .little);
					return 8;
				}
				if (rd == 0) return 2;
				const second = std.mem.readInt(u32, p[4..8], .little);
				if (second & 3 != 3 or (second >> 15) & 31 != rd) return 2;
				// Collision escape: undo the field permutation without PC arithmetic.
				std.mem.writeInt(u32, p[0..4], (second << 12) | 0x117, .little);
				std.mem.writeInt(u32, p[4..8], (word & 0xfffff000) | (second >> 20), .little);
				return 8;
			},
		}
		return 4;
	}
};

const TestSink = struct {
	bytes: std.ArrayList(u8) = .empty,
	pub fn write(self: *TestSink, bytes: []const u8) !void {
		try self.bytes.appendSlice(std.testing.allocator, bytes);
	}
	fn deinit(self: *TestSink) void {
		self.bytes.deinit(std.testing.allocator);
	}
};

fn oracleCase(comptime name: []const u8, method: []const u8, props: []const u8) !void {
	const encoded = @embedFile("fixtures/filters/" ++ name ++ "/encoded.bin");
	const plain = @embedFile("fixtures/filters/" ++ name ++ "/plain.bin");
	try std.testing.expect(!std.mem.eql(u8, encoded, plain));
	for (0..encoded.len + 1) |split| {
		var decoder = try Decoder.init(method, props);
		var sink: TestSink = .{};
		defer sink.deinit();
		try decoder.write(encoded[0..split], &sink);
		try decoder.write(&.{}, &sink);
		try decoder.write(encoded[split..], &sink);
		try decoder.finish(&sink);
		try std.testing.expectEqualSlices(u8, plain, sink.bytes.items);
	}
	var decoder = try Decoder.init(method, props);
	var sink: TestSink = .{};
	defer sink.deinit();
	for (encoded) |b| try decoder.write(&.{b}, &sink);
	try decoder.finish(&sink);
	try std.testing.expectEqualSlices(u8, plain, sink.bytes.items);
}

test "Delta independent oracle all split points and history wrap" {
	try oracleCase("delta1", &.{3}, &.{0});
	try oracleCase("delta2", &.{3}, &.{1});
	try oracleCase("delta3", &.{3}, &.{2});
	try oracleCase("delta16", &.{3}, &.{15});
	try oracleCase("delta256", &.{3}, &.{255});
}

test "Swap independent oracle odd tails and all split points" {
	try oracleCase("swap2", &.{ 2, 3, 2 }, &.{});
	try oracleCase("swap4", &.{ 2, 3, 4 }, &.{});
}

test "ARM independent oracle all split points" {
	try oracleCase("arm", &.{ 3, 3, 5, 1 }, &.{});
}

test "ARMT independent oracle all split points" {
	try oracleCase("armt", &.{ 3, 3, 7, 1 }, &.{});
}

test "PPC independent oracle all split points" {
	try oracleCase("ppc", &.{ 3, 3, 2, 5 }, &.{});
}

test "SPARC independent oracle all split points" {
	try oracleCase("sparc", &.{ 3, 3, 8, 5 }, &.{});
}

test "ARM64 independent oracle all split points" {
	try oracleCase("arm64", &.{10}, &.{});
}

test "IA64 independent oracle all templates and slots" {
	try oracleCase("ia64", &.{ 3, 3, 4, 1 }, &.{});
}

test "RISCV independent oracle all split points" {
	try oracleCase("riscv", &.{11}, &.{});
}

test "unknown methods and invalid property lengths are distinct" {
	try std.testing.expectError(error.UnsupportedMethod, Decoder.init(&.{99}, &.{}));
	try std.testing.expectError(error.InvalidProperties, Decoder.init(&.{3}, &.{}));
	try std.testing.expectError(error.InvalidProperties, Decoder.init(&.{3}, &.{ 0, 0 }));
	try std.testing.expectError(error.InvalidProperties, Decoder.init(&.{ 2, 3, 2 }, &.{0}));
	try std.testing.expectError(error.InvalidProperties, Decoder.init(&.{10}, &.{0}));
	try std.testing.expectError(error.InvalidProperties, Decoder.init(&.{10}, &.{ 0, 0, 0, 0, 0 }));
}

test "oracle property acceptance matrix and all incomplete unit lengths" {
	for (@import("fixtures/filters/probes.zig").cases) |c| {
		if (!c.accepted) {
			try std.testing.expectError(error.InvalidProperties, Decoder.init(c.method, c.props));
			continue;
		}
		for ([_]usize{ 1, 2, 3, 7, 16, 31, 4096 }) |chunk_size| {
			var decoder = try Decoder.init(c.method, c.props);
			var sink: TestSink = .{};
			defer sink.deinit();
			var pos: usize = 0;
			while (pos < c.encoded.len) {
				const end = @min(c.encoded.len, pos + chunk_size);
				try decoder.write(c.encoded[pos..end], &sink);
				pos = end;
			}
			try decoder.finish(&sink);
			try std.testing.expectEqualSlices(u8, c.plain, sink.bytes.items);
		}
	}
}

fn chunkCase(comptime name: []const u8, method: []const u8) !void {
	const encoded = @embedFile("fixtures/filters/" ++ name ++ "/encoded.bin");
	const plain = @embedFile("fixtures/filters/" ++ name ++ "/plain.bin");
	try std.testing.expect(!std.mem.eql(u8, encoded, plain));
	for ([_]usize{ 1, 2, 3, 7, 16, 31, 4096, 65536 }) |chunk_size| {
		var decoder = try Decoder.init(method, &.{});
		var sink: TestSink = .{};
		defer sink.deinit();
		var pos: usize = 0;
		while (pos < encoded.len) {
			const end = @min(encoded.len, pos + chunk_size);
			try decoder.write(encoded[pos..end], &sink);
			pos = end;
		}
		try decoder.finish(&sink);
		try std.testing.expectEqualSlices(u8, plain, sink.bytes.items);
	}
}

test "independent random byte fixtures" {
	try chunkCase("arm-random", &.{ 3, 3, 5, 1 });
	try chunkCase("armt-random", &.{ 3, 3, 7, 1 });
	try chunkCase("ppc-random", &.{ 3, 3, 2, 5 });
	try chunkCase("sparc-random", &.{ 3, 3, 8, 5 });
	try chunkCase("arm64-random", &.{10});
	try chunkCase("ia64-random", &.{ 3, 3, 4, 1 });
}

test "RISCV independent opcode and register classifier sets and random bytes" {
	try chunkCase("riscv-shapes", &.{11});
	try chunkCase("riscv-random", &.{11});
}

test "supported method IDs classify whole sets without prefix matches" {
	var single_matches: std.ArrayList(u8) = .empty;
	defer single_matches.deinit(std.testing.allocator);
	for (0..256) |id| {
		const method = [_]u8{@intCast(id)};
		if (supports(&method)) try single_matches.append(std.testing.allocator, @intCast(id));
	}
	try std.testing.expectEqualSlices(u8, &.{ 3, 10, 11 }, single_matches.items);
	try std.testing.expect(!supports(&.{}));
	inline for (methods) |entry| {
		try std.testing.expect(supports(entry[0]));
		try std.testing.expect(!supports(entry[0] ++ "\x00"));
		try std.testing.expect(!supports("\x00" ++ entry[0]));
	}
}

test "finish preserves short output exactly once and prevents further writes" {
	var decoder = try Decoder.init(&.{ 2, 3, 4 }, &.{});
	var sink: TestSink = .{};
	defer sink.deinit();
	try decoder.write(&.{ 1, 2, 3 }, &sink);
	try std.testing.expectEqual(@as(usize, 0), sink.bytes.items.len);
	try decoder.finish(&sink);
	try decoder.finish(&sink);
	try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, sink.bytes.items);
	try std.testing.expectError(error.DecoderFinished, decoder.write(&.{4}, &sink));
}

const RejectSink = struct {
	pub fn write(_: *@This(), _: []const u8) error{Rejected}!void {
		return error.Rejected;
	}
};

test "sink errors propagate and poison decoder on write and finish" {
	var sink: RejectSink = .{};
	var decoder = try Decoder.init(&.{3}, &.{0});
	try std.testing.expectError(error.Rejected, decoder.write(&.{1}, &sink));
	try std.testing.expectError(error.DecoderFailed, decoder.write(&.{2}, &sink));
	try std.testing.expectError(error.DecoderFailed, decoder.finish(&sink));
	var tail_decoder = try Decoder.init(&.{ 2, 3, 4 }, &.{});
	try tail_decoder.write(&.{1}, &sink);
	try std.testing.expectError(error.Rejected, tail_decoder.finish(&sink));
	try std.testing.expectError(error.DecoderFailed, tail_decoder.finish(&sink));
}

test "empty stream and independent Delta decoder ownership" {
	var sink: TestSink = .{};
	defer sink.deinit();
	inline for (methods) |entry| {
		var decoder = try Decoder.init(entry[0], if (entry[1] == .delta) &.{0} else &.{});
		try decoder.write(&.{}, &sink);
		try decoder.finish(&sink);
	}
	try std.testing.expectEqual(@as(usize, 0), sink.bytes.items.len);
	var first = try Decoder.init(&.{3}, &.{0});
	var second = try Decoder.init(&.{3}, &.{0});
	try first.write(&.{10}, &sink);
	try second.write(&.{20}, &sink);
	try first.write(&.{1}, &sink);
	try second.write(&.{2}, &sink);
	try std.testing.expectEqualSlices(u8, &.{ 10, 20, 11, 22 }, sink.bytes.items);
}
