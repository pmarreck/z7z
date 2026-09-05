# z7z — Cleanroom 7z Archive Format Implementation

A cleanroom reimplementation of the 7z archive format in Zig, built from `SPEC_7Z_CLEANROOM.md` without reference to the original 7-Zip source code.

## Current Completion Target

Support every current 7z archive feature needed for metadata inspection and deep
verification in `../validate` and `../validate_gui`, including all applicable
codecs, filters, encryption, headers, and coder graphs. Verification must respect
caller-provided allocators and resource limits and distinguish incomplete checks
from verified integrity. Preserve existing archive creation and extraction.

ZIP is handled separately, and RAR is handled by `../rarz`. Full 7-Zip application
parity, other archive containers, and new archive-editing or encoding features are
outside this verification milestone. Compression methods used inside 7z remain
in scope even when another container handler uses the same algorithm.

Reference executables are temporary development oracles only. Remove their
dependencies after the complete verification feature matrix passes independent
compatibility checks. Retain fixtures, expected results, and provenance so the
regression suite continues to run without the oracle. See `PLAN.md` for the gates.

## Architecture

```
C CLI (main.c) ──► C FFI (ffi.zig) ──► Zig core (src/*.zig, pure, no I/O)
```

- **Zig core**: All parsing, encoding, and codec logic. Pure functions, no I/O.
- **C FFI**: The public C API boundary, exercised by the C CLI. Zig callers may import the Zig library directly when that C ABI coverage is maintained.
- **C CLI**: Dogfoods the C FFI. Handles all I/O.

## Terminology

- **Signature Header**: Fixed 32-byte header at offset 0 of every .7z file
- **Next Header**: The metadata region containing file listings, codec info, etc.
- **Folder**: A group of one or more files compressed together through a coder pipeline
- **Coder**: A compression or encryption algorithm (LZMA2, Copy, 7zAES, etc.)
- **Pack Stream**: Compressed data in the archive body
- **NID**: Node/Property ID — single-byte tags that identify header sections
- **Varint (UINT64)**: 7z's variable-length 1-9 byte integer encoding

## Test Strategy

Three-way interop verification for each feature:
1. z7z encode → z7z decode (Zig unit tests)
2. z7z encode → 7z decode (integration tests with oracle binary)
3. 7z encode → z7z decode (integration tests with oracle binary)
