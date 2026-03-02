# LZMA2 compression performance from zdiff — NOT a z7z issue

## Resolved

After profiling, the LZMA2 compression via z7z is **not the bottleneck**. On a 50MB diff:

- **Diff computation**: 1431ms (CDC + BLAKE3 + Elder diff)
- **Encode + LZMA2 compress**: 238ms

The 238ms for encode+compress is perfectly reasonable. The performance issue is in zdiff's own diff algorithm, not z7z's LZMA2 encoder.

## Source

zdiff project, 2026-02-26
