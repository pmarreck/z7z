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
- [x] Profile and identify hot paths — DP inner loop price estimation was the bottleneck (~2026-02-23)
- [x] Pre-compute position-dependent price invariants (is_match, is_rep, rep base prices) (~2026-02-23)
- [x] Pre-compute length price tables [16][272] for len_encoder and rep_len_encoder (~2026-02-23)
- [x] Pre-compute distance price tables (pos_slot[4][64], align[16], special_dist[128]) (~2026-02-23)
- [x] Result: 374ms → 258ms (31% faster) on price table pre-computation (~2026-02-23)
- [x] Multithreading: parallel block compression via std.Thread.Pool (~2026-02-23)
  - Made prob_prices comptime-const (thread safety prerequisite)
  - compressBlock: self-contained single-block LZMA2 compression
  - compressParallel: splits data into N blocks (min 1MB), compresses independently
  - compress() auto-detects CPU count, dispatches to parallel path for data >= 1MB
  - 3 new tests: compressBlock roundtrip, compressParallel 4-thread, large-data compress roundtrip
- [x] Match finder optimization: 10x speedup, z7z now FASTER than 7zz-st (~2026-02-23 EST)
  - Profiled: 97.9% of CPU time was in BT4 match finding (byte-by-byte comparison)
  - u64 XOR + @ctz word-at-a-time string comparison (5x speedup)
  - Nice-length early exit (NICE_LEN=128): stop tree traversal at long matches
  - Lightweight skip: hash-only update instead of full tree maintenance
  - BT_DEPTH reduced from 64 to 32
  - Results: 1.16MB text 12.6ms vs 7zz 22.2ms (1.76x faster), 4MB text 18.9ms vs 69.4ms (3.67x faster)
  - Trade-off: slightly larger compressed output on highly repetitive text (tree quality vs speed)
- [x] HC2+HC3 secondary hash tables + tree-preserving skip (~2026-02-23 EST)
  - 2-byte perfect hash (64K entries) + 3-byte hash (256K entries) for short matches
  - Skip only updates HC2/HC3, leaves BT4 tree untouched → restored compression quality
  - text_1m: 1861→1045 bytes (44% smaller), text_4m: 6575→3686 bytes (44% smaller)
  - Speed maintained: 2.0x faster than 7zz-st on text, 3.84x on 4MB parallel
- [ ] Further optimization: HC4 hybrid, LLVM IR hand-tuning
- [x] Incompressible data performance: 113ms → 7.7ms (8.4x faster than 7zz) (~2026-02-24 EST)
  - HC miss early-out: skip BT4 tree walk when neither HC2 nor HC3 finds a match
  - Adaptive BT4 depth: depth=2 when only HC2 matched (no HC3 hit)
  - Entropy-based chunk probe: count unique bytes in first 2KB; ≥250 → skip LZMA encoder
  - Dictionary match check: probe HC3 for cross-chunk matches before skipping
  - Result: random 1MB 7.7ms vs 7zz 65ms; compressible text unchanged (12.6ms, 1.5x faster)

## Phase 8: Benchmark Suite (~2026-02-23)
- [x] `./bm` — Bash script using hyperfine to benchmark z7z vs 7zz (~2026-02-23 EST)
  - 4 data files: 1.16MB text, 4MB text, 1MB binary, 1MB gaussian (deterministic, RAM-backed)
  - 3 commands per file: z7z (auto), 7zz -mx=5 -mmt=1, 7zz -mx=5 -mmt=on
  - Compression ratio display, 7zz interop validation, debug build check
  - Results logged to tests/benchmark/benchmark.log with regression detection (>10% delta)
- [x] Microbenchmark regression guard in lzma2_encoder.zig (~2026-02-23 EST)
  - 256KB deterministic compress, fails if >25% slower than 150ms baseline
  - Runs as part of `./test` to catch algorithmic regressions automatically
- [x] Vendored LuaJIT tools: random, gen-fake-tree, dictionary.txt in tools/ (~2026-02-24 EST)
  - bm script updated to use vendored tools/random instead of PATH dependency

## Phase 9: Feature Completion
- [x] Directory input support for `create` command (recursive file collection) (~2026-02-24 EST)
  - FileEntry.is_dir field, directory metadata (EmptyStream, FILE_ATTRIBUTE_DIRECTORY)
  - Correct substream index mapping in read() (directories skip substream entries)
  - C FFI: z7z_file_is_dir(), Z7Z_FLAG_DIRECTORY flag, z7z_file_entry.flags
  - CLI: recursive walk_directory(), ensure_dir_recursive(), directory-aware extract
  - 44 CLI tests (23 new): directory roundtrip, trailing slash, mixed files+dirs, 7zz interop
