# BZip2 Integration, 2026-09-06

## Result

`src/bzip2_adapter.zig` provides a pure allocator-owned retained decoder and a
whole-block sink decoder using committed bzip2z source. No sibling changes,
vendored codec, C codec, original 7-Zip source, or dirty dependency is needed.
The normal pinned dependency is integrated into the three build roots and the
existing Nix dependency cache. Codec dispatch, archive/metadata error propagation,
and C CLI coverage are integrated. Final shipment verification is recorded in
PLAN.md.

The streaming `Decompressor` at bzip2z HEAD
`6113a10a9073c4076a5be5409868b1c868192b38` compiles directly on Zig 0.16.0.
This was tested both from `git archive` and from the immutable GitHub download.

## Pin And Module

- URL: `https://github.com/pmarreck/bzip2z/archive/6113a10a9073c4076a5be5409868b1c868192b38.tar.gz`
- Zig fetch hash: `bzip2z-0.1.0-m5NdluccCAAHOlMkmGvJHFqYCFjK6KlL6qSL3UDrirUY`
- Raw download SRI (for `fetchurl`, not unpacked `fetchzip`): `sha256-NIB9vtZ0ygkU4YRFNRZ5axub6/KunfM+ggcXtEy7AQk=`
- Committed `src/bzip2.zig` SHA-256: `925b400adc6dbb632ecae4416c2519dbb2dc70b763f253ff3b05d0241b23d578`
- Dirty sibling `src/bzip2.zig` SHA-256: `e3e10f94501735054f0a9521e7799fc893440622d9f2ffb420851d0bc2d38186`
- Dirty codec diff moves SA-IS compression code into `src/sais.zig`; decoder
  code is unchanged. Dirty tree also contains test/FFI/build changes and deleted
  CLI/migration files. None were modified or needed here.

Use `bzip2_dep.module("bzip2z")` and access the decoder through
`@import("bzip2z").bzip2`. Share that exported module across the static core,
named z7z module, and unit-test root. Downstream consumers can then depend on
the same bzip2z package without assigning its source file to two Zig modules.

The initial private module rooted at `src/bzip2.zig` passed z7z's standalone
tests and a z7z-only external consumer. It failed in validate, which also imports
bzip2z's exported module. The new `tests/integration/bzip-module-identity`
consumer depends on both packages, checks that their bzip2z pins resolve to the
same exported module, and exercises both APIs. It first failed with the exact
duplicate-module diagnostic, then passed after replacing the private module.
All 17 adapter tests pass through the exported root; dependency-module tests
were not collected in that focused run. Avoiding the exported root to avoid
upstream tests was therefore unnecessary for this consumer.

Upstream `build.zig` evaluates its CLI/progrez graph, but its CLI artifacts are
not compiled by this library-module consumer. The omitted `c/` manifest path
therefore does not block this integration. A full upstream CLI build remains
untested. `lazyDependency` still evaluates upstream build once fetched and is
unnecessary. The earlier separate-source-fetch recommendation was superseded
after testing normal dependency evaluation.

Existing `zig build --fetch=all` and the Nix dependency FOD work unchanged.
The measured and verified new FOD hash is
`sha256-c8QpZA9KFPIQ52gNIiLClfxTmP8B4SzHoieQCnKMLgg=`.

## APIs And Bounds

```zig
const bz = @import("bzip2_adapter.zig");
const output = try bz.decode(allocator, compressed, .{
	.expected_size = unpack_size,
	.max_output = output_limit,
	.memory_limit = memory_limit,
	.expected_crc32 = optional_crc32,
});
defer allocator.free(output);

const stats = try bz.decodeToSink(allocator, compressed, options, sink);
```

`sink` must have a public `write([]const u8) !void` method. Existing z7z
`*OutputSink` has that shape. Count-returning writers are deliberately rejected
at compile time. Each block is accepted completely or returns its original
downstream error; the adapter saves that error before upstream maps it to
`CorruptData`. Error unions are generic (`anyerror`) to preserve custom sink
errors. Dispatch preserves its four `SinkError` values and maps other decoder
errors into `DecompressFailed`. Retained dispatch preserves both
`OutOfMemory` and `ResourceLimitExceeded`, including the archive/metadata catch
switches.

- `expected_size` is mandatory and checked exactly. Output exceeding it never
  reaches the sink. A shorter decoded result returns `OutputSizeMismatch`.
