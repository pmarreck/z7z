//! 7z header metadata parser.
//!
//! Parses the next-header region into structured metadata:
//! kHeader → [MainStreamsInfo] [FilesInfo] kEnd

const std = @import("std");
const nid = @import("nid.zig");
const Reader = @import("reader.zig").Reader;
const ReadError = @import("reader.zig").ReadError;
const crc32 = @import("crc32.zig");

pub const ParseError = error{
    StructuralError,
    UnsupportedFeature,
    EndOfStream,
    OutOfMemory,
};

// ============================================================================
// Data structures
// ============================================================================

pub const Coder = struct {
    method_id: []const u8, // raw codec ID bytes (owned by archive metadata allocator)
    properties: []const u8, // coder properties (owned)
    num_in_streams: u64,
    num_out_streams: u64,
};

pub const BindPair = struct {
    in_index: u64,
    out_index: u64,
};

pub const Folder = struct {
    coders: []Coder,
    bind_pairs: []BindPair,
    packed_indices: []u64,
    unpack_sizes: []u64, // populated after kCodersUnpackSize
    unpack_crc: ?u32,
};

pub const PackInfo = struct {
    pack_pos: u64,
    pack_sizes: []u64,
    pack_crcs: ?[]?u32, // null if no CRCs declared
};

pub const SubStreamInfo = struct {
    unpack_sizes: []u64,
    digests: []?u32,
};

pub const FileInfo = struct {
    name: ?[]const u8, // UTF-8 encoded filename (owned)
    is_empty_stream: bool,
    is_empty_file: bool,
    is_anti: bool,
    ctime: ?u64, // NTFS FILETIME
    atime: ?u64,
    mtime: ?u64,
    win_attrib: ?u32,
    start_pos: ?u64,
};

pub const ArchiveMetadata = struct {
    pack_info: ?PackInfo,
    folders: []Folder,
    sub_streams: ?SubStreamInfo,
    files: []FileInfo,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ArchiveMetadata) void {
        if (self.pack_info) |pi| {
            self.allocator.free(pi.pack_sizes);
            if (pi.pack_crcs) |crcs| self.allocator.free(crcs);
        }
        for (self.folders) |folder| {
            for (folder.coders) |coder| {
                self.allocator.free(coder.method_id);
                self.allocator.free(coder.properties);
            }
            self.allocator.free(folder.coders);
            self.allocator.free(folder.bind_pairs);
            self.allocator.free(folder.packed_indices);
            self.allocator.free(folder.unpack_sizes);
        }
        self.allocator.free(self.folders);
        if (self.sub_streams) |ss| {
            self.allocator.free(ss.unpack_sizes);
            self.allocator.free(ss.digests);
        }
        for (self.files) |file| {
            if (file.name) |n| self.allocator.free(n);
        }
        self.allocator.free(self.files);
    }
};

// ============================================================================
// Parsing
// ============================================================================

/// Parse a next-header region starting with kHeader or kEncodedHeader.
pub fn parseNextHeader(data: []const u8, allocator: std.mem.Allocator) ParseError!ArchiveMetadata {
    var r = Reader.init(data);

    const first_nid = r.readNid() catch return ParseError.EndOfStream;

    return switch (first_nid) {
        .header => parseHeaderBody(&r, allocator),
        .encoded_header => ParseError.UnsupportedFeature, // TODO: decode then parse
        else => ParseError.StructuralError,
    };
}

fn parseHeaderBody(r: *Reader, allocator: std.mem.Allocator) ParseError!ArchiveMetadata {
    var result = ArchiveMetadata{
        .pack_info = null,
        .folders = &.{},
        .sub_streams = null,
        .files = &.{},
        .allocator = allocator,
    };
    errdefer result.deinit();

    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        switch (tag) {
            .end => return result,
            .archive_properties => {
                try skipArchiveProperties(r);
            },
            .main_streams_info => {
                try parseMainStreamsInfo(r, &result, allocator);
            },
            .additional_streams_info => {
                // Skip for now — read as StreamsInfo then discard
                return ParseError.UnsupportedFeature;
            },
            .files_info => {
                try parseFilesInfo(r, &result, allocator);
            },
            else => return ParseError.StructuralError,
        }
    }
}

