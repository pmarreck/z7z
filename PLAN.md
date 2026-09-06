# z7z — Implementation Plan

## Active Roadmap: Complete 7z Verification and Oracle Removal (2026-09-04 EDT)

### Approved Next Steps (2026-09-06 EDT)

Peter gives standing approval for delegation (2026-09-06 EDT). Assign disjoint
files or isolated worktrees; the coordinating agent owns shared integration and
must independently check each agent's test and performance claims.

- [x] Resolve missing Mechatron CI delivery for commit 1567c2c and verify its exact-commit result (2026-09-06 10:50 AM EDT). Retried the signed GitHub delivery; all six targets passed in 228 seconds.
- [x] Add a persistent regression check for Downloads/RESET BAT-499-v1.7z (2026-09-06 10:50 AM EDT). The failure no longer reproduces: oracle, C ABI, Zig verification, and installed validate all pass. Method is LZMA:16; no decoder fix was warranted. Keep the private archive out of Git.
- [x] Create an initial machine-readable verification feature matrix with method/property IDs, implemented paths, evidence, and explicit gaps (2026-09-06 11:02 AM EDT). 26 method rows and 19 structural/consumer rows; set-based mutation tests and Nix coverage check pass. The oracle-removal gate intentionally fails while coverage is incomplete.
- [ ] Implement the confirmed filter, Deflate64, BZip2, PPMd, and archive-structure gaps in separately tested and measured increments; retain the development oracle until the complete matrix passes.
- [x] Resolve the measured LZMA2 regression (2026-09-06 12:22 PM EDT). Prevent BZip2 sink-call inlining to restore the shared dispatch frame. Twelve canonical Nix pairs measured CPU 738.52 ms baseline, 777.00 ms initial integration, 738.24 ms final. The earlier LZMA2 noinline candidate failed canonical acceptance. All measurements remain in tests/benchmark/2026-09-06-codecs.json.
- [ ] Ship the integrated codec/filter increment after final benchmarks, full tests, five-target builds, and exact-commit Mechatron CI; notify validate of the pushed revision and remaining limits.
- [x] Check BZip2 final padding against the 7z oracle (2026-09-06 11:55 AM EDT). Twelve nonzero-padding variants preserve oracle output but initially failed with TrailingData. Removed only the zero-padding guard; all 17 adapter tests pass and whole trailing bytes remain rejected. Evidence: src/fixtures/bzip2/padding-provenance.json.
- [x] Integrate pinned pure-Zig bzip2z 6113a10 for 7z BZip2 data (2026-09-06 12:22 PM EDT). Adapter tests cover whole-write semantics, original sink errors, allocation limits/failures, CRC/framing, multiblock/RLE and padding. Retained/sink/range/C ABI paths pass; BCJ2 pull remains unsupported. Normal Zig dependency and Nix FOD verified without sibling edits or vendoring.
- [x] Verify final codec integration with ./build, ./test, Nix test/coverage checks, and all five ./build_all targets (2026-09-06 12:22 PM EDT). Existing CLI 178/178 and new fixture CLI 405/405 checks pass; 31/31 archives supported. Final Nix verifier exactly matches the measured executable SHA-256 b12c59e6d96550c97c180256fad24a735568ee611776b9359703056bb0612178.
- [x] Preserve encrypted-header behavior under strict coder output-size checks (2026-09-06 11:52 AM EDT). Use the unbound output size, not the final metadata array entry. Existing archive/C ABI regressions became red; focused reproduction confirmed StructuralError, then passed after the correction. Full suite passes.
- [x] Verify and enforce optional packed-stream/header CRCs (2026-09-06 approximately 11:25 AM EDT). Paired failing regressions, permanent oracle-audited fixtures, retained/slice/range and C CLI checks pass. Full ./test and ./build passed in an isolated CRC-only worktree. Gaussian/uniform LZMA2 wall changes -0.47%/-0.18%, within measured variation; tests/benchmark/2026-09-06-crc.md. Packed CRC checks intentionally reject two cases the oracle accepts.
- [x] Ship CRC fix 362499532be7b7ed152cc8c991257ab09f01e718 and verify all seven Mechatron targets (2026-09-06 11:51 AM EDT). Sent validate a durable status note with exact SHA/CI result and the Zig-to-Zig/C ABI clarification; receipt has not been acknowledged.