- [x] Multi-file benchmark using gen-fake-tree (~2026-02-24 EST)
  - `run_dir_benchmark_group()` in bm script: generates deterministic 50-file tree via gen-fake-tree
  - Benchmarks z7z vs 7zz on directory archive creation, validates interop
- [x] Multi-folder (multi-block) archive extraction (~2026-02-24 EST)
  - readWithPassword() now iterates ALL folders with correct pack offset and per-folder file mapping
  - Added SubStreamInfo.num_unpack_per_folder for proper file→folder assignment
  - Workaround for Zig stdlib LZMA dictionary wrap bug (CorruptInput when output > dict_size)
  - 5 new CLI tests: non-solid 3-file extraction, solid multi-block extraction
  - Verified against real-world 107MB archive (16905 files, 2 folders, BCJ+LZMA2)
- [x] Symlink support (reading + writing symlinks as 7z stores them) (~2026-02-24 EST)
  - FileEntry.is_symlink, computeWinAttrib() with S_IFLNK in upper 16 bits of win_attrib
  - FFI: Z7Z_FLAG_SYMLINK, z7z_file_is_symlink() detection via POSIX mode bits
  - CLI create: lstat() + readlink() for symlink detection, --dereference/-L flag
  - CLI extract: symlink() creation with path traversal security (rejects absolute/../ targets)
  - CLI list: <symlink> display with target path
  - Broken symlink preservation, bidirectional 7zz interop verified
  - 62 CLI tests (7 new symlink tests), 2 new Zig unit tests, 2 new FFI tests
- [x] Metadata preservation: mtime + POSIX permissions on create and extract (~2026-02-24 EST)
  - FFI: z7z_file_mtime() and z7z_file_attrib() query functions, FILETIME↔Unix conversion
  - z7z_file_entry struct extended with mtime (int64_t) and win_attrib (uint32_t)
  - CLI create: captures st_mtime and st_mode from lstat(), encodes as FILETIME + POSIX-in-win_attrib
  - CLI extract: restores mtime via utimes(), permissions via chmod(), deferred dir mtime
  - 5 new CLI tests: file mtime, 0640 perms, 0755 perms, directory mtime, 7zz→z7z mtime interop
  - 69 total CLI tests, all passing
- [x] Shannon entropy adaptive nice_len (~2026-02-24 EST)
  - Kept as experimental: documented trade-offs and rollback sites in code
  - Replaces unique-byte-count probe with multi-window Shannon entropy
  - Tunes MatchFinder.nice_len per-chunk: 128/64/32/16 based on entropy thresholds
  - Benefit: ~10% better compression on mixed-file directory archives
  - Cost: added complexity, no improvement on single-file benchmarks
- [x] Birthtime (kCTime) + atime (kATime) support (~2026-02-24 EST)
  - Zig core: ctime/atime fields in FileEntry, threaded through all createXxx()
  - FFI: z7z_file_ctime()/z7z_file_atime() query functions, Z7zFileEntry extended
  - CLI: --no-ctime (suppress birthtime), --atime (enable access time) flags
  - macOS: capture via st_birthtimespec, restore via setattrlist ATTR_CMN_CRTIME
  - Linux: capture via statx() STATX_BTIME (correctly uses birth time, not inode ctime)
  - Birthtime on by default (unlike 7zz which stores wrong st_ctime)
  - --no-ctime on extract warns if archive had no creation times
  - 7zz interop verified: z7z archives with ctime pass `7zz t`, 7zz -mtc archives readable
- [x] Extended attribute (xattr) preservation via custom property 0x7A (~2026-02-24 EST)
  - Custom 7z property ID 0x7A ('z'): transparent to 7zz (skips unknown properties by size)
  - Zig core: NID.xattr, FileInfo.xattrs, parseXattrProperty(), encodeXattrProperty()
  - FFI: z7z_file_xattrs() query, FileEntry.xattrs, Z7zFileEntry extended
  - CLI: capture/restore with blocklist (com.apple.quarantine, genstore, diskimages.*)
  - Blob format: varint count, per-xattr varint:name_len + name + varint:val_len + val
  - --no-xattr flag works on both create and extract
  - List command shows [+xattr] marker for entries with xattr data
  - macOS: listxattr/getxattr/setxattr with XATTR_NOFOLLOW
  - Linux: llistxattr/lgetxattr/lsetxattr for symlink support
  - com.apple.ResourceFork preserved (not on blocklist)
  - 7zz validates z7z archives with 0x7A property ("Everything is Ok")
  - 89 total CLI tests (20 new), all passing
