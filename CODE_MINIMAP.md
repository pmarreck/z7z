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
- `LevelParams` — compression level config: dict_size + nice_len per level 0-9, with `fromLevel()` mapping
- `compressBlock()` — self-contained single-block LZMA2 compression (own MatchFinder + LzmaEncoder)
- `compressParallel()` — parallel block compression via std.Thread.Pool (splits data, concatenates results)

## src/progress.zig
Progress callback context shared across compression/extraction pipeline.
- `ProgressContext` — struct with C-callable callback + user_data, no-op when callback is null

## src/archive.zig
Archive-level create and read operations.
- `FileEntry` — input struct with name, data, is_dir, is_symlink, mtime, win_attrib, ctime, atime, xattrs, group_index
- `ArchiveContents` — result struct with metadata + extracted file data
- `ArchiveStats` — metadata-only counts and unpack-size estimates for memory admission (files, folders, substreams, total/largest unpack sizes)
- `VerifyOptions` — deep verification guardrails: password, progress, max total/folder/file unpack sizes, max expansion ratio
- `computeWinAttrib()` — derives win_attrib from FileEntry type (dir/symlink/file), sets POSIX mode bits
- `LevelParams` — re-export from codec.zig (dict_size + nice_len per level 0-9)
- `inspect()` — parse archive metadata and return `ArchiveStats` without decompressing payloads
- `verify()` — deep-verify archive payloads folder-by-folder, checking folder/substream CRCs and discarding decompressed buffers
- `create()` / `createWithMethod()` / `createWithMethodAndPassword()` — archive creation (Copy, LZMA2, LZMA2+AES)
- `createWithLevel()` — archive creation with explicit compression level (0-9)
- `createWithProgress()` — archive creation with progress callback, defaults to level 5
- `createMultiFolder()` — multi-folder archive creation: groups files by group_index, one folder per unique group
  - Sorts files by (is_dir last, group_index asc, original order); directories appended after all data files
  - Supports .lzma2, .copy, and .lzma2_aes methods
  - For .lzma2_aes: per-group 2-coder pipeline (LZMA2 + 7zAES) with independent IV/salt/key derivation
  - Single group degenerates to one folder (no multi-folder overhead)
- `readWithProgress()` — archive extraction with progress callback (fires per-folder decompressed)
  - Multi-folder support: iterates ALL folders with correct pack offset calculation
  - Per-folder file mapping via SubStreamInfo.num_unpack_per_folder
  - Verifies folder/substream CRCs before returning extracted file data
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
- `decompressBcj2Pipeline()` — BCJ2 multi-stream DAG (4 sub-streams: main/call/jump/rc)
- `bcj2Decode()` — BCJ2 filter decode: range-coded E8/E9/0F8x branch recombination
- `bcj2RangeDecode()` — binary arithmetic range decoder for BCJ2 probability contexts
- `findPackStreamIndex()` — resolve global input stream to pack stream ordinal
- `decodeLzma()` — LZMA1 decompression with Zig stdlib dictionary wrap bug workaround
- `decodeLzma2()` — LZMA2 decompression via std.compress.lzma2
- `decodeZstd()` — Zstandard decompression via std.compress.zstd (7z method ID 04.F7.11.01)
- `bcjX86Decode()` / `bcjX86Encode()` — x86 BCJ filter (jump/call address translation)
- `LevelParams` — re-export from lzma2_encoder (compression level config)
- `compressLzma2()` — LZMA2 compression via lzma2_encoder (accepts dict_size, nice_len, ProgressContext)

## src/ffi.zig
C FFI boundary for z7z. All functions use C calling convention.
- `Z7Z_ERR_RESOURCE_LIMIT` — C-visible mapping for resource-limit errors from Zig archive APIs
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
- `z7z_create_ex_pw` — create with password + level + progress (LZMA2+AES when password set, level 0-9)
- `z7z_open_ex` / `z7z_open_ex_pw` — open with progress callback (fires per-folder during decompression)
- `z7z_close`, `z7z_free` — memory management
- `z7z_error_string` — human-readable error messages
- `Z7zFileEntry` — extern struct with name, data, data_len, flags, mtime, ctime, atime, win_attrib, xattrs, xattrs_len, group_index

