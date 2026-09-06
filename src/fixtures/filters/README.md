# Filter oracle fixtures

`src/filters.zig` is an independent, pure Zig 0.16 streaming decoder. No 7-Zip
or XZ implementation source was inspected. Standards, instruction descriptions,
and the external 7zz executable provided the format and behavior evidence.

## API

```zig
var decoder = try filters.Decoder.init(method_id, properties);
try decoder.write(encoded_bytes, &sink);
try decoder.finish(&sink);
```

`filters.supports(method_id)` checks exact byte IDs. Sink `write([]const u8) !void`
must consume the entire borrowed slice or return an error, and must not retain
the slice. The decoder performs no I/O or allocation; the caller owns its fixed
state and the sink owns output. No `deinit` is required. Decoder instances may
be used independently but each instance needs exclusive access during a call.

Sink errors propagate and poison the decoder. Subsequent calls return
`DecoderFailed`. `finish` is idempotent and preserves incomplete final units.
Writes after successful finish return `DecoderFinished`. These filters cannot
detect a truncated archive by themselves: an incomplete instruction is valid
trailing data. The enclosing archive must validate sizes and checksums.

| Method | 7z ID (hex bytes) | Accepted properties |
| --- | --- | --- |
| Delta | `03` | One byte, distance minus one (0 through 255) |
| Swap2 | `02 03 02` | Empty |
| Swap4 | `02 03 04` | Empty |
| ARM | `03 03 05 01` | Empty |
| ARMT | `03 03 07 01` | Empty |
| PPC | `03 03 02 05` | Empty |
| SPARC | `03 03 08 05` | Empty |
| IA64 | `03 03 04 01` | Empty |
| ARM64 | `0a` | Empty or four-byte little-endian start, aligned to 4 |
| RISCV | `0b` | Empty or four-byte little-endian start, aligned to 2 |

Unknown IDs return `UnsupportedMethod`; rejected properties return
`InvalidProperties`. In particular, four zero bytes are rejected for legacy
BCJ IDs. This follows the 7zz 26.03 oracle rather than general XZ conventions.

## Reproduction

The reference executable is 7-Zip 26.03, dated 2026-09-03:

```bash
ORACLE=/dev/shm/z7z-coverage-20260906.QOCJby/7zzs node src/fixtures/filters/generate.mjs
ORACLE=/dev/shm/z7z-coverage-20260906.QOCJby/7zzs node src/fixtures/filters/probe.mjs
nix develop /home/pmarreck/Code/z7z -c zig test src/filters.zig -O ReleaseSafe -target x86_64-linux-musl -lc
```

Node is needed only to regenerate fixtures. Tests embed checked-in bytes and
require neither Node nor 7zz. Never execute fixture bytes or extracted files.

`generate.mjs` constructs deterministic synthetic instruction streams and
seeded random bytes. It invokes 7zz to create filter-only archives with plain
headers, confirms packed size equals input size, takes the packed bytes at
offset 32, checks a non-identity witness, and verifies `7zz x -so` recovers the
original bytes. `provenance.json` records the executable hash, commands, file
hashes, byte counts, and changed-byte counts. Each case retains `oracle.7z`,
`encoded.bin`, and `plain.bin`.

`probe.mjs` constructs minimal single-filter containers from the public 7z
container specification, with independent CRC32 from Node's zlib. 7zz produces
all expected decoded bytes and property acceptance statuses. The generator
retains `probe.7z`, the encoded input, decoded stdout, and a JSON record of
status/stderr/hashes. `probes.zig` is a generated manifest for the unit tests.
Rejected-property cases intentionally have empty `plain.bin` files. These
containers are constructed probes; their decoded outputs are oracle-generated.

## Coverage

- Every two-chunk split point plus one-byte writes for all ten filters.
- Delta distances 1, 2, 3, 16, 256, history wrap, and isolated decoder state.
- Swap odd tails; all incomplete instruction-unit lengths against the oracle.
- Legacy-BCJ property rejection and ARM64/RISCV start/alignment/wrap behavior.
- Seeded 65,539-byte random fixtures for all seven instruction filters.
- IA64 all 32 templates and all three slots.
- RISCV all 32 registers and 128 opcode values with matching/mismatching
  registers, JAL immediate bit witnesses, and AUIPC marker-collision escapes.
- Exact method-ID classification, sink errors, empty input, and finish state.

The test suite does not benchmark throughput or run the parent archive
integration. Parent integration and the full project suite remain separate.

## References

- [7z method IDs](https://github.com/ip7z/7zip/blob/main/DOC/Methods.txt)
- [7z container specification](https://github.com/ip7z/7zip/blob/main/DOC/7zFormat.txt)
- [XZ format 1.2.1](https://tukaani.org/xz/xz-file-format.txt), filter properties and Delta
- [RISC-V ISA](https://docs.riscv.org/reference/isa/v20240411/_attachments/riscv-unprivileged.pdf), JAL/AUIPC field semantics
- [Arm instruction reference](https://documentation-service.arm.com/static/68da52dfbd7cab51328c0622), ADRP field semantics
- [Intel Itanium specification update](https://www.intel.com/content/dam/doc/specification-update/itanium-architecture-software-developers-manual-spec-update.pdf), branch instruction fields