Completed delegated work: Noether owns src/filters.zig and filter fixtures; Pauli owns
src/deflate64.zig and Deflate64 fixtures; Raman owns the BZip2 adapter/reuse audit;
Arendt owns PPMd feasibility/implementation. Progress and final reports are in
/tmp/dispatch-log/z7z-{filters,deflate64,bzip2,ppmd}-{progress,final}.md. The parent
owns archive dispatch, dependency manifests, builds, tests, and shipping. Follow-up
delegation (2026-09-06 11:16 AM EDT): Pauli integrates Deflate64 and filters in
src/codec.zig; Noether independently checks the CRC fixtures with the oracle;
Raman investigates a portable pinned BZip2 build dependency. PPMd model reuse
awaits Peter's provenance decision; its property parser is not decoder support.
The coordinator has integrated the completed codec/filter work. Noether's
performance follow-up is complete; final shipping remains coordinator-owned.

- [x] Integrate the verified Zig 0.16 stdlib Deflate decoder into retained extraction, sink/range verification, and supported coder chains; use failing tests and record performance (completed 2026-09-04 09:58 PM EDT; tests/benchmark/2026-09-04-deflate.md). Ship through exact-commit Mechatron CI.
- [x] Repair the pre-existing nondeterministic CLI compression-level fixture exposed by the baseline run; replace random/clock input with deterministic data and let ./test accumulate failures (completed 2026-09-04 09:53 PM EDT; 196/196 Zig and 178/178 CLI checks pass).
- [x] Integrate ordinary Deflate through std.compress.flate into extraction, sink/range verification, BCJ, BCJ2, and AES pipelines. Permanent oracle fixtures, malformed/truncated inputs, allocation failures, and sink failures pass; ./build and all five ./build_all targets pass (completed 2026-09-04 09:53 PM EDT).
- [x] Lay out a reviewable, ordered plan for complete feature coverage and eventual oracle removal (completed 2026-09-04 09:06 PM EDT).
- [x] Incorporate verification-first scope for ../validate and ../validate_gui, with ZIP handled separately and RAR owned by ../rarz (completed 2026-09-04 09:06 PM EDT).
- [x] Inspect ~/Code projects for an existing Zig Deflate decoder/encoder and assess reuse in 7z verification (completed 2026-09-04 09:10 PM EDT; source inspection only).
- [x] Trace ../validate Deflate handling and its dependencies as a reuse lead (completed 2026-09-04 09:10 PM EDT; source inspection only).
- [x] Investigate Zig decoder correctness with independent fixtures, historical stdlib regression cases, Deflate64 distinctions, and bzip2z integration constraints (completed 2026-09-04 09:25 PM EDT; see docs/research/2026-09-04-decoder-reuse.md).

Peter clarified that deflate_fingerprint is an incomplete attempt to reproduce
original ZIP encoder output byte-for-byte when restoring Office documents from a
different archive representation. Its forensic identity requirement must not be
confused with z7z's need to decode and verify existing Deflate streams.

### Contract and Completion Criteria

The codec and archive implementation remains pure Zig, developed from format
specifications and black-box behavior. Reference executables are temporary
development tools. They must never become production dependencies. Retain the
oracle until the entire agreed current-feature inventory passes compatibility
checks; completing individual codecs does not authorize early oracle removal.
Keep independently obtained fixtures and expected results after removal.

The official release baseline on 2026-09-04 is 7-Zip 26.03 (2026-09-03), verified
against https://www.7-zip.org/ and https://www.7-zip.org/history.txt. Pin the actual
oracle binary version and hash when building the matrix. Reconcile newer releases
before declaring completion, so a stale baseline cannot satisfy "current."

