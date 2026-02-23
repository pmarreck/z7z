//! LZMA2 encoder — cleanroom implementation.
//!
//! Implements LZMA2 compression wrapping LZMA1 with range coding
//! and LZ77 match finding. Designed from the public LZMA specification
//! and by studying the Zig stdlib decoder (MIT licensed).

const std = @import("std");

// ============================================================================
// Range Encoder
// ============================================================================

/// Arithmetic range encoder — inverse of the range decoder.
/// Produces bytes compatible with the Zig stdlib LZMA range decoder.
const RangeEncoder = struct {
    low: u64 = 0,
    range: u32 = 0xFFFF_FFFF,
    cache_size: u32 = 1,
    cache: u8 = 0,
    output: std.ArrayListUnmanaged(u8) = .{},

    fn init() RangeEncoder {
        return .{};
    }

    fn deinit(self: *RangeEncoder, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }

    fn shiftLow(self: *RangeEncoder, allocator: std.mem.Allocator) !void {
        const low32 = @as(u32, @truncate(self.low));
        const carry: u8 = @intCast(self.low >> 32);
        if (low32 < 0xFF00_0000 or carry != 0) {
            var temp = self.cache;
            var cs = self.cache_size;
            while (cs > 0) : (cs -= 1) {
                try self.output.append(allocator, temp +% carry);
                temp = 0xFF;
            }
            self.cache = @intCast((self.low >> 24) & 0xFF);
            self.cache_size = 0;
        }
        self.cache_size += 1;
        // Match C's ((UInt32)Low) << 8: truncate to u32, shift, truncate again
        self.low = (@as(u64, low32) << 8) & 0xFFFFFFFF;
    }

    /// Encode a single bit using adaptive probability.
    fn encodeBit(self: *RangeEncoder, prob: *u16, bit: u1, allocator: std.mem.Allocator) !void {
        const bound = (self.range >> 11) * prob.*;
        if (bit == 0) {
            self.range = bound;
            prob.* += @intCast((@as(u32, 0x800) - prob.*) >> 5);
        } else {
            self.low += bound;
            self.range -= bound;
            prob.* -= @intCast(prob.* >> 5);
        }
        if (self.range < 0x0100_0000) {
            self.range <<= 8;
            try self.shiftLow(allocator);
        }
    }

    /// Encode a fixed (equiprobable) bit.
    fn encodeDirect(self: *RangeEncoder, bit: u1, allocator: std.mem.Allocator) !void {
        self.range >>= 1;
        if (bit == 1) {
            self.low += self.range;
        }
        if (self.range < 0x0100_0000) {
            self.range <<= 8;
            try self.shiftLow(allocator);
        }
    }

    /// Encode multiple direct bits MSB-first.
    fn encodeDirectBits(self: *RangeEncoder, value: u32, count: u5, allocator: std.mem.Allocator) !void {
        var i: u5 = count;
        while (i > 0) {
            i -= 1;
            try self.encodeDirect(@intCast((value >> i) & 1), allocator);
        }
    }

    /// Encode a value using a forward bit tree.
    fn encodeBitTree(self: *RangeEncoder, probs: []u16, num_bits: u5, value: u32, allocator: std.mem.Allocator) !void {
        var idx: u32 = 1;
        var i: u5 = num_bits;
        while (i > 0) {
            i -= 1;
            const bit: u1 = @intCast((value >> i) & 1);
            try self.encodeBit(&probs[idx], bit, allocator);
            idx = (idx << 1) | bit;
        }
    }

    /// Encode a value using a reverse bit tree (LSB first).
    fn encodeReverseBitTree(self: *RangeEncoder, probs: []u16, num_bits: u5, value: u32, allocator: std.mem.Allocator) !void {
        var idx: u32 = 1;
        var val = value;
        for (0..num_bits) |_| {
            const bit: u1 = @intCast(val & 1);
            try self.encodeBit(&probs[idx], bit, allocator);
            idx = (idx << 1) | bit;
            val >>= 1;
        }
    }

    /// Flush the range encoder — must be called at end of stream.
    fn flush(self: *RangeEncoder, allocator: std.mem.Allocator) !void {
        for (0..5) |_| {
            try self.shiftLow(allocator);
        }
    }

    /// Get the encoded bytes (including the 5-byte header: 0x00 + 4 bytes code).
    /// The range encoder output already includes the properly formatted bytes.
    fn getOutput(self: *RangeEncoder) []const u8 {
        return self.output.items;
    }
};

