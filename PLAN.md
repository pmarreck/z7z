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
- [ ] Encoded header support (kEncodedHeader → decode → kHeader) — deferred to Phase 5

## Phase 3: Copy Codec + End-to-End (Complete)
- [x] Archive creation: single and multi-file, Copy method, plain header
- [x] Archive extraction: read packstream, apply Copy, emit file data
- [x] Three-way interop: z7z↔z7z, z7z→7zz, 7zz→z7z (5 tests)

## Phase 4: C FFI + C CLI ← NEXT
- [ ] C FFI header (z7z.h) with list/extract/create functions
- [ ] Zig exports via `export` keyword
- [ ] C CLI that dogfoods the FFI
- [ ] CLI tests via shell scripts

## Phase 5: Compression Codecs
- [ ] Encoded header support (kEncodedHeader → decompress → parse)
- [ ] LZMA2 decode
- [ ] LZMA2 encode
- [ ] BCJ filters
- [ ] Coder graph pipeline (multi-coder folders)

## Phase 6: Encryption
- [ ] 7zAES decode (with password)
- [ ] 7zAES encode
- [ ] Encrypted header support
