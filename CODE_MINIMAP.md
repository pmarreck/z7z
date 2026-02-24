# Code Minimap

## src/lib.zig
Root module. Re-exports all submodules. Contains test references.

## src/crc32.zig
- `Hasher` — type alias for `std.hash.crc.Crc32` (IEEE CRC-32)
- `hash(data) → u32` — one-shot CRC-32
- `State` — incremental CRC-32 (init/update/final)

## src/varint.zig
7z variable UINT64 encoding (spec section 2.2).
- `decode(data) → {value, bytes_read}` — decode from byte slice
- `encode(value, buf) → bytes_written` — encode to byte buffer
- `encodedSize(value) → u8` — bytes needed to encode a value

## src/header.zig
32-byte signature header (spec section 1.1).
- `SignatureHeader` — struct with version, offsets, CRCs
- `parse(data) → SignatureHeader` — parse + validate (signature, CRC)
- `encode(header) → [32]u8` — encode with computed StartHeaderCRC
- Constants: `HEADER_SIZE`, `SIGNATURE`

## src/lzma2_encoder.zig
LZMA2 compression encoder with forward optimal parser.
- `LzmaEncoder` — LZMA1 state machine: range encoder, probability models, rep distances
- `encodeLzma2()` — top-level LZMA2 encoder: splits input into chunks, writes LZMA2 framing
- `encodeLzma1ChunkOptimal()` — forward DP optimal parser over 64KB chunks
  - Pre-computes price tables (length, distance, pos_slot, align) before DP loop
  - Evaluates literals, short reps, rep matches (4 distances × all lengths), new matches
  - Uses pre-computed position-dependent price invariants per position
- `MatchFinder` — BT4 binary tree match finder with HC2+HC3 short-match hashes
  - HC2 (2-byte perfect hash, 64K entries) + HC3 (3-byte hash, 256K entries) for short matches
  - `extendMatch()` — u64 XOR + @ctz word-at-a-time string comparison
  - `findMatches()` — HC2/HC3 lookup + BT4 binary tree search (BT_DEPTH=32, NICE_LEN=128)
  - `skip()` — HC2/HC3-only update, preserves BT4 tree structure
- `priceLenVal`, `probPrice0/1`, `priceBitTreeVal`, `priceRevBitTree` — price estimation primitives
- `prob_prices` — comptime-const probability price lookup table (thread-safe)
- `compressBlock()` — self-contained single-block LZMA2 compression (own MatchFinder + LzmaEncoder)
- `compressParallel()` — parallel block compression via std.Thread.Pool (splits data, concatenates results)

## build.zig
Build configuration. Static lib + test step. ReleaseFast default.

## flake.nix
Nix devShell: zig 0.15.x, 7zz (oracle), hyperfine.

## bm
Benchmark script (Bash). Uses hyperfine to compare z7z vs 7zz reference on 3 data files.
- Generates deterministic test data in $TMPDIR (1.16MB text, 4MB text, 1MB binary)
- Runs 3-way comparison: z7z auto, 7zz single-threaded, 7zz multi-threaded
- Shows compression ratios, validates interop, checks for debug builds
- Logs timestamped results to `tests/benchmark/benchmark.log`
- Compares against previous run: warns if >10% slower, notices if >10% faster

## tests/benchmark/benchmark.log
Timestamped benchmark results. Format: `timestamp | label | file | mean | stddev | size | ratio`