The target is complete reading and deep verification of current 7z archive
features, primarily as a library for ../validate and ../validate_gui. ZIP has a
separate handler; RAR belongs to ../rarz. Other archive containers, the 7-Zip GUI,
shell integration, and full archive-editing/encoder parity are outside this
milestone. Existing creation and extraction behavior must keep working.
Deflate inside a 7z coder pipeline remains in scope even though ZIP is handled
elsewhere. Inspect the existing pure-Zig Deflate API for reuse before duplicating
it; preserve allocator ownership, cleanroom provenance, and dependency boundaries.
No currently supported feature is excluded merely because its algorithm is old.
Any obsolete exclusion requires documented evidence and Peter's agreement.

### 1. Establish a Falsifiable Inventory

- [x] Record the scope decision and reconcile PROJECT_OVERVIEW.md and README.md with it (completed 2026-09-04 09:53 PM EDT).
- [ ] Create a machine-readable feature matrix from the pinned binary's capabilities, official user documentation, format specifications, and observed behavior. Do not consult reference implementation source.
- [ ] Record method/property IDs, valid parameter ranges, decode/inspect/verify support, platform restrictions, test IDs, fixture provenance, and measured status for each row. Track existing write support separately as regression coverage.
- [ ] Separate implemented, independently verified, missing, and explicitly excluded states. Unknown or skipped coverage blocks completion.
- [ ] Run the existing suite and a deterministic ReleaseFast baseline before implementation; record wall time, CPU time, memory, compressed size, hardware, and commit.
- [ ] Audit existing oracle references, fixture provenance, production linkage, and Nix dependencies. Resolve provenance gaps before claiming cleanroom completion.
- [ ] Curiosity poke: can a passing test exercise an identity filter or skip a missing oracle? Require transformed-data witnesses and fail missing required oracle checks during this phase.

### 2. Establish Permanent Compatibility Evidence

- [ ] Build a versioned fixture corpus with seeded text, random and partially compressible data, architecture-specific branch instructions, empty files, boundary-sized inputs, and multi-file trees.
- [ ] Capture oracle-generated archives, exact payloads or hashes, metadata, creation commands, oracle version/hash, and expected validity. Include deliberately malformed fixtures with specified rejection reasons.
- [ ] For every supported operation, test z7z reading oracle output and the oracle reading z7z output where writing is supported. Compare content and metadata; do not require compressed bytes to match when multiple encodings are valid.
- [ ] Wire retained extraction, sink verification, range verification, Zig APIs, and the dogfooded C ABI/CLI into applicable matrix rows.
- [ ] Add classifier-set coverage, truncation sweeps, corruption tests paired with valid archives, and seeded property/metamorphic tests. Keep fuzzing and timing benchmarks outside ./test.
- [ ] Curiosity poke: a z7z-only round trip can preserve matching encoder/decoder bugs. Keep independent vectors and previously validated encoder-output evidence alongside it.

### 3. Complete Codecs and Filters in Small TDD Units

The following gaps come from the existing dispatch code and the earlier inventory;
recheck their decoding capabilities against 26.03 before marking matrix rows.

