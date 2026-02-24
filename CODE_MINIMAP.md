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

## src/progress.zig
Progress callback context shared across compression/extraction pipeline.
- `ProgressContext` — struct with C-callable callback + user_data, no-op when callback is null

## src/archive.zig
Archive-level create and read operations.
- `FileEntry` — input struct with name, data, is_dir, is_symlink, mtime, win_attrib, ctime, atime, xattrs
- `ArchiveContents` — result struct with metadata + extracted file data
- `computeWinAttrib()` — derives win_attrib from FileEntry type (dir/symlink/file), sets POSIX mode bits
- `create()` / `createWithMethod()` / `createWithMethodAndPassword()` — archive creation (Copy, LZMA2, LZMA2+AES)
- `createWithProgress()` — archive creation with progress callback (fires during LZMA2 compression)
- `readWithProgress()` — archive extraction with progress callback (fires per-folder decompressed)
  - Multi-folder support: iterates ALL folders with correct pack offset calculation
  - Per-folder file mapping via SubStreamInfo.num_unpack_per_folder
  - Handles empty stream (directory) entries correctly during file→folder assignment

## src/metadata.zig
7z header metadata parser and structures.
- `FileInfo` — includes xattrs field (serialized blob, owned, freed in deinit)
- `SubStreamInfo` — includes `num_unpack_per_folder` for multi-folder file assignment
- `parseSubStreamsInfo()` — stores per-folder substream counts
- `parseXattrProperty()` — parse custom 0x7A xattr blobs (BOOL_VECTOR2 + per-file varint+blob)
- `decodeEncodedHeader()` — decompresses LZMA/LZMA2-compressed headers
- `getFinalUnpackSize()` — finds unbound output stream in multi-coder pipelines

## src/nid.zig
7z property ID enum (NID constants from the 7z specification).
- `Nid` enum — all standard property IDs (header, pack_info, folder, etc.)
- `xattr = 0x7A` — custom z7z property for extended attribute blobs

## src/encoder.zig
7z header metadata encoder (writes FilesInfo properties).
- `encodeFilesInfo()` — encodes names, empty streams, timestamps, attributes, xattrs
- `encodeTimeProperty()` — encodes mtime/ctime/atime as FILETIME values with BOOL_VECTOR2
- `encodeXattrProperty()` — encodes xattr blobs under custom NID 0x7A with BOOL_VECTOR2
- `encodeWinAttrib()` — encodes win_attrib values with BOOL_VECTOR2

## src/codec.zig
Codec dispatch: decompress packed data for a folder's coder pipeline.
- `decompressFolder()` — handles single-coder and multi-coder pipelines
- `decompressMultiCoderPipeline()` — BCJ+LZMA2, AES+LZMA2, AES+BCJ+LZMA2
- `decodeLzma()` — LZMA1 decompression with Zig stdlib dictionary wrap bug workaround
- `decodeLzma2()` — LZMA2 decompression via std.compress.lzma2
- `bcjX86Decode()` / `bcjX86Encode()` — x86 BCJ filter (jump/call address translation)
- `compressLzma2()` — LZMA2 compression via lzma2_encoder (accepts ProgressContext for progress reporting)

## src/ffi.zig
C FFI boundary for z7z. All functions use C calling convention.
- `z7z_open` — open archive from memory buffer, returns opaque handle
- `z7z_file_count`, `z7z_file_name`, `z7z_file_data`, `z7z_file_size` — query file entries
- `z7z_file_is_dir` — check if entry is a directory (EmptyStream && !EmptyFile)
- `z7z_file_is_symlink` — check if entry is a symlink (POSIX S_IFLNK in win_attrib upper bits)
- `z7z_file_mtime` — get file mtime as Unix timestamp (FILETIME→Unix conversion)
- `z7z_file_ctime` — get file creation/birth time as Unix timestamp
- `z7z_file_atime` — get file access time as Unix timestamp
- `z7z_file_attrib` — get file's win_attrib (POSIX mode in upper 16, Windows attrs in lower 16)
- `z7z_file_xattrs` — get xattr blob pointer + length (NULL if none)
- `z7z_create` — create archive from file entries (supports flags, mtime, ctime, atime, win_attrib, xattrs)
- `z7z_create_ex` — create with progress callback (fires per-chunk/block during compression)
- `z7z_create_ex_pw` — create with password encryption + progress (LZMA2+AES when password set)
- `z7z_open_ex` / `z7z_open_ex_pw` — open with progress callback (fires per-folder during decompression)
- `z7z_close`, `z7z_free` — memory management
- `z7z_error_string` — human-readable error messages
- `Z7zFileEntry` — extern struct with name, data, data_len, flags, mtime, ctime, atime, win_attrib, xattrs, xattrs_len

