# PLAN

Completed work: [log](docs/PLAN_LOG.md). Details and original wording: [context](docs/plan_context/2026-09-24-migration-context.md).

## First Priority

- [x] Refresh upstream revisions and flake pins; full tests, all-system evaluation, and seven Nix targets passed (done 2026-09-24 17:09 EDT). (context: docs/plan_context/2026-09-24-migration-context.md#task-01)

## Active Roadmap: Complete 7z Verification and Oracle Removal (2026-09-04 EDT)

### Corruption Probe Follow-up (2026-09-11 EDT)

- [ ] Assess named LZMA2 findings and byte-offset diagnostics for validate. (context: docs/plan_context/2026-09-24-migration-context.md#task-02)
- [ ] Cover repeated LZMA2 property changes across compressed chunks. (context: docs/plan_context/2026-09-24-migration-context.md#follow-ups-embedded-in-completion-evidence)
- [ ] Add a known-valid specificity corpus and targeted oracle checks to corruption probing. (context: docs/plan_context/2026-09-24-migration-context.md#follow-ups-embedded-in-completion-evidence)
- [ ] Confirm validate shipment receipts and consumer replay without assuming delivery proves integration. (context: docs/plan_context/2026-09-24-migration-context.md#follow-ups-embedded-in-completion-evidence)

### Approved Next Steps (2026-09-06 EDT)

- [ ] Resolve PPMd provenance and obtain explicit adaptation approval. (context: docs/plan_context/2026-09-24-migration-context.md#task-03)
- [ ] Close remaining codec/filter/structure gaps in tested, measured increments; retain the oracle until full acceptance. (context: docs/plan_context/2026-09-24-migration-context.md#task-04)

### 1. Establish a Falsifiable Inventory

- [ ] Complete the pinned, cleanroom machine-readable feature inventory. (context: docs/plan_context/2026-09-24-migration-context.md#task-05)
- [ ] Record IDs, parameter ranges, support, platforms, provenance, tests, measurements, and existing write coverage. (context: docs/plan_context/2026-09-24-migration-context.md#task-06)
- [ ] Distinguish implementation, independent verification, gaps, and approved exclusions; block on unknowns or skips. (context: docs/plan_context/2026-09-24-migration-context.md#task-07)
- [ ] Record the existing suite and deterministic ReleaseFast CPU/wall/memory/size baseline, hardware, and commit. (context: docs/plan_context/2026-09-24-migration-context.md#task-08)
- [ ] Audit oracle references, fixture provenance, production linkage, and Nix dependencies. (context: docs/plan_context/2026-09-24-migration-context.md#task-09)
- [ ] Require transformed-data witnesses and fail missing required oracle checks. (context: docs/plan_context/2026-09-24-migration-context.md#task-10)

### 2. Establish Permanent Compatibility Evidence

- [ ] Build the versioned, seeded compatibility corpus across data types and boundary cases. (context: docs/plan_context/2026-09-24-migration-context.md#task-11)
- [ ] Capture oracle archives, payloads, metadata, commands, version/hash, and malformed-case rejection reasons. (context: docs/plan_context/2026-09-24-migration-context.md#task-12)
- [ ] Check independent bidirectional content/metadata compatibility wherever writing is supported. (context: docs/plan_context/2026-09-24-migration-context.md#task-13)
- [ ] Map retained/sink/range verification and Zig/C ABI/CLI paths to applicable matrix rows. (context: docs/plan_context/2026-09-24-migration-context.md#task-14)
- [ ] Add set-classifier, truncation, paired corruption, and seeded property/metamorphic coverage. (context: docs/plan_context/2026-09-24-migration-context.md#task-15)
- [ ] Keep independent vectors and validated encoder outputs alongside local round trips. (context: docs/plan_context/2026-09-24-migration-context.md#task-16)

### 3. Complete Codecs and Filters in Small TDD Units

- [ ] Finish verified bzip2z integration with sink/error/allocator contracts and legacy/multiblock coverage. (context: docs/plan_context/2026-09-24-migration-context.md#task-17)
- [ ] Implement the 7z PPMd variant with property, reset, memory-limit, and truncation coverage after approval. (context: docs/plan_context/2026-09-24-migration-context.md#task-18)
- [ ] Audit LZMA/LZMA2/BCJ/BCJ2/AES retained, sink, and range decoding and verification. (context: docs/plan_context/2026-09-24-migration-context.md#task-19)
- [ ] Preserve Zstd extension behavior and establish its status separately from official 7z capabilities. (context: docs/plan_context/2026-09-24-migration-context.md#task-20)
- [ ] Integrate each codec through archive/verification/C ABI/CLI with TDD, full checks, and measurements. (context: docs/plan_context/2026-09-24-migration-context.md#task-21)
- [ ] Cover legal parameter combinations and tail conditions beyond defaults. (context: docs/plan_context/2026-09-24-migration-context.md#task-22)

### 4. Complete Archive Structures and Bounded Streaming

- [ ] Complete valid coder graphs and encrypted/filter combinations; reject cycles, bad bindings, and size mismatches. (context: docs/plan_context/2026-09-24-migration-context.md#task-23)
- [ ] Reproduce folder totals/bind-index, simple-pipeline binding, and BCJ2 unused-byte review concerns. (context: docs/plan_context/2026-09-24-migration-context.md#task-24)
- [ ] Audit BZip2 RUNA/RUNB overflow, randomized blocks, maximum RLE expansion, and concatenated members. (context: docs/plan_context/2026-09-24-migration-context.md#task-25)
- [ ] Complete headers, external metadata, substreams, CRCs, empty flags, names, times, attributes, and unknown properties. (context: docs/plan_context/2026-09-24-migration-context.md#task-26)
- [ ] Cover folder layouts, empty entries, large offsets/sizes, SFX prefixes, trailing data, and split volumes. (context: docs/plan_context/2026-09-24-migration-context.md#task-27)
- [ ] Stream packed input within solid folders through decryption/multi-stream pipelines with explicit memory accounting. (context: docs/plan_context/2026-09-24-migration-context.md#task-28)
- [ ] Check equivalent slice/range/retained/sink results under read and allocation failures. (context: docs/plan_context/2026-09-24-migration-context.md#task-29)
- [ ] Distinguish malformed/unsupported/password/resource errors from valid archives exceeding policy. (context: docs/plan_context/2026-09-24-migration-context.md#task-30)

### 5. Integrate the Verification Consumers

- [ ] Inspect validate/validate_gui contracts and ownership; preserve existing ZIP/RAR boundaries. (context: docs/plan_context/2026-09-24-migration-context.md#task-31)
- [ ] Cover consumer inspection, deep verification, range/volume input, passwords, cancellation, and progress. (context: docs/plan_context/2026-09-24-migration-context.md#task-32)
- [ ] Return distinct failure outcomes; never report password-less encrypted content as deeply verified. (context: docs/plan_context/2026-09-24-migration-context.md#task-33)
- [ ] Specify checksum-absent verification strength and ambiguous outcomes in consumer tests. (context: docs/plan_context/2026-09-24-migration-context.md#task-34)
- [ ] Preserve allocator-aware Zig APIs and dogfooded C ABI with ownership/failure coverage. (context: docs/plan_context/2026-09-24-migration-context.md#task-35)
- [ ] Add RESET/new-method consumer regressions and concurrent memory-limit coverage while preserving CLI checks. (context: docs/plan_context/2026-09-24-migration-context.md#task-36)
- [ ] Run runtime checks on supported operating systems. (context: docs/plan_context/2026-09-24-migration-context.md#task-37)
- [ ] Verify hostile filenames/metadata in memory without implying safe extraction. (context: docs/plan_context/2026-09-24-migration-context.md#task-38)

### 6. Validate the Complete Feature Set

- [ ] Pass every applicable matrix cell and publish exact-commit counts/evidence without unapproved gaps. (context: docs/plan_context/2026-09-24-migration-context.md#task-39)
- [ ] Sweep parameter boundaries/combinations; exhaust small domains and document larger-domain sampling. (context: docs/plan_context/2026-09-24-migration-context.md#task-40)
- [ ] Run independent acceptance review, differential fuzzing, and real-world archives; retain defect regressions. (context: docs/plan_context/2026-09-24-migration-context.md#task-41)
- [ ] Measure deterministic ReleaseFast verification and shared create/extract regressions before baseline acceptance. (context: docs/plan_context/2026-09-24-migration-context.md#task-42)
- [ ] Pass test/build/build_all, runtime checks, and exact-commit CI; reconcile the latest official release. (context: docs/plan_context/2026-09-24-migration-context.md#task-43)
- [ ] Report measured feature/parameter/combination coverage and remaining uncertainty. (context: docs/plan_context/2026-09-24-migration-context.md#task-44)

### 7. Remove the Development Oracle

- [ ] After full parity acceptance, replace live-oracle checks with independent fixtures and permanent evidence. (context: docs/plan_context/2026-09-24-migration-context.md#task-45)
- [ ] Remove oracle dependencies from shell/tests/benchmarks/CI/builds while retaining provenance and measurements. (context: docs/plan_context/2026-09-24-migration-context.md#task-46)
- [ ] Run the full workflow without the oracle and assert test counts. (context: docs/plan_context/2026-09-24-migration-context.md#task-47)
- [ ] Verify production/development closures, commit, push, and confirm exact-commit CI. (context: docs/plan_context/2026-09-24-migration-context.md#task-48)
- [ ] Require fresh independent evidence for future format/encoder changes, using a temporary oracle as needed. (context: docs/plan_context/2026-09-24-migration-context.md#task-49)

## Phase 7: Performance Optimization

- [ ] Explore HC4 hybrid and LLVM IR optimization. (context: docs/plan_context/2026-09-24-migration-context.md#task-50)

## TODO

- [ ] Complete every non-obsolete current 7z feature (Peter directive, 2026-08-27 EDT). (context: docs/plan_context/2026-09-24-migration-context.md#task-51)
	- [ ] Complete the differential matrix for methods, filters, encryption, headers, and folder graphs. (context: docs/plan_context/2026-09-24-migration-context.md#task-52)
	- [ ] Document evidence and rationale for obsolete exclusions and obtain Peter's agreement. (context: docs/plan_context/2026-09-24-migration-context.md#task-53)
	- [ ] Distinguish unsupported codecs, malformed metadata, and password-required content. (context: docs/plan_context/2026-09-24-migration-context.md#task-54)
- [ ] Finish range-input verification without breaking verify([]const u8, ...) (requested 2026-07-10 EDT). (context: docs/plan_context/2026-09-24-migration-context.md#task-55)
	- [ ] Stream packed input within a solid folder beyond the existing whole-packed-folder adapter. (context: docs/plan_context/2026-09-24-migration-context.md#task-56)
- [ ] Finish validate's streaming/deep-validation surface (requested 2026-07-08). (context: docs/plan_context/2026-09-24-migration-context.md#task-57)
	- [ ] Close validate's streaming sink verifier follow-up (requested 2026-07-08 18:46). (context: docs/plan_context/2026-09-24-migration-context.md#task-58)
- [ ] Deliver translations after textual UI stabilizes; reconcile the legacy 30-language request with canonical i18n scope. (context: docs/plan_context/2026-09-24-migration-context.md#task-59)
- [ ] Add --simple to suppress emoji and ANSI. (context: docs/plan_context/2026-09-24-migration-context.md#task-60)
- [ ] Add --no-ansi/--no-color. (context: docs/plan_context/2026-09-24-migration-context.md#task-61)
- [ ] Add structured JSON output. (context: docs/plan_context/2026-09-24-migration-context.md#task-62)
- [ ] Explore LLVM IR tuning for match-finder and DP-parser hot paths. (context: docs/plan_context/2026-09-24-migration-context.md#task-63)

## CLI ergonomics (2026-07-21 EST)

- [ ] Ask Peter to decide stdin entry metadata defaults (0644/current time versus alternatives). (context: docs/plan_context/2026-09-24-migration-context.md#task-64)

## Code-review follow-ups (fleet review 2026-06-01) — done + deferred

- [ ] Defer large encoder-function decomposition unless justified alongside a benchmark guard. (context: docs/plan_context/2026-09-24-migration-context.md#task-65)
- [ ] Defer batched z7z_file_entry_read until a real large-archive consumer justifies it. (context: docs/plan_context/2026-09-24-migration-context.md#task-66)
- [ ] Complete the remaining metadata/encoder per-feature test matrix incrementally. (context: docs/plan_context/2026-09-24-migration-context.md#task-67)