- [x] Implement Delta and Swap2/Swap4 with property validation and split-buffer tests (2026-09-06 11:52 AM EDT). Retained/sink/range and C CLI tests pass; generic coder graphs remain pending.
- [x] Implement ARM64 and RISC-V filters, then ARM, Thumb, PowerPC, SPARC, and IA64 (2026-09-06 11:52 AM EDT). Oracle non-identity cases, offsets, alignment, wraparound and instruction splits pass; generic coder graphs remain pending.
- [x] Evaluate Deflate reuse candidates with independent fixtures: pinned Zig 0.16 passes 90 comparisons, short-input tests, and the original #24963 ZIP; fingerprint inspection accepts an invalid backreference (completed 2026-09-04 09:25 PM EDT).
- [x] Add failing 7z Deflate archive/sink/range regressions, then integrate std.compress.flate with allocator-owned buffers, strict output limits, and before/after measurements (completed 2026-09-04 09:58 PM EDT).
- [x] Implement Deflate64 separately (2026-09-06 11:52 AM EDT). 64 KiB distances, extended code285, framing checks and all four BCJ2 input roles pass. Initial long-history verification measures about 114 MiB/s; complete combination inventory remains pending.
- [x] Evaluate local bzip2z: 2 MiB oracle payload passes, partial sink writes lose output, and repeated-data expansion grows buffers before the sink sees bytes (completed 2026-09-04 09:25 PM EDT).
- [ ] Integrate a verified green bzip2z revision with all-or-error sink writes, preserved resource/input/cancellation errors, and allocator-enforced limits. Cover multi-block decoding, integrity checks, and legacy encodings still accepted by the current oracle. The investigated sibling worktree contains uncommitted changes.
- [ ] Implement PPMd with the exact variant and property semantics used by 7z; exercise model resets, memory limits, and truncation.
- [ ] Audit LZMA, LZMA2, BCJ, BCJ2, and AES across retained extraction, sink verification, and range verification. Close decoding and verification gaps without requiring new encoders for this milestone.
- [ ] Preserve existing Zstd extension behavior and determine its status separately from official 7-Zip 7z capabilities.
- [ ] Integrate each codec through archive, verification, C ABI, and CLI paths before declaring that feature complete. Require failing tests first, then full suite/build and measured performance.
- [ ] Curiosity poke: support legal parameter combinations and tail conditions, not just each method's defaults.

Reuse findings (2026-09-04 EDT, inspected source; no builds/tests run):

- ../deflate_fingerprint/src/encoder.zig provides our own parameterized raw-Deflate encoder, exported through the deflate_fingerprint Zig module. src/inspect.zig:inspectTokens parses stored/fixed/dynamic blocks into an allocated token trace. src/blocks.zig:reconstructFromTokens expands a different token representation into a full output buffer. These are useful primitives, but the inspected APIs do not provide bounded streaming verification or Deflate64 support; they require contract/provenance review before reuse.
- ../validate/src/core/archive_validators.zig calls zlib.inflateRawWithCrc for ZIP and zlib.validateGzipBodyStream for gzip. src/core/zlib.zig wraps C zlib through @cImport; build.zig.zon pins allyourcodebase/zlib 1.3.2. Its inflateStream callback API also calls C zlib. It is not an existing pure-Zig decoder to import into z7z.
- validate's source comments cite historical std.compress.flate failures (ziglang/zig#24963); this inspection does not establish their status in the pinned Zig 0.16 toolchain. Reproduce the relevant cases before judging current stdlib reuse.
- ../blar/src/zip.zig uses std.compress.flate.Decompress in raw mode with retained output; src/zlib_io.zig uses zlib framing. Its src/deflate_emit.zig calls C zlib for encoding. ../pdfz, ../tiffz, and ../c0 Deflate adapters also wrap C zlib. ../zigimg carries Zig encoder code, but the inspected compression directory did not expose a decoder.
- ../bzip2z/src/bzip2.zig exposes allocator-owned Decompressor state and reader/writer decompression, plus retained-output convenience APIs. validate already imports bzip2z. Treat it as the first BZip2 integration candidate; audit framing, limits, and current tests.

### 4. Complete Archive Structures and Bounded Streaming

- [ ] Exercise and implement valid coder graphs, binding order, multiple packed streams, filter chains, and encrypted combinations, including BCJ2. Reject cycles, invalid bindings, and inconsistent sizes.
- [ ] Reproduce source-review concerns with executable tests: unchecked folder stream totals/bind indices, ignored simple-pipeline bindings, and unused BCJ2 side-stream bytes. These are unproven risks, not demonstrated false acceptances (2026-09-06 review).
- [ ] Audit bzip2z malformed RUNA/RUNB accumulation and independently cover randomized blocks, maximum RLE expansion, and concatenated members. The current adapter corpus does not establish these cases.
- [ ] Complete plain, encoded, and encrypted headers; external metadata streams where supported; substream defaults; optional CRCs; empty-stream flags; Unicode names; timestamps; attributes; and unknown-property handling.
- [ ] Cover solid/non-solid/multi-folder archives, zero-length entries, large sizes and offsets, archive prefixes/SFX, trailing data, and split volumes according to observed reference semantics.
- [ ] Complete packed-input streaming within a single solid folder, including decryption and multi-stream pipelines; account for codec dictionary/model memory explicitly.
- [ ] Verify slice, short-read range, retained extraction, and sink paths give equivalent content/integrity results under injected read and allocation failures.
- [ ] Curiosity poke: distinguish malformed input, unsupported features, password errors, resource-limit failures, and valid archives larger than a configured policy permits.

