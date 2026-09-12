# z7z Terminology

Project definitions used by [INTENT.md](INTENT.md) and the
[cleanroom format specification](SPEC_7Z_CLEANROOM.md).

- **Signature Header**: Fixed 32-byte header at offset 0 of every .7z file
- **Next Header**: The metadata region containing file listings, codec info, etc.
- **Folder**: A group of one or more files compressed together through a coder pipeline
- **Coder**: A compression or encryption algorithm (LZMA2, Copy, 7zAES, etc.)
- **Pack Stream**: Compressed data in the archive body
- **NID**: Node/Property ID - single-byte tags that identify header sections
- **Varint (UINT64)**: 7z's variable-length 1-9 byte integer encoding