- `max_output` is enforced before sink calls; declared sizes above it fail
  before decoder allocation. A null `memory_limit` means 128 MiB for sink decode
  or checked `declared output size + 128 MiB` for retained decode. An explicit
  `memory_limit` remains a total heap cap. The sink integration should pass
  128 MiB explicitly until a caller option is introduced.
- The budget wraps every decoder heap allocation, including the decoder state,
  buffers, selectors, and temporary old/new allocations during realloc.
  Requests exceeding the budget fail before the backing allocator is called.
  Initial RLE expansion must pass this budget before its enlarged buffers exist.
- The budget counts live requested bytes, not allocator metadata/RSS. Input
  memory and downstream-owned allocations are excluded. Retained `decode`
  subtracts its output allocation from the same overall budget.
- An exceeded budget returns `ResourceLimitExceeded`; backing allocator failure
  returns `OutOfMemory`. All failure paths release adapter-owned allocations.
- The 900,000-byte BWT block bound is not an expanded-output bound. The oracle's
  49-byte RLE fixture expands into 1,200,000 bytes in one block and passes.
  Valid larger expansions are permitted when the explicit budget allows them.
- `Stats` returns input consumption, output size, IEEE CRC32, and peak requested
  decoder heap bytes. Optional expected IEEE CRC32 comes from the archive;
  upstream also verifies its distinct BZip2 block and stream CRCs.
- Upstream accepts incomplete 1-3-byte headers after a finished stream. The
  adapter checks that the verified final 80-bit footer ends at the supplied
  input boundary, followed by at most seven arbitrary padding bits. Trailing fragments
  fail with `TrailingData`; truncations and CRC errors fail as well.
- Complete concatenated BZip2 members follow upstream's decoding behavior.
  This is not a policy restricting a coder to exactly one member.
- Sink output is provisional until success: earlier blocks may already have
  reached the sink when a later CRC/footer/size check fails. No rollback is
  promised. A sink that requires atomic effects must provide that transaction.

## BCJ2 And Remaining Risks

The sink API emits whole expanded blocks, not caller-sized chunks. Upstream
`decompress` keeps the bit reader and loop state on its call stack and runs to
completion. A sink error unwinds that state. Aborting a write and restarting
cannot provide a correct resumable BCJ2 pull decoder.

BCJ2 BZip2 pull remains pending. Verification must not silently materialize
whole output or fake continuation by restarting upstream. True interleaved
bounded pull needs an upstream incremental reader/block API, or independently
reviewed coroutine integration. No pull API or bounded-BCJ2 claim is made here.

The fixture/mutation checks are not an exhaustive malformed-input audit of
bzip2z. Its RUNA/RUNB accumulation uses unchecked `u32` arithmetic before the
block-size check; adversarial long symbol sequences deserve a separate upstream
test/audit. No crash was observed in the 720 single-bit small-fixture mutations.
Legacy randomized blocks, a near-maximum expansion, and multi-member streams
are not independently oracle-covered here. All executed tests target
`x86_64-linux-musl`; other target runtime behavior remains parent verification.

## Fixtures And Verification

`src/fixtures/bzip2/generate.mjs` runs independent static 7-Zip 26.03 as a
black-box oracle, writes `.7z` archives, and takes their single packed BZip2
stream from the documented start-header offset. Uncompressed archive headers
make that range unambiguous. It also extracts each archive to memory with
`7zzs x -so` and checks exact original bytes. No extracted content is executed.
`provenance.json` records commands, packed/input/archive SHA-256, sizes, and the
oracle-reported archive CRC32 values.

| Fixture | Output Bytes | Packed Bytes | IEEE CRC32 |
| --- | ---: | ---: | --- |
| small | 49 | 90 | 34E73C90 |
| rle-expansion | 1,200,000 | 49 | 69DFAE60 |
| multiblock | 210,000 | 2,254 | A05D9824 |
| filter-swap4 | 1,031 | 767 | 256881DA |

The fourth fixture compresses `fixtures/filters/swap4/encoded.bin` from the
independent filter oracle. Its input source is recorded in the same four-case
`provenance.json`; archive admission and CLI coverage are parent-coordinated.

Oracle executable SHA-256:
`eab4c8d7f193e3d6d3237370bbcaa879a160a3f1dc82202207e27baeab79b6ac`.

