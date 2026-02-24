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
    - HC miss early-out: if neither HC2 nor HC3 finds a match, skips BT4 tree walk entirely
    - Adaptive depth: if only HC2 matched (no HC3), BT4 depth reduced from 32 to 2
  - `skip()` — HC2/HC3-only update, preserves BT4 tree structure
- `compressChunked()` — continuous-state LZMA2 encoding over 64KB chunks
  - Entropy-based incompressibility probe: counts unique bytes in first 2KB of each chunk
  - Dictionary match check: probes HC3 to avoid skipping chunks with cross-chunk matches
  - Skip path: emit uncompressed + lightweight hash update via skip()
- `priceLenVal`, `probPrice0/1`, `priceBitTreeVal`, `priceRevBitTree` — price estimation primitives
- `prob_prices` — comptime-const probability price lookup table (thread-safe)
- `compressBlock()` — self-contained single-block LZMA2 compression (own MatchFinder + LzmaEncoder)
- `compressParallel()` — parallel block compression via std.Thread.Pool (splits data, concatenates results)

## src/archive.zig
Archive-level create and read operations.
- `FileEntry` — input struct with name, data, is_dir, is_symlink, mtime, win_attrib
- `ArchiveContents` — result struct with metadata + extracted file data
- `computeWinAttrib()` — derives win_attrib from FileEntry type (dir/symlink/file), sets POSIX mode bits
- `create()` / `createWithMethod()` / `createWithMethodAndPassword()` — archive creation (Copy, LZMA2, LZMA2+AES)
  - Symlinks stored as data-bearing entries (target path as data, S_IFLNK in win_attrib)
- `read()` / `readWithPassword()` — archive extraction
  - Multi-folder support: iterates ALL folders with correct pack offset calculation
  - Per-folder file mapping via SubStreamInfo.num_unpack_per_folder
  - Handles empty stream (directory) entries correctly during file→folder assignment

## src/metadata.zig
7z header metadata parser and structures.
- `SubStreamInfo` — includes `num_unpack_per_folder` for multi-folder file assignment
- `parseSubStreamsInfo()` — stores per-folder substream counts
- `decodeEncodedHeader()` — decompresses LZMA/LZMA2-compressed headers
- `getFinalUnpackSize()` — finds unbound output stream in multi-coder pipelines

## src/codec.zig
Codec dispatch: decompress packed data for a folder's coder pipeline.
- `decompressFolder()` — handles single-coder and multi-coder pipelines
- `decompressMultiCoderPipeline()` — BCJ+LZMA2, AES+LZMA2, AES+BCJ+LZMA2
- `decodeLzma()` — LZMA1 decompression with Zig stdlib dictionary wrap bug workaround
- `decodeLzma2()` — LZMA2 decompression via std.compress.lzma2
- `bcjX86Decode()` / `bcjX86Encode()` — x86 BCJ filter (jump/call address translation)
- `compressLzma2()` — LZMA2 compression via lzma2_encoder

## src/ffi.zig
C FFI boundary for z7z. All functions use C calling convention.
- `z7z_open` — open archive from memory buffer, returns opaque handle
- `z7z_file_count`, `z7z_file_name`, `z7z_file_data`, `z7z_file_size` — query file entries
- `z7z_file_is_dir` — check if entry is a directory (EmptyStream && !EmptyFile)
- `z7z_file_is_symlink` — check if entry is a symlink (POSIX S_IFLNK in win_attrib upper bits)
- `z7z_create` — create archive from file entries (supports Z7Z_FLAG_DIRECTORY, Z7Z_FLAG_SYMLINK)
- `z7z_close`, `z7z_free` — memory management
- `z7z_error_string` — human-readable error messages
- `Z7zFileEntry` — extern struct with name, data, data_len, flags

## include/z7z.h
C header for the FFI. Matches ffi.zig exports.
- `z7z_file_entry` — struct with name, data, data_len, flags (Z7Z_FLAG_DIRECTORY = 0x01, Z7Z_FLAG_SYMLINK = 0x02)
- `z7z_file_is_symlink()` — query if archive entry is a symbolic link

## cli/main.c
C CLI that dogfoods the FFI (list, extract, create commands).
- `cmd_create` — accepts files, directories, and symlinks; `--dereference`/`-L` flag to follow symlinks
- `cmd_extract` — creates directories, symlinks, and files; path traversal security for symlink targets
- `cmd_list` — shows `<dir>` for directories, `<symlink>` with target for symbolic links
- `entry_list` — dynamic array for collecting file entries during directory walking
- `entry_list_add_symlink()` — add symlink entry with target path as data
- `walk_directory()` — recursive POSIX directory traversal using lstat() (preserves symlinks by default)
- `symlink_target_is_safe()` — security check: rejects absolute paths and ../ traversal
- `ensure_dir_recursive()` — mkdir -p equivalent
- `ensure_parent_dir()` — creates parent directories for a file path

## build.zig
Build configuration. Static lib + test step. ReleaseFast default.

## flake.nix
Nix devShell: zig 0.15.x, 7zz (oracle), hyperfine, luajit, jq.

## tools/
Vendored LuaJIT tools for self-contained benchmarking (no external PATH dependencies).
- `tools/random` — deterministic pseudo-random number generator (PCG32, multiple distributions)
- `tools/gen-fake-tree` — deterministic fake directory hierarchy generator (for multi-file benchmarks)
- `tools/data/dictionary.txt` — 89K-word dictionary used by gen-fake-tree

## bm
Benchmark script (Bash). Uses hyperfine to compare z7z vs 7zz reference on 4 data files.
- Generates deterministic test data in $TMPDIR via vendored `tools/random` (LuaJIT):
  - 1.16MB repeating prose, 4MB prose, 1MB uniform random, 1MB gaussian (semi-compressible)
- Runs 3-way comparison: z7z auto, 7zz single-threaded, 7zz multi-threaded
- Shows compression ratios, validates interop, checks for debug builds
- Logs timestamped results to `tests/benchmark/benchmark.log`
- Compares against previous run: warns if >10% slower, notices if >10% faster

## tests/benchmark/benchmark.log
Timestamped benchmark results. Format: `timestamp | label | file | mean | stddev | size | ratio`