fn skipArchiveProperties(r: *Reader) ParseError!void {
    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        if (tag == .end) return;
        const size = r.readUint64() catch return ParseError.EndOfStream;
        r.skip(@intCast(size)) catch return ParseError.EndOfStream;
    }
}

fn parseMainStreamsInfo(r: *Reader, result: *ArchiveMetadata, allocator: std.mem.Allocator) ParseError!void {
    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        switch (tag) {
            .end => return,
            .pack_info => {
                result.pack_info = try parsePackInfo(r, allocator);
            },
            .unpack_info => {
                try parseUnpackInfo(r, result, allocator);
            },
            .sub_streams_info => {
                try parseSubStreamsInfo(r, result, allocator);
            },
            else => return ParseError.StructuralError,
        }
    }
}

fn parsePackInfo(r: *Reader, allocator: std.mem.Allocator) ParseError!PackInfo {
    const pack_pos = r.readUint64() catch return ParseError.EndOfStream;
    const num_pack_streams = r.readUint64() catch return ParseError.EndOfStream;

    var pack_sizes: []u64 = &.{};
    var pack_crcs: ?[]?u32 = null;

    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        switch (tag) {
            .end => break,
            .size => {
                pack_sizes = try allocator.alloc(u64, @intCast(num_pack_streams));
                for (pack_sizes) |*s| {
                    s.* = r.readUint64() catch return ParseError.EndOfStream;
                }
            },
            .crc => {
                pack_crcs = try readDigestVector(r, @intCast(num_pack_streams), allocator);
            },
            else => return ParseError.StructuralError,
        }
    }

    return .{
        .pack_pos = pack_pos,
        .pack_sizes = pack_sizes,
        .pack_crcs = pack_crcs,
    };
}

fn parseUnpackInfo(r: *Reader, result: *ArchiveMetadata, allocator: std.mem.Allocator) ParseError!void {
    // Expect kFolder
    const folder_tag = r.readNid() catch return ParseError.EndOfStream;
    if (folder_tag != .folder) return ParseError.StructuralError;

    const num_folders = r.readUint64() catch return ParseError.EndOfStream;
    const external = r.readByte() catch return ParseError.EndOfStream;
    if (external != 0) return ParseError.UnsupportedFeature;

    // Parse folder records
    result.folders = try allocator.alloc(Folder, @intCast(num_folders));
    for (result.folders) |*folder| {
        folder.* = try parseFolderRecord(r, allocator);
    }

    // Read remaining UnpackInfo fields
    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        switch (tag) {
            .end => return,
            .coders_unpack_size => {
                // One size per coder output stream across all folders
                for (result.folders) |*folder| {
                    var total_out: u64 = 0;
                    for (folder.coders) |coder| {
                        total_out += coder.num_out_streams;
                    }
                    folder.unpack_sizes = try allocator.alloc(u64, @intCast(total_out));
                    for (folder.unpack_sizes) |*s| {
                        s.* = r.readUint64() catch return ParseError.EndOfStream;
                    }
                }
            },
            .crc => {
                const digests = try readDigestVector(r, @intCast(num_folders), allocator);
                for (result.folders, 0..) |*folder, i| {
                    folder.unpack_crc = digests[i];
                }
                allocator.free(digests);
            },
            else => return ParseError.StructuralError,
        }
    }
}