TDD: ten behavior tests first failed against `NotImplemented` stubs (0 passed,
10 failed), then passed after the wrapper implementation. Three additional
tests cover expansion allocation failures, three block emissions within a
6,000,000-byte budget, and all 720 single-bit mutations of the small payload.
Every successful mutated decode must still equal the oracle's original bytes.
All strict prefixes of the small payload are rejected. Allocation-failure
sweeps cover retained allocation, decoder initialization, and both expansion
reallocations, with `std.testing.allocator` leak checks.

The initial 13 tests passed in ReleaseSafe, Debug, and ReleaseFast against the downloaded
commit; the clean git export also passed the final 13-test ReleaseSafe suite.
An earlier raw `.bz2` probe rejected a last-byte low-bit mutation with
exit 2/Data Error. That observation does not establish `.7z` packed-stream
behavior. A subsequent bounded `.7z` probe accepted all 12 padding mutations:
individual low bits and all unused bits together in the six-bit RLE and
four-bit Swap4 fixtures. Both `7zzs t` and `7zzs x -so` returned 0 with unchanged
output hashes. All four good archives passed; adjacent CRC-bit controls failed
with exit 2. The adapter's zero-padding restriction was therefore removed.

The persistent padding regression first failed with `TrailingData`, then all
17 adapter groups passed ReleaseSafe after the one-condition correction.
The new test checks retained/sink output, consumption, size, CRC, and rejection
of one through three whole appended zero bytes for each accepted mutation.
Oracle probe results are checked in as
`src/fixtures/bzip2/padding-provenance.json`. The exploratory probe source remains
at `/tmp/dispatch-log/z7z-bzip2-padding-probe.mjs`; the persistent Zig regression
constructs the same padding mutations without requiring that temporary script.

`zig fmt --check` flags the project's requested tab indentation. A formatted
temporary copy compares equal with `diff -w`; the adapter retains tabs.

Focused command (replace `$BZIP2_SOURCE` with the immutable extracted source):

```bash
nix develop /home/pmarreck/Code/z7z -c zig test \
  -O ReleaseSafe -target x86_64-linux-musl -lc \
  --dep bzip2z -Mroot=src/bzip2_adapter.zig \
  -O ReleaseSafe -target x86_64-linux-musl \
  -Mbzip2z="$BZIP2_SOURCE/src/lib.zig"
```

Investigation source export: `/dev/shm/z7z-bzip2.MEnP75/src/bzip2.zig`.
Downloaded package extraction:
`/dev/shm/z7z-bzip2.MEnP75/downloaded/bzip2z-0.1.0-m5NdluccCAAHOlMkmGvJHFqYCFjK6KlL6qSL3UDrirUY/`.
These paths are temporary verification artifacts, never dependency references.

## Dispatch Integration

After Peter relayed Pauli's explicit codec ownership release, eight codec test
groups were added first. Seven failed against unsupported dispatch; the BCJ2
sink rejection guard already passed. Minimal retained/sink dispatch and
compressor classification then passed all 37 codec groups in ReleaseSafe and
ReleaseFast. Tests cover oracle bytes, 1.2 MB RLE expansion, property rejection,
size/truncation/trailing/CRC failures, Swap4 and AES pipelines, sink error
identity, allocation-failure sweeps, and explicit decoder budget exhaustion.
The AES pipeline uses existing local CBC test helpers around oracle-compressed
bytes; it is not a separately generated encrypted archive fixture.

`CodecError.ResourceLimitExceeded` now survives retained dispatch and
archive/metadata propagation; the oversized declared-output regression passes.
Sink dispatch supplies an explicit 128 MiB
decoder budget. Retained allocation uses checked declared-output size plus
128 MiB unless an explicit total cap is supplied. The retained-budget test
first failed, then the adapter suite passed all 16 groups in ReleaseSafe and
Debug. A failing allocator verifies the greater-than-128-MiB default without
actually allocating a large output buffer.

One intermediate dispatch test caught size mismatch incorrectly mapped to a
resource error by setting both `max_output` and `expected_size` to the declared
size. Dispatch now uses `expected_size` alone, which still rejects excess bytes
before the sink and reports the structural failure as `DecompressFailed`.

The coordinator runs project-wide checks and shipping after codec integration.
Dependency fetch/FOD verification and dirtree notes are complete.