- [x] CLI UX: --help, --about, --version, --verbose, --no-progress flags (~2026-02-24 EST)
- [x] Progress reporting with rate/ETA for compression and extraction (~2026-02-24 EST)
  - ProgressContext struct (C-callable callback + user_data) in separate progress.zig module
  - Threaded through entire pipeline: lzma2_encoder → codec → archive → FFI
  - Sequential: per-64KB-chunk reporting in compressChunked()
  - Parallel: per-block atomic counter in compressParallel()
  - Extraction: per-folder packed bytes decompressed
  - FFI: z7z_create_ex(), z7z_open_ex(), z7z_open_ex_pw() with z7z_progress_fn callback
  - CLI: progress bar with rate/ETA on interactive terminals, summary stats on completion
  - isatty() check + --no-progress flag to suppress
  - 106 total CLI tests (7 new progress tests), all passing
- [x] --password/-p flag for encrypted archive create/extract (~2026-02-24 EST)
  - z7z_create_ex_pw() FFI export: LZMA2+AES when password set, plain LZMA2 otherwise
  - CLI: -p/--password on create, extract, and list commands
  - Wrong password / missing password → proper error handling
  - 7zz interop verified for encrypted archives
  - 114 total CLI tests (8 new encryption tests), all passing
- [x] stdin/stdout support: - and @stdin/@stdout (~2026-02-24 EST)
  - read_stdin() with dynamic buffer growth for piped archive input
  - write_file() supports stdout path for archive output
  - Works with create (output to stdout), extract (input from stdin), list (input from stdin)
  - 120 total CLI tests (6 new stdio tests), all passing
- [x] i18n groundwork with --lang flag and Z7Z_LANG env var (~2026-02-24 EST)
  - English-only for now (groundwork for 30-language translations)
  - --lang <code> flag overrides Z7Z_LANG env var which overrides locale detection
  - Refactored flag parsing to support flags before and after command name
  - 123 total CLI tests (3 new i18n tests), all passing
- [x] Multi-folder encrypted archive support (createMultiFolderAes) (~2026-02-26 EST)
  - createMultiFolder now handles .lzma2_aes method with per-group encryption
  - Each group gets independent 2-coder pipeline (LZMA2 + 7zAES) with unique IV/salt/key
  - Auto-dispatched via createWithProgress when mixed group_indices + encryption
  - 132 Zig unit tests (1 new), 123 CLI tests, all passing
- [x] MIME-grouped solid archive creation via libmagic (~2026-02-26 EST)
  - createMultiFolder() in archive.zig: N folders, one per unique group_index
  - createMultiFolderAes() for encrypted multi-folder archives (integrated into createMultiFolder)
  - libmagic integration in CLI: magic_open(MAGIC_MIME_TYPE) -> magic_file() per entry
  - assign_mime_groups() clusters by exact MIME type
  - --solid (one block), --no-solid (one file per block), default (MIME-grouped)
  - group_index field added to FileEntry/Z7zFileEntry/z7z_file_entry
  - 7zz interop verified for all modes (solid, no-solid, grouped, encrypted)
  - Edge case tests: single group, 3+ groups, symlinks across groups, single file, all same type, empty dir
  - 157 total CLI tests, all passing

- [x] Vendor libmagic via build.zig.zon for cross-platform CI (~2026-02-26 EST)
  - Created pmarreck/libmagic GitHub repo with Zig build system for file-5.46
  - Replaced linkSystemLibrary("magic") with static dependency via build.zig.zon
  - Platform-conditional: libmagic linked on non-Windows, skipped on Windows (CLI already gated)
  - Fixed Linux cross-compile: removed <linux/stat.h>, use musl statx via _GNU_SOURCE
  - Fixed Windows cross-compile: added <io.h>/<fcntl.h>/<sys/utime.h>, _utime fallback
  - Updated flake.nix with pre-fetch + --system pattern for Nix sandbox builds
  - All 5 CI targets build: macOS aarch64, Linux x86_64/aarch64, Windows x86_64/aarch64

- [x] Compression levels: -mx=N, -N, --level N (0-9) (~2026-02-28 EST)
  - LevelParams struct in lzma2_encoder.zig: dict_size (64KB-64MB) + nice_len (8-256) per level
  - Threaded through entire call chain: encoder → codec → archive → FFI → CLI
  - createWithLevel() in archive.zig accepts level: u4
  - z7z_create_ex_pw() FFI extended with level: u8 parameter
  - CLI: -mx=N (7zz compatible), -N (Unix shorthand), --level N (verbose)
  - Default level 5 (matches 7zz -mx=5)
  - Dict size clamped to data length for small files
  - Adaptive nice_len uses level's nice_len as ceiling
  - 7zz interop verified at levels 0, 3, 9
  - 172 total CLI tests (15 new), all passing

## TODO
- [x] CI: GitHub Actions for macos-aarch64, linux-x86_64, linux-aarch64, windows-x86_64, windows-aarch64
- [ ] Actual i18n translations (30 languages) once textual UI is stable
- [ ] `--simple` flag (suppress emoji + ANSI)
- [ ] `--no-ansi`/`--no-color` flags
- [ ] JSON output option for structured output
