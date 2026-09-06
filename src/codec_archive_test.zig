//! Archive acceptance for retained independent codec fixtures.
//! Codec integration may leave these tests red; unsupported methods are never skipped.
const std = @import("std");
const archive = @import("archive.zig");
const signature = @import("header.zig");
const allocator = std.testing.allocator;

const Group = enum { filters, deflate64, bzip2 };
const filter_names = .{
    "delta1",       "delta2",     "delta3",      "delta16",    "delta256",     "swap2",        "swap4",
    "arm",          "ppc",        "sparc",       "armt",       "arm64",        "ia64",         "riscv",
    "riscv-shapes", "arm-random", "armt-random", "ppc-random", "sparc-random", "arm64-random", "ia64-random",
    "riscv-random",
};
const deflate64_names = .{ "fixed", "stored", "dynamic", "history49152", "length285" };
const bzip2_names = .{ "small", "rle-expansion", "multiblock", "filter-swap4" };
const awkward_splits = [_]usize{ 1, 3, 7, 2, 11 };

const Entry = struct {
    name: []const u8,
    archive_sha256: []const u8,
    plain_sha256: ?[]const u8 = null,
    input_sha256: ?[]const u8 = null,
    bytes: u64 = 0,
    plain_size: u64 = 0,
    size: u64 = 0,
    raw_size: u64 = 0,
    packed_size: u64 = 0,
    changed_bytes: u64 = 0,
    crc32: ?[]const u8 = null,

    fn unpackSize(self: Entry, group: Group) u64 {
        return switch (group) {
            .filters => self.bytes,
            .deflate64 => self.plain_size,
            .bzip2 => self.size,
        };
    }

    fn packSize(self: Entry, group: Group) u64 {
        return switch (group) {
            .filters => self.bytes,
            .deflate64 => self.raw_size,
            .bzip2 => self.packed_size,
        };
    }
};
const Manifest = struct { oracle_sha256: []const u8, cases: []Entry };

fn manifest(comptime group: Group) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, allocator, @embedFile("fixtures/" ++ @tagName(group) ++ "/provenance.json"), .{ .ignore_unknown_fields = true });
}

fn findEntry(entries: []const Entry, name: []const u8) !Entry {
    var found: ?Entry = null;
    for (entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            if (found != null) return error.DuplicateFixture;
            found = entry;
        }
    }
    return found orelse error.MissingFixture;
}

fn expectSha256(expected: []const u8, bytes: []const u8) !void {
    var expected_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_hash, expected);
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &actual);
}

fn expectStats(stats: archive.ArchiveStats, entry: Entry, group: Group) !void {
    try std.testing.expectEqual(@as(u64, 1), stats.file_count);
    try std.testing.expectEqual(@as(u64, 1), stats.data_file_count);
    try std.testing.expectEqual(@as(u64, 1), stats.folder_count);
    try std.testing.expectEqual(@as(u64, 1), stats.substream_count);
    try std.testing.expectEqual(entry.packSize(group), stats.total_pack_size);
    try std.testing.expectEqual(entry.unpackSize(group), stats.total_unpack_size);
    try std.testing.expectEqual(entry.unpackSize(group), stats.largest_folder_unpack_size);
    try std.testing.expectEqual(entry.unpackSize(group), stats.max_file_unpack_size);
}