## include/z7z.h
C header for the FFI. Matches ffi.zig exports.
- `Z7Z_ERR_RESOURCE_LIMIT` — resource-limit error code (appended to existing enum)
- `z7z_file_entry` — struct with name, data, data_len, flags, mtime, win_attrib, ctime, atime, xattrs, xattrs_len, group_index
- `z7z_progress_fn` — progress callback typedef: (bytes_done, bytes_total, user_data)
- `z7z_open_ex()` / `z7z_open_ex_pw()` — open with progress + optional password
- `z7z_create_ex()` — create with progress callback
- `z7z_create_ex_pw()` — create with password + level + progress
- `Z7Z_DEFAULT_LEVEL` — default compression level (5)
- `z7z_file_mtime()` — get file modification time as Unix timestamp
- `z7z_file_ctime()` — get file creation/birth time as Unix timestamp
- `z7z_file_atime()` — get file access time as Unix timestamp
- `z7z_file_attrib()` — get file's win_attrib (POSIX mode<<16 | win_flags)
- `z7z_file_xattrs()` — get xattr blob pointer + length
- `z7z_file_is_symlink()` — query if archive entry is a symbolic link

## cli/main.c
C CLI that dogfoods the FFI (list, extract, create, test commands).
- `solid_mode_t` — enum: SOLID_AUTO (MIME-grouped), SOLID_ON (one block), SOLID_OFF (per-file blocks)
- `init_magic()` — initialize libmagic handle (MAGIC_MIME_TYPE | MAGIC_SYMLINK); no-op on Windows
- `detect_mime()` — detect MIME type for a filesystem path via libmagic; returns NULL on failure
- `assign_mime_groups()` — cluster entry_list files by unique MIME type, assigning group_index per unique MIME
- `wildcard_match()` — simple wildcard matching (supports `*` and `?`)
- `matches_filter()` — check if archive entry matches selective extraction filters (exact, wildcard, basename, prefix)
- `cmd_test` — verify archive integrity without extracting; reports "Everything is Ok" or error
  - Flags: `--no-progress`, `-v` (show individual file names), `-p`/`--password`
- `cmd_create` — accepts files, directories, and symlinks
  - Flags: `--dereference`/`-L`, `--no-ctime`, `--atime`, `--no-xattr`, `-p`/`--password`, `--solid`, `--no-solid`, `-mx=N`, `-0`..`-9`, `--level N`, `-mmt=N`, `-mhe=on`
  - Captures st_mtime, birthtime, atime, st_mode, xattrs from lstat()
  - Uses progrez library for progress display + z7z-specific archive summary (ratio, sizes, entries)
- `cmd_extract` — creates directories, symlinks, and files; path traversal security for symlink targets
  - Supports flat extract via `e` command (strips directory structure, extracts basenames only)
  - Supports selective extraction: remaining positional args are file filters (exact, wildcard, directory prefix)
  - Flags: `--no-ctime`, `--no-xattr`, `-p`/`--password`, `-o<dir>`, `-y`
  - `-o<dir>`: output directory (7zz-compatible, no space)
  - `-y`: overwrite existing files without prompting (default: skip with warning)
  - Restores permissions, mtime+atime via set_times(), birthtime via set_birthtime(), xattrs via restore_xattrs()
  - Deferred directory mtime restoration (deepest-first) to avoid clobbering by child writes
  - Uses progrez library for progress display + z7z-specific extraction summary
  - Warnings: --no-ctime with no ctime in archive, --no-xattr with xattr data present
- `cmd_list` — shows `<dir>`, `<symlink>` with target, `[+xattr]` marker for xattr data
- `progrez_adapter()` — bridges z7z FFI's (done, total, user_data) callback to progrez_update()
- `elapsed_since()` / `format_size()` — timing and size formatting for archive-specific summary stats
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
Build configuration. Static lib + C CLI + test step. ReleaseFast default.
- libmagic linked as a static dependency via build.zig.zon on non-Windows targets
- progrez linked as a static dependency via build.zig.zon on all platforms
- `_GNU_SOURCE` macro added for Linux musl compatibility (statx, asprintf)
- CLI compiled with `-std=gnu11` for POSIX extension support

## build.zig.zon
Package manifest. Dependencies:
- `libmagic` — pmarreck/libmagic (file-5.46 with Zig build system, static linkage)
- `progrez` — pmarreck/progrez (progress bar library with truecolor gradient, render thread, C FFI)

## flake.nix
Nix devShell: zig 0.15.x, 7zz (oracle), hyperfine, luajit, jq, file (for magic database).
- Pre-fetches libmagic tarball for Nix sandbox builds via `--system` flag pattern.

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
