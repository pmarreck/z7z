# LZMA2 flush mutation: independent executable evidence

Measured 2026-09-12 at 10:23 EDT. No original 7-Zip source or z7z
implementation was read. No implementation, tests, fixtures, build files,
or sibling-project files were edited. No builds or commits were performed.

## Fixture and procedure

- Input: `/home/pmarreck/Code/validate/tests/fixtures/sevenz/lzma2_plain.7z`
- Archive length: 6,968 bytes.
- Archive SHA256: `e3c8fde1ed2a0f26929b4bb56011cb82236df34fc33c7d53183da17ffbb771b4`
- Packed range: zero-based archive offsets 32 through 6869 inclusive,
  6,838 bytes. Slice convention: `[32, 6870)`.
- Mutation: archive offset 6867, packed-relative offset 6835. Original byte
  `0x31`; XOR `0xff` changes it to `0xce`. All other bytes were asserted unchanged.
- Pristine packed SHA256: `039ead8ad703998ad4b1bdb9749389aeed5a690b3ababb7ea55fa1ef5cd22d63`
- XOR-ff archive SHA256: `f3045f15cdd1ebc1f406165bf9a29d39daf3d4ef0512c1bf43282a5f3e07ef8a`
- XOR-ff packed SHA256: `498055bc683534f72be914f6bf5416cec6bf63b2c82f3f987d7aa824e34b6447`

The runner read the fixture once, copied each case into a fresh buffer, changed
only the specified byte, and wrote archives and raw packed slices into RAM-backed
`/tmp`. It invoked executables synchronously without a shell pipeline, retaining
stdout, stderr, and exit status separately. `LC_ALL=C`, `XZ_DEFAULTS=''`, and
`XZ_OPT=''` were supplied. Acceptance means exit status zero, not output equality.

Commands for each archive and its packed slice:

```bash
7zz x -so -y CASE.7z
7zz t -y CASE.7z
xz --format=raw --lzma2=dict=64KiB --decompress --stdout CASE.lzma2
```

CRC was measured with `7zz h -scrcCRC32 pristine.7zz.stdout`. Complete buffers
were compared directly, in addition to SHA256. Separate `cmp` commands confirmed
both XOR-ff outputs equal the pristine 7zz output, returning zero.

## Executable identities

7-Zip (z) 26.00 (x64), dated 2026-02-12:

```text
/nix/store/673pb6dnkwnxs9zclmxyvl1idfz7spgb-7zz-26.00/bin/7zz
SHA256 be1d074f196bf5f351b21731572fd9337a42813a3ec20d734d41e9897f4167ec
```

xz (XZ Utils) 5.8.3; reported liblzma 5.8.3:

```text
/nix/store/2nm5c858fh52s6mhcffm07s3biaxys44-xz-5.8.3-bin/bin/xz
SHA256 5dc01eabf8c353e9edaa8686b8a4839270ac04c50e2d1ef7252ca96adaa4c5be
```

Hashes cover the executable files, not their shared-library closure.

## Results

| XOR mask | Resulting byte | 7zz extract/test exits | xz exit | Output bytes, both | Equal to pristine, both |
| --- | --- | --- | --- | --- | --- |
| 00 (control) | 31 | 0 / 0 | 0 | 62352 | yes |
| ff | ce | 2 / 2 | 1 | 62352 | yes |
| 01 | 30 | 2 / 2 | 1 | 62351 | no |
| 02 | 33 | 2 / 2 | 1 | 62352 | yes |
| 04 | 35 | 2 / 2 | 1 | 62352 | yes |
| 08 | 39 | 2 / 2 | 1 | 62352 | yes |
| 10 | 21 | 2 / 2 | 1 | 62351 | no |
| 20 | 11 | 2 / 2 | 1 | 62351 | no |
| 40 | 71 | 2 / 2 | 1 | 62352 | yes |
| 80 | b1 | 2 / 2 | 1 | 62352 | yes |

Masks and resulting bytes are hexadecimal. Among the eight single-bit masks,
both acceptance sets are empty: `A_7zz = A_xz = {}`. Both rejection sets are
`{01, 02, 04, 08, 10, 20, 40, 80}`. The output-preserving single-bit set is
`{02, 04, 08, 40, 80}`. Across all ten cases, only the pristine control is accepted.

