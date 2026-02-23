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
- [ ] Profile and identify hot paths (LZMA2 encoder, range coder, match finder, BCJ filter)
- [ ] Generate LLVM IR (.ll) from hot paths via `zig build -Doptimize=ReleaseFast --verbose-llvm-ir` or `--emit-llvm-ir`
- [ ] Hand-optimize the generated .ll (unroll loops, vectorize, eliminate redundant ops)
- [ ] Include optimized .ll as inline assembly or precompiled objects
- [ ] Benchmark before/after with hyperfine against 7zz oracle
