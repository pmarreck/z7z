//! LZMA2 encoder — cleanroom implementation.
//!
//! Implements LZMA2 compression wrapping LZMA1 with range coding
//! and LZ77 match finding. Designed from the public LZMA specification
//! and by studying the Zig stdlib decoder (MIT licensed).

const std = @import("std");
const ProgressContext = @import("progress.zig").ProgressContext;

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
    output: std.ArrayListUnmanaged(u8) = .empty,

    fn init() RangeEncoder {
        return .{};
    }

    fn deinit(self: *RangeEncoder, allocator: std.mem.Allocator) void {
        self.output.deinit(allocator);
    }

    /// Reset the range encoder for a new LZMA2 chunk, keeping state in the
    /// parent LzmaEncoder but starting a fresh bitstream.
    fn resetForNewChunk(self: *RangeEncoder) void {
        self.output.clearRetainingCapacity();
        self.low = 0;
        self.range = 0xFFFF_FFFF;
        self.cache_size = 1;
        self.cache = 0;
    }

    fn shiftLow(self: *RangeEncoder, allocator: std.mem.Allocator) !void {
        const low32 = @as(u32, @truncate(self.low));
        const carry: u8 = @intCast(self.low >> 32);
        if (low32 < 0xFF00_0000 or carry != 0) {
            const cs = self.cache_size;
            // Pre-allocate capacity for all bytes we're about to emit,
            // avoiding per-byte capacity checks in the hot loop.
            try self.output.ensureUnusedCapacity(allocator, cs);
            self.output.appendAssumeCapacity(self.cache +% carry);
            var remaining = cs - 1;
            const fill: u8 = 0xFF +% carry;
            while (remaining > 0) : (remaining -= 1) {
                self.output.appendAssumeCapacity(fill);
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
// LZ77 Match Finder (Binary Tree — BT4)
// ============================================================================

const HASH_BITS = 20;
const HASH_SIZE = 1 << HASH_BITS;
const HASH2_SIZE = 1 << 16; // 65536 — perfect hash for 2-byte keys
const HASH3_BITS = 18;
const HASH3_SIZE = 1 << HASH3_BITS; // 262144
const MIN_MATCH = 2;
const MAX_MATCH = 273;
// Number of distinct match lengths (MIN_MATCH..MAX_MATCH), i.e. the size of the
// per-pos-state length price tables. Indexed by (length - MIN_MATCH).
const NUM_LEN_PRICE_SLOTS = MAX_MATCH - MIN_MATCH + 1;

const Match = struct {
    distance: u32, // 0-based distance (rep format)
    length: u32,
};

/// Binary tree match finder (BT4). At each position, simultaneously inserts
/// into a binary search tree (keyed by lexicographic order of suffixes) and
/// finds all matches. The tree structure avoids re-comparing bytes already
/// known to match, giving O(depth) comparisons per position with each
/// comparison starting from a known common prefix.
const MatchFinder = struct {
    hash: []u32, // 4-byte hash table -> most recent pos+1 (0 = empty)
    hash2: []u32, // 2-byte hash table (perfect hash, 65536 entries)
    hash3: []u32, // 3-byte hash table (262144 entries)
    bt_left: []u32, // left child array (circular, indexed by pos & bt_mask)
    bt_right: []u32, // right child array (circular, indexed by pos & bt_mask)
    data: []const u8,
    dict_size: u32,
    nice_len: u32,
    bt_mask: usize, // bt_size - 1, for fast modular indexing

    const BT_DEPTH: u32 = 32;
    const DEFAULT_NICE_LEN: u32 = 128;

    fn init(data: []const u8, dict_size: u32, nice_len_param: u32, allocator: std.mem.Allocator) !MatchFinder {
        const hash = try allocator.alloc(u32, HASH_SIZE);
        errdefer allocator.free(hash);
        @memset(hash, 0);
        const hash2 = try allocator.alloc(u32, HASH2_SIZE);
        errdefer allocator.free(hash2);
        @memset(hash2, 0);
        const hash3 = try allocator.alloc(u32, HASH3_SIZE);
        errdefer allocator.free(hash3);
        @memset(hash3, 0);
        // Sliding window: bt arrays only need dict_size entries (not data.len).
        // This reduces memory from O(data.len) to O(dict_size) — critical for
        // large inputs where data.len >> dict_size (e.g. 1.5GB block with 8MB dict
        // saves ~12GB per block). Round up to power of 2 for fast bitmask indexing.
        const raw_bt_size: usize = @min(data.len, @as(usize, dict_size));
        const bt_size: usize = if (raw_bt_size == 0) 1 else std.math.ceilPowerOfTwo(usize, raw_bt_size) catch raw_bt_size;
        const bt_left = try allocator.alloc(u32, bt_size);
        errdefer allocator.free(bt_left);
        @memset(bt_left, 0);
        const bt_right = try allocator.alloc(u32, bt_size);
        @memset(bt_right, 0);
        return .{
            .hash = hash,
            .hash2 = hash2,
            .hash3 = hash3,
            .bt_left = bt_left,
            .bt_right = bt_right,
            .data = data,
            .dict_size = dict_size,
            .nice_len = nice_len_param,
            .bt_mask = bt_size - 1,
        };
    }

    fn deinit(self: *MatchFinder, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.hash2);
        allocator.free(self.hash3);
        allocator.free(self.bt_left);
        allocator.free(self.bt_right);
    }

    // Word-at-a-time string comparison: extends `common` to the first
    // differing byte between data[a+common..] and data[b+common..],
    // up to max_len. Uses u64 XOR + @ctz to process 8 bytes per iteration.
    fn extendMatch(data: []const u8, a: usize, b: usize, start: u32, max_len: u32) u32 {
        var common = start;
        // u64 fast path: compare 8 bytes at a time
        while (common + 8 <= max_len) {
            const va = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(data.ptr + a + common)), .little);
            const vb = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(data.ptr + b + common)), .little);
            const diff = va ^ vb;
            if (diff != 0) {
                return common + @as(u32, @intCast(@ctz(diff) >> 3));
            }
            common += 8;
        }
        // Byte-by-byte tail
        while (common < max_len and data[a + common] == data[b + common]) {
            common += 1;
        }
        return common;
    }

    fn hash2val(data: []const u8, pos: usize) u32 {
        return std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data.ptr + pos)), .little);
    }

    fn hash3val(data: []const u8, pos: usize) u32 {
        // Load 2 bytes + 1 byte: use a u16 read + separate byte to avoid unaligned u32
        const lo: u32 = std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(data.ptr + pos)), .little);
        const hi: u32 = data[pos + 2];
        return ((hi << 16) | lo) *% 0x56A3B17D >> (32 - HASH3_BITS);
    }

    fn hash4(data: []const u8, pos: usize) u32 {
        if (pos + 3 >= data.len) return 0;
        const v = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data.ptr + pos)), .little);
        return (v *% 0x9E3779B1) >> (32 - HASH_BITS);
    }

    /// Find the single best (longest) match. Used by compressLzma1 for small files.
    fn findMatch(self: *MatchFinder, pos: usize) ?Match {
        const candidates = self.findMatches(pos);
        if (candidates.count > 0) {
            return candidates.items[candidates.count - 1];
        }
        return null;
    }

    /// Insert position into the binary tree and find all matches.
    /// Returns matches sorted by increasing length; each entry has the
    /// closest distance for that length level. The binary tree walk
    /// avoids re-comparing known-matching prefix bytes.
    fn findMatches(self: *MatchFinder, pos: usize) MatchCandidates {
        var candidates = MatchCandidates{};
        if (pos + 3 >= self.data.len) return candidates;

        // --- HC2: 2-byte hash lookup ---
        const h2 = hash2val(self.data, pos);
        const h2_prev = self.hash2[h2];
        self.hash2[h2] = @intCast(pos + 1);

        // --- HC3: 3-byte hash lookup ---
        const h3 = hash3val(self.data, pos);
        const h3_prev = self.hash3[h3];
        self.hash3[h3] = @intCast(pos + 1);

        var best_len: u32 = MIN_MATCH - 1;

        // Check 2-byte match
        if (h2_prev > 0) {
            const mp2 = h2_prev - 1;
            if (pos > mp2) {
                const d2 = @as(u32, @intCast(pos - mp2));
                if (d2 <= self.dict_size and self.data[mp2] == self.data[pos] and self.data[mp2 + 1] == self.data[pos + 1]) {
                    candidates.add(.{ .distance = d2 - 1, .length = 2 });
                    best_len = 2;
                }
            }
        }

        // Check 3-byte match
        if (h3_prev > 0) {
            const mp3 = h3_prev - 1;
            if (pos > mp3) {
                const d3 = @as(u32, @intCast(pos - mp3));
                if (d3 <= self.dict_size and self.data[mp3] == self.data[pos] and self.data[mp3 + 1] == self.data[pos + 1] and self.data[mp3 + 2] == self.data[pos + 2]) {
                    // Extend to find actual match length
                    const max_len = @min(MAX_MATCH, @as(u32, @intCast(self.data.len - pos)));
                    const actual_len = extendMatch(self.data, pos, mp3, 3, max_len);
                    if (actual_len > best_len) {
                        candidates.add(.{ .distance = d3 - 1, .length = actual_len });
                        best_len = actual_len;
                    }
                }
            }
        }

        // Early-out for incompressible data: if neither HC2 nor HC3 found
        // any match, skip the expensive BT4 tree walk. Still insert into
        // hash4 and initialize tree nodes so future lookups work.
        if (best_len < MIN_MATCH) {
            const h = hash4(self.data, pos);
            const cur = self.hash[h];
            self.hash[h] = @intCast(pos + 1);
            // Graft the existing chain onto this node (minimal tree maintenance)
            self.bt_left[pos & self.bt_mask] = cur;
            self.bt_right[pos & self.bt_mask] = 0;
            return candidates;
        }

        // --- BT4: binary tree match finding ---
        // Adaptive depth: if HC3 missed (only HC2 found a 2-byte match),
        // use a shallow tree walk. On incompressible data, 3-byte hash
        // misses are frequent and deep BT4 walks find nothing useful.
        const effective_depth: u32 = if (best_len <= 2) 2 else BT_DEPTH;
        const h = hash4(self.data, pos);
        var cur = self.hash[h];
        self.hash[h] = @intCast(pos + 1);

        var left_ptr = &self.bt_left[pos & self.bt_mask];
        var right_ptr = &self.bt_right[pos & self.bt_mask];
        var best_left_len: u32 = 0;
        var best_right_len: u32 = 0;
        var depth: u32 = 0;

        while (cur > 0 and depth < effective_depth) : (depth += 1) {
            const match_pos = cur - 1;
            if (pos <= match_pos) break;
            const dist = @as(u32, @intCast(pos - match_pos));
            if (dist > self.dict_size) break;

            const max_len = @min(MAX_MATCH, @as(u32, @intCast(self.data.len - pos)));
            const common = extendMatch(self.data, pos, match_pos, @min(best_left_len, best_right_len), max_len);

            if (common > best_len) {
                candidates.add(.{ .distance = dist - 1, .length = common });
                best_len = common;
                // Early exit: max_len reached OR match is "nice enough"
                if (common >= max_len or common >= self.nice_len) {
                    left_ptr.* = self.bt_left[match_pos & self.bt_mask];
                    right_ptr.* = self.bt_right[match_pos & self.bt_mask];
                    return candidates;
                }
            }

            if (common < max_len and self.data[pos + common] < self.data[match_pos + common]) {
                right_ptr.* = cur;
                right_ptr = &self.bt_left[match_pos & self.bt_mask];
                cur = self.bt_left[match_pos & self.bt_mask];
                best_right_len = common;
            } else {
                left_ptr.* = cur;
                left_ptr = &self.bt_right[match_pos & self.bt_mask];
                cur = self.bt_right[match_pos & self.bt_mask];
                best_left_len = common;
            }
        }

        left_ptr.* = 0;
        right_ptr.* = 0;
        return candidates;
    }

    /// Lightweight skip: update only HC2+HC3 hash tables, leave BT4 tree    /// completely untouched. Skipped positions are findable via short-match
    /// hashes but don't disrupt the binary tree structure at all.
    fn skip(self: *MatchFinder, pos: usize) void {
        if (pos + 1 >= self.data.len) return;
        self.hash2[hash2val(self.data, pos)] = @intCast(pos + 1);
        if (pos + 2 < self.data.len) {
            self.hash3[hash3val(self.data, pos)] = @intCast(pos + 1);
        }
    }
};