### 5. Integrate the Verification Consumers

- [ ] Inspect ../validate and ../validate_gui consumer contracts; identify the actual library/adaptor ownership before editing either consumer. Keep RAR dispatch delegated to ../rarz and ZIP to its existing handler.
- [ ] Cover metadata inspection, deep verification, seekable/range reads, split-volume input adapters, password supply, cancellation, and progress where required by those consumers. Keep filesystem I/O in adapters.
- [ ] Return distinct outcomes for corrupt data, unsupported methods, missing/wrong passwords when distinguishable, missing volumes, input failure, cancellation, and resource limits. An encrypted archive without a password cannot be reported as deeply verified.
- [ ] Report verification strength when checksums are absent: successful structural decoding cannot prove integrity of every payload byte. Specify treatment of unverifiable/ambiguous cases in consumer tests.
- [ ] Retain allocator-aware direct Zig APIs while the C CLI continues exercising the C ABI. Test allocation failure and ownership across both boundaries.
- [ ] Add consumer regressions for the reported RESET archive and representative new methods, plus concurrent verification under caller-provided memory limits. Preserve C CLI verification coverage.
- [ ] Run relevant runtime tests on supported operating systems; cross-compilation alone does not verify runtime behavior.
- [ ] Curiosity poke: verify hostile filenames and metadata in memory without creating archive-controlled filesystem paths; callers must not confuse verification with safe extraction.

### 6. Validate the Complete Feature Set

- [ ] Require all applicable matrix cells to pass with no unapproved exclusions, unknowns, or silently skipped tests. Publish counts and evidence by exact commit.
- [ ] Sweep valid parameter boundaries and feature combinations; exhaust finite small domains and document the sampling strategy for larger combinations.
- [ ] Run independent acceptance review from specifications and the matrix, plus differential fuzzing and representative real-world archives. Convert every discovered defect into a permanent regression.
- [ ] Measure ReleaseFast verify performance on deterministic mixed data, recording CPU/wall time, peak memory, and allocations. Retain create/extract regression benchmarks for changed shared code. Investigate regressions before accepting baselines.
- [ ] Pass ./test, ./build, ./build_all, runtime platform checks, and exact-commit Mechatron CI. Reconcile the pinned inventory with the latest official release.
- [ ] Curiosity poke: finite testing cannot prove every possible archive correct. Report actual feature/parameter/combination coverage and remaining uncertainty without calling a sample exhaustive.

### 7. Remove the Development Oracle

- [ ] After full parity acceptance, replace remaining live-oracle test/benchmark needs with retained independent fixtures, reference measurements, contract checks, and seeded property tests.
- [ ] Remove oracle executables and dependencies from the development shell, test runners, benchmarks, CI, and build inputs. Preserve useful provenance and historical measurements.
- [ ] Run the entire required workflow in an environment with no oracle executable available. Assert test counts so disappearance of differential tests cannot silently reduce coverage.
- [ ] Verify production and development dependency closures, then commit, push, and confirm Mechatron passes for that exact commit.
- [ ] Curiosity poke: fixtures preserve past compatibility evidence but cannot independently validate every future encoder output. Future format/encoder changes need fresh independent evidence, with temporary oracle use when required.

Execution order: inventory and permanent evidence first; codecs/filters can then
proceed independently against agreed interfaces while archive/CLI integration is
kept incremental. Each completed unit gets its own green commit. Existing packed
input streaming work remains in scope under step 4. This roadmap supersedes broad
"Complete" headings below as evidence of overall feature parity; those sections
record historical delivery of an implemented subset.

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

