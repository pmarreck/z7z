# z7z — Implementation Plan

## Phase 1: Foundation (Complete)
- [x] flake.nix with Zig 0.15.x, 7zz oracle, hyperfine
- [x] build.zig with test step, ReleaseFast default
- [x] CRC-32 — stdlib wrapper, verified against spec TV-A
- [x] Variable UINT64 — encode/decode with roundtrip tests
- [x] Signature header — parse/encode, all 3 test vectors, mutation detection
- [x] ./build and ./test scripts

## Phase 2: Header Metadata (Complete)
- [x] NID constants enum
- [x] Sequential reader/writer utilities
- [x] Header tree parser (kHeader → StreamsInfo → FilesInfo → kEnd)
- [x] PackInfo parsing
- [x] UnpackInfo / Folder record parsing
- [x] SubStreamsInfo parsing (with inferred sizes for default case)
- [x] FilesInfo parsing (names UTF-16LE→UTF-8, timestamps, attributes)
- [x] Metadata encoder (byte-identical roundtrip on TV-A)

## Phase 3: Copy Codec + End-to-End (Complete)
- [x] Archive creation: single and multi-file, Copy method, plain header
- [x] Archive extraction: read packstream, apply Copy, emit file data
- [x] Three-way interop: z7z↔z7z, z7z→7zz, 7zz→z7z (5 tests)

## Phase 4: C FFI + C CLI (Complete)
- [x] C FFI header (z7z.h) with list/extract/create functions
- [x] Zig exports via `export` keyword
- [x] C CLI that dogfoods the FFI
- [x] CLI tests via shell scripts (21 tests)

## Phase 5: Compression Codecs (Complete)
- [x] LZMA2 decode (wrapping std.compress.lzma2)
- [x] LZMA decode (wrapping std.compress.lzma)
- [x] Encoded header support (kEncodedHeader → decompress → parse)
- [x] Codec dispatch module (codec.zig)
- [x] LZMA2 encode (cleanroom implementation: range encoder + LZ77 match finder + LZMA state machine)
- [x] BCJ x86 filter (cleanroom from LZMA SDK public domain algorithm)
- [x] Coder graph pipeline (two-coder folders: filter + compressor)

## Phase 6: Encryption (Complete)
- [x] 7zAES decode (SHA-256 iterative KDF, AES-256-CBC decrypt)
- [x] 7zAES encode (property encoding, key derivation, CBC encrypt)
- [x] Encrypted header support (single-coder 7zAES folders for kEncodedHeader)
- [x] Multi-coder pipeline (AES + LZMA2 + optional BCJ filter)
- [x] Folder.getFinalUnpackSize() — correct unbound output stream resolution
- [x] Interop: 7zz→z7z encrypted (with/without header encryption)
- [x] Interop: z7z→7zz encrypted archive extraction

## Phase 7: Performance Optimization
- [x] Profile and identify hot paths — DP inner loop price estimation was the bottleneck (~2026-02-23)
- [x] Pre-compute position-dependent price invariants (is_match, is_rep, rep base prices) (~2026-02-23)
- [x] Pre-compute length price tables [16][272] for len_encoder and rep_len_encoder (~2026-02-23)
- [x] Pre-compute distance price tables (pos_slot[4][64], align[16], special_dist[128]) (~2026-02-23)
- [x] Result: 374ms → 258ms (31% faster) on price table pre-computation (~2026-02-23)
- [x] Multithreading: parallel block compression via std.Thread.Pool (~2026-02-23)
  - Made prob_prices comptime-const (thread safety prerequisite)
  - compressBlock: self-contained single-block LZMA2 compression
  - compressParallel: splits data into N blocks (min 1MB), compresses independently
  - compress() auto-detects CPU count, dispatches to parallel path for data >= 1MB
  - 3 new tests: compressBlock roundtrip, compressParallel 4-thread, large-data compress roundtrip
- [x] Match finder optimization: 10x speedup, z7z now FASTER than 7zz-st (~2026-02-23 EST)
  - Profiled: 97.9% of CPU time was in BT4 match finding (byte-by-byte comparison)
  - u64 XOR + @ctz word-at-a-time string comparison (5x speedup)
  - Nice-length early exit (NICE_LEN=128): stop tree traversal at long matches
  - Lightweight skip: hash-only update instead of full tree maintenance
  - BT_DEPTH reduced from 64 to 32
  - Results: 1.16MB text 12.6ms vs 7zz 22.2ms (1.76x faster), 4MB text 18.9ms vs 69.4ms (3.67x faster)
  - Trade-off: slightly larger compressed output on highly repetitive text (tree quality vs speed)
- [ ] Further optimization: HC4 hybrid, HC2+HC3 hash tables, LLVM IR hand-tuning

## Phase 8: Benchmark Suite (~2026-02-23)
- [x] `./bm` — Bash script using hyperfine to benchmark z7z vs 7zz (~2026-02-23 EST)
  - 3 data files: 1.16MB text, 4MB text, 1MB binary (deterministic, RAM-backed)
  - 3 commands per file: z7z (auto), 7zz -mx=5 -mmt=1, 7zz -mx=5 -mmt=on
  - Compression ratio display, 7zz interop validation, debug build check
  - Results logged to tests/benchmark/benchmark.log with regression detection (>10% delta)
- [x] Microbenchmark regression guard in lzma2_encoder.zig (~2026-02-23 EST)
  - 256KB deterministic compress, fails if >25% slower than 150ms baseline
  - Runs as part of `./test` to catch algorithmic regressions automatically