fn parseFolderRecord(r: *Reader, allocator: std.mem.Allocator) ParseError!Folder {
    const num_coders = r.readUint64() catch return ParseError.EndOfStream;
    const coders = try allocator.alloc(Coder, @intCast(num_coders));
    errdefer allocator.free(coders);

    var total_in: u64 = 0;
    var total_out: u64 = 0;

    for (coders) |*coder| {
        const main_byte = r.readByte() catch return ParseError.EndOfStream;

        // Check reserved bits
        if (main_byte & 0xC0 != 0) return ParseError.UnsupportedFeature;

        const codec_id_size: usize = main_byte & 0x0F;
        const is_complex = (main_byte & 0x10) != 0;
        const has_props = (main_byte & 0x20) != 0;

        // Read codec ID
        const method_id = try allocator.alloc(u8, codec_id_size);
        if (codec_id_size > 0) {
            const id_bytes = r.readBytes(codec_id_size) catch return ParseError.EndOfStream;
            @memcpy(method_id, id_bytes);
        }

        // In/out stream counts
        var num_in: u64 = 1;
        var num_out: u64 = 1;
        if (is_complex) {
            num_in = r.readUint64() catch return ParseError.EndOfStream;
            num_out = r.readUint64() catch return ParseError.EndOfStream;
        }

        // Properties
        var properties: []u8 = &.{};
        if (has_props) {
            const props_size = r.readUint64() catch return ParseError.EndOfStream;
            properties = try allocator.alloc(u8, @intCast(props_size));
            const prop_bytes = r.readBytes(@intCast(props_size)) catch return ParseError.EndOfStream;
            @memcpy(properties, prop_bytes);
        }

        coder.* = .{
            .method_id = method_id,
            .properties = properties,
            .num_in_streams = num_in,
            .num_out_streams = num_out,
        };

        total_in += num_in;
        total_out += num_out;
    }

    // Bind pairs
    const num_bind_pairs = total_out - 1;
    const bind_pairs = try allocator.alloc(BindPair, @intCast(num_bind_pairs));
    for (bind_pairs) |*bp| {
        bp.in_index = r.readUint64() catch return ParseError.EndOfStream;
        bp.out_index = r.readUint64() catch return ParseError.EndOfStream;
    }

    // Packed stream indices
    const num_packed = total_in - num_bind_pairs;
    var packed_indices: []u64 = &.{};
    if (num_packed > 1) {
        packed_indices = try allocator.alloc(u64, @intCast(num_packed));
        for (packed_indices) |*idx| {
            idx.* = r.readUint64() catch return ParseError.EndOfStream;
        }
    }

    return .{
        .coders = coders,
        .bind_pairs = bind_pairs,
        .packed_indices = packed_indices,
        .unpack_sizes = &.{}, // populated later by kCodersUnpackSize
        .unpack_crc = null,
    };
}

fn parseSubStreamsInfo(r: *Reader, result: *ArchiveMetadata, allocator: std.mem.Allocator) ParseError!void {
    const num_folders = result.folders.len;

    // Default: 1 substream per folder
    const num_unpack_streams = try allocator.alloc(u64, num_folders);
    defer allocator.free(num_unpack_streams);
    @memset(num_unpack_streams, 1);

    var all_sizes = std.ArrayListUnmanaged(u64){};
    defer all_sizes.deinit(allocator);

    var all_digests = std.ArrayListUnmanaged(?u32){};
    defer all_digests.deinit(allocator);

    while (true) {
        const tag = r.readNid() catch return ParseError.EndOfStream;
        switch (tag) {
            .end => break,
            .num_unpack_stream => {
                for (num_unpack_streams) |*n| {
                    n.* = r.readUint64() catch return ParseError.EndOfStream;
                }
            },
            .size => {
                // For each folder with n substreams, store first n-1 sizes
                for (0..num_folders) |fi| {
                    const n = num_unpack_streams[fi];
                    if (n == 0) continue;
                    for (0..@intCast(n - 1)) |_| {
                        const sz = r.readUint64() catch return ParseError.EndOfStream;
                        try all_sizes.append(allocator, sz);
                    }
                    // Last size is inferred (added during extraction)
                    try all_sizes.append(allocator, 0); // placeholder
                }
            },
            .crc => {
                // Count substreams needing digests
                var num_sub_digests: usize = 0;
                for (0..num_folders) |fi| {
                    const n = num_unpack_streams[fi];
                    if (n == 1 and result.folders[fi].unpack_crc != null) {
                        // Inherited from folder
                    } else {
                        num_sub_digests += @intCast(n);
                    }
                }
                const digests = try readDigestVector(r, num_sub_digests, allocator);
                defer allocator.free(digests);
                for (digests) |d| {
                    try all_digests.append(allocator, d);
                }
            },
            else => return ParseError.StructuralError,
        }
    }

    // If no kSize section was present, infer sizes from folder unpack sizes
    // (default: 1 substream per folder, size = folder's final unpack size)
    if (all_sizes.items.len == 0) {
        for (0..num_folders) |fi| {
            const n: usize = @intCast(num_unpack_streams[fi]);
            if (n == 1) {
                // Single substream — size is the folder's unpack size
                const folder_size = if (result.folders[fi].unpack_sizes.len > 0)
                    result.folders[fi].unpack_sizes[result.folders[fi].unpack_sizes.len - 1]
                else
                    0;
                try all_sizes.append(allocator, folder_size);
            } else {
                // Multiple substreams without kSize is a structural error
                // (kSize is required when NumUnPackStream > 1)
                for (0..n) |_| {
                    try all_sizes.append(allocator, 0);
                }
            }
        }
    } else {
        // Compute inferred last sizes for folders with explicit kSize
        var size_idx: usize = 0;
        for (0..num_folders) |fi| {
            const n: usize = @intCast(num_unpack_streams[fi]);
            if (n == 0) continue;
            var sum: u64 = 0;
            for (0..n - 1) |_| {
                sum += all_sizes.items[size_idx];
                size_idx += 1;
            }
            // Last size = folder unpack size - sum of previous
            const folder_size = if (result.folders[fi].unpack_sizes.len > 0)
                result.folders[fi].unpack_sizes[result.folders[fi].unpack_sizes.len - 1]
            else
                0;
            all_sizes.items[size_idx] = folder_size - sum;
            size_idx += 1;
        }
    }

    result.sub_streams = .{
        .unpack_sizes = try allocator.dupe(u64, all_sizes.items),
        .digests = try allocator.dupe(?u32, all_digests.items),
    };
}