## Phase 5: Initial Compression Codecs (Delivered Subset)
- [x] LZMA2 decode (wrapping std.compress.lzma2)
- [x] LZMA decode (wrapping std.compress.lzma)
- [x] Encoded header support (kEncodedHeader → decompress → parse)
- [x] Codec dispatch module (codec.zig)
- [x] LZMA2 encode (cleanroom implementation: range encoder + LZ77 match finder + LZMA state machine)
- [x] BCJ x86 filter (cleanroom from LZMA SDK public domain algorithm)
- [x] Coder graph pipeline (two-coder folders: filter + compressor)
- [x] BCJ2 filter decode (4-stream range-coded x86 branch filter, DAG pipeline) (~2026-03-23 EST)

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
- [x] Streaming verify optimization: batched LZMA2 sink writes, cheaper dictionary indexing, and single-substream CRC dedupe (~2026-07-08 22:55 EDT)
  - Verify 25x: text_1m 333ms→82ms, text_4m 1.17s→284ms, binary_1m 230ms→58ms, gauss_1m 1.99s→1.90s, fake_tree 1.20s→1.13s

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

- [x] Integrate progrez library for progress display (~2026-02-28 EST)
  - Replaced hand-rolled ~80-line progress bar (progress_state/progress_callback) with progrez library
  - progrez provides: truecolor gradient bar, Unicode block elements, braille spinner, dedicated render thread
  - Adapter callback bridges z7z FFI's (done, total, user_data) to progrez_update(ctx, files, bytes)
  - Both cmd_create() and cmd_extract() use progrez; z7z-specific summary (ratio, sizes, entries) preserved
  - --no-progress flag skips progrez_create() entirely and passes NULL callback
  - PROGRESS env var, NO_COLOR support, ASCII fallback handled by progrez internally
  - 172 CLI tests, all passing

- [x] 7zip CLI parity features (~2026-03-13 EST)
  - `test`/`t` command: verify archive integrity without extracting, reports "Everything is Ok"
  - `e` command: flat extract (strip directory structure), files extracted to output dir root
  - Selective extraction: specify filenames/patterns after archive path (e.g. `z7z x archive.7z file1.txt *.doc`)
  - Wildcard matching: `*` (any chars) and `?` (single char) in file filters
  - `-o<dir>` flag: set output directory for extraction (7zz-compatible, no space after -o)
  - `-y` flag: assume Yes on overwrite prompts (without -y, skips existing files with warning)
  - `-mmt=N` flag: thread count (0=auto, 1=single-threaded, -mmt=on, -mmt=off)
  - `-mhe=on` flag: header encryption (warns if used without -p)
  - 10 new CLI integration tests, all passing

## TODO
- [x] Migrate CI from retired Garnix/GitHub Actions to Mechatron Prime (completed 2026-08-27 01:32 PM EDT)
  - [x] Expose reproducible Nix build outputs for macOS arm64, musl Linux arm64/x86_64, and Windows GNU arm64/x86_64 (completed 2026-08-27 01:24 PM EDT)
  - [x] Add exact-commit `.mechatron-prime/targets` plus a five-platform `./build_all` developer entry point (completed 2026-08-27 01:24 PM EDT)
  - [x] Replace retired CI badges and remove the redundant GitHub Actions workflow after target builds pass (completed 2026-08-27 01:24 PM EDT)
  - [x] Verify the active signed GitHub webhook, push `yolo`, and confirm exact SHA `d495452` passes Mechatron with a public `PASSING` badge (completed 2026-08-27 01:32 PM EDT)
  - [x] Curiosity poke: inspect produced binaries so successful derivations cannot hide wrong target formats or dynamic Linux linkage (completed 2026-08-27 01:24 PM EDT)
