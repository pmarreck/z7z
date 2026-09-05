# Decoder Reuse Investigation

Investigated 2026-09-04 EDT for complete 7z verification in z7z. The investigation
stage changed no production codec or consumer implementation. Deflate was then
integrated into z7z, with permanent fixtures in `src/fixtures/deflate` and
measurements in `tests/benchmark/2026-09-04-deflate.md`.
The companion `decoder-reuse-probe.zig`
is a standalone candidate-evaluation experiment, independent of the product test
suite. Its two failing suitability checks are findings, not repaired regressions.

## Recommendation

Use the pinned Zig 0.16.0 `std.compress.flate.Decompress` for ordinary raw Deflate,
subject to archive/sink integration tests and resource-limit tests. Its buffered
mode passed the investigated history-window and short-input cases. Deflate64
requires separate implementation work. Evaluate `bzip2z` as the BZip2 dependency
with an all-or-error sink adapter, preserved error classification, and tracked
allocation limits; pin and verify a green revision before integrating it.

`deflate_fingerprint` solves a different problem: reproducing the compressed
bytes chosen by an original encoder so an Office ZIP can be restored with exactly
its original hash. Peter described that project as incomplete. Ordinary decoding
does not require discovering or reproducing the original encoder's choices.
The existing fingerprint inspector is useful for forensic token analysis, but
the experiment shows that it cannot be used as a validity oracle as-is.

## Measured Results

Toolchain: Zig 0.16.0, ReleaseSafe, x86_64-linux-musl. The project dev shell provides
7-Zip 26.00, not the current 26.03 release. These tests establish reuse evidence;
they do not establish complete current-release feature parity or performance.
Every generated 7z fixture was accepted by `7zz t`, and the probe checked its
single-coder method ID before testing the extracted packed stream.

| Probe | Observed result |
| --- | --- |
| Standard Deflate, direct and buffered output | PASS: 18 oracle fixtures x 5 read modes = 90 exact-byte comparisons |
| Invalid block type, invalid history, truncated hello stream | PASS: both malformed inputs and all 7 truncations rejected; complete hello decoded correctly |
| Fingerprint parser rejects invalid history | FAIL: `03 02 00` accepted despite requesting distance 1 before any output exists |
| Deflate64 long-distance witness | PASS: oracle-valid data was not decoded correctly as ordinary Deflate |
| Original Zig issue #24963 archive | PASS: std.zip.extract completed on pinned Zig 0.16.0 |
| Short compressed-input refills | PASS: refill sizes 1, 7, 31 bytes with a 32-byte input buffer, 64 KiB decoder window, and 257-byte output chunks |
| bzip2z, 7z BZip2 payload | PASS: 2 MiB seeded random data decoded exactly through the reader/writer API |
| bzip2z retries partial writes | FAIL: decoder returned success after emitting 7 of 29,696 required bytes |
| bzip2z allocation growth | PASS: 4 MiB repeated input decoded exactly; both block and output allocations grew to at least 4 MiB each |

Overall: 9 diagnostic tests, 7 passed, 2 failed, 0 skipped. Exit code 1 is expected
for these inspected candidate versions because the two suitability checks fail.

The 18 Deflate fixtures use sizes 1, 257, 32,768, 65,536, 262,144, and 1,048,576
bytes, each with repeated, mixed-compressibility, and seeded-random data. Modes
are retained output plus buffered output with chunk sizes 1, 257, 4,096, and
65,536. The RNG seed is `0x7def1a7e`.

The first Deflate64 experiment used only repeated `A` bytes and also decoded
successfully as ordinary Deflate. That fixture exercised their shared subset.
The replacement duplicates 49,152 seeded random bytes, checks that compression
beats 75% of the input size, and exposes the missing long-distance capability.
This is a compatibility witness, not an exhaustive Deflate64 test.

## Interpretation and Integration Constraints