const MAX_MATCH_CANDIDATES = 32;
const MatchCandidates = struct {
    items: [MAX_MATCH_CANDIDATES]Match = undefined,
    count: u32 = 0,

    fn add(self: *MatchCandidates, m: Match) void {
        if (self.count < MAX_MATCH_CANDIDATES) {
            self.items[self.count] = m;
            self.count += 1;
        }
    }

    fn slice(self: *const MatchCandidates) []const Match {
        return self.items[0..self.count];
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

    /// Reset all mutable LZMA state to initial values.
    /// Used when the decoder will also reset (reset_mode >= 1) or when
    /// a chunk was emitted uncompressed (decoder has no LZMA context).
    fn resetState(self: *LzmaEncoder) void {
        self.state = 0;
        self.rep = .{ 0, 0, 0, 0 };
        self.is_match = [_]u16{0x400} ** (NUM_STATES * NUM_POS_STATES_MAX);
        self.is_rep = [_]u16{0x400} ** NUM_STATES;
        self.is_rep_g0 = [_]u16{0x400} ** NUM_STATES;
        self.is_rep_g1 = [_]u16{0x400} ** NUM_STATES;
        self.is_rep_g2 = [_]u16{0x400} ** NUM_STATES;
        self.is_rep_0long = [_]u16{0x400} ** (NUM_STATES * NUM_POS_STATES_MAX);
        @memset(self.literal_probs, 0x400);
        self.len_encoder = .{};
        self.rep_len_encoder = .{};
        self.pos_slot_encoders = [_][64]u16{[_]u16{0x400} ** 64} ** NUM_LEN_STATES;
        self.pos_encoders = [_]u16{0x400} ** 115;
        self.align_encoder = [_]u16{0x400} ** 16;
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

    // --- Price estimation methods for optimal parsing ---

    fn priceLiteralAt(self: *const LzmaEncoder, cur_byte: u8, pos: usize, prev_byte: u8, match_byte: u8, state: u4) u32 {
        const ps: usize = pos & ((@as(usize, 1) << @as(u5, self.pb)) - 1);
        var price: u32 = probPrice0(self.is_match[@as(usize, state) * NUM_POS_STATES_MAX + ps]);
        const ls = ((@as(usize, pos) & ((@as(usize, 1) << @as(u5, self.lp)) - 1)) << @as(u5, self.lc)) +
            (@as(usize, prev_byte) >> @as(u5, 8 - @as(u5, self.lc)));
        const probs = self.literal_probs[ls * 0x300 .. (ls + 1) * 0x300];

        if (state >= 7) {
            var symbol: u32 = 1;
            var mb = match_byte;
            var bit_i: u32 = 8;
            while (bit_i > 0) {
                bit_i -= 1;
                const match_bit: u32 = (mb >> 7) & 1;
                mb <<= 1;
                const bit: u1 = @intCast((cur_byte >> @intCast(bit_i)) & 1);
                const ctx = ((1 + match_bit) << 8) + symbol;
                price += if (bit == 0) probPrice0(probs[ctx]) else probPrice1(probs[ctx]);
                symbol = (symbol << 1) | bit;
                if (match_bit != bit) {
                    while (bit_i > 0) {
                        bit_i -= 1;
                        const b: u1 = @intCast((cur_byte >> @intCast(bit_i)) & 1);
                        price += if (b == 0) probPrice0(probs[symbol]) else probPrice1(probs[symbol]);
                        symbol = (symbol << 1) | b;
                    }
                    break;
                }
            }
        } else {
            var symbol: u32 = 1;
            var bit_i: u32 = 8;
            while (bit_i > 0) {
                bit_i -= 1;
                const bit: u1 = @intCast((cur_byte >> @intCast(bit_i)) & 1);
                price += if (bit == 0) probPrice0(probs[symbol]) else probPrice1(probs[symbol]);
                symbol = (symbol << 1) | bit;
            }
        }
        return price;
    }

    fn priceMatchAt(self: *const LzmaEncoder, length: u32, dist: u32, pos: usize, state: u4) u32 {
        const ps: usize = pos & ((@as(usize, 1) << @as(u5, self.pb)) - 1);
        var price: u32 = 0;
        price += probPrice1(self.is_match[@as(usize, state) * NUM_POS_STATES_MAX + ps]);
        price += probPrice0(self.is_rep[state]);
        price += priceLenVal(&self.len_encoder, length - 2, @intCast(ps));
        price += self.priceDistAt(dist, length);
        return price;
    }

    fn priceRepMatchAt(self: *const LzmaEncoder, rep_idx: u2, length: u32, pos: usize, state: u4) u32 {
        const ps: usize = pos & ((@as(usize, 1) << @as(u5, self.pb)) - 1);
        var price: u32 = 0;
        price += probPrice1(self.is_match[@as(usize, state) * NUM_POS_STATES_MAX + ps]);
        price += probPrice1(self.is_rep[state]);

        if (rep_idx == 0) {
            price += probPrice0(self.is_rep_g0[state]);
            if (length == 1) {
                price += probPrice0(self.is_rep_0long[@as(usize, state) * NUM_POS_STATES_MAX + ps]);
            } else {
                price += probPrice1(self.is_rep_0long[@as(usize, state) * NUM_POS_STATES_MAX + ps]);
            }
        } else {
            price += probPrice1(self.is_rep_g0[state]);
            if (rep_idx == 1) {
                price += probPrice0(self.is_rep_g1[state]);
            } else {
                price += probPrice1(self.is_rep_g1[state]);
                if (rep_idx == 2) {
                    price += probPrice0(self.is_rep_g2[state]);
                } else {
                    price += probPrice1(self.is_rep_g2[state]);
                }
            }
        }

        if (length > 1) {
            price += priceLenVal(&self.rep_len_encoder, length - 2, @intCast(ps));
        }
        return price;
    }

    fn priceDistAt(self: *const LzmaEncoder, dist: u32, length: u32) u32 {
        const len_state: usize = @min(length - 2, NUM_LEN_STATES - 1);
        const pos_slot = getPosSlot(dist);
        var price = priceBitTreeVal(&self.pos_slot_encoders[len_state], 6, pos_slot);

        if (pos_slot >= 4) {
            const num_direct_bits: u5 = @intCast((pos_slot >> 1) - 1);
            const base = (2 | (pos_slot & 1)) << num_direct_bits;
            const remainder = dist - base;

            if (pos_slot < 14) {
                const offset = base - pos_slot;
                price += priceRevBitTree(self.pos_encoders[offset..], num_direct_bits, remainder);
            } else {
                price += @as(u32, num_direct_bits - 4) * (1 << PRICE_SHIFT);
                price += priceRevBitTree(&self.align_encoder, 4, remainder & 0xF);
            }
        }
        return price;
    }
};

fn priceLenVal(len_enc: *const LenEncoder, raw_length: u32, pos_state: u4) u32 {
    var price: u32 = 0;
    if (raw_length < 8) {
        price += probPrice0(len_enc.choice);
        price += priceBitTreeVal(&len_enc.low[pos_state], 3, raw_length);
    } else if (raw_length < 16) {
        price += probPrice1(len_enc.choice);
        price += probPrice0(len_enc.choice2);
        price += priceBitTreeVal(&len_enc.mid[pos_state], 3, raw_length - 8);
    } else {
        price += probPrice1(len_enc.choice);
        price += probPrice1(len_enc.choice2);
        price += priceBitTreeVal(&len_enc.high, 8, raw_length - 16);
    }
    return price;
}

fn getPosSlot(dist: u32) u32 {
    if (dist < 4) return dist;
    const msb = 31 - @as(u5, @intCast(@clz(dist)));
    return @as(u32, msb) * 2 + ((dist >> @intCast(msb - 1)) & 1);
}

// ============================================================================
// Price Estimation for Optimal Parsing
// ============================================================================

const PRICE_SHIFT: u32 = 4;
const INFINITY_PRICE: u32 = 0x0FFFFFFF;

/// Pre-computed probability → bit-price lookup table.
/// Comptime-const for thread safety — no runtime init needed.
const prob_prices: [128]u32 = computeProbPrices();

fn computeProbPrices() [128]u32 {
    @setEvalBranchQuota(10_000);
    var prices: [128]u32 = [_]u32{0} ** 128;
    for (0..128) |i| {
        var w: u32 = @as(u32, @intCast(i)) * 16 + 8;
        var bit_count: u32 = 0;
        for (0..PRICE_SHIFT) |_| {
            w = w * w;
            bit_count <<= 1;
            while (w >= (1 << 16)) {
                w >>= 1;
                bit_count += 1;
            }
        }
        prices[i] = (11 << PRICE_SHIFT) - 15 - bit_count;
    }
    return prices;
}

fn probPrice0(prob: u16) u32 {
    return prob_prices[prob >> 4];
}

fn probPrice1(prob: u16) u32 {
    return prob_prices[(@as(u32, 2048) - prob) >> 4];
}

fn priceBitTreeVal(probs: []const u16, num_bits: u5, value: u32) u32 {
    var price: u32 = 0;
    var idx: u32 = 1;
    var i = num_bits;
    while (i > 0) {
        i -= 1;
        const bit: u1 = @intCast((value >> i) & 1);
        price += if (bit == 0) probPrice0(probs[idx]) else probPrice1(probs[idx]);
        idx = (idx << 1) | bit;
    }
    return price;
}

fn priceRevBitTree(probs: []const u16, num_bits: u5, value: u32) u32 {
    var price: u32 = 0;
    var idx: u32 = 1;
    var val = value;
    for (0..num_bits) |_| {
        const bit: u1 = @intCast(val & 1);
        price += if (bit == 0) probPrice0(probs[idx]) else probPrice1(probs[idx]);
        idx = (idx << 1) | bit;
        val >>= 1;
    }
    return price;
}

fn nextStateLiteral(state: u4) u4 {
    if (state < 4) return 0;
    if (state < 10) return state - 3;
    return state - 6;
}

fn nextStateMatch(state: u4) u4 {
    return if (state < 7) 7 else 10;
}

fn nextStateRep(state: u4) u4 {
    return if (state < 7) 8 else 11;
}

fn nextStateShortRep(state: u4) u4 {
    return if (state < 7) 9 else 11;
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
/// Progress callback fires after each 64KB chunk (sequential) or block (parallel).
/// Compression level parameters: dict_size and nice_len for levels 0-9.
pub const LevelParams = struct {
    dict_size: u32,
    nice_len: u32,

    /// Map compression level (0-9) to dict_size + nice_len.
    /// Level 5 is the default, matching 7zz -mx=5 convention.
    pub fn fromLevel(level: u4) LevelParams {
        return switch (level) {
            0 => .{ .dict_size = 1 << 16, .nice_len = 8 }, // 64KB
            1 => .{ .dict_size = 1 << 18, .nice_len = 16 }, // 256KB
            2 => .{ .dict_size = 1 << 20, .nice_len = 24 }, // 1MB
            3 => .{ .dict_size = 1 << 21, .nice_len = 32 }, // 2MB
            4 => .{ .dict_size = 1 << 22, .nice_len = 48 }, // 4MB
            5 => .{ .dict_size = 1 << 23, .nice_len = 64 }, // 8MB (default)
            6 => .{ .dict_size = 1 << 24, .nice_len = 96 }, // 16MB
            7 => .{ .dict_size = 1 << 24, .nice_len = 128 }, // 16MB (previous default)
            8 => .{ .dict_size = 1 << 25, .nice_len = 192 }, // 32MB
            9 => .{ .dict_size = 1 << 26, .nice_len = 256 }, // 64MB
            else => .{ .dict_size = 1 << 23, .nice_len = 64 }, // fallback = level 5
        };
    }

    /// Default compression level (5).
    pub const DEFAULT_LEVEL: u4 = 5;
};

pub fn compress(data: []const u8, dict_size: u32, nice_len: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    return compressWithThreads(data, dict_size, nice_len, 0, progress, allocator);
}

/// Compress data to LZMA2 format with explicit thread count control.
/// thread_count: 0 = auto-detect, 1 = single-threaded, N = use N threads.
pub fn compressWithThreads(data: []const u8, dict_size: u32, nice_len: u32, thread_count: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
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
    // Clamp dict_size to data length (no point in bigger dict than data)
    const clamped_dict_size: u32 = @min(dict_size, @as(u32, @intCast(@min(data.len, 0xFFFFFFFF))));

    // Parallel compression for large inputs on multi-core machines
    // thread_count: 0 = auto, 1 = force single, N = use N threads
    const MIN_PARALLEL_SIZE = 1 << 20; // 1MB
    if (thread_count != 1 and data.len >= MIN_PARALLEL_SIZE) {
        const cpu_count: usize = if (thread_count > 0) @intCast(thread_count) else (std.Thread.getCpuCount() catch 1);
        if (cpu_count > 1) {
            const num_blocks = @min(cpu_count, data.len / MIN_PARALLEL_SIZE);
            if (num_blocks > 1) {
                return compressParallel(data, lc, lp, pb, clamped_dict_size, nice_len, num_blocks, progress, allocator);
            }
        }
    }

    // For data that might produce LZMA1 output > 65536 bytes (the LZMA2
    // packed size limit), use chunked compression with adaptive chunk sizing.
    if (data.len > 0x10000) {
        return compressChunked(data, lc, lp, pb, clamped_dict_size, nice_len, progress, allocator);
    }

    // Small data: compress as single LZMA2 chunk
    const lzma_data = try compressLzma1(data, lc, lp, pb, clamped_dict_size, nice_len, allocator);
    defer allocator.free(lzma_data);

    // Build LZMA2 output
    var output = std.ArrayListUnmanaged(u8).empty;
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

    progress.report(data.len, data.len);
    return try allocator.dupe(u8, output.items);
}

/// Compress data in multiple LZMA2 chunks with continuous LZMA state.
/// A single MatchFinder and LzmaEncoder span the entire input:
/// - Dictionary carries across chunks (cross-chunk match references)
/// - Probability tables carry across chunks (better adaptation)
/// - Only the range coder resets between chunks (as LZMA2 requires)
fn compressChunked(data: []const u8, lc: u3, lp: u2, pb: u2, dict_size: u32, nice_len: u32, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    var output = std.ArrayListUnmanaged(u8).empty;
    defer output.deinit(allocator);

    // Single match finder over the entire input
    var mf = try MatchFinder.init(data, dict_size, nice_len, allocator);
    defer mf.deinit(allocator);

    // Single LZMA encoder — state carries across all chunks
    var enc = try LzmaEncoder.init(lc, lp, pb, allocator);
    defer enc.deinit(allocator);

    const chunk_size: usize = 0x10000; // 64KB — constrained by LZMA2 packed size limit (16-bit)
    var offset: usize = 0;
    var dict_reset_done = false;
    var props_sent = false;
    var state_valid = false; // Whether encoder state matches what decoder would have

    while (offset < data.len) {
        const this_chunk = @min(chunk_size, data.len - offset);
        const chunk_end = offset + this_chunk;

        // === EXPERIMENTAL: Shannon entropy probe + adaptive nice_len ===
        //
        // Status: Kept but uncertain whether the benefit justifies the complexity.
        //
        // Idea: Measure per-chunk Shannon entropy H = -sum(p * log2(p)) to:
        //   1. Skip LZMA encoding entirely for near-random data (H >= 7.9)
        //   2. Tune MatchFinder.nice_len per-chunk based on data compressibility
        //
        // Results (2026-02-24 benchmarks):
        //   - text_1m/text_4m: no speed change, no compression change (good)
        //   - binary_1m: no change (incompressibility skip was already working)
        //   - gauss_1m: no improvement (DP optimal parser is the real bottleneck)
        //   - fake_tree: ~10% BETTER compression (50.2% vs 55.7%), ~10% slower
        //
        // Trade-off: One category benefits (mixed-file trees), others unchanged.
        //   Pro: better compression on heterogeneous real-world directory archives
        //   Con: added complexity (runtime nice_len, multi-window sampling, f64 math)
        //
        // Change sites (for rollback reference):
        //   1. MatchFinder struct: `nice_len` field + DEFAULT_NICE_LEN constant (~line 164)
        //   2. MatchFinder.init(): sets nice_len = DEFAULT_NICE_LEN (~line 188)
        //   3. findMatches(): uses self.nice_len instead of const NICE_LEN (~line 341)
        //   4. This block: Shannon entropy calculation + nice_len assignment (~line 1030)
        //   5. encodeLzma1ChunkOptimal(): reads mf.nice_len into local (~line 1421)
        //
        // To revert: restore NICE_LEN as comptime const, remove nice_len field,
        //   replace entropy probe with the simpler unique-byte-count check
        //   (threshold: unique >= 250 out of 256 in first 2KB).
        // ================================================================
        const probe_window: usize = 2048;
        const probe_len = @min(probe_window, this_chunk);
        if (probe_len >= 512) {
            // Sample up to 4 windows spread across the chunk
            const num_probes: usize = if (this_chunk >= probe_window * 4) 4 else if (this_chunk >= probe_window * 2) 2 else 1;
            var total_entropy: f64 = 0.0;

            for (0..num_probes) |probe_idx| {
                const probe_start = offset + (probe_idx * (this_chunk - probe_window)) / @max(num_probes - 1, 1);
                const plen = @min(probe_window, data.len - probe_start);

                var freq = [_]u32{0} ** 256;
                for (0..plen) |pi| {
                    freq[data[probe_start + pi]] += 1;
                }

                var entropy: f64 = 0.0;
                const n: f64 = @floatFromInt(plen);
                for (freq) |f| {
                    if (f > 0) {
                        const p: f64 = @as(f64, @floatFromInt(f)) / n;
                        entropy -= p * @log2(p);
                    }
                }
                total_entropy += entropy;
            }

            const avg_entropy = total_entropy / @as(f64, @floatFromInt(num_probes));

            // Adaptive nice_len based on entropy (ceiling is the level's nice_len):
            // - Low entropy (<4 bits/byte): highly compressible → use level's nice_len
            // - Medium entropy (4-6): moderately compressible → min(64, nice_len)
            // - High entropy (6-7.5): barely compressible → min(32, nice_len)
            // - Very high (>7.5): near-random → min(16, nice_len)
            mf.nice_len = if (avg_entropy < 4.0)
                nice_len
            else if (avg_entropy < 6.0)
                @min(nice_len, 64)
            else if (avg_entropy < 7.5)
                @min(nice_len, 32)
            else
                @min(nice_len, 16);

            if (avg_entropy >= 7.9) {
                // High entropy — but check if dictionary has cross-chunk matches.
                // Repeated blocks of random data ARE compressible via dictionary carry.
                // Probe a few positions: if HC3 finds verified 3-byte matches from
                // previous chunks, the data may compress despite high local entropy.
                var dict_hits: u32 = 0;
                const dict_probe = @min(@as(usize, 64), probe_len);
                for (0..dict_probe) |dpi| {
                    const p = offset + dpi;
                    if (p + 2 >= data.len) break;
                    const h3 = MatchFinder.hash3val(data, p);
                    const h3_prev = mf.hash3[h3];
                    if (h3_prev > 0) {
                        const mp3 = h3_prev - 1;
                        if (p > mp3 and p - mp3 <= mf.dict_size and
                            data[mp3] == data[p] and data[mp3 + 1] == data[p + 1] and data[mp3 + 2] == data[p + 2])
                        {
                            dict_hits += 1;
                        }
                    }
                }
                // If > 25% of probed positions have dictionary matches, don't skip
                if (dict_hits <= dict_probe / 4) {
                    // High entropy, no dictionary matches: skip LZMA encoding entirely.
                    // Update match finder hash tables for dictionary continuity.
                    for (offset..chunk_end) |p| {
                        mf.skip(p);
                    }
                    // Emit as uncompressed sub-chunks (LZMA2 size field is 16-bit)
                    var unc_off: usize = 0;
                    while (unc_off < this_chunk) {
                        const unc_len = @min(@as(usize, 0x10000), this_chunk - unc_off);
                        const unc_control: u8 = if (!dict_reset_done) 0x01 else 0x02;
                        try output.append(allocator, unc_control);
                        const size_m1: u16 = @intCast(unc_len - 1);
                        try output.append(allocator, @intCast(size_m1 >> 8));
                        try output.append(allocator, @intCast(size_m1 & 0xFF));
                        try output.appendSlice(allocator, data[offset + unc_off .. offset + unc_off + unc_len]);
                        dict_reset_done = true;
                        unc_off += unc_len;
                    }
                    state_valid = false;
                    enc.resetState();
                    offset = chunk_end;
                    progress.report(@intCast(offset), @intCast(data.len));
                    continue;
                }
            }
        }

        // Determine reset mode BEFORE encoding so we can sync encoder/decoder state:
        // - First ever: reset_mode=3 (dict + state + props)
        // - After uncompressed or first props: reset_mode=2 (state + props)
        // - After compressed (continuous state): reset_mode=0
        const reset_mode: u2 = if (!dict_reset_done) 3 else if (!props_sent or !state_valid) 2 else 0;

        // If resetting, sync encoder state with what decoder will have
        if (reset_mode >= 1) {
            enc.resetState();
        }

        // Reset range encoder for this chunk (always — each chunk has its own range stream)
        enc.rc.resetForNewChunk();

        // Encode this chunk using the shared encoder and match finder
        try encodeLzma1ChunkOptimal(&enc, &mf, data, offset, chunk_end, allocator);

        // Flush range encoder for this chunk
        try enc.rc.flush(allocator);
        const lzma_data = enc.rc.getOutput();

        if (lzma_data.len <= 65536 and lzma_data.len < this_chunk) {
            // Compressed chunk fits — emit it
            const unpack_size_m1: u32 = @intCast(this_chunk - 1);
            const control: u8 = 0x80 | (@as(u8, reset_mode) << 5) | @as(u8, @intCast((unpack_size_m1 >> 16) & 0x1F));
            try output.append(allocator, control);

            try output.append(allocator, @intCast((unpack_size_m1 >> 8) & 0xFF));
            try output.append(allocator, @intCast(unpack_size_m1 & 0xFF));

            const pack_size_m1: u16 = @intCast(lzma_data.len - 1);
            try output.append(allocator, @intCast(pack_size_m1 >> 8));
            try output.append(allocator, @intCast(pack_size_m1 & 0xFF));

            if (reset_mode >= 2) {
                try output.append(allocator, @as(u8, lc) + 9 * (@as(u8, lp) + 5 * @as(u8, pb)));
                props_sent = true;
            }

            try output.appendSlice(allocator, lzma_data);
            dict_reset_done = true;
            state_valid = true; // Decoder now has valid LZMA state from this chunk
        } else {
            // Uncompressed fallback — emit as 64KB sub-chunks (LZMA2 size field is 16-bit)
            var unc_off: usize = 0;
            while (unc_off < this_chunk) {
                const unc_len = @min(@as(usize, 0x10000), this_chunk - unc_off);
                const unc_control: u8 = if (!dict_reset_done) 0x01 else 0x02;
                try output.append(allocator, unc_control);
                const size_m1: u16 = @intCast(unc_len - 1);
                try output.append(allocator, @intCast(size_m1 >> 8));
                try output.append(allocator, @intCast(size_m1 & 0xFF));
                try output.appendSlice(allocator, data[offset + unc_off .. offset + unc_off + unc_len]);
                dict_reset_done = true;
                unc_off += unc_len;
            }
            state_valid = false;
            enc.resetState();
        }

        offset = chunk_end;
        progress.report(@intCast(offset), @intCast(data.len));
    }

    try output.append(allocator, 0x00); // end of stream
    return try allocator.dupe(u8, output.items);
}

/// Compress a single independent block of data into LZMA2 format.
/// Self-contained: creates its own MatchFinder and LzmaEncoder with full reset.
/// Returns owned LZMA2 byte stream including end marker.
fn compressBlock(block_data: []const u8, lc: u3, lp: u2, pb: u2, dict_size: u32, nice_len: u32, allocator: std.mem.Allocator) ![]u8 {
    if (block_data.len == 0) {
        const result = try allocator.alloc(u8, 1);
        result[0] = 0x00;
        return result;
    }

    // Small block: compress as single LZMA2 chunk (same path as compress())
    if (block_data.len <= 0x10000) {
        const lzma_data = try compressLzma1(block_data, lc, lp, pb, dict_size, nice_len, allocator);
        defer allocator.free(lzma_data);

        var output = std.ArrayListUnmanaged(u8).empty;
        defer output.deinit(allocator);

        if (lzma_data.len >= block_data.len) {
            const control: u8 = 0x01;
            try output.append(allocator, control);
            const size_m1: u16 = @intCast(block_data.len - 1);
            try output.append(allocator, @intCast(size_m1 >> 8));
            try output.append(allocator, @intCast(size_m1 & 0xFF));
            try output.appendSlice(allocator, block_data);
        } else {
            const unpack_size_m1: u32 = @intCast(block_data.len - 1);
            const control: u8 = 0x80 | (3 << 5) | @as(u8, @intCast((unpack_size_m1 >> 16) & 0x1F));
            try output.append(allocator, control);
            try output.append(allocator, @intCast((unpack_size_m1 >> 8) & 0xFF));
            try output.append(allocator, @intCast(unpack_size_m1 & 0xFF));
            const pack_size_m1: u16 = @intCast(lzma_data.len - 1);
            try output.append(allocator, @intCast(pack_size_m1 >> 8));
            try output.append(allocator, @intCast(pack_size_m1 & 0xFF));
            try output.append(allocator, @as(u8, lc) + 9 * (@as(u8, lp) + 5 * @as(u8, pb)));
            try output.appendSlice(allocator, lzma_data);
        }
        try output.append(allocator, 0x00);
        return try allocator.dupe(u8, output.items);
    }

    // Large block: use compressChunked with full reset at start
    // compressChunked already handles chunking internally with dict/state carry
    // No progress for individual blocks — parallel wrapper reports per-block completion
    return compressChunked(block_data, lc, lp, pb, dict_size, nice_len, .{}, allocator);
}

/// Compress data in parallel by splitting into independent blocks.
/// Each block is compressed with full state reset (reset_mode=3) using its own
/// MatchFinder and LzmaEncoder. Blocks are concatenated in order.
fn compressParallel(
    data: []const u8,
    lc: u3,
    lp: u2,
    pb: u2,
    dict_size: u32,
    nice_len: u32,
    num_threads: usize,
    progress: ProgressContext,
    allocator: std.mem.Allocator,
) ![]u8 {
    const actual_threads = @min(num_threads, data.len / (1 << 20)); // min 1MB per block
    if (actual_threads <= 1) {
        return compressChunked(data, lc, lp, pb, dict_size, nice_len, progress, allocator);
    }

    const block_size = data.len / actual_threads;
    const num_blocks = actual_threads;

    // Allocate result and error slots — one per block, disjoint access (no mutex needed)
    const results = try allocator.alloc(?[]u8, num_blocks);
    defer allocator.free(results);
    @memset(results, null);

    const errors = try allocator.alloc(?anyerror, num_blocks);
    defer allocator.free(errors);
    @memset(errors, null);

    // Zig 0.16: std.Thread.Pool and std.Thread.WaitGroup were removed.
    // Per the mini_blar firsthand note in the migration doc, the simplest
    // replacement for "N independent jobs, K workers" is a bounded raw-spawn
    // pool driven by an atomic next-slot counter — no io plumbing required.
    var progress_done = std.atomic.Value(u64).init(0);
    var next_slot = std.atomic.Value(usize).init(0);

    const WorkerCtx = struct {
        data: []const u8,
        block_size: usize,
        num_blocks: usize,
        lc: u3,
        lp: u2,
        pb: u2,
        dict_size: u32,
        nice_len: u32,
        results: []?[]u8,
        errors: []?anyerror,
        next: *std.atomic.Value(usize),
        progress_done: *std.atomic.Value(u64),
        progress_total: u64,
        progress: ProgressContext,
        allocator: std.mem.Allocator,
    };

    const worker_fn = struct {
        fn run(ctx: *const WorkerCtx) void {
            while (true) {
                const slot = ctx.next.fetchAdd(1, .acq_rel);
                if (slot >= ctx.num_blocks) return;
                const start = slot * ctx.block_size;
                const end = if (slot == ctx.num_blocks - 1) ctx.data.len else start + ctx.block_size;
                const block_data = ctx.data[start..end];
                const block_result = compressBlock(
                    block_data,
                    ctx.lc,
                    ctx.lp,
                    ctx.pb,
                    ctx.dict_size,
                    ctx.nice_len,
                    ctx.allocator,
                ) catch |err| {
                    ctx.errors[slot] = err;
                    continue;
                };
                ctx.results[slot] = block_result;
                const new_done = ctx.progress_done.fetchAdd(block_data.len, .monotonic) + block_data.len;
                ctx.progress.report(new_done, ctx.progress_total);
            }
        }
    }.run;

    const ctx: WorkerCtx = .{
        .data = data,
        .block_size = block_size,
        .num_blocks = num_blocks,
        .lc = lc,
        .lp = lp,
        .pb = pb,
        .dict_size = dict_size,
        .nice_len = nice_len,
        .results = results,
        .errors = errors,
        .next = &next_slot,
        .progress_done = &progress_done,
        .progress_total = @as(u64, data.len),
        .progress = progress,
        .allocator = allocator,
    };

    const workers = try allocator.alloc(std.Thread, actual_threads);
    defer allocator.free(workers);
    var spawned: usize = 0;
    for (workers) |*t| {
        t.* = std.Thread.spawn(.{}, worker_fn, .{&ctx}) catch {
            // Drain the queue so already-spawned workers exit, then join + bail.
            _ = next_slot.fetchAdd(num_blocks, .release);
            for (workers[0..spawned]) |w| w.join();
            return error.OutOfMemory;
        };
        spawned += 1;
    }
    for (workers) |t| t.join();

    // Check for errors — if any block failed, free all successful results and return the error
    var first_error: ?anyerror = null;
    for (errors) |maybe_err| {
        if (maybe_err) |err| {
            first_error = err;
            break;
        }
    }

    if (first_error) |err| {
        for (results) |maybe_result| {
            if (maybe_result) |result| {
                allocator.free(result);
            }
        }
        return err;
    }

    // Concatenate block results in order, replacing per-block end markers
    // with a single final end marker
    var total_len: usize = 0;
    for (results) |maybe_result| {
        const result = maybe_result.?;
        // Each block ends with 0x00 (end marker); we strip it except for the last
        total_len += result.len - 1; // strip end marker
    }
    total_len += 1; // single final end marker

    const output = try allocator.alloc(u8, total_len);
    errdefer allocator.free(output);
    var write_pos: usize = 0;
    for (results) |maybe_result| {
        const result = maybe_result.?;
        const payload = result[0 .. result.len - 1]; // strip end marker
        @memcpy(output[write_pos .. write_pos + payload.len], payload);
        write_pos += payload.len;
        allocator.free(result);
    }
    output[write_pos] = 0x00; // final end marker

    return output;
}

// ============================================================================
// Optimal Parser
// ============================================================================

const OptimalAction = enum(u2) { literal, short_rep, rep_match, new_match };

const OptimalNode = struct {
    price: u32 = INFINITY_PRICE,
    state: u4 = 0,
    rep: [4]u32 = .{ 0, 0, 0, 0 },
    action: OptimalAction = .literal,
    match_len: u32 = 0,
    match_dist: u32 = 0,
    match_rep_idx: u2 = 0,
};

/// Encode a chunk using forward optimal parsing with price-based decisions.
fn encodeLzma1ChunkOptimal(
    enc: *LzmaEncoder,
    mf: *MatchFinder,
    full_data: []const u8,
    encode_start: usize,
    encode_end: usize,
    allocator: std.mem.Allocator,
) !void {
    const chunk_len = encode_end - encode_start;
    if (chunk_len == 0) return;

    // Allocate DP nodes: one per position + 1 for the end
    const nodes = try allocator.alloc(OptimalNode, chunk_len + 1);
    defer allocator.free(nodes);
    @memset(nodes, OptimalNode{});

    // Initialize start node
    nodes[0].price = 0;
    nodes[0].state = enc.state;
    nodes[0].rep = enc.rep;

    // Pre-compute length price tables — turns priceLenVal calls into array lookups.
    // Prices are stable during the DP phase (probabilities only update during encoding).
    var len_prices: [NUM_POS_STATES_MAX][NUM_LEN_PRICE_SLOTS]u32 = undefined;
    var rep_len_prices: [NUM_POS_STATES_MAX][NUM_LEN_PRICE_SLOTS]u32 = undefined;
    for (0..NUM_POS_STATES_MAX) |ps| {
        for (0..NUM_LEN_PRICE_SLOTS) |rl| {
            len_prices[ps][rl] = priceLenVal(&enc.len_encoder, @intCast(rl), @intCast(ps));
            rep_len_prices[ps][rl] = priceLenVal(&enc.rep_len_encoder, @intCast(rl), @intCast(ps));
        }
    }

    // Pre-compute distance price tables — replaces tree walks with array lookups.
    // pos_slot_prices: 4 len_states × 64 pos_slots, each is a 6-level bit tree walk
    var pos_slot_prices: [NUM_LEN_STATES][64]u32 = undefined;
    for (0..NUM_LEN_STATES) |ls| {
        for (0..64) |ps| {
            pos_slot_prices[ls][ps] = priceBitTreeVal(&enc.pos_slot_encoders[ls], 6, @intCast(ps));
        }
    }
    // align_prices: 16 values for the 4-bit alignment tree (pos_slot >= 14)
    var align_prices: [16]u32 = undefined;
    for (0..16) |v| {
        align_prices[v] = priceRevBitTree(&enc.align_encoder, 4, @intCast(v));
    }
    // special_dist_prices: reverse bit tree prices for pos_slots 4-13
    // Indexed by [offset + remainder] where offset = base - pos_slot
    var special_dist_prices: [128]u32 = undefined;
    for (4..14) |slot| {
        const num_direct_bits: u5 = @intCast((slot >> 1) - 1);
        const base = (@as(u32, 2) | @as(u32, @intCast(slot & 1))) << num_direct_bits;
        const offset = base - @as(u32, @intCast(slot));
        const num_remainders = @as(u32, 1) << num_direct_bits;
        for (0..num_remainders) |r| {
            special_dist_prices[offset + r] = priceRevBitTree(enc.pos_encoders[offset..], num_direct_bits, @intCast(r));
        }
    }

    // Forward DP pass
    const nice_len = mf.nice_len;
    var skip_until: usize = 0;
    var i: usize = 0;
    while (i < chunk_len) : (i += 1) {
        // Fast-forward: inside a committed long match, just maintain hash chain
        if (i < skip_until) {
            mf.skip(encode_start + i);
            continue;
        }
        if (nodes[i].price == INFINITY_PRICE) {
            mf.skip(encode_start + i);
            continue;
        }

        const abs_pos = encode_start + i;
        const cur_byte = full_data[abs_pos];
        const prev_byte: u8 = if (abs_pos > 0) full_data[abs_pos - 1] else 0;
        const cur_state = nodes[i].state;
        const cur_rep = nodes[i].rep;
        const remaining: u32 = @intCast(chunk_len - i);
        const base_price = nodes[i].price;

        // Pre-compute position-dependent invariants once per position
        const ps: usize = abs_pos & ((@as(usize, 1) << @as(u5, enc.pb)) - 1);
        const is_match_price = probPrice1(enc.is_match[@as(usize, cur_state) * NUM_POS_STATES_MAX + ps]);
        const is_rep_price = is_match_price + probPrice1(enc.is_rep[cur_state]);
        const is_match_not_rep_price = is_match_price + probPrice0(enc.is_rep[cur_state]);

        // --- Option 1: Literal ---
        if (i + 1 <= chunk_len) {
            const match_byte: u8 = if (cur_state >= 7 and cur_rep[0] < abs_pos) full_data[abs_pos - cur_rep[0] - 1] else 0;
            const lit_price = base_price + enc.priceLiteralAt(cur_byte, abs_pos, prev_byte, match_byte, cur_state);
            if (lit_price < nodes[i + 1].price) {
                nodes[i + 1] = .{
                    .price = lit_price,
                    .state = nextStateLiteral(cur_state),
                    .rep = cur_rep,
                    .action = .literal,
                    .match_len = 0,
                    .match_dist = 0,
                    .match_rep_idx = 0,
                };
            }
        }

        // --- Option 2: Rep matches ---
        // Pre-compute rep selection base prices (everything except length)
        const rep_g0_price = is_rep_price + probPrice0(enc.is_rep_g0[cur_state]);
        const rep_g1_base = is_rep_price + probPrice1(enc.is_rep_g0[cur_state]);
        const rep_base_prices = [4]u32{
            rep_g0_price + probPrice1(enc.is_rep_0long[@as(usize, cur_state) * NUM_POS_STATES_MAX + ps]), // rep0 long
            rep_g1_base + probPrice0(enc.is_rep_g1[cur_state]), // rep1
            rep_g1_base + probPrice1(enc.is_rep_g1[cur_state]) + probPrice0(enc.is_rep_g2[cur_state]), // rep2
            rep_g1_base + probPrice1(enc.is_rep_g1[cur_state]) + probPrice1(enc.is_rep_g2[cur_state]), // rep3
        };
        // Short rep price (rep0, length 1)
        const short_rep_price = base_price + rep_g0_price + probPrice0(enc.is_rep_0long[@as(usize, cur_state) * NUM_POS_STATES_MAX + ps]);

        for (0..4) |ri| {
            const rep_dist = cur_rep[ri];
            if (rep_dist >= abs_pos) continue;
            const match_pos = abs_pos - rep_dist - 1;
            if (match_pos >= full_data.len) continue;

            // Find max rep match length
            var rep_len: u32 = 0;
            const max_rep = @min(MAX_MATCH, remaining);
            while (rep_len < max_rep and full_data[match_pos + rep_len] == full_data[abs_pos + rep_len]) {
                rep_len += 1;
            }

            if (rep_len == 0) continue;
            const rep_idx: u2 = @intCast(ri);

            // Short rep (length 1, rep[0] only)
            if (ri == 0 and rep_len >= 1 and i + 1 <= chunk_len) {
                if (short_rep_price < nodes[i + 1].price) {
                    nodes[i + 1] = .{
                        .price = short_rep_price,
                        .state = nextStateShortRep(cur_state),
                        .rep = cur_rep,
                        .action = .short_rep,
                        .match_len = 1,
                        .match_dist = 0,
                        .match_rep_idx = 0,
                    };
                }
            }

            // Rep matches length 2+
            if (rep_len >= 2) {
                var new_rep = cur_rep;
                if (ri > 0) {
                    const dist = cur_rep[ri];
                    var j: usize = ri;
                    while (j > 0) : (j -= 1) new_rep[j] = new_rep[j - 1];
                    new_rep[0] = dist;
                }
                const new_state = nextStateRep(cur_state);
                const rep_base = base_price + rep_base_prices[ri];

                var try_len: u32 = 2;
                while (try_len <= rep_len) : (try_len += 1) {
                    if (i + try_len > chunk_len) break;
                    const rp = rep_base + rep_len_prices[ps][try_len - 2];
                    if (rp < nodes[i + try_len].price) {
                        nodes[i + try_len] = .{
                            .price = rp,
                            .state = new_state,
                            .rep = new_rep,
                            .action = .rep_match,
                            .match_len = try_len,
                            .match_dist = 0,
                            .match_rep_idx = rep_idx,
                        };
                    }
                }
            }
        }

        // --- Option 3: New matches ---
        const candidates = mf.findMatches(abs_pos);
        const matches = candidates.slice();
        if (matches.len > 0) {
            const new_state = nextStateMatch(cur_state);
            const match_base = base_price + is_match_not_rep_price;

            var prev_len: u32 = 1;
            for (matches) |m| {
                // Compute distance price via pre-computed tables (no tree walks)
                const pos_slot = getPosSlot(m.distance);
                var remainder_price: u32 = 0;
                if (pos_slot >= 4) {
                    const num_direct_bits: u5 = @intCast((pos_slot >> 1) - 1);
                    const base_dist = (@as(u32, 2) | (pos_slot & 1)) << num_direct_bits;
                    const remainder = m.distance - base_dist;
                    if (pos_slot < 14) {
                        const offset = base_dist - pos_slot;
                        remainder_price = special_dist_prices[offset + remainder];
                    } else {
                        remainder_price = @as(u32, num_direct_bits - 4) * (1 << PRICE_SHIFT) + align_prices[remainder & 0xF];
                    }
                }
                const dist_prices = [4]u32{
                    pos_slot_prices[0][pos_slot] + remainder_price,
                    pos_slot_prices[1][pos_slot] + remainder_price,
                    pos_slot_prices[2][pos_slot] + remainder_price,
                    pos_slot_prices[3][pos_slot] + remainder_price,
                };
                const new_rep = [4]u32{ m.distance, cur_rep[0], cur_rep[1], cur_rep[2] };

                const min_useful: u32 = @max(prev_len + 1, if (m.distance < 128) @as(u32, 2) else if (m.distance < 2048) @as(u32, 3) else if (m.distance < 32768) @as(u32, 4) else @as(u32, 5));
                var try_len = min_useful;
                while (try_len <= m.length) : (try_len += 1) {
                    if (i + try_len > chunk_len) break;
                    const len_state_idx = @min(try_len - 2, 3);
                    const mp = match_base + len_prices[ps][try_len - 2] + dist_prices[len_state_idx];
                    if (mp < nodes[i + try_len].price) {
                        nodes[i + try_len] = .{
                            .price = mp,
                            .state = new_state,
                            .rep = new_rep,
                            .match_len = try_len,
                            .match_dist = m.distance,
                            .action = .new_match,
                            .match_rep_idx = 0,
                        };
                    }
                }
                prev_len = m.length;
            }

            // Fast-forward past very long matches — the DP benefit is
            // negligible for matches >= nice_len
            if (matches.len > 0) {
                const longest = matches[matches.len - 1].length;
                if (longest >= nice_len and i + longest <= chunk_len) {
                    skip_until = i + longest;
                }
            }
        }
    }

    // Backtrack to build encoding sequence
    const actions = try allocator.alloc(struct { pos: usize, node: OptimalNode }, chunk_len);
    defer allocator.free(actions);
    var action_count: usize = 0;

    var pos = chunk_len;
    while (pos > 0) {
        const node = nodes[pos];
        const step: usize = if (node.action == .literal) 1 else node.match_len;
        actions[action_count] = .{ .pos = pos - step, .node = node };
        action_count += 1;
        pos -= step;
    }

    // Reverse to get forward order
    var lo: usize = 0;
    var hi: usize = action_count;
    while (lo < hi) {
        hi -= 1;
        const tmp = actions[lo];
        actions[lo] = actions[hi];
        actions[hi] = tmp;
        lo += 1;
    }

    // Encode the optimal sequence
    for (actions[0..action_count]) |act| {
        const abs_pos = encode_start + act.pos;
        switch (act.node.action) {
            .literal => {
                const cur_byte = full_data[abs_pos];
                const prev_byte: u8 = if (abs_pos > 0) full_data[abs_pos - 1] else 0;
                const match_byte: u8 = if (enc.state >= 7 and enc.rep[0] < abs_pos) full_data[abs_pos - enc.rep[0] - 1] else 0;
                try enc.encodeLiteral(cur_byte, abs_pos, prev_byte, match_byte, allocator);
            },
            .short_rep => {
                try enc.encodeRepMatch(0, 1, abs_pos, allocator);
            },
            .rep_match => {
                try enc.encodeRepMatch(act.node.match_rep_idx, act.node.match_len, abs_pos, allocator);
            },
            .new_match => {
                try enc.encodeMatch(act.node.match_len, act.node.match_dist, abs_pos, allocator);
            },
        }
    }
}

/// Compress a block of data using LZMA1.
/// Returns the raw LZMA1 compressed bytes (5-byte range coder init + compressed data).
/// Does NOT include the 13-byte standalone LZMA header.
fn compressLzma1(data: []const u8, lc: u3, lp: u2, pb: u2, dict_size: u32, nice_len: u32, allocator: std.mem.Allocator) ![]u8 {
    var enc = try LzmaEncoder.init(lc, lp, pb, allocator);
    defer enc.deinit(allocator);

    var mf = try MatchFinder.init(data, dict_size, nice_len, allocator);
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

/// Find rep match with explicit max length (for chunked encoding with dictionary carry).
fn findRepMatchRange(enc: *const LzmaEncoder, data: []const u8, pos: usize, max_remaining: u32) ?RepMatch {
    var best_idx: u2 = 0;
    var best_len: u32 = 0;

    for (0..4) |i| {
        const dist = enc.rep[i];
        if (dist >= pos) continue;

        const match_pos = pos - dist - 1;
        if (match_pos >= data.len) continue;

        var len: u32 = 0;
        const max_len: u32 = @min(MAX_MATCH, max_remaining);
        while (len < max_len and data[match_pos + len] == data[pos + len]) {
            len += 1;
        }

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

/// Zig 0.16 test helper: decompress an LZMA2 stream into an exact-size buffer.
/// Replaces the 0.15 `std.compress.lzma2.decompress(alloc, fbs_reader, fbs_writer)`
/// pattern which is gone — the new API is method-based on Decode and takes
/// *Reader / *Writer.Allocating.
fn testDecompressLzma2(compressed: []const u8, out: []u8, allocator: std.mem.Allocator) !void {
    var in: std.Io.Reader = .fixed(compressed);
    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, out.len);
    defer aw.deinit();
    var dec = try std.compress.lzma2.Decode.init(allocator);
    defer dec.deinit(allocator);
    _ = try dec.decompress(&in, &aw);
    const written = aw.written();
    if (written.len != out.len) return error.TestUnexpectedResult;
    @memcpy(out, written);
}

/// Zig 0.16 test helper: decompress a full LZMA1 stream (13-byte header + payload).
fn testDecompressLzma1(stream: []const u8, expected_out_len: usize, allocator: std.mem.Allocator) ![]u8 {
    if (stream.len < 13) return error.TestUnexpectedResult;
    var in: std.Io.Reader = .fixed(stream);
    const props_byte = try in.takeByte();
    if (props_byte >= 225) return error.TestUnexpectedResult;
    const lc: u4 = @intCast(props_byte % 9);
    const lp_pb = props_byte / 9;
    const lp: u3 = @intCast(lp_pb % 5);
    const pb: u3 = @intCast(lp_pb / 5);
    const dict_size = try in.takeInt(u32, .little);
    _ = try in.takeInt(u64, .little); // unpack size

    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, expected_out_len);
    errdefer aw.deinit();
    var dec: std.compress.lzma.Decode = try .init(allocator, .{ .lc = lc, .lp = lp, .pb = pb });
    defer dec.deinit(allocator);

    var buffer = std.compress.lzma.Decode.CircularBuffer.init(@max(@as(usize, dict_size), expected_out_len), std.math.maxInt(usize));
    defer buffer.deinit(allocator);

    var n_read: u64 = 0;
    var range_decoder: std.compress.lzma.RangeDecoder = try .initCounting(&in, &n_read);
    while (buffer.len < expected_out_len) {
        const status = try dec.process(&in, &aw, &buffer, &range_decoder, &n_read);
        if (status == .finished) break;
    }
    try buffer.finish(&aw.writer);
    return aw.toOwnedSlice();
}

/// Zig 0.16 test helper: monotonic timer using Io.Timestamp.now(.awake).
const TestTimer = struct {
    start_ns: i96,
    fn start() TestTimer {
        return .{ .start_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds };
    }
    fn read(self: TestTimer) u64 {
        const now_ns = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).nanoseconds;
        const elapsed: i96 = now_ns - self.start_ns;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
};

test "lzma1 raw: encode single byte roundtrip" {
    const allocator = std.testing.allocator;
    const input = "A";
    const lzma_data = try compressLzma1(input, 3, 0, 2, 4096, MatchFinder.DEFAULT_NICE_LEN, allocator);
    defer allocator.free(lzma_data);

    // First byte must be 0x00 (range coder reserved byte)
    try std.testing.expectEqual(@as(u8, 0x00), lzma_data[0]);

    // Build standalone LZMA stream and verify roundtrip
    var stream_buf: [256]u8 = undefined;
    stream_buf[0] = 93; // props: lc=3 + 9*(lp=0 + 5*pb=2) = 93
    std.mem.writeInt(u32, stream_buf[1..5], 4096, .little);
    std.mem.writeInt(u64, stream_buf[5..13], 1, .little);
    @memcpy(stream_buf[13 .. 13 + lzma_data.len], lzma_data);

    const result = try testDecompressLzma1(stream_buf[0 .. 13 + lzma_data.len], 1, allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A", result);
}

test "lzma2 encoder: empty data" {
    const allocator = std.testing.allocator;
    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const result = try compress(&.{}, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u8, 0x00), result[0]); // end marker
}

test "lzma2 encoder: roundtrip small data" {
    const allocator = std.testing.allocator;
    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const input = "hello world";
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    // Decompress using stdlib decoder
    var out_buf: [11]u8 = undefined;
    try testDecompressLzma2(compressed, &out_buf, allocator);
    try std.testing.expectEqualStrings(input, &out_buf);
}

test "lzma2 encoder: roundtrip repetitive data" {
    const allocator = std.testing.allocator;
    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const input = "ABCDEFGHIJ" ** 50;
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    // Should actually compress
    try std.testing.expect(compressed.len < input.len);

    // Verify roundtrip
    var out_buf: [500]u8 = undefined;
    try testDecompressLzma2(compressed, out_buf[0..input.len], allocator);
    try std.testing.expectEqualStrings(input, out_buf[0..input.len]);
}

test "lzma2 encoder: roundtrip varied text with matches" {
    const allocator = std.testing.allocator;
    // This specific input triggers match/rep-match encoding paths
    // that previously produced data 7zz couldn't decode.
    const input = "quick the jumps fox fox brown quick and quick cat lazy";
    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    var out_buf: [256]u8 = undefined;
    try testDecompressLzma2(compressed, out_buf[0..input.len], allocator);
    try std.testing.expectEqualStrings(input, out_buf[0..input.len]);
}

test "lzma2 encoder: roundtrip binary data" {
    const allocator = std.testing.allocator;
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @intCast(i);
    }
    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const compressed = try compress(&input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    var out_buf: [512]u8 = undefined;
    try testDecompressLzma2(compressed, out_buf[0..input.len], allocator);
    try std.testing.expectEqualSlices(u8, &input, out_buf[0..input.len]);
}

test "lzma2 encoder: cross-chunk dictionary carry" {
    const allocator = std.testing.allocator;

    const block_size = 64 * 1024;
    const num_blocks = 4;

    // Generate one block of pseudo-random data (incompressible on its own)
    const block = try allocator.alloc(u8, block_size);
    defer allocator.free(block);
    var seed: u32 = 42;
    for (block) |*b| {
        seed = seed *% 1103515245 +% 12345;
        b.* = @intCast((seed >> 16) & 0xFF);
    }

    // Create 4 identical copies — only cross-chunk matches can compress this
    const input = try allocator.alloc(u8, block_size * num_blocks);
    defer allocator.free(input);
    for (0..num_blocks) |i| {
        @memcpy(input[i * block_size .. (i + 1) * block_size], block);
    }

    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    // Without dictionary carry: each block ~100% (random) = ~256KB total
    // With dictionary carry: block 1 ~100% + blocks 2-4 ~0% each = ~65KB
    try std.testing.expect(compressed.len < input.len / 2);

    // Verify roundtrip decompression
    const decompressed = try allocator.alloc(u8, input.len);
    defer allocator.free(decompressed);
    try testDecompressLzma2(compressed, decompressed, allocator);
    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "compressBlock: standalone block roundtrip" {
    const allocator = std.testing.allocator;
    // 128KB of repetitive data — compressible as a standalone block
    const block_size = 128 * 1024;
    const input = try allocator.alloc(u8, block_size);
    defer allocator.free(input);
    for (input, 0..) |*b, i| {
        b.* = @intCast(i % 251); // prime-cycle pattern
    }

    const lc: u3 = 3;
    const lp: u2 = 0;
    const pb: u2 = 2;
    const dict_size: u32 = 1 << 20;

    const block_lzma2 = try compressBlock(input, lc, lp, pb, dict_size, MatchFinder.DEFAULT_NICE_LEN, allocator);
    defer allocator.free(block_lzma2);

    // Must end with 0x00 (LZMA2 end marker)
    try std.testing.expectEqual(@as(u8, 0x00), block_lzma2[block_lzma2.len - 1]);

    // Roundtrip via stdlib decoder
    const decompressed = try allocator.alloc(u8, block_size);
    defer allocator.free(decompressed);
    try testDecompressLzma2(block_lzma2, decompressed, allocator);
    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "compressParallel: 4MB roundtrip with explicit thread count" {
    const allocator = std.testing.allocator;
    const data_size = 4 * 1024 * 1024; // 4MB
    const input = try allocator.alloc(u8, data_size);
    defer allocator.free(input);

    // Semi-compressible data: repeating pattern with variation
    var seed: u32 = 12345;
    for (input, 0..) |*b, i| {
        seed = seed *% 1103515245 +% 12345;
        b.* = @intCast((@as(usize, (seed >> 16) & 0xFF) + i / 1024) % 256);
    }

    const lc: u3 = 3;
    const lp: u2 = 0;
    const pb: u2 = 2;
    const dict_size: u32 = 1 << 20;

    const compressed = try compressParallel(input, lc, lp, pb, dict_size, MatchFinder.DEFAULT_NICE_LEN, 4, .{}, allocator);
    defer allocator.free(compressed);

    // Must end with 0x00
    try std.testing.expectEqual(@as(u8, 0x00), compressed[compressed.len - 1]);

    // Roundtrip
    const decompressed = try allocator.alloc(u8, data_size);
    defer allocator.free(decompressed);
    try testDecompressLzma2(compressed, decompressed, allocator);
    try std.testing.expectEqualSlices(u8, input, decompressed);
}

test "compress: large data uses parallel path and roundtrips" {
    const allocator = std.testing.allocator;
    // 2MB of compressible text-like data
    const data_size = 2 * 1024 * 1024;
    const input = try allocator.alloc(u8, data_size);
    defer allocator.free(input);

    const phrase = "The quick brown fox jumps over the lazy dog. ";
    for (input, 0..) |*b, i| {
        b.* = phrase[i % phrase.len];
    }

    const p = LevelParams.fromLevel(LevelParams.DEFAULT_LEVEL);
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);

    // Should actually compress well
    try std.testing.expect(compressed.len < input.len / 2);

    // Roundtrip
    const decompressed = try allocator.alloc(u8, data_size);
    defer allocator.free(decompressed);
    try testDecompressLzma2(compressed, decompressed, allocator);
    try std.testing.expectEqualSlices(u8, input, decompressed);
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

// Verify HC2+HC3 finds short matches that pure BT4 would miss.
// Data pattern: 2-3 byte sequences repeat at distance > 4 but with different
// 4th bytes, so the 4-byte hash sends them to different buckets.
test "match finder: short matches via HC2+HC3" {
    const allocator = std.testing.allocator;

    // Build data where 3-byte patterns repeat with different 4th bytes:
    // "ABCX....ABCY" — the 3-byte prefix "ABC" repeats at distance 8 but
    // "ABCX" != "ABCY" so hash4 sends them to different buckets.
    var data: [64]u8 = undefined;
    @memset(&data, 0x20); // fill with spaces
    // Place "ABC" at position 4 and position 20 (distance 16)
    data[4] = 'A';
    data[5] = 'B';
    data[6] = 'C';
    data[7] = 'X'; // different 4th byte
    data[20] = 'A';
    data[21] = 'B';
    data[22] = 'C';
    data[23] = 'Y'; // different 4th byte — hash4 differs

    var mf = try MatchFinder.init(&data, 64, MatchFinder.DEFAULT_NICE_LEN, allocator);
    defer mf.deinit(allocator);

    // Walk through positions 0..19 to populate hash tables
    for (0..20) |p| {
        _ = mf.findMatches(p);
    }

    // At position 20, the 3-byte hash should find the match at position 4
    const candidates = mf.findMatches(20);
    const matches = candidates.slice();

    // We should find at least a 3-byte match (distance 15 = 20-4-1)
    var found_short = false;
    for (matches) |m| {
        if (m.length >= 3 and m.distance == 15) {
            found_short = true;
            break;
        }
    }
    try std.testing.expect(found_short);
}

// Phase-level profiler: measures match finding, DP, and encoding separately.
// Run with: zig build test 2>&1 | grep '\[profile\]'
test "lzma2 encoder: phase profiling" {
    const allocator = std.testing.allocator;

    // Use 1.16MB of prose-like data — same as ./bm text_1m benchmark
    const data_size = 1187840;
    const input = try allocator.alloc(u8, data_size);
    defer allocator.free(input);
    const phrase = "Call me Ishmael. Some years ago, never mind how long precisely, having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. ";
    for (input, 0..) |*b, i| {
        b.* = phrase[i % phrase.len];
    }

    const dict_size: u32 = @min(@as(u32, @intCast(data_size)), 1 << 24);

    // ---------------------------------------------------------------
    // Measurement A: Match finding only (no DP, no encoding)
    // Just walk every position through findMatches/skip
    // ---------------------------------------------------------------
    {
        var mf_a = try MatchFinder.init(input, dict_size, MatchFinder.DEFAULT_NICE_LEN, allocator);
        defer mf_a.deinit(allocator);

        var t_mf = TestTimer.start();
        var pos: usize = 0;
        var total_matches: usize = 0;
        while (pos < input.len) {
            const candidates = mf_a.findMatches(pos);
            total_matches += candidates.count;
            pos += 1;
        }
        const mf_ns = t_mf.read();
        const mf_ms = @as(f64, @floatFromInt(mf_ns)) / 1_000_000.0;
        std.debug.print("\n  [profile] A. Match finding only:     {d:7.1}ms ({d} total matches found)\n", .{ mf_ms, total_matches });
    }

    // ---------------------------------------------------------------
    // Measurement B: Full compression (match finding + DP + encoding)
    // ---------------------------------------------------------------
    var t_full = TestTimer.start();
    const compressed = try compress(input, dict_size, MatchFinder.DEFAULT_NICE_LEN, .{}, allocator);
    const full_ns = t_full.read();
    const full_ms = @as(f64, @floatFromInt(full_ns)) / 1_000_000.0;
    allocator.free(compressed);
    std.debug.print("  [profile] B. Full compression:        {d:7.1}ms\n", .{full_ms});

    // ---------------------------------------------------------------
    // Measurement C: Match finding rerun (for subtraction estimate)
    // DP+encoding time ~= B - C
    // ---------------------------------------------------------------
    var mf_rerun_ns: u64 = undefined;
    {
        var mf_d = try MatchFinder.init(input, dict_size, MatchFinder.DEFAULT_NICE_LEN, allocator);
        defer mf_d.deinit(allocator);
        var t_d = TestTimer.start();
        var pos: usize = 0;
        while (pos < input.len) {
            _ = mf_d.findMatches(pos);
            pos += 1;
        }
        mf_rerun_ns = t_d.read();
    }
    const mf_rerun_ms = @as(f64, @floatFromInt(mf_rerun_ns)) / 1_000_000.0;
    const dp_plus_encode_ms = full_ms - mf_rerun_ms;

    std.debug.print("  [profile] C. Match finding (rerun):   {d:7.1}ms\n", .{mf_rerun_ms});
    std.debug.print("  [profile] D. DP + encoding (B - C):   {d:7.1}ms\n", .{dp_plus_encode_ms});
    std.debug.print("  [profile]\n", .{});
    std.debug.print("  [profile] Breakdown estimate:\n", .{});
    std.debug.print("  [profile]   Match finding:  {d:5.1}% of total\n", .{mf_rerun_ms / full_ms * 100});
    std.debug.print("  [profile]   DP + encoding:  {d:5.1}% of total\n", .{dp_plus_encode_ms / full_ms * 100});
    std.debug.print("  [profile]   Throughput:     {d:.1} MB/s\n", .{@as(f64, @floatFromInt(data_size)) / 1048576.0 / (full_ms / 1000.0)});
}

// Microbenchmark regression guard: compresses a deterministic 256KB block and
// fails if wall-clock time exceeds the baseline by more than 25%. Catches
// accidental O(n^2) regressions in the encoder hot path.
test "lzma2 encoder: compression speed regression guard" {
    const allocator = std.testing.allocator;

    // Generate deterministic 256KB block — repeating prime-cycle pattern
    const block_size = 256 * 1024;
    const input = try allocator.alloc(u8, block_size);
    defer allocator.free(input);
    for (input, 0..) |*b, i| {
        b.* = @intCast(i % 251); // prime-cycle: compressible but non-trivial
    }

    // Use old default params (level 7: 16MB dict, nice_len=128) for regression guard
    const p = LevelParams.fromLevel(7);

    // Warm up (first run may be slower due to cache effects)
    const warmup = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    allocator.free(warmup);

    // Timed run
    var timer = TestTimer.start();
    const compressed = try compress(input, p.dict_size, p.nice_len, .{}, allocator);
    defer allocator.free(compressed);
    const elapsed_ns = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    // Print timing to stderr for manual inspection during test runs
    std.debug.print("\n  [perf] 256KB compress: {d:.1}ms (compressed to {d} bytes, {d:.1}%)\n", .{
        elapsed_ms,
        compressed.len,
        @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(block_size)) * 100.0,
    });

    // Baseline: 150ms on Apple M1 Max ReleaseFast (generous ceiling).
    // Update this const when performance improvements land.
    const baseline_ms: f64 = 150.0;
    const threshold = baseline_ms * 1.25; // 25% regression tolerance

    if (elapsed_ms > threshold) {
        std.debug.print("  [perf] REGRESSION: {d:.1}ms exceeds threshold {d:.1}ms (baseline {d:.0}ms + 25%)\n", .{
            elapsed_ms,
            threshold,
            baseline_ms,
        });
        return error.PerformanceRegression;
    }
}

test "LevelParams: level mapping" {
    // Level 0: 64KB dict, nice_len 8
    const l0 = LevelParams.fromLevel(0);
    try std.testing.expectEqual(@as(u32, 1 << 16), l0.dict_size);
    try std.testing.expectEqual(@as(u32, 8), l0.nice_len);

    // Level 5 (default): 8MB dict, nice_len 64
    const l5 = LevelParams.fromLevel(5);
    try std.testing.expectEqual(@as(u32, 1 << 23), l5.dict_size);
    try std.testing.expectEqual(@as(u32, 64), l5.nice_len);

    // Level 9: 64MB dict, nice_len 256
    const l9 = LevelParams.fromLevel(9);
    try std.testing.expectEqual(@as(u32, 1 << 26), l9.dict_size);
    try std.testing.expectEqual(@as(u32, 256), l9.nice_len);
}

test "compress: level 0 vs level 9 compression ratio" {
    const allocator = std.testing.allocator;

    // 128KB of compressible text data
    const data_size = 128 * 1024;
    const input = try allocator.alloc(u8, data_size);
    defer allocator.free(input);
    const phrase = "The quick brown fox jumps over the lazy dog. ";
    for (input, 0..) |*b, i| {
        b.* = phrase[i % phrase.len];
    }

    // Level 0: fastest, minimal compression
    const p0 = LevelParams.fromLevel(0);
    const compressed_0 = try compress(input, p0.dict_size, p0.nice_len, .{}, allocator);
    defer allocator.free(compressed_0);

    // Level 9: best compression
    const p9 = LevelParams.fromLevel(9);
    const compressed_9 = try compress(input, p9.dict_size, p9.nice_len, .{}, allocator);
    defer allocator.free(compressed_9);

    // Both must roundtrip correctly
    {
        const decompressed = try allocator.alloc(u8, data_size);
        defer allocator.free(decompressed);
        try testDecompressLzma2(compressed_0, decompressed, allocator);
        try std.testing.expectEqualSlices(u8, input, decompressed);
    }
    {
        const decompressed = try allocator.alloc(u8, data_size);
        defer allocator.free(decompressed);
        try testDecompressLzma2(compressed_9, decompressed, allocator);
        try std.testing.expectEqualSlices(u8, input, decompressed);
    }

    // Level 9 should compress at least as well as level 0
    // (For highly repetitive data, level 0 may also compress well, but 9 should be <= 0)
    std.debug.print("\n  [level] Level 0: {d} bytes, Level 9: {d} bytes\n", .{ compressed_0.len, compressed_9.len });
    try std.testing.expect(compressed_9.len <= compressed_0.len);
}

test "lzma2: MatchFinder.init leaks nothing when a later allocation fails" {
	// Regression: init had no errdefer on hash/hash2/hash3/bt_left, so a failure
	// in any allocation after the first leaked all earlier ones. Drive each
	// allocation index to failure; testing.allocator asserts zero leaks at teardown.
	const data = [_]u8{0} ** 64;
	var i: usize = 0;
	while (i < 5) : (i += 1) {
		var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
		const a = failing.allocator();
		try std.testing.expectError(error.OutOfMemory, MatchFinder.init(&data, 64, 32, a));
	}
}
