# Deflate64 Fixtures

Generated on 2026-09-06 with the black-box static 7zz 26.03 executable:

`/dev/shm/z7z-coverage-20260906.QOCJby/7zzs`

Oracle SHA-256: `eab4c8d7f193e3d6d3237370bbcaa879a160a3f1dc82202207e27baeab79b6ac`.

No 7-Zip source or other codec implementation source was inspected. The Node
scripts create data, assemble explicit wire vectors, parse container offsets,
and invoke the executable. They import no compression library. Extracted bytes
are compared in memory and never executed.

## Oracle-Compressed Cases

`generate.mjs` invokes `7zz a -t7z -m0=Deflate64 -mx=9 -mhc=off -ms=off
-mtm=off -mta=off -mtc=off NAME.7z NAME.plain`, then verifies that `7zz x -so`
returns the original bytes. The unencoded 7z next-header offset at bytes 12..20
gives the packed-data length; the raw stream starts at byte 32.

| Name | Plain Bytes | Raw Bytes | Coverage |
| --- | ---: | ---: | --- |
| fixed | 17 | 19 | Fixed Huffman block |
| stored | 49152 | 49162 | Stored blocks, seeded random bytes |
| dynamic | 31500 | 245 | Dynamic Huffman blocks |
| history49152 | 98304 | 49747 | 49152 random bytes duplicated, ring wrap |
| length285 | 70000 | 268 | Repeated A bytes, oracle's length choices |

`provenance.json` records commands, seed algorithm, sizes, first block types,
and SHA-256 hashes of archives, raw streams, and expected outputs.

## Explicit Boundary Cases

`crafted.mjs` writes stored/fixed bit sequences in ZIP method-9 containers with
CRC32, then requires byte-for-byte agreement from `7zz x -so`.

| Name | Meaning |
| --- | --- |
| extended-0 | Literal A, code285 with extra=0, distance1: four A bytes |
| extended-255 | Literal A, code285 with extra=255, distance1: 259 A bytes |
| extended-65535 | Literal A, code285 with extra=65535, distance1: 65539 A bytes |
| distance65536 | 65536 stored bytes, fixed length3 at distance65536 |

`crafted-provenance.json` records the valid bit counts and all payload hashes.
These cases prove that code285 means `3 + sixteen_extra_bits`, including
length65538, and distance code31 reaches 65536. The maximum match length can
exceed the history size because overlapping copies advance byte by byte.

Both generators refuse to overwrite existing archives. To reproduce, copy the
scripts into a fresh directory, run `node generate.mjs` followed by
`node crafted.mjs`, and compare the manifests. `ORACLE` can override the binary
path; the executable must report 26.03. Raw payload hashes are deterministic;
7z container metadata may depend on file attributes of the regeneration host.

## Decoder Contract

`src/deflate64.zig` exports `Error = error{DecompressFailed, OutOfMemory}`,
`window_size = 65536`, and `Decoder`:

```zig
Decoder.create(data: []const u8, expected_size: u64,
    properties: []const u8, allocator: std.mem.Allocator) Error!*Decoder
decoder.deinit(allocator: std.mem.Allocator) void
decoder.read(output: []u8) Error!usize
decoder.readByte() (Error || error{EndOfStream})!u8
```

Input remains borrowed for the decoder lifetime. Properties must be empty.
The decoder owns one fixed-size heap allocation below 70 KiB, including its
64 KiB history, Huffman tables, and header scratch space. Reads allocate nothing.
Output allocation and sink limits remain the caller's responsibility.

Reads that reach the declared size also consume and check the final block/EOB.
Early EOF, excess output, malformed trees/distances, truncation, and trailing
whole bytes return `DecompressFailed`. Padding bits in the last byte are ignored.
An empty expected output is validated during `create`. A zero-length read is a
no-op. After a read error, further reads fail; any partial output from a failing
read must be discarded. Callers abandoning the stream before its declared size
have not validated its remainder. `deinit` only releases memory.

## Focused Tests

```sh
nix develop /home/pmarreck/Code/z7z -c zig test src/deflate64.zig \
  -O ReleaseSafe -target x86_64-linux-musl -lc
```

Tests embed the raw/expected fixtures, compare every decoded byte at multiple
chunk sizes, check malformed trees/repeats/distances and truncated prefixes,
exercise output and padding boundaries, and inject every allocation failure.
The memory test decodes 98304 bytes inside a 70 KiB fixed allocator.

## Format References

- [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951), bit ordering, blocks,
  canonical Huffman trees, dynamic headers, and base Deflate tables.
- [PKWARE APPNOTE 6.3.10](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT),
  sections 5.5 and 5.6, Deflate and the 64 KiB extension; ZIP record layout.
- [Enhanced Deflate technical note](https://inflate64.readthedocs.io/en/latest/technote.html),
  extended length and distance fields. Its length table/prose has inconsistent
  endpoints; the explicit boundary cases above were checked against 7zz.