fn parseFilesInfo(r: *Reader, result: *ArchiveMetadata, allocator: std.mem.Allocator) ParseError!void {
    const num_files = r.readUint64() catch return ParseError.EndOfStream;

    result.files = try allocator.alloc(FileInfo, @intCast(num_files));
    for (result.files) |*f| {
        f.* = .{
            .name = null,
            .is_empty_stream = false,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = null,
            .atime = null,
            .mtime = null,
            .win_attrib = null,
            .start_pos = null,
        };
    }

    var empty_stream_flags: ?[]bool = null;
    defer if (empty_stream_flags) |f| allocator.free(f);

    while (true) {
        const prop_type_val = r.readUint64() catch return ParseError.EndOfStream;
        const prop_type = nid.Nid.fromByte(@intCast(prop_type_val & 0xFF));

        if (prop_type == .end) return;

        const prop_size = r.readUint64() catch return ParseError.EndOfStream;
        const prop_start = r.pos;

        switch (prop_type) {
            .name => try parseFileNames(r, result.files, allocator),
            .empty_stream => {
                empty_stream_flags = r.readBoolVector(@intCast(num_files), allocator) catch return ParseError.EndOfStream;
                for (result.files, 0..) |*f, i| {
                    f.is_empty_stream = empty_stream_flags.?[i];
                }
            },
            .empty_file => {
                var empty_count: usize = 0;
                if (empty_stream_flags) |flags| {
                    for (flags) |f| {
                        if (f) empty_count += 1;
                    }
                }
                const ef = r.readBoolVector(empty_count, allocator) catch return ParseError.EndOfStream;
                defer allocator.free(ef);
                var ei: usize = 0;
                for (result.files) |*f| {
                    if (f.is_empty_stream) {
                        f.is_empty_file = ef[ei];
                        ei += 1;
                    }
                }
            },
            .anti => {
                var empty_count: usize = 0;
                if (empty_stream_flags) |flags| {
                    for (flags) |f| {
                        if (f) empty_count += 1;
                    }
                }
                const af = r.readBoolVector(empty_count, allocator) catch return ParseError.EndOfStream;
                defer allocator.free(af);
                var ai: usize = 0;
                for (result.files) |*f| {
                    if (f.is_empty_stream) {
                        f.is_anti = af[ai];
                        ai += 1;
                    }
                }
            },
            .m_time, .c_time, .a_time, .start_pos => {
                try parseTimeProperty(r, result.files, prop_type, allocator);
            },
            .win_attrib => {
                try parseWinAttrib(r, result.files, allocator);
            },
            .dummy => {
                // Skip dummy padding
                r.skip(@intCast(prop_size)) catch return ParseError.EndOfStream;
                continue; // skip the size check below
            },
            else => {
                // Unknown property — skip by size (emit warning in future)
                r.skip(@intCast(prop_size)) catch return ParseError.EndOfStream;
                continue;
            },
        }

        // Verify we consumed exactly prop_size bytes
        const consumed = r.pos - prop_start;
        if (consumed != @as(usize, @intCast(prop_size))) {
            return ParseError.StructuralError;
        }
    }
}

