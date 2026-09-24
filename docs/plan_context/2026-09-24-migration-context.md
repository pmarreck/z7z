# Plan Migration Context (2026-09-24)

The active plan preserves all 67 original unchecked entries in their original order. Task numbers below map them one-to-one to their full pre-migration wording. This is supporting context, not a second execution checklist.

[Full pre-migration snapshot](2026-09-24-plan-before-migration.md) retains every byte of the Sept24 plan, including the prior uncommitted Sept12 completion notes. Removing only the new Sept24 task and its following blank line reconstructs /tmp/z7z-plan-before-update-20260924.md. Completed entries and nested evidence were retired by the skill into [PLAN_LOG](../PLAN_LOG.md); no completion dates or commits were invented.

## Governing Context

Read the snapshot's [contract](2026-09-24-plan-before-migration.md#contract-and-completion-criteria), [delegation and reuse constraints](2026-09-24-plan-before-migration.md#approved-next-steps-2026-09-06-edt), and [decoder reuse findings](2026-09-24-plan-before-migration.md#3-complete-codecs-and-filters-in-small-tdd-units) before implementing these tasks. They retain the cleanroom boundary, historical oracle baseline, scope, execution order, ownership, and provenance caveats verbatim. Historical baseline claims were not reverified during this documentation migration.

Peter's standing delegation permission remains in force. The parent owns dependency changes, builds, tests, integration, and shipment. PPMd adaptation still requires the separate provenance decision; no original 7-Zip source or PPMd drafts were inspected here.

Several legacy unchecked items overlap later completion evidence (especially BZip2, the initial feature matrix, and streaming APIs). They remain open for reconciliation rather than being silently marked complete. Task 59 preserves the historical 30-language wording below; implementation must resolve it against the canonical i18n contract. No localization decision was made here.

## Follow-ups Embedded in Completion Evidence

