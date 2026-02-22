# z7z — Cleanroom 7z Archive Format Implementation

A cleanroom reimplementation of the 7z archive format in Zig, built from `SPEC_7Z_CLEANROOM.md` without reference to the original 7-Zip source code.

## Architecture

```
C CLI (main.c) ──► C FFI (ffi.zig) ──► Zig core (src/*.zig, pure, no I/O)
```

- **Zig core**: All parsing, encoding, and codec logic. Pure functions, no I/O.
- **C FFI**: The public API boundary. All external consumers go through this.
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