## include/z7z.h
C header for the FFI. Matches ffi.zig exports.
- `z7z_file_entry` — struct with name, data, data_len, flags, mtime, win_attrib, ctime, atime, xattrs, xattrs_len
- `z7z_progress_fn` — progress callback typedef: (bytes_done, bytes_total, user_data)
- `z7z_open_ex()` / `z7z_open_ex_pw()` — open with progress + optional password
- `z7z_create_ex()` — create with progress callback
- `z7z_create_ex_pw()` — create with password + progress
- `z7z_file_mtime()` — get file modification time as Unix timestamp
- `z7z_file_ctime()` — get file creation/birth time as Unix timestamp
- `z7z_file_atime()` — get file access time as Unix timestamp
- `z7z_file_attrib()` — get file's win_attrib (POSIX mode<<16 | win_flags)
- `z7z_file_xattrs()` — get xattr blob pointer + length
- `z7z_file_is_symlink()` — query if archive entry is a symbolic link

## cli/main.c
C CLI that dogfoods the FFI (list, extract, create commands).
- `cmd_create` — accepts files, directories, and symlinks
  - Flags: `--dereference`/`-L`, `--no-ctime`, `--atime`, `--no-xattr`, `-p`/`--password`
  - Captures st_mtime, birthtime, atime, st_mode, xattrs from lstat()
  - Uses z7z_create_ex() with progress callback for compression progress bar + stats summary
- `cmd_extract` — creates directories, symlinks, and files; path traversal security for symlink targets
  - Flags: `--no-ctime`, `--no-xattr`, `-p`/`--password`
  - Restores permissions, mtime+atime via set_times(), birthtime via set_birthtime(), xattrs via restore_xattrs()
  - Deferred directory mtime restoration (deepest-first) to avoid clobbering by child writes
  - Uses z7z_open_ex() with progress callback for decompression progress bar + stats summary
  - Warnings: --no-ctime with no ctime in archive, --no-xattr with xattr data present
- `cmd_list` — shows `<dir>`, `<symlink>` with target, `[+xattr]` marker for xattr data
- `progress_state` / `progress_callback()` — progress bar with rate/ETA, isatty() gated, --no-progress flag
- `is_stdin_path()` / `is_stdout_path()` — check for `-` or `@stdin`/`@stdout` path aliases
- `read_stdin()` — read all of stdin into dynamically growing buffer
- `g_lang` — language selection: Z7Z_LANG env var, overridden by --lang flag (English default)
- `capture_birthtime()` — macOS: st_birthtimespec; Linux: statx() STATX_BTIME; others: 0
- `capture_atime()` — returns atime when --atime flag set
- `set_birthtime()` — macOS: setattrlist ATTR_CMN_CRTIME
- `capture_xattrs()` — serialize xattrs to blob (varint count + per-xattr name+value), applies blocklist
- `restore_xattrs()` — deserialize blob and setxattr each entry
- `xattr_is_blocked()` — blocklist: quarantine, genstore, diskimages.*
- `set_times()` — restore mtime + optional atime via utimes()
- `set_permissions()` — restore POSIX permissions from win_attrib upper bits via chmod()
- `win_attrib_from_mode()` — convert POSIX st_mode to 7z win_attrib format
- `entry_list` — dynamic array with xattr_bufs for directory walking
- `walk_directory()` — recursive POSIX directory traversal using lstat() (preserves symlinks by default)
- `symlink_target_is_safe()` — security check: rejects absolute paths and ../ traversal

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