const ShortSource = struct {
    bytes: []const u8,
    next_header: u64,
    splits: []const usize,
    calls: usize = 0,
    short_reads: usize = 0,
    saw_payload: bool = false,
    saw_next_header: bool = false,

    fn source(self: *ShortSource) archive.RangeSource {
        return .{ .ptr = self, .len = self.bytes.len, .readFn = readAt };
    }

    fn readAt(context: *anyopaque, offset: u64, destination: []u8) archive.RangeReadError!usize {
        const self: *ShortSource = @ptrCast(@alignCast(context));
        const limit = self.splits[self.calls % self.splits.len];
        self.calls += 1;
        if (offset >= self.bytes.len or destination.len == 0) return 0;
        const start: usize = @intCast(offset);
        const count = @min(limit, destination.len, self.bytes.len - start);
        if (count < destination.len) self.short_reads += 1;
        if (offset >= signature.HEADER_SIZE and offset < self.next_header) self.saw_payload = true;
        if (offset >= self.next_header) self.saw_next_header = true;
        @memcpy(destination[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

fn expectCorruptionError(err: archive.ArchiveError) !void {
    switch (err) {
        error.ChecksumError, error.StructuralError, error.TruncatedInput, error.EndOfStream => {},
        else => return err,
    }
}

fn expectRejected(bytes: []const u8, next_header: u64) !void {
    if (archive.read(bytes, allocator)) |result| {
        var contents = result;
        contents.deinit();
        return error.CorruptArchiveWasExtracted;
    } else |err| try expectCorruptionError(err);
    if (archive.verify(bytes, .{}, allocator)) |_| {
        return error.CorruptArchiveWasVerified;
    } else |err| try expectCorruptionError(err);
    var source = ShortSource{ .bytes = bytes, .next_header = next_header, .splits = &awkward_splits };
    if (archive.verifyRange(source.source(), .{}, allocator)) |_| {
        return error.CorruptArchiveWasRangeVerified;
    } else |err| try expectCorruptionError(err);
}

fn Fixture(comptime group: Group, comptime name: []const u8) type {
    return struct {
        const bytes = switch (group) {
            .filters => @embedFile("fixtures/filters/" ++ name ++ "/oracle.7z"),
            .deflate64 => @embedFile("fixtures/deflate64/" ++ name ++ ".7z"),
            .bzip2 => @embedFile("fixtures/bzip2/" ++ name ++ ".7z"),
        };
        const filename = switch (group) {
            .filters => "plain.bin",
            .deflate64 => name ++ ".plain",
            .bzip2 => name ++ ".bin",
        };

        fn payload(entry: Entry) ![]u8 {
            if (group == .filters) return allocator.dupe(u8, @embedFile("fixtures/filters/" ++ name ++ "/plain.bin"));
            if (group == .deflate64) return allocator.dupe(u8, @embedFile("fixtures/deflate64/" ++ name ++ ".plain"));
            if (comptime std.mem.eql(u8, name, "filter-swap4")) return allocator.dupe(u8, @embedFile("fixtures/filters/swap4/encoded.bin"));
            // BZip2's generator retains hashes, not plaintext; these are its input recipes.
            if (comptime std.mem.eql(u8, name, "small"))
                return allocator.dupe(u8, "BZip2 from independent 7-Zip 26.03.\nBinary: \x00\x01\x7f\xff\n");
            const expected = try allocator.alloc(u8, @intCast(entry.size));
            if (comptime std.mem.eql(u8, name, "rle-expansion")) {
                @memset(expected, 0x41);
            } else {
                for (expected, 0..) |*byte, i| byte.* = @intCast(i % 251);
            }
            return expected;
        }

        fn admit(entry: Entry) !void {
            try expectSha256(entry.archive_sha256, bytes);
            const expected = try payload(entry);
            defer allocator.free(expected);
            try std.testing.expectEqual(entry.unpackSize(group), expected.len);
            try expectSha256(entry.plain_sha256 orelse entry.input_sha256 orelse return error.MissingPayloadHash, expected);
            if (entry.crc32) |crc| try std.testing.expectEqual(try std.fmt.parseInt(u32, crc, 16), std.hash.Crc32.hash(expected));
            const header = try signature.parse(bytes);
            try std.testing.expectEqual(entry.packSize(group), header.next_header_offset);
            if (group == .filters) {
                try std.testing.expect(entry.changed_bytes > 0);
                try std.testing.expect(!std.mem.eql(u8, expected, @embedFile("fixtures/filters/" ++ name ++ "/encoded.bin")));
            }
        }

        fn retained(entry: Entry) !void {
            const expected = try payload(entry);
            defer allocator.free(expected);
            var contents = try archive.read(bytes, allocator);
            defer contents.deinit();
            try std.testing.expectEqual(@as(usize, 1), contents.file_data.len);
            try std.testing.expectEqual(@as(usize, 1), contents.metadata.files.len);
            try std.testing.expectEqual(@as(usize, 1), contents.metadata.folders.len);
            try std.testing.expect(!contents.metadata.files[0].is_empty_stream);
            try std.testing.expectEqualStrings(filename, contents.metadata.files[0].name orelse return error.MissingFileName);
            try std.testing.expectEqual(entry.unpackSize(group), contents.file_data[0].len);
            try std.testing.expectEqualSlices(u8, expected, contents.file_data[0]);
        }

        fn ranged(entry: Entry, splits: []const usize) !void {
            const header = try signature.parse(bytes);
            var source = ShortSource{ .bytes = bytes, .next_header = header.nextHeaderAbsoluteOffset(), .splits = splits };
            try expectStats(try archive.verifyRange(source.source(), .{}, allocator), entry, group);
            try std.testing.expect(source.calls > 3);
            try std.testing.expect(source.short_reads > 0);
            try std.testing.expect(source.saw_payload);
            try std.testing.expect(source.saw_next_header);
        }

        test "codec archives: retained extraction" {
            const parsed = try manifest(group);
            defer parsed.deinit();
            try retained(try findEntry(parsed.value.cases, name));
        }

        test "codec archives: verify counts and sizes" {
            const parsed = try manifest(group);
            defer parsed.deinit();
            try expectStats(try archive.verify(bytes, .{}, allocator), try findEntry(parsed.value.cases, name), group);
        }

        test "codec archives: verifyRange awkward short reads" {
            const parsed = try manifest(group);
            defer parsed.deinit();
            const entry = try findEntry(parsed.value.cases, name);
            try ranged(entry, &.{1});
            try ranged(entry, &awkward_splits);
        }

        test "codec archives: packed corruption paired with valid input" {
            const parsed = try manifest(group);
            defer parsed.deinit();
            const entry = try findEntry(parsed.value.cases, name);
            try retained(entry);
            try expectStats(try archive.verify(bytes, .{}, allocator), entry, group);
            try ranged(entry, &awkward_splits);
            const changed = try allocator.dupe(u8, bytes);
            defer allocator.free(changed);
            const header = try signature.parse(bytes);
            try std.testing.expect(header.next_header_offset > 0);
            if (group == .deflate64) {
                // Reserved BTYPE=3 is invalid; high header bits can be ignored padding.
                changed[signature.HEADER_SIZE] |= 0x06;
            } else {
                changed[signature.HEADER_SIZE] ^= 0x80;
            }
            try expectRejected(changed, header.nextHeaderAbsoluteOffset());
        }

        test "codec archives: truncation paired with valid input" {
            const parsed = try manifest(group);
            defer parsed.deinit();
            const entry = try findEntry(parsed.value.cases, name);
            try retained(entry);
            try expectStats(try archive.verify(bytes, .{}, allocator), entry, group);
            try ranged(entry, &awkward_splits);
            const header = try signature.parse(bytes);
            const cuts = [_]usize{ 0, 1, signature.HEADER_SIZE - 1, signature.HEADER_SIZE, @intCast(header.nextHeaderAbsoluteOffset() - 1), bytes.len - 1 };
            for (cuts) |length| try expectRejected(bytes[0..length], header.nextHeaderAbsoluteOffset());
        }
    };
}

comptime {
    for (filter_names) |name| _ = Fixture(.filters, name);
    for (deflate64_names) |name| _ = Fixture(.deflate64, name);
    for (bzip2_names) |name| _ = Fixture(.bzip2, name);
}

test "codec archives: complete fixture manifest admission" {
    inline for (.{ Group.filters, Group.deflate64, Group.bzip2 }) |group| {
        const parsed = try manifest(group);
        defer parsed.deinit();
        try std.testing.expectEqualStrings("eab4c8d7f193e3d6d3237370bbcaa879a160a3f1dc82202207e27baeab79b6ac", parsed.value.oracle_sha256);
        const names = switch (group) {
            .filters => filter_names,
            .deflate64 => deflate64_names,
            .bzip2 => bzip2_names,
        };
        try std.testing.expectEqual(@as(usize, names.len), parsed.value.cases.len);
        inline for (names) |name| try Fixture(group, name).admit(try findEntry(parsed.value.cases, name));
    }
}