// ============================================================================
// LZ77 Match Finder (Hash Chain)
// ============================================================================

const HASH_BITS = 16;
const HASH_SIZE = 1 << HASH_BITS;
const MIN_MATCH = 2;
const MAX_MATCH = 273;

const Match = struct {
    distance: u32, // 0-based distance (rep format)
    length: u32,
};

const MatchFinder = struct {
    head: [HASH_SIZE]u32,
    chain: []u32,
    data: []const u8,
    dict_size: u32,

    fn init(data: []const u8, dict_size: u32, allocator: std.mem.Allocator) !MatchFinder {
        const chain = try allocator.alloc(u32, data.len);
        @memset(chain, 0);
        var mf = MatchFinder{
            .head = undefined,
            .chain = chain,
            .data = data,
            .dict_size = dict_size,
        };
        @memset(&mf.head, 0);
        return mf;
    }

    fn deinit(self: *MatchFinder, allocator: std.mem.Allocator) void {
        allocator.free(self.chain);
    }

    fn hash3(data: []const u8, pos: usize) u32 {
        if (pos + 2 >= data.len) return 0;
        const h = @as(u32, data[pos]) ^ (@as(u32, data[pos + 1]) << 8) ^ (@as(u32, data[pos + 2]) << 5);
        return h & (HASH_SIZE - 1);
    }

    /// Find the best match at the given position.
    /// Returns null if no match found of length >= MIN_MATCH.
    fn findMatch(self: *MatchFinder, pos: usize) ?Match {
        if (pos + MIN_MATCH > self.data.len) return null;

        const h = hash3(self.data, pos);
        const prev = self.head[h];
        self.chain[pos] = prev;
        self.head[h] = @intCast(pos + 1); // +1 so 0 means "no entry"

        var best_len: u32 = MIN_MATCH - 1;
        var best_dist: u32 = 0;
        var cur = prev;
        var depth: u32 = 0;
        const max_depth: u32 = 64; // limit search depth for speed

        while (cur > 0 and depth < max_depth) : (depth += 1) {
            const match_pos = cur - 1; // convert back from 1-based
            const dist = @as(u32, @intCast(pos - match_pos));
            if (dist > self.dict_size) break;

            // Compare bytes
            const max_len = @min(MAX_MATCH, @as(u32, @intCast(self.data.len - pos)));
            var len: u32 = 0;
            while (len < max_len and self.data[match_pos + len] == self.data[pos + len]) {
                len += 1;
            }

            if (len > best_len) {
                best_len = len;
                best_dist = dist - 1; // 0-based distance
                if (len == max_len) break;
            }

            cur = self.chain[match_pos];
        }

        if (best_len >= MIN_MATCH) {
            return .{ .distance = best_dist, .length = best_len };
        }
        return null;
    }

    /// Insert position into hash chain without searching.
    fn skip(self: *MatchFinder, pos: usize) void {
        if (pos + 2 >= self.data.len) return;
        const h = hash3(self.data, pos);
        self.chain[pos] = self.head[h];
        self.head[h] = @intCast(pos + 1);
    }
};

// ============================================================================
// LZMA1 Encoder
// ============================================================================

const NUM_STATES = 12;
const NUM_POS_STATES_MAX = 16; // 1 << pb_max(4)
const NUM_LEN_STATES = 4;
const END_MARKER_DIST: u32 = 0xFFFF_FFFF;

