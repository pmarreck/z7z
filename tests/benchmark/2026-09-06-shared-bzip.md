# Shared BZip2 Module Measurements

Measured 2026-09-06 EDT, AMD Ryzen Threadripper 3990X, Linux x86_64,
Zig 0.16.0, ReleaseFast binaries from canonical Nix builds. Baseline is
357c8ce8ba4a0c6dbc24d21b8bdf8ab3fb3e3a35; candidate replaces the private
decoder module with bzip2z's exported library module. No decoder algorithm,
dependency pin, or allocation policy changed.

Each comparison has twelve pairs alternating before/after order, pinned to
CPU 24. Hyperfine runs one warmup and one measured invocation per command per
pair. LZMA2 uses ten verifications of the seeded 1 MiB Gaussian archive from
[the Deflate report](2026-09-04-deflate.md). BZip2 uses fifty verifications of
src/fixtures/bzip2/rle-expansion.7z (1,200,000 output bytes). Process startup
and one archive read are included; CPU is user plus system time.
MUTE_DEBUG_STATUS was unset. No project builds ran during measurements;
activity from other projects on the machine was not controlled.

| Comparison | Before Wall | After Wall | Before CPU | After CPU | Mean CPU Change | Median Paired CPU Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| LZMA2 initial | 762.81 ms | 787.76 ms | 757.24 ms | 781.30 ms | +3.18% | +0.59% |
| BZip2 | 364.81 ms | 360.85 ms | 361.67 ms | 357.97 ms | -1.02% | -0.28% |
| LZMA2 repeat | 781.78 ms | 776.21 ms | 774.89 ms | 770.45 ms | -0.57% | -0.06% |

Three consecutive slow candidate samples drove the initial LZMA2 mean up.
The repeat also contains variable timings, but did not reproduce that mean
slowdown. These comparisons do not establish a consistent regression or a
small speedup. All samples, including slow runs, are retained in
[the raw report](2026-09-06-shared-bzip.json). Other platforms were built,
but their runtime performance was not measured.

Executable SHA-256:

- Before: b12c59e6d96550c97c180256fad24a735568ee611776b9359703056bb0612178
- After: 2183c2ba4b43bb4a2e53dec781d415f25b7644c2c93063a45e0451b6128947d3

To repeat a pair with saved canonical binaries and the same archive:

```bash
hyperfine --warmup 1 --runs 1 --export-json pair.json \
  -n before "taskset -c 24 $BEFORE $ARCHIVE $ITERATIONS" \
  -n after "taskset -c 24 $AFTER $ARCHIVE $ITERATIONS"
```

Reverse command order on odd-numbered pairs. Aggregate twelve pairs rather
than treating one invocation as a stable estimate.