- Zig 0.16's decoder validates match history and has no Deflate64 mode. Its distance decoder rejects codes above 29. Deflate64 requires more than increasing a buffer size.
- The fingerprint parser accepts a syntactically decodable token without checking that its backreference can be satisfied. Its allocated token trace is also unsuitable as the default bounded-memory verification path.
- bzip2z calls `writer.write` once per output block and ignores the returned count. Our sink adapter must consume the whole slice or fail; do not pass a partial-write interface directly.
- bzip2z maps sink failures to `CorruptData`. Resource-limit/cancellation/input errors need adapter state or a library change so z7z does not misreport policy failures as corrupt archives.
- bzip2z initially allocates about 5.4 MB for block, transformation, output, and selector storage, excluding its struct. Initial RLE expansion can grow block and output buffers before the sink sees data. A sink-only output cap does not bound those allocations.
- bzip2z was tested from a modified local worktree. The observed behavior cannot be attributed solely to validate's pinned dependency commit.
- Finite fixtures do not establish complete malformed-stream safety, performance, or the remaining method/property combinations. These remain integration acceptance work.

## Provenance

- z7z base: `e28c2290316f61738686a7e800d7bf266ef32cd2`, with planning/research changes.
- deflate_fingerprint HEAD: `1c53676eee27cf13327a7fffed37236eb6169056`; inspected source unchanged relative to that HEAD.
- bzip2z HEAD: `6113a10a9073c4076a5be5409868b1c868192b38`; tested `src/bzip2.zig` and other files have local changes.
- SHA-256 of tested bzip2z/src/bzip2.zig: `e3e10f94501735054f0a9521e7799fc893440622d9f2ffb420851d0bc2d38186`.
- SHA-256 of tested deflate_fingerprint/src/inspect.zig: `a8a0697eb44c3fd6dd605da6b09f3fcf40a035447f8c0f6ca435fe06b3b16fd9`.
- SHA-256 of pinned std/compress/flate/Decompress.zig: `5eb7ae3c361808145524e6d696ad648df0418d0df3afec30a4c4b702ee5c623a`.
- Historical ZIP fixture SHA-256: `b072c4c7fa21d3bda3bb22976259ab7296d5e7b95f5ed1df7ca90c5361889fc8`.

## Reproduction

From z7z, with the inspected sibling checkouts available:

```bash
decoder_probe_dir=$(mktemp -d "${TMPDIR:-/dev/shm}/z7z-decoder-probe.XXXXXX")
curl --fail --location --output "$decoder_probe_dir/qsv.zip" \
  https://github.com/dathere/qsv/releases/download/6.0.1/qsv-6.0.1-x86_64-unknown-linux-musl.zip
sha256sum "$decoder_probe_dir/qsv.zip"
env Z7Z_PROBE_QSV_ZIP="$decoder_probe_dir/qsv.zip" nix develop -c zig test \
  -O ReleaseSafe -target x86_64-linux-musl -lc \
  --dep seven --dep fingerprint --dep bzip2 \
  -Mroot=docs/research/decoder-reuse-probe.zig \
  -Mseven=src/lib.zig \
  -Mfingerprint=../deflate_fingerprint/src/inspect.zig \
  -Mbzip2=../bzip2z/src/bzip2.zig --test-filter 'probe:'
```

The archive is test data only; no extracted executable is run. Missing oracle or
historical fixture fails the experiment rather than silently skipping coverage.
Keep temporary data recoverable according to the workspace's data policy.

## Primary References

- [Zig 0.16 release notes: Deflate implementation changes and limit fixes](https://ziglang.org/download/0.16.0/release-notes.html).
- [Zig issue #24963: the original Zig 0.15.1 ZIP crash and fixture](https://github.com/ziglang/zig/issues/24963). The tested reproducer passes on 0.16.0; this does not establish every related issue is fixed.
- [PKWARE APPNOTE, section 5.6](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT): Deflate64's larger dictionary. Further format details need specification/oracle evidence before implementation.