- [ ] Support every non-obsolete 7z feature accepted by current 7-Zip (Peter directive, 2026-08-27 EDT)
  - [x] Reproduce and classify `/home/pmarreck/Downloads/RESET BAT-499-v1.7z` as single-coder LZMA before changing behavior (completed 2026-08-27 12:40 PM EDT)
  - [x] Add a failing 7zz-generated LZMA extraction/streaming differential regression and verify the reported fixture directly (completed 2026-08-27 12:40 PM EDT)
  - [x] Stream LZMA verification output with dictionary-bounded memory (completed 2026-08-27 12:40 PM EDT)
  - [ ] Build a differential feature matrix against current 7zz for modern methods, filters, encryption, headers, and folder graphs
  - [ ] Define obsolete exclusions from current 7-Zip documentation/history and record the rationale
  - [ ] Curiosity poke: distinguish unsupported codec data from malformed metadata and encrypted data requiring a password
- [x] Restore streaming verification parity for coder/filter chains (validate request, completed 2026-08-27 01:32 PM EDT)
  - [x] Add a failing BCJ+LZMA2 streaming-verification regression that passes through retained extraction (completed 2026-08-27 12:40 PM EDT)
  - [x] Add differential verdict/CRC coverage and a packed-region corruption sweep against the extraction path (completed 2026-08-27 12:40 PM EDT)
  - [x] Stream x86 BCJ with four bytes of fixed boundary state and cover split branch operands (completed 2026-08-27 12:40 PM EDT)
  - [x] Stream every filter supported by retained extraction with bounded memory; preserve AES and multi-folder behavior (completed 2026-08-27 12:56 PM EDT)
  - [x] Stream BCJ2 through pull-based Copy/LZMA/LZMA2 inputs; cover a real 7zz folder graph, corruption parity, and capped allocation (completed 2026-08-27 12:56 PM EDT)
  - [x] Curiosity poke: verify x86 filter state across sink chunk boundaries and BCJ2 operands across pull refills (completed 2026-08-27 12:56 PM EDT)
  - [x] Reply to validate with pushed SHA `d495452` and API/artifact notes (completed 2026-08-27 01:32 PM EDT)
- [ ] Add seekable/range-input verification API without breaking `verify([]const u8, ...)` (validate request, 2026-07-10 EDT)
  - [x] Add a failing chunked seekable-source test covering end-header reads, payload ranges, short reads, and substream CRC failure (completed 2026-08-27 01:12 PM EDT)
  - [x] Add `RangeSource` and `verifyRange()` while preserving `verify([]const u8, ...)` through a zero-copy slice adapter (completed 2026-08-27 01:12 PM EDT)
  - [x] Preserve resource limits, encrypted encoded headers, multi-folder handling, folder/substream CRC accounting, and output sink semantics (completed 2026-08-27 01:12 PM EDT)
  - [x] Curiosity poke: reject offset/length overflow, premature EOF, and callback failure without allocating the declared archive size (completed 2026-08-27 01:12 PM EDT)
  - [ ] Follow-up: stream packed input within a single solid folder; the first patch retains one packed folder at a time because codec inputs are slices
  - [x] Reply to validate with pushed SHA `d495452`, consumption notes, and the packed-folder limitation (completed 2026-08-27 01:32 PM EDT)
- [ ] Streaming/deep validation surface for validate (requested 2026-07-08 EST)
  - [x] Add failing CRC-mismatch tests for payload/substream verification (completed 2026-07-08 04:42 PM EDT)
  - [x] Add metadata-only unpack-size stats and resource guardrail tests (completed 2026-07-08 04:42 PM EDT)
  - [x] Add Zig-native verifier/stats API so validate can pass its tracked allocator directly (completed 2026-07-08 04:42 PM EDT)
  - [x] Keep C ABI dogfooded by z7z CLI/tests, but do not route validate through FFI (completed 2026-07-08 04:42 PM EDT)
  - [x] Update docs/minimap and reply to validate with consumption instructions (completed 2026-07-08 04:49 PM EDT)
  - [ ] Streaming sink verifier follow-up from validate (requested 2026-07-08 06:46 PM EDT)
    - [x] Add capped-allocation regression proving `verify()` does not allocate the full Copy folder output (completed 2026-07-08 07:17 PM EDT)
    - [x] Add streaming substream CRC/boundary and resource-limit coverage (completed 2026-07-08 07:17 PM EDT)
    - [x] Add codec output sink for Copy and wire `archive.verify()` through it (completed 2026-07-08 07:17 PM EDT)
    - [x] Implement LZMA2 streaming sink path, including multi-block dictionary-reset regression (completed 2026-07-08 07:17 PM EDT)
    - [x] Add `z7z verify (25x)` microbenchmark baseline over deterministic/random/semi-compressible datasets (completed 2026-07-08 07:17 PM EDT)
    - [x] Reply to validate with the green streaming implementation and pushed SHA `d495452` (completed 2026-08-27 01:32 PM EDT)
