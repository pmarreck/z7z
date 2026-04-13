# z7z missing Zstandard (ZSTD) codec support

## Source
validate project (7z deep validator via z7z FFI)

## Problem
Real-world 7z archives compressed with Zstandard fail with `unsupported feature` because z7z only supports Copy, LZMA, LZMA2, BCJ x86, BCJ2, and 7zAES codecs.

## Evidence
Two files from a Windows File History backup use `ZSTD:v1.5,l3` (confirmed via `7z l -slt`). The reference p7zip 17.05 reads them fine. z7z returns `Z7Z_ERR_UNSUPPORTED` during `z7z_open()` when trying to decompress the metadata/folder data.

## 7z ZSTD method ID
The 7z codec ID for Zstandard is `04 F7 11 01` (4 bytes). This was added to the 7z format by Igor Pavlov in 7-Zip 21.01 (2021).

## Impact
Any 7z archive created with ZSTD compression (increasingly common since 7-Zip 21.01+) will fail validation. This is a decompression-only gap — z7z does not need to *create* ZSTD archives, just read them.

## Suggested fix
Add ZSTD decompression support in `src/codec.zig`. Zig's `std.compress.zstd` provides a pure-Zig Zstandard decoder that could be wired in as a new single-coder method alongside LZMA/LZMA2/Copy. The method ID to match is `{ 0x04, 0xF7, 0x11, 0x01 }`.
