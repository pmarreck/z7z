# Compression Levels Design

## Overview

Add user-configurable compression levels (0-9) to z7z, matching 7zz's `-mx=N` convention.
Default level is 5. All levels use LZMA2 (no Copy codec at level 0).

## Flag Syntax

Accepts three equivalent forms:
- `-mx=N` — 7zz compatible
- `-N` — Unix shorthand (e.g., `-5`, `-9`)
- `--level N` — verbose form

Later args override earlier ones. Default is 5 if unspecified.

## Level Table

| Lvl | dict_size | nice_len | Description |
|-----|-----------|----------|-------------|
| 0 | 64KB | 8 | Fastest (minimal compression) |
| 1 | 256KB | 16 | Fast |
| 2 | 1MB | 24 | Fast-normal |
| 3 | 2MB | 32 | |
| 4 | 4MB | 48 | |
| 5 | 8MB | 64 | **Default** |
| 6 | 16MB | 96 | |
| 7 | 16MB | 128 | Previous default |
| 8 | 32MB | 192 | |
| 9 | 64MB | 256 | Ultra |

Entropy-based adaptive nice_len applies as a ceiling: if the level sets nice_len=64
but a chunk has high entropy, it can be reduced to 32/16 as before.

dict_size is also clamped to data length (no point in 64MB dict for a 10KB file).

## Implementation Layers

### Zig core (lzma2_encoder.zig)
- `compress()` gains `dict_size: u32` and `nice_len: u32` parameters
- Remove hardcoded `1 << 24` dict_size and `DEFAULT_NICE_LEN = 128`
- `compressParallel()` and `compressChunked()` thread the parameters through
- `MatchFinder.init()` already accepts dict_size and has nice_len field

### FFI (ffi.zig, z7z.h)
- Add `uint8_t level` field to `z7z_file_entry` or as parameter to create functions
- Alternatively: pass `dict_size` + `nice_len` directly (more flexible, avoids level mapping in Zig)
- Recommendation: pass level as uint8_t, map to dict_size/nice_len in Zig core

### CLI (cli/main.c)
- Parse `-mx=N`, `-0`..`-9`, `--level N` in flag processing loop
- Map level to dict_size+nice_len using the table above
- Pass through FFI to compress calls
- Update `--help` output

### Tests
- CLI tests for each flag form (-mx=N, -N, --level N)
- Verify level 0 produces larger archives than level 9
- Verify default (no flag) matches level 5 behavior
- Roundtrip: archives created at all levels extractable
- 7zz interop: archives at each level pass `7zz t`