The [Sept11/12 notes](2026-09-24-plan-before-migration.md#corruption-probe-follow-up-2026-09-11-edt) retain repeated LZMA2 property changes as a narrow coverage follow-up, a known-valid specificity corpus plus targeted oracle checks, and unacknowledged validate receipt/consumer replay. These are surfaced as separate tasks after the original corruption diagnostic task. Earlier codec and BZip2 shipment receipts are also unacknowledged in the snapshot; consumer confirmation should reconcile those without assuming failure or success.

## Link Preservation

The active plan retains the exact heading "2. Establish Permanent Compatibility Evidence", so INTENT.md#Success-Evidence's PLAN.md fragment needs no update. Other removed historical phase headings remain in the snapshot; any external pointer to those historical sections should point to this snapshot's matching fragment. No out-of-scope document was edited.

## Original Open Obligations

### Task 01

Source section: Sept24 priority (before the first section).

Refresh applicable upstream package revisions and flake pins, run full tests and five-platform Nix builds, then push and verify exact-commit CI (requested 2026-09-24 EDT).

### Task 02

Source section: Corruption Probe Follow-up (2026-09-11 EDT).

Assess named LZMA2 findings and byte-offset diagnostics for validate separately. This fix retains CodecError.DecompressFailed, ArchiveError.StructuralError and C Z7Z_ERR_STRUCTURAL; no richer diagnostic API is claimed.

### Task 03

Source section: Approved Next Steps (2026-09-06 EDT).

Resolve PPMd port provenance from the August 27 implementation record and applicable notices, then obtain an explicit adaptation decision. Do not treat MIT metadata or public-domain ancestry alone as a verified rights chain; do not claim 7z compatibility from RAR tests.

### Task 04

Source section: Approved Next Steps (2026-09-06 EDT).

Implement the confirmed filter, Deflate64, BZip2, PPMd, and archive-structure gaps in separately tested and measured increments; retain the development oracle until the complete matrix passes.

### Task 05

Source section: 1. Establish a Falsifiable Inventory.

Create a machine-readable feature matrix from the pinned binary's capabilities, official user documentation, format specifications, and observed behavior. Do not consult reference implementation source.

### Task 06

Source section: 1. Establish a Falsifiable Inventory.

Record method/property IDs, valid parameter ranges, decode/inspect/verify support, platform restrictions, test IDs, fixture provenance, and measured status for each row. Track existing write support separately as regression coverage.

### Task 07

Source section: 1. Establish a Falsifiable Inventory.

Separate implemented, independently verified, missing, and explicitly excluded states. Unknown or skipped coverage blocks completion.

### Task 08

Source section: 1. Establish a Falsifiable Inventory.

Run the existing suite and a deterministic ReleaseFast baseline before implementation; record wall time, CPU time, memory, compressed size, hardware, and commit.

### Task 09

Source section: 1. Establish a Falsifiable Inventory.

Audit existing oracle references, fixture provenance, production linkage, and Nix dependencies. Resolve provenance gaps before claiming cleanroom completion.

### Task 10

Source section: 1. Establish a Falsifiable Inventory.

Curiosity poke: can a passing test exercise an identity filter or skip a missing oracle? Require transformed-data witnesses and fail missing required oracle checks during this phase.

### Task 11

Source section: 2. Establish Permanent Compatibility Evidence.

Build a versioned fixture corpus with seeded text, random and partially compressible data, architecture-specific branch instructions, empty files, boundary-sized inputs, and multi-file trees.

### Task 12

Source section: 2. Establish Permanent Compatibility Evidence.

Capture oracle-generated archives, exact payloads or hashes, metadata, creation commands, oracle version/hash, and expected validity. Include deliberately malformed fixtures with specified rejection reasons.

### Task 13

Source section: 2. Establish Permanent Compatibility Evidence.

For every supported operation, test z7z reading oracle output and the oracle reading z7z output where writing is supported. Compare content and metadata; do not require compressed bytes to match when multiple encodings are valid.

### Task 14

Source section: 2. Establish Permanent Compatibility Evidence.

Wire retained extraction, sink verification, range verification, Zig APIs, and the dogfooded C ABI/CLI into applicable matrix rows.

### Task 15

Source section: 2. Establish Permanent Compatibility Evidence.

Add classifier-set coverage, truncation sweeps, corruption tests paired with valid archives, and seeded property/metamorphic tests. Keep fuzzing and timing benchmarks outside ./test.

### Task 16

Source section: 2. Establish Permanent Compatibility Evidence.

Curiosity poke: a z7z-only round trip can preserve matching encoder/decoder bugs. Keep independent vectors and previously validated encoder-output evidence alongside it.

### Task 17

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Integrate a verified green bzip2z revision with all-or-error sink writes, preserved resource/input/cancellation errors, and allocator-enforced limits. Cover multi-block decoding, integrity checks, and legacy encodings still accepted by the current oracle. The investigated sibling worktree contains uncommitted changes.

### Task 18

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Implement PPMd with the exact variant and property semantics used by 7z; exercise model resets, memory limits, and truncation.

### Task 19

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Audit LZMA, LZMA2, BCJ, BCJ2, and AES across retained extraction, sink verification, and range verification. Close decoding and verification gaps without requiring new encoders for this milestone.

### Task 20

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Preserve existing Zstd extension behavior and determine its status separately from official 7-Zip 7z capabilities.

### Task 21

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Integrate each codec through archive, verification, C ABI, and CLI paths before declaring that feature complete. Require failing tests first, then full suite/build and measured performance.

### Task 22

Source section: 3. Complete Codecs and Filters in Small TDD Units.

Curiosity poke: support legal parameter combinations and tail conditions, not just each method's defaults.

### Task 23

Source section: 4. Complete Archive Structures and Bounded Streaming.

Exercise and implement valid coder graphs, binding order, multiple packed streams, filter chains, and encrypted combinations, including BCJ2. Reject cycles, invalid bindings, and inconsistent sizes.

### Task 24

Source section: 4. Complete Archive Structures and Bounded Streaming.

Reproduce source-review concerns with executable tests: unchecked folder stream totals/bind indices, ignored simple-pipeline bindings, and unused BCJ2 side-stream bytes. These are unproven risks, not demonstrated false acceptances (2026-09-06 review).

### Task 25

Source section: 4. Complete Archive Structures and Bounded Streaming.

Audit bzip2z malformed RUNA/RUNB accumulation and independently cover randomized blocks, maximum RLE expansion, and concatenated members. The current adapter corpus does not establish these cases.

### Task 26

Source section: 4. Complete Archive Structures and Bounded Streaming.

Complete plain, encoded, and encrypted headers; external metadata streams where supported; substream defaults; optional CRCs; empty-stream flags; Unicode names; timestamps; attributes; and unknown-property handling.

### Task 27

Source section: 4. Complete Archive Structures and Bounded Streaming.

Cover solid/non-solid/multi-folder archives, zero-length entries, large sizes and offsets, archive prefixes/SFX, trailing data, and split volumes according to observed reference semantics.

### Task 28

Source section: 4. Complete Archive Structures and Bounded Streaming.

Complete packed-input streaming within a single solid folder, including decryption and multi-stream pipelines; account for codec dictionary/model memory explicitly.

### Task 29

Source section: 4. Complete Archive Structures and Bounded Streaming.

Verify slice, short-read range, retained extraction, and sink paths give equivalent content/integrity results under injected read and allocation failures.

### Task 30

Source section: 4. Complete Archive Structures and Bounded Streaming.

Curiosity poke: distinguish malformed input, unsupported features, password errors, resource-limit failures, and valid archives larger than a configured policy permits.

### Task 31

Source section: 5. Integrate the Verification Consumers.

Inspect ../validate and ../validate_gui consumer contracts; identify the actual library/adaptor ownership before editing either consumer. Keep RAR dispatch delegated to ../rarz and ZIP to its existing handler.

### Task 32

Source section: 5. Integrate the Verification Consumers.

Cover metadata inspection, deep verification, seekable/range reads, split-volume input adapters, password supply, cancellation, and progress where required by those consumers. Keep filesystem I/O in adapters.

### Task 33

Source section: 5. Integrate the Verification Consumers.

Return distinct outcomes for corrupt data, unsupported methods, missing/wrong passwords when distinguishable, missing volumes, input failure, cancellation, and resource limits. An encrypted archive without a password cannot be reported as deeply verified.

### Task 34

Source section: 5. Integrate the Verification Consumers.

Report verification strength when checksums are absent: successful structural decoding cannot prove integrity of every payload byte. Specify treatment of unverifiable/ambiguous cases in consumer tests.

### Task 35

Source section: 5. Integrate the Verification Consumers.

Retain allocator-aware direct Zig APIs while the C CLI continues exercising the C ABI. Test allocation failure and ownership across both boundaries.

### Task 36

Source section: 5. Integrate the Verification Consumers.

Add consumer regressions for the reported RESET archive and representative new methods, plus concurrent verification under caller-provided memory limits. Preserve C CLI verification coverage.

### Task 37

Source section: 5. Integrate the Verification Consumers.

Run relevant runtime tests on supported operating systems; cross-compilation alone does not verify runtime behavior.

### Task 38

Source section: 5. Integrate the Verification Consumers.

Curiosity poke: verify hostile filenames and metadata in memory without creating archive-controlled filesystem paths; callers must not confuse verification with safe extraction.

### Task 39

Source section: 6. Validate the Complete Feature Set.

Require all applicable matrix cells to pass with no unapproved exclusions, unknowns, or silently skipped tests. Publish counts and evidence by exact commit.

### Task 40

Source section: 6. Validate the Complete Feature Set.

Sweep valid parameter boundaries and feature combinations; exhaust finite small domains and document the sampling strategy for larger combinations.

### Task 41

Source section: 6. Validate the Complete Feature Set.

Run independent acceptance review from specifications and the matrix, plus differential fuzzing and representative real-world archives. Convert every discovered defect into a permanent regression.

### Task 42

Source section: 6. Validate the Complete Feature Set.

Measure ReleaseFast verify performance on deterministic mixed data, recording CPU/wall time, peak memory, and allocations. Retain create/extract regression benchmarks for changed shared code. Investigate regressions before accepting baselines.

### Task 43

Source section: 6. Validate the Complete Feature Set.

Pass ./test, ./build, ./build_all, runtime platform checks, and exact-commit Mechatron CI. Reconcile the pinned inventory with the latest official release.

### Task 44

Source section: 6. Validate the Complete Feature Set.

Curiosity poke: finite testing cannot prove every possible archive correct. Report actual feature/parameter/combination coverage and remaining uncertainty without calling a sample exhaustive.

### Task 45

Source section: 7. Remove the Development Oracle.

After full parity acceptance, replace remaining live-oracle test/benchmark needs with retained independent fixtures, reference measurements, contract checks, and seeded property tests.

### Task 46

Source section: 7. Remove the Development Oracle.

Remove oracle executables and dependencies from the development shell, test runners, benchmarks, CI, and build inputs. Preserve useful provenance and historical measurements.

### Task 47

Source section: 7. Remove the Development Oracle.

Run the entire required workflow in an environment with no oracle executable available. Assert test counts so disappearance of differential tests cannot silently reduce coverage.

### Task 48

Source section: 7. Remove the Development Oracle.

Verify production and development dependency closures, then commit, push, and confirm Mechatron passes for that exact commit.

### Task 49

Source section: 7. Remove the Development Oracle.

Curiosity poke: fixtures preserve past compatibility evidence but cannot independently validate every future encoder output. Future format/encoder changes need fresh independent evidence, with temporary oracle use when required.

### Task 50

Source section: Phase 7: Performance Optimization.

Further optimization: HC4 hybrid, LLVM IR hand-tuning

### Task 51

Source section: TODO.

Support every non-obsolete 7z feature accepted by current 7-Zip (Peter directive, 2026-08-27 EDT)

### Task 52

Source section: TODO.

Build a differential feature matrix against current 7zz for modern methods, filters, encryption, headers, and folder graphs

### Task 53

Source section: TODO.

Define obsolete exclusions from current 7-Zip documentation/history and record the rationale

### Task 54

Source section: TODO.

Curiosity poke: distinguish unsupported codec data from malformed metadata and encrypted data requiring a password

### Task 55

Source section: TODO.

Add seekable/range-input verification API without breaking `verify([]const u8, ...)` (validate request, 2026-07-10 EDT)

### Task 56

Source section: TODO.

Follow-up: stream packed input within a single solid folder; the first patch retains one packed folder at a time because codec inputs are slices

### Task 57

Source section: TODO.

Streaming/deep validation surface for validate (requested 2026-07-08 EST)

### Task 58

Source section: TODO.

Streaming sink verifier follow-up from validate (requested 2026-07-08 06:46 PM EDT)

### Task 59

Source section: TODO.

Actual i18n translations (30 languages) once textual UI is stable

### Task 60

Source section: TODO.

`--simple` flag (suppress emoji + ANSI)

### Task 61

Source section: TODO.

`--no-ansi`/`--no-color` flags

### Task 62

Source section: TODO.

JSON output option for structured output

### Task 63

Source section: TODO.

LLVM IR hand-tuning for hot paths (match finder, DP parser)

### Task 64

Source section: CLI ergonomics (2026-07-21 EST).

**DECIDE (Peter): stdin entry metadata** — currently synthesized as regular file mode 0644 + current time (stdin has no fs metadata). Confirm or pick a different default (e.g. epoch mtime for reproducibility).

### Task 65

Source section: Code-review follow-ups (fleet review 2026-06-01) — done + deferred.

**Deferred (low value / high risk):** decompose 200-400 line encoder functions (createMultiFolder, encodeLzma1ChunkOptimal, compressChunked) — pure readability refactor of a working, hot, tested path; regression risk > benefit. Do only alongside a bench guard.

### Task 66

Source section: Code-review follow-ups (fleet review 2026-06-01) — done + deferred.

**Deferred (speculative):** batched `z7z_file_entry_read` FFI accessor — real win only at 100k+ entry archives; no current consumer, so premature per minimal-implementation rule.

### Task 67

Source section: Code-review follow-ups (fleet review 2026-06-01) — done + deferred.

**Deferred (partial):** exhaustive metadata/encoder per-feature test matrix (truncation-at-every-NID, per-flag encode roundtrips) — highest-value subset added; remainder is incremental.