Pristine and every output-preserving mutation produce CRC32 `E331D7E4` and SHA256
`e758b333859439fe6adc0fd67cab53641fddca88f6f983e47cd892c3d8325867`.
The three 62,351-byte outputs share SHA256
`93943d9621ae8ad46ef9db32785255d7f9c1b5cda68e648c677164c7a7e38e39`.

For XOR ff and the five output-preserving single-bit mutations, 7zz extraction
reports `ERROR: Data Error : #0`. For masks 01, 10, and 20 it reports
`ERROR: Data Error : payload_x86.o`. xz reports `Compressed data is corrupt`
for every mutation. Both pristine extraction stderr streams are empty.

## Exhaustive byte-value classification

A second run at 10:26:23 EDT tested all 256 possible values at archive offset
6867. These sets describe actual replacement byte values, not XOR masks.
All other bytes remained unchanged. Each case ran 7zz extraction, 7zz test,
and raw xz, for 768 decoder process invocations.

| Replacement byte set | Count | 7zz extract/test exits | xz exit | Output verdict, both |
| --- | --- | --- | --- | --- |
| `{0x31}` | 1 | 0 / 0 | 0 | Exact pristine output, 62352 bytes |
| `[0x32, 0xff]` | 206 | 2 / 2 | 1 | Exact pristine output, 62352 bytes |
| `[0x00, 0x30]` | 49 | 2 / 2 | 1 | Exact pristine prefix, 62351 bytes |

Intervals are inclusive. The independently measured sets for each oracle are:

```text
7zz accepted = {0x31}
xz  accepted = {0x31}
7zz rejected = [0x00, 0x30] union [0x32, 0xff]
xz  rejected = [0x00, 0x30] union [0x32, 0xff]
7zz exact-output = [0x31, 0xff]
xz  exact-output = [0x31, 0xff]
7zz different-output = [0x00, 0x30]
xz  different-output = [0x00, 0x30]
```

A post-run check asserted complete 256-value coverage without duplicates,
compared every oracle pair byte-for-byte, compared every result with the
corresponding pristine prefix, and asserted all measured sets above as arrays.
7zz archive-test status matched extraction status for every value. No
accepted-but-different-output case occurred. There are 206 rejected-but-exact-output
cases. These separate classifications can supply deterministic set-based tests;
an output-only validator would accept 207 values where both oracles accept one.

Full second-run evidence is under `/tmp/z7z-flush-oracle-sLSkD6/`:
`results.json` preserves each command, process exit, length, hash, exact-output
verdict and stderr; `classification.json` enumerates all sets in decimal actual
byte values. Per-case archives, packed slices, and stdout/stderr are retained.
Executable hashes and pristine fixture/output checks were repeated by the runner.

## Interpretation and limits

The XOR-ff mutation is rejected even though every decoded byte and the output
CRC match pristine. Raw xz rejection reproduces this without the 7z container.
Output length, output CRC, and decoded-byte equality therefore cannot alone
establish stream validity for this fixture.

These are externally measured acceptance expectations for a parent-owned z7z
regression test. This experiment does not run z7z, reproduce its reported
acceptance, identify the internal failed condition, or prove a particular
range-decoder flush fix. The expanded sweep exhausts all values at the specified
byte, but no other offsets. The pristine control guards
against an oracle invocation that simply rejects everything. There is no new
blocking CI gate in this evidence-only task.

## Retained RAM artifacts

- `/tmp/dispatch-log/z7z-flush-oracle-run.cjs`: executable-oracle experiment runner.
- `/tmp/z7z-flush-oracle-Fwmpa5/results.json`: complete arguments, statuses,
  per-case hashes, byte comparisons, stderr, and CRC command output.
- `/tmp/z7z-flush-oracle-Fwmpa5/`: per-case archives, packed slices, captured
  output streams, archive-test captures, and full executable version output.
- `/tmp/dispatch-log/z7z-flush-oracle-progress.md`: checklist and activity log.
- `/tmp/dispatch-log/z7z-flush-oracle-final.md`: completion report.

Rerun with `node /tmp/dispatch-log/z7z-flush-oracle-run.cjs`; it asserts the
fixture hash, pristine success/size/CRC, and XOR-ff rejection with identical
output, then writes the complete 256-value sweep and classification as JSON in
a new RAM scratch directory. Its stdout prints the classification.
RAM artifacts are temporary and may disappear on reboot; this note preserves
the measured results. All command sessions completed; no watchers or background
jobs were started. The original fixture SHA256 was rechecked unchanged.