fn parseFileNames(r: *Reader, files: []FileInfo, allocator: std.mem.Allocator) ParseError!void {
    const external = r.readByte() catch return ParseError.EndOfStream;
    if (external != 0) return ParseError.UnsupportedFeature;

    for (files) |*file| {
        // Read UTF-16LE chars until NUL
        var utf16_buf = std.ArrayListUnmanaged(u16){};
        defer utf16_buf.deinit(allocator);

        while (true) {
            const lo = r.readByte() catch return ParseError.EndOfStream;
            const hi = r.readByte() catch return ParseError.EndOfStream;
            const code_unit: u16 = @as(u16, hi) << 8 | lo;
            if (code_unit == 0) break;
            try utf16_buf.append(allocator, code_unit);
        }

        // Convert UTF-16LE to UTF-8
        var utf8_buf = std.ArrayListUnmanaged(u8){};
        errdefer utf8_buf.deinit(allocator);

        for (utf16_buf.items) |cu| {
            var out: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cu, &out) catch return ParseError.StructuralError;
            try utf8_buf.appendSlice(allocator, out[0..len]);
        }

        file.name = try utf8_buf.toOwnedSlice(allocator);
    }
}

fn parseTimeProperty(r: *Reader, files: []FileInfo, prop_type: nid.Nid, allocator: std.mem.Allocator) ParseError!void {
    const defined = r.readBoolVector2(files.len, allocator) catch return ParseError.EndOfStream;
    defer allocator.free(defined);

    const external = r.readByte() catch return ParseError.EndOfStream;
    if (external != 0) return ParseError.UnsupportedFeature;

    for (files, 0..) |*file, i| {
        if (defined[i]) {
            const val = r.readU64Le() catch return ParseError.EndOfStream;
            switch (prop_type) {
                .c_time => file.ctime = val,
                .a_time => file.atime = val,
                .m_time => file.mtime = val,
                .start_pos => file.start_pos = val,
                else => {},
            }
        }
    }
}

fn parseWinAttrib(r: *Reader, files: []FileInfo, allocator: std.mem.Allocator) ParseError!void {
    const defined = r.readBoolVector2(files.len, allocator) catch return ParseError.EndOfStream;
    defer allocator.free(defined);

    const external = r.readByte() catch return ParseError.EndOfStream;
    if (external != 0) return ParseError.UnsupportedFeature;

    for (files, 0..) |*file, i| {
        if (defined[i]) {
            file.win_attrib = r.readU32Le() catch return ParseError.EndOfStream;
        }
    }
}

fn readDigestVector(r: *Reader, count: usize, allocator: std.mem.Allocator) ParseError![]?u32 {
    const defined = r.readBoolVector2(count, allocator) catch return ParseError.EndOfStream;
    defer allocator.free(defined);

    const result = try allocator.alloc(?u32, count);
    for (result, 0..) |*d, i| {
        if (defined[i]) {
            d.* = r.readU32Le() catch return ParseError.EndOfStream;
        } else {
            d.* = null;
        }
    }
    return result;
}

// ============================================================================
// Tests
// ============================================================================

// TV-A next-header bytes (bytes 38..111 of the archive, 74 bytes)
const tv_a_next_header = [74]u8{
    0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x06, 0x00,
    0x07, 0x0B, 0x01, 0x00, 0x01, 0x01, 0x00, 0x0C,
    0x06, 0x00, 0x08, 0x0A, 0x01, 0x20, 0x30, 0x3A,
    0x36, 0x00, 0x00, 0x05, 0x01, 0x11, 0x15, 0x00,
    0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00,
    0x6F, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00,
    0x74, 0x00, 0x00, 0x00, 0x14, 0x0A, 0x01, 0x00,
    0x80, 0xCA, 0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01,
    0x15, 0x06, 0x01, 0x00, 0x20, 0x80, 0xA4, 0x81,
    0x00, 0x00,
};

