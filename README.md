# z7z

[![CI](https://github.com/pmarreck/z7z/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/z7z/actions/workflows/ci.yml)
[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fz7z%3Fbranch%3Dyolo)](https://garnix.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A cleanroom 7z archive implementation in Zig. Creates and extracts 7z archives that are fully interoperable with the reference `7-Zip` implementation.

## Features

- **LZMA2 compression** — BT4+HC2/HC3 match finder, forward optimal parser, parallel compression
- **AES-256-CBC encryption** — password-protected archives with `-p`/`--password`
- **BCJ x86 filter** — executable pre-processing for better compression
- **MIME-grouped solid blocks** — content-based file type detection via libmagic (`--solid`/`--no-solid` overrides)
- **Full metadata** — mtime, birthtime (fixes [7zz's long-standing bug](https://sourceforge.net/p/sevenzip/bugs/) of storing ctime instead), atime, POSIX permissions
- **Extended attributes** — xattrs preserved on macOS and Linux, including `com.apple.ResourceFork` (resource forks); stored as custom property 0x7A, invisible to 7zz (`7zz t` validates clean). Ephemeral xattrs (`com.apple.quarantine`, etc.) are excluded. Use `--no-xattr` to skip
- **Symlink support** — with path-traversal security
- **Deep verification API** — Zig-native metadata stats, expansion guardrails, and CRC verification without retaining extracted payloads
- **Progress reporting** — rate/ETA on interactive terminals
- **stdin/stdout** — pipe support via `-`/`@stdin`/`@stdout`
- **i18n groundwork** — `--lang` flag, `Z7Z_LANG` env var (30-language translation ready)
- **Cross-platform** — macOS aarch64, Linux x86_64/aarch64, Windows x86_64/aarch64

## Architecture

```
CLI (C) ──► C FFI boundary ──► Zig core (pure logic, no I/O)
```

All business logic lives in the Zig core with no I/O. The C FFI is exercised by the C CLI, so Zig consumers can import the Zig module directly when they need allocator-aware APIs such as `archive.inspect()` and `archive.verify()`.

## Performance

Compared against `7zz` at `-mx=5` on macOS/ARM64 (Apple M4):

| Workload | z7z | 7zz -mmt=1 | z7z vs 7zz-st |
|----------|-----|------------|---------------|
| 1.16MB text | 10.5ms | 20.6ms | **1.97x faster** |
| 4MB text | 18.8ms | 67.7ms | **3.61x faster** |
| 1MB random | 8.1ms | 50.1ms | **6.17x faster** |

Compression ratios within 1-2% of 7zz at `-mx=5`. Full bidirectional interop verified.

## Building

Requires Zig 0.16+:

```sh
zig build                          # ReleaseFast by default
zig build -Doptimize=Debug         # debug build
zig build test                     # run all tests
```

Or with Nix:

```sh
nix develop                        # enter dev shell
nix build                          # build package
nix flake check                    # run checks
```

## Usage

```sh
z7z create archive.7z file1.txt file2.txt dir/   # create archive
z7z create -p secret enc.7z file1.txt             # encrypted archive
z7z extract archive.7z                            # extract to current dir
z7z extract archive.7z -o outdir/                 # extract to specific dir
z7z list archive.7z                               # list contents
z7z --help                                        # full usage
```

## Status

This is an active work in progress. See [PLAN.md](PLAN.md) for the roadmap.

## License

[MIT](LICENSE)