- [ ] Actual i18n translations (30 languages) once textual UI is stable
- [ ] `--simple` flag (suppress emoji + ANSI)
- [ ] `--no-ansi`/`--no-color` flags
- [ ] JSON output option for structured output
- [ ] LLVM IR hand-tuning for hot paths (match finder, DP parser)

## CLI ergonomics (2026-07-21 EST)
- [x] Expand a leading `~/` in path args to $HOME (USERPROFILE fallback on Windows) — quoted paths (needed for spaces) suppress shell tilde expansion
- [x] Default output archive to `<input>.7z` when a single non-.7z input is given
- [x] Verb inference: bare `<file>` → create; bare `<archive.7z>` → extract (single→file, many→folder "of the same name"); unknown non-file arg still errors ("unknown command", typo protection)
- [x] `-f`/`--force` guards the auto-derived targets (derived .7z, extract folder/file) against silent overwrite
- [x] `--if`/`--input-filename` + `--of`/`--output-filename` archive stdin as one named entry; `--of -` writes to stdout
- [x] Hardened test-cli: `set -u` (not `set -euo pipefail`) + explicit build guard, per testing rules
- [ ] **DECIDE (Peter): stdin entry metadata** — currently synthesized as regular file mode 0644 + current time (stdin has no fs metadata). Confirm or pick a different default (e.g. epoch mtime for reproducibility).

## Code-review follow-ups (fleet review 2026-06-01) — done + deferred
Verified all 7 finding notes against source; fixed the real bugs (TDD, regression-tested):
- [x] CRITICAL double-frees in aes_crypt.decrypt7zAes + codec BCJ2 decode (explicit free + errdefer)
- [x] CRITICAL errdefer leak gaps + latent double-free across archive create paths (createLzma2/createLzma2Aes/createMultiFolder) + MatchFinder.init — failing-allocator regression tests
- [x] CRITICAL `error.OutOfMemory` masquerade for missing password → `PasswordRequired` (+ FFI Z7Z_ERR_PASSWORD_REQUIRED, header, CLI)
- [x] FFI dedup: convertFileEntries (4 create variants) + unix/filetime helpers; mapCreateError no longer swallows unknown → Z7Z_ERR_INTERNAL
- [x] interop tests skip (error.SkipZigTest) instead of silently passing when 7zz absent
- [x] deleted unreferenced src/_debug_lzma.zig; named magic literal 272 → NUM_LEN_PRICE_SLOTS
- [x] test coverage: decompression error paths (LZMA2/zstd mismatch, truncated), wrong-password, progress contract
- [ ] **Deferred (low value / high risk):** decompose 200-400 line encoder functions (createMultiFolder, encodeLzma1ChunkOptimal, compressChunked) — pure readability refactor of a working, hot, tested path; regression risk > benefit. Do only alongside a bench guard.
- [ ] **Deferred (speculative):** batched `z7z_file_entry_read` FFI accessor — real win only at 100k+ entry archives; no current consumer, so premature per minimal-implementation rule.
- [ ] **Deferred (partial):** exhaustive metadata/encoder per-feature test matrix (truncation-at-every-NID, per-flag encode roundtrips) — highest-value subset added; remainder is incremental.