const LzmaEncoder = struct {
    // Properties
    lc: u3 = 3,
    lp: u2 = 0,
    pb: u2 = 2,

    // State
    state: u4 = 0,
    rep: [4]u32 = .{ 0, 0, 0, 0 },

    // Probability tables (all initialized to 0x400 = 1024)
    is_match: [NUM_STATES * NUM_POS_STATES_MAX]u16 = [_]u16{0x400} ** (NUM_STATES * NUM_POS_STATES_MAX),
    is_rep: [NUM_STATES]u16 = [_]u16{0x400} ** NUM_STATES,
    is_rep_g0: [NUM_STATES]u16 = [_]u16{0x400} ** NUM_STATES,
    is_rep_g1: [NUM_STATES]u16 = [_]u16{0x400} ** NUM_STATES,
    is_rep_g2: [NUM_STATES]u16 = [_]u16{0x400} ** NUM_STATES,
    is_rep_0long: [NUM_STATES * NUM_POS_STATES_MAX]u16 = [_]u16{0x400} ** (NUM_STATES * NUM_POS_STATES_MAX),

    // Literal probabilities
    literal_probs: []u16 = &.{},

    // Length encoders
    len_encoder: LenEncoder = .{},
    rep_len_encoder: LenEncoder = .{},

    // Distance encoding
    pos_slot_encoders: [NUM_LEN_STATES][64]u16 = [_][64]u16{[_]u16{0x400} ** 64} ** NUM_LEN_STATES,
    pos_encoders: [115]u16 = [_]u16{0x400} ** 115,
    align_encoder: [16]u16 = [_]u16{0x400} ** 16,

    // Range encoder
    rc: RangeEncoder = RangeEncoder.init(),

    fn init(lc: u3, lp: u2, pb: u2, allocator: std.mem.Allocator) !LzmaEncoder {
        const num_lit_contexts = @as(usize, 1) << (@as(u5, lc) + @as(u5, lp));
        const lit_probs = try allocator.alloc(u16, num_lit_contexts * 0x300);
        @memset(lit_probs, 0x400);

        return .{
            .lc = lc,
            .lp = lp,
            .pb = pb,
            .literal_probs = lit_probs,
        };
    }

    fn deinit(self: *LzmaEncoder, allocator: std.mem.Allocator) void {
        if (self.literal_probs.len > 0) {
            allocator.free(self.literal_probs);
        }
        self.rc.deinit(allocator);
    }

    fn getPropsBytes(self: *const LzmaEncoder) u8 {
        return self.lc + 9 * (@as(u8, self.lp) + 5 * @as(u8, self.pb));
    }

    // State transitions
    fn updateStateLiteral(self: *LzmaEncoder) void {
        self.state = if (self.state < 4) 0 else if (self.state < 10) self.state - 3 else self.state - 6;
    }

    fn updateStateMatch(self: *LzmaEncoder) void {
        self.state = if (self.state < 7) 7 else 10;
    }

    fn updateStateRep(self: *LzmaEncoder) void {
        self.state = if (self.state < 7) 8 else 11;
    }

    fn updateStateShortRep(self: *LzmaEncoder) void {
        self.state = if (self.state < 7) 9 else 11;
    }

    fn posState(self: *const LzmaEncoder, pos: usize) u4 {
        return @intCast(pos & ((@as(usize, 1) << @as(u5, self.pb)) - 1));
    }

    fn litState(self: *const LzmaEncoder, pos: usize, prev_byte: u8) usize {
        return ((@as(usize, pos) & ((@as(usize, 1) << @as(u5, self.lp)) - 1)) << @as(u5, self.lc)) +
            (@as(usize, prev_byte) >> @as(u5, 8 - @as(u5, self.lc)));
    }

    /// Encode a literal byte.
    fn encodeLiteral(self: *LzmaEncoder, cur_byte: u8, pos: usize, prev_byte: u8, match_byte: u8, allocator: std.mem.Allocator) !void {
        const ps = self.posState(pos);
        try self.rc.encodeBit(&self.is_match[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 0, allocator);

        const ls = self.litState(pos, prev_byte);
        const probs = self.literal_probs[ls * 0x300 .. (ls + 1) * 0x300];

        if (self.state >= 7) {
            // Match-literal encoding
            try self.encodeLiteralMatched(probs, cur_byte, match_byte, allocator);
        } else {
            // Simple literal encoding
            try self.encodeLiteralSimple(probs, cur_byte, allocator);
        }

        self.updateStateLiteral();
    }

    fn encodeLiteralSimple(self: *LzmaEncoder, probs: []u16, cur_byte: u8, allocator: std.mem.Allocator) !void {
        var symbol: u32 = 1;
        var i: u32 = 8;
        while (i > 0) {
            i -= 1;
            const bit: u1 = @intCast((cur_byte >> @intCast(i)) & 1);
            try self.rc.encodeBit(&probs[symbol], bit, allocator);
            symbol = (symbol << 1) | bit;
        }
    }

    fn encodeLiteralMatched(self: *LzmaEncoder, probs: []u16, cur_byte: u8, match_byte: u8, allocator: std.mem.Allocator) !void {
        var symbol: u32 = 1;
        var mb = match_byte;
        var i: u32 = 8;
        while (i > 0) {
            i -= 1;
            const match_bit: u32 = (mb >> 7) & 1;
            mb <<= 1;
            const bit: u1 = @intCast((cur_byte >> @intCast(i)) & 1);
            const ctx = ((1 + match_bit) << 8) + symbol;
            try self.rc.encodeBit(&probs[ctx], bit, allocator);
            symbol = (symbol << 1) | bit;
            if (match_bit != bit) {
                // Diverged from match byte — encode rest as simple
                while (i > 0) {
                    i -= 1;
                    const b: u1 = @intCast((cur_byte >> @intCast(i)) & 1);
                    try self.rc.encodeBit(&probs[symbol], b, allocator);
                    symbol = (symbol << 1) | b;
                }
                break;
            }
        }
    }

    /// Encode a match (new distance).
    fn encodeMatch(self: *LzmaEncoder, length: u32, dist: u32, pos: usize, allocator: std.mem.Allocator) !void {
        const ps = self.posState(pos);
        try self.rc.encodeBit(&self.is_match[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 1, allocator);
        try self.rc.encodeBit(&self.is_rep[self.state], 0, allocator);

        // Encode length (length - 2 is the raw value)
        try self.len_encoder.encode(&self.rc, length - 2, ps, allocator);

        // Encode distance
        try self.encodeDistance(dist, length, allocator);

        // Update rep distances
        self.rep[3] = self.rep[2];
        self.rep[2] = self.rep[1];
        self.rep[1] = self.rep[0];
        self.rep[0] = dist;

        self.updateStateMatch();
    }

    /// Encode a rep match (reuse existing distance).
    fn encodeRepMatch(self: *LzmaEncoder, rep_idx: u2, length: u32, pos: usize, allocator: std.mem.Allocator) !void {
        const ps = self.posState(pos);
        try self.rc.encodeBit(&self.is_match[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 1, allocator);
        try self.rc.encodeBit(&self.is_rep[self.state], 1, allocator);

        if (rep_idx == 0) {
            try self.rc.encodeBit(&self.is_rep_g0[self.state], 0, allocator);
            if (length == 1) {
                // Short rep
                try self.rc.encodeBit(&self.is_rep_0long[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 0, allocator);
                self.updateStateShortRep();
                return;
            } else {
                try self.rc.encodeBit(&self.is_rep_0long[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 1, allocator);
            }
        } else {
            try self.rc.encodeBit(&self.is_rep_g0[self.state], 1, allocator);
            if (rep_idx == 1) {
                try self.rc.encodeBit(&self.is_rep_g1[self.state], 0, allocator);
            } else {
                try self.rc.encodeBit(&self.is_rep_g1[self.state], 1, allocator);
                if (rep_idx == 2) {
                    try self.rc.encodeBit(&self.is_rep_g2[self.state], 0, allocator);
                } else {
                    try self.rc.encodeBit(&self.is_rep_g2[self.state], 1, allocator);
                }
            }
            // Rotate rep array
            const dist = self.rep[rep_idx];
            var i: usize = rep_idx;
            while (i > 0) : (i -= 1) {
                self.rep[i] = self.rep[i - 1];
            }
            self.rep[0] = dist;
        }

        // Encode length (length - 2 is the raw value)
        try self.rep_len_encoder.encode(&self.rc, length - 2, ps, allocator);

        self.updateStateRep();
    }

    fn encodeDistance(self: *LzmaEncoder, dist: u32, length: u32, allocator: std.mem.Allocator) !void {
        const len_state: usize = @min(length - 2, NUM_LEN_STATES - 1);

        // Determine pos_slot
        const pos_slot = getPosSlot(dist);

        try self.rc.encodeBitTree(&self.pos_slot_encoders[len_state], 6, pos_slot, allocator);

        if (pos_slot >= 4) {
            const num_direct_bits: u5 = @intCast((pos_slot >> 1) - 1);
            const base = (2 | (pos_slot & 1)) << num_direct_bits;
            const remainder = dist - base;

            if (pos_slot < 14) {
                // Use reverse bit tree with pos_encoders
                const offset = base - pos_slot;
                try self.rc.encodeReverseBitTree(self.pos_encoders[offset..], num_direct_bits, remainder, allocator);
            } else {
                // Direct bits for middle portion, align bits for bottom 4
                try self.rc.encodeDirectBits(remainder >> 4, num_direct_bits - 4, allocator);
                try self.rc.encodeReverseBitTree(&self.align_encoder, 4, remainder & 0xF, allocator);
            }
        }
    }

    /// Encode end-of-stream marker.
    fn encodeEndMarker(self: *LzmaEncoder, pos: usize, allocator: std.mem.Allocator) !void {
        const ps = self.posState(pos);
        try self.rc.encodeBit(&self.is_match[@as(usize, self.state) * NUM_POS_STATES_MAX + ps], 1, allocator);
        try self.rc.encodeBit(&self.is_rep[self.state], 0, allocator);

        // Length = 0 (minimum, raw value)
        try self.len_encoder.encode(&self.rc, 0, ps, allocator);

        // Distance = 0xFFFFFFFF → pos_slot = 63, all bits 1
        try self.rc.encodeBitTree(&self.pos_slot_encoders[0], 6, 63, allocator);
        // pos_slot=63: num_direct_bits = 30
        // Direct bits: 26 bits of 1s
        try self.rc.encodeDirectBits(0x3FF_FFFF, 26, allocator);
        // Align bits: 4 bits of 1s
        try self.rc.encodeReverseBitTree(&self.align_encoder, 4, 0xF, allocator);
    }
};

fn getPosSlot(dist: u32) u32 {
    if (dist < 4) return dist;
    const msb = 31 - @as(u5, @intCast(@clz(dist)));
    return @as(u32, msb) * 2 + ((dist >> @intCast(msb - 1)) & 1);
}

// ============================================================================
// Length Encoder
// ============================================================================

const LenEncoder = struct {
    choice: u16 = 0x400,
    choice2: u16 = 0x400,
    low: [NUM_POS_STATES_MAX][8]u16 = [_][8]u16{[_]u16{0x400} ** 8} ** NUM_POS_STATES_MAX,
    mid: [NUM_POS_STATES_MAX][8]u16 = [_][8]u16{[_]u16{0x400} ** 8} ** NUM_POS_STATES_MAX,
    high: [256]u16 = [_]u16{0x400} ** 256,

    /// Encode a length value (0..271, which maps to actual length 2..273).
    fn encode(self: *LenEncoder, rc: *RangeEncoder, length: u32, pos_state: u4, allocator: std.mem.Allocator) !void {
        if (length < 8) {
            try rc.encodeBit(&self.choice, 0, allocator);
            try rc.encodeBitTree(&self.low[pos_state], 3, length, allocator);
        } else if (length < 16) {
            try rc.encodeBit(&self.choice, 1, allocator);
            try rc.encodeBit(&self.choice2, 0, allocator);
            try rc.encodeBitTree(&self.mid[pos_state], 3, length - 8, allocator);
        } else {
            try rc.encodeBit(&self.choice, 1, allocator);
            try rc.encodeBit(&self.choice2, 1, allocator);
            try rc.encodeBitTree(&self.high, 8, length - 16, allocator);
        }
    }
};

// ============================================================================
// LZMA2 Encoder (top-level)
// ============================================================================

/// Compress data using LZMA2 format.
/// Returns owned slice of LZMA2-compressed bytes.
pub fn compress(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (data.len == 0) {
        // Empty data: just end marker
        const result = try allocator.alloc(u8, 1);
        result[0] = 0x00; // end of stream
        return result;
    }

    // Use conservative properties for broad compatibility
    const lc: u3 = 3;
    const lp: u2 = 0;
    const pb: u2 = 2;
    const dict_size: u32 = @min(@as(u32, @intCast(@min(data.len, 0xFFFFFFFF))), 1 << 24); // up to 16MB

    // For data that might produce LZMA1 output > 65536 bytes (the LZMA2
    // packed size limit), use chunked compression with adaptive chunk sizing.
    if (data.len > 0x10000) {
        return compressChunked(data, lc, lp, pb, dict_size, allocator);
    }

    // Small data: compress as single LZMA2 chunk
    const lzma_data = try compressLzma1(data, lc, lp, pb, dict_size, allocator);
    defer allocator.free(lzma_data);

    // Build LZMA2 output
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    if (lzma_data.len >= data.len) {
        // LZMA didn't help — emit uncompressed chunk
        const control: u8 = 0x01; // uncompressed with reset
        try output.append(allocator, control);
        const size_m1: u16 = @intCast(data.len - 1);
        try output.append(allocator, @intCast(size_m1 >> 8));
        try output.append(allocator, @intCast(size_m1 & 0xFF));
        try output.appendSlice(allocator, data);
    } else {
        // Control byte: bit7=1, bits6-5=11 (full reset), bits4-0=high 5 of unpack size
        const unpack_size_m1: u32 = @intCast(data.len - 1);
        const control: u8 = 0x80 | (3 << 5) | @as(u8, @intCast((unpack_size_m1 >> 16) & 0x1F));
        try output.append(allocator, control);

        // Unpacked size low 16 bits (big-endian)
        try output.append(allocator, @intCast((unpack_size_m1 >> 8) & 0xFF));
        try output.append(allocator, @intCast(unpack_size_m1 & 0xFF));

        // Packed size - 1, big-endian u16
        const pack_size_m1: u16 = @intCast(lzma_data.len - 1);
        try output.append(allocator, @intCast(pack_size_m1 >> 8));
        try output.append(allocator, @intCast(pack_size_m1 & 0xFF));

        // Properties byte
        try output.append(allocator, @as(u8, lc) + 9 * (@as(u8, lp) + 5 * @as(u8, pb)));

        // LZMA data (already includes range coder init)
        try output.appendSlice(allocator, lzma_data);
    }

    // End of stream marker
    try output.append(allocator, 0x00);

    return try allocator.dupe(u8, output.items);
}

/// Compress data in multiple LZMA2 chunks for large inputs.
fn compressChunked(data: []const u8, lc: u3, lp: u2, pb: u2, dict_size: u32, allocator: std.mem.Allocator) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(allocator);

    // Start with 64KB chunks — small enough that LZMA1 output typically
    // fits in the 65536-byte LZMA2 packed size limit.
    const initial_chunk_size: usize = 0x10000; // 64KB
    var offset: usize = 0;

    while (offset < data.len) {
        var chunk_size = initial_chunk_size;
        var compressed = false;

        // Try to compress, reducing chunk size if LZMA1 output > 65536
        while (chunk_size >= 1024) {
            const this_chunk = @min(chunk_size, data.len - offset);
            const chunk_data = data[offset .. offset + this_chunk];

            const lzma_data = try compressLzma1(chunk_data, lc, lp, pb, dict_size, allocator);

            if (lzma_data.len <= 65536 and lzma_data.len < chunk_data.len) {
                // Compressed chunk fits — emit it
                // Full reset for every chunk since each is compressed independently
                const reset_mode: u2 = 3;
                const unpack_size_m1: u32 = @intCast(this_chunk - 1);
                const control: u8 = 0x80 | (@as(u8, reset_mode) << 5) | @as(u8, @intCast((unpack_size_m1 >> 16) & 0x1F));
                try output.append(allocator, control);

                try output.append(allocator, @intCast((unpack_size_m1 >> 8) & 0xFF));
                try output.append(allocator, @intCast(unpack_size_m1 & 0xFF));

                const pack_size_m1: u16 = @intCast(lzma_data.len - 1);
                try output.append(allocator, @intCast(pack_size_m1 >> 8));
                try output.append(allocator, @intCast(pack_size_m1 & 0xFF));

                try output.append(allocator, @as(u8, lc) + 9 * (@as(u8, lp) + 5 * @as(u8, pb)));
                try output.appendSlice(allocator, lzma_data);

                allocator.free(lzma_data);
                offset += this_chunk;
                compressed = true;
                break;
            }

            allocator.free(lzma_data);

            // LZMA output too large or didn't compress — try smaller chunk
            chunk_size /= 2;
        }

        if (!compressed) {
            // Even small chunks don't compress — emit uncompressed
            const this_chunk = @min(@as(usize, 65536), data.len - offset);
            const control: u8 = 0x01; // uncompressed with dictionary reset
            try output.append(allocator, control);
            const size_m1: u16 = @intCast(this_chunk - 1);
            try output.append(allocator, @intCast(size_m1 >> 8));
            try output.append(allocator, @intCast(size_m1 & 0xFF));
            try output.appendSlice(allocator, data[offset .. offset + this_chunk]);
            offset += this_chunk;
        }
    }

    try output.append(allocator, 0x00); // end of stream
    return try allocator.dupe(u8, output.items);
}

/// Compress a block of data using LZMA1.
/// Returns the raw LZMA1 compressed bytes (5-byte range coder init + compressed data).
/// Does NOT include the 13-byte standalone LZMA header.
fn compressLzma1(data: []const u8, lc: u3, lp: u2, pb: u2, dict_size: u32, allocator: std.mem.Allocator) ![]u8 {
    var enc = try LzmaEncoder.init(lc, lp, pb, allocator);
    defer enc.deinit(allocator);

    var mf = try MatchFinder.init(data, dict_size, allocator);
    defer mf.deinit(allocator);

    var pos: usize = 0;
    const prev_byte = blk: {
        _ = &pos;
        break :blk @as(u8, 0);
    };
    _ = prev_byte;

    while (pos < data.len) {
        const cur_byte = data[pos];
        const pb_val: u8 = if (pos > 0) data[pos - 1] else 0;

        // Check for rep matches first
        const rep_match = findRepMatch(&enc, data, pos);

        // Find a new match
        const new_match = mf.findMatch(pos);

        if (rep_match) |rm| {
            if (new_match) |nm| {
                // Prefer the longer match
                if (nm.length > rm.length + 1) {
                    // New match is significantly better
                    try enc.encodeMatch(nm.length, nm.distance, pos, allocator);
                    var skip_i: usize = 1;
                    while (skip_i < nm.length) : (skip_i += 1) {
                        mf.skip(pos + skip_i);
                    }
                    pos += nm.length;
                } else {
                    // Rep match is good enough
                    if (rm.length == 1) {
                        try enc.encodeRepMatch(rm.rep_idx, 1, pos, allocator);
                    } else {
                        try enc.encodeRepMatch(rm.rep_idx, rm.length, pos, allocator);
                    }
                    var skip_i: usize = 1;
                    while (skip_i < rm.length) : (skip_i += 1) {
                        mf.skip(pos + skip_i);
                    }
                    pos += rm.length;
                }
            } else {
                // Only rep match available
                if (rm.length == 1) {
                    try enc.encodeRepMatch(rm.rep_idx, 1, pos, allocator);
                } else {
                    try enc.encodeRepMatch(rm.rep_idx, rm.length, pos, allocator);
                }
                var skip_i: usize = 1;
                while (skip_i < rm.length) : (skip_i += 1) {
                    mf.skip(pos + skip_i);
                }
                pos += rm.length;
            }
        } else if (new_match) |nm| {
            // Only new match available
            if (nm.length >= 2) {
                try enc.encodeMatch(nm.length, nm.distance, pos, allocator);
                var skip_i: usize = 1;
                while (skip_i < nm.length) : (skip_i += 1) {
                    mf.skip(pos + skip_i);
                }
                pos += nm.length;
            } else {
                // Match too short, encode as literal
                const match_byte: u8 = if (enc.state >= 7 and enc.rep[0] < pos) data[pos - enc.rep[0] - 1] else 0;
                try enc.encodeLiteral(cur_byte, pos, pb_val, match_byte, allocator);
                pos += 1;
            }
        } else {
            // No match — encode literal
            const match_byte: u8 = if (enc.state >= 7 and enc.rep[0] < pos) data[pos - enc.rep[0] - 1] else 0;
            try enc.encodeLiteral(cur_byte, pos, pb_val, match_byte, allocator);
            pos += 1;
        }
    }

    // Flush range encoder
    try enc.rc.flush(allocator);

    return try allocator.dupe(u8, enc.rc.getOutput());
}

const RepMatch = struct {
    rep_idx: u2,
    length: u32,
};

fn findRepMatch(enc: *const LzmaEncoder, data: []const u8, pos: usize) ?RepMatch {
    var best_idx: u2 = 0;
    var best_len: u32 = 0;

    for (0..4) |i| {
        const dist = enc.rep[i];
        if (dist >= pos) continue; // can't look back past start

        const match_pos = pos - dist - 1;
        if (match_pos >= data.len) continue;

        var len: u32 = 0;
        const max_len: u32 = @min(MAX_MATCH, @as(u32, @intCast(data.len - pos)));
        while (len < max_len and data[match_pos + len] == data[pos + len]) {
            len += 1;
        }

        // rep[0] can match length 1 (ShortRep), rep[1..3] need length >= 2
        const min_len: u32 = if (i == 0) 1 else 2;
        if (len >= min_len and len > best_len) {
            best_len = len;
            best_idx = @intCast(i);
        }
    }

    if (best_len >= 1) {
        return .{ .rep_idx = best_idx, .length = best_len };
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "lzma1 raw: encode single byte roundtrip" {
    const allocator = std.testing.allocator;
    const input = "A";
    const lzma_data = try compressLzma1(input, 3, 0, 2, 4096, allocator);
    defer allocator.free(lzma_data);

    // First byte must be 0x00 (range coder reserved byte)
    try std.testing.expectEqual(@as(u8, 0x00), lzma_data[0]);

    // Build standalone LZMA stream and verify roundtrip
    var stream_buf: [256]u8 = undefined;
    stream_buf[0] = 93; // props: lc=3 + 9*(lp=0 + 5*pb=2) = 93
    std.mem.writeInt(u32, stream_buf[1..5], 4096, .little);
    std.mem.writeInt(u64, stream_buf[5..13], 1, .little);
    @memcpy(stream_buf[13 .. 13 + lzma_data.len], lzma_data);

    var in_stream = std.io.fixedBufferStream(stream_buf[0 .. 13 + lzma_data.len]);
    var decomp = try std.compress.lzma.decompress(allocator, in_stream.reader());
    defer decomp.deinit();
    var out_buf: [64]u8 = undefined;
    const n = decomp.reader().readAll(&out_buf) catch return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A", out_buf[0..n]);
}

test "lzma2 encoder: empty data" {
    const allocator = std.testing.allocator;
    const result = try compress(&.{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 0x00), result[0]); // end marker
}

test "lzma2 encoder: roundtrip small data" {
    const allocator = std.testing.allocator;
    const input = "hello world";
    const compressed = try compress(input, allocator);
    defer allocator.free(compressed);

    // Decompress using stdlib decoder
    var in_stream = std.io.fixedBufferStream(compressed);
    var out_buf: [1024]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    try std.compress.lzma2.decompress(allocator, in_stream.reader(), out_stream.writer());
    try std.testing.expectEqualStrings(input, out_stream.getWritten());
}

test "lzma2 encoder: roundtrip repetitive data" {
    const allocator = std.testing.allocator;
    const input = "ABCDEFGHIJ" ** 50;
    const compressed = try compress(input, allocator);
    defer allocator.free(compressed);

    // Should actually compress
    try std.testing.expect(compressed.len < input.len);

    // Verify roundtrip
    var in_stream = std.io.fixedBufferStream(compressed);
    var out_buf: [1024]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    try std.compress.lzma2.decompress(allocator, in_stream.reader(), out_stream.writer());
    try std.testing.expectEqualStrings(input, out_stream.getWritten());
}

test "lzma2 encoder: roundtrip varied text with matches" {
    const allocator = std.testing.allocator;
    // This specific input triggers match/rep-match encoding paths
    // that previously produced data 7zz couldn't decode.
    const input = "quick the jumps fox fox brown quick and quick cat lazy";
    const compressed = try compress(input, allocator);
    defer allocator.free(compressed);

    var in_stream = std.io.fixedBufferStream(compressed);
    var out_buf: [256]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    try std.compress.lzma2.decompress(allocator, in_stream.reader(), out_stream.writer());
    try std.testing.expectEqualStrings(input, out_stream.getWritten());
}

test "lzma2 encoder: roundtrip binary data" {
    const allocator = std.testing.allocator;
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast(i);
    }
    const compressed = try compress(&input, allocator);
    defer allocator.free(compressed);

    var in_stream = std.io.fixedBufferStream(compressed);
    var out_buf: [512]u8 = undefined;
    var out_stream = std.io.fixedBufferStream(&out_buf);
    try std.compress.lzma2.decompress(allocator, in_stream.reader(), out_stream.writer());
    try std.testing.expectEqualSlices(u8, &input, out_stream.getWritten());
}

test "pos_slot calculation" {
    // slot 0-3 map directly to dist 0-3
    try std.testing.expectEqual(@as(u32, 0), getPosSlot(0));
    try std.testing.expectEqual(@as(u32, 1), getPosSlot(1));
    try std.testing.expectEqual(@as(u32, 2), getPosSlot(2));
    try std.testing.expectEqual(@as(u32, 3), getPosSlot(3));
    // slot 4: base=4, 1 direct bit, range 4-5
    try std.testing.expectEqual(@as(u32, 4), getPosSlot(4));
    try std.testing.expectEqual(@as(u32, 4), getPosSlot(5));
    // slot 5: base=6, 1 direct bit, range 6-7
    try std.testing.expectEqual(@as(u32, 5), getPosSlot(6));
    try std.testing.expectEqual(@as(u32, 5), getPosSlot(7));
    // slot 6: base=8, 2 direct bits, range 8-11
    try std.testing.expectEqual(@as(u32, 6), getPosSlot(8));
    try std.testing.expectEqual(@as(u32, 6), getPosSlot(11));
    // slot 7: base=12, 2 direct bits, range 12-15
    try std.testing.expectEqual(@as(u32, 7), getPosSlot(12));
    try std.testing.expectEqual(@as(u32, 7), getPosSlot(15));
    // slot 8: base=16, 3 direct bits, range 16-23
    try std.testing.expectEqual(@as(u32, 8), getPosSlot(16));
    try std.testing.expectEqual(@as(u32, 8), getPosSlot(23));
}