test "metadata: parse TV-A next-header" {
    const allocator = std.testing.allocator;
    var meta = try parseNextHeader(&tv_a_next_header, allocator);
    defer meta.deinit();

    // PackInfo
    try std.testing.expect(meta.pack_info != null);
    const pi = meta.pack_info.?;
    try std.testing.expectEqual(@as(u64, 0), pi.pack_pos);
    try std.testing.expectEqual(@as(usize, 1), pi.pack_sizes.len);
    try std.testing.expectEqual(@as(u64, 6), pi.pack_sizes[0]);

    // Folders
    try std.testing.expectEqual(@as(usize, 1), meta.folders.len);
    const folder = meta.folders[0];
    try std.testing.expectEqual(@as(usize, 1), folder.coders.len);

    // Coder: Copy method (method_id = 0x00)
    try std.testing.expectEqual(@as(usize, 1), folder.coders[0].method_id.len);
    try std.testing.expectEqual(@as(u8, 0x00), folder.coders[0].method_id[0]);

    // Unpack size
    try std.testing.expectEqual(@as(usize, 1), folder.unpack_sizes.len);
    try std.testing.expectEqual(@as(u64, 6), folder.unpack_sizes[0]);

    // SubStreamsInfo CRC
    try std.testing.expect(meta.sub_streams != null);

    // FilesInfo
    try std.testing.expectEqual(@as(usize, 1), meta.files.len);
    const file = meta.files[0];
    try std.testing.expectEqualStrings("hello.txt", file.name.?);
    try std.testing.expect(file.mtime != null);
    try std.testing.expect(file.win_attrib != null);
}

test "metadata: TV-A folder CRC matches expected value" {
    const allocator = std.testing.allocator;
    var meta = try parseNextHeader(&tv_a_next_header, allocator);
    defer meta.deinit();

    // From the spec: CRC 0x363A3020 for "hello\n"
    try std.testing.expect(meta.sub_streams != null);
    const ss = meta.sub_streams.?;
    try std.testing.expectEqual(@as(usize, 1), ss.digests.len);
    try std.testing.expectEqual(@as(?u32, 0x363A3020), ss.digests[0]);
}

test "metadata: parse TV-B next-header" {
    // TV-B: NextHeaderOffset=0x0A, NextHeaderSize=0x5A=90
    // Archive bytes 42..131 (90 bytes)
    const tv_b_archive = [132]u8{
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x6D, 0xE0, 0xCC, 0x1D, 0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x5A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xDA, 0x13, 0xAD, 0xAC,
        0x01, 0x00, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x0A, 0x00, 0x01, 0x04, 0x06, 0x00, 0x01, 0x09,
        0x0A, 0x00, 0x07, 0x0B, 0x01, 0x00, 0x01, 0x21, 0x21, 0x01, 0x00, 0x0C, 0x06, 0x00, 0x08, 0x0A,
        0x01, 0x20, 0x30, 0x3A, 0x36, 0x00, 0x00, 0x05, 0x01, 0x19, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x15, 0x00, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00,
        0x6C, 0x00, 0x6F, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00, 0x00, 0x14, 0x0A,
        0x01, 0x00, 0x80, 0xCA, 0x91, 0x2A, 0x0D, 0xA4, 0xDC, 0x01, 0x15, 0x06, 0x01, 0x00, 0x20, 0x80,
        0xA4, 0x81, 0x00, 0x00,
    };

    // Extract next-header region
    const nh_start = 32 + 0x0A; // 42
    const nh_size = 0x5A; // 90
    const next_header = tv_b_archive[nh_start .. nh_start + nh_size];

    const allocator = std.testing.allocator;
    var meta = try parseNextHeader(next_header, allocator);
    defer meta.deinit();

    // LZMA2 method
    try std.testing.expectEqual(@as(usize, 1), meta.folders.len);
    try std.testing.expectEqual(@as(usize, 1), meta.folders[0].coders.len);
    try std.testing.expectEqual(@as(usize, 1), meta.folders[0].coders[0].method_id.len);
    try std.testing.expectEqual(@as(u8, 0x21), meta.folders[0].coders[0].method_id[0]);

    // LZMA2 should have 1 property byte
    try std.testing.expectEqual(@as(usize, 1), meta.folders[0].coders[0].properties.len);

    // File name
    try std.testing.expectEqualStrings("hello.txt", meta.files[0].name.?);
}

test "metadata: reject garbage input" {
    const allocator = std.testing.allocator;
    const result = parseNextHeader(&[_]u8{ 0xFF, 0x00 }, allocator);
    try std.testing.expectError(ParseError.StructuralError, result);
}
