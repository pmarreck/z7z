# z7z — Implementation Plan

## Phase 1: Foundation (Complete)
- [x] flake.nix with Zig 0.15.x, 7zz oracle, hyperfine (~2026-02-22 EST)
- [x] build.zig with test step, ReleaseFast default (~2026-02-22 EST)
- [x] CRC-32 — stdlib wrapper, verified against spec TV-A (~2026-02-22 EST)
- [x] Variable UINT64 — encode/decode with roundtrip tests (~2026-02-22 EST)
- [x] Signature header — parse/encode, all 3 test vectors, mutation detection (~2026-02-22 EST)
- [x] ./build and ./test scripts (~2026-02-22 EST)

## Phase 2: Header Metadata Parsing
- [ ] NID constants enum
- [ ] Header tree parser (kHeader → StreamsInfo → FilesInfo → kEnd)
- [ ] PackInfo parsing
- [ ] UnpackInfo / Folder record parsing
- [ ] SubStreamsInfo parsing
- [ ] FilesInfo parsing (names, timestamps, attributes)
- [ ] Encoded header support (kEncodedHeader → decode → kHeader)

## Phase 3: Copy Codec (First End-to-End)
- [ ] Copy method encode/decode (passthrough)
- [ ] Archive creation: one file, Copy method, plain header
- [ ] Archive extraction: read packstream, apply Copy, emit file data
- [ ] Three-way interop: z7z↔z7z, z7z→7z, 7z→z7z

## Phase 4: C FFI + C CLI
- [ ] C FFI header (z7z.h) with list/extract/create functions
- [ ] C CLI that dogfoods the FFI
- [ ] CLI tests in Bash

## Phase 5: Compression Codecs
- [ ] LZMA2 decode
- [ ] LZMA2 encode
- [ ] BCJ filters
- [ ] Coder graph pipeline (multi-coder folders)

## Phase 6: Encryption
- [ ] 7zAES decode (with password)
- [ ] 7zAES encode
- [ ] Encrypted header support
