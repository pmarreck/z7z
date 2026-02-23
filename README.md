# z7z

A cleanroom 7z archive implementation in Zig. Creates and extracts 7z archives that are fully interoperable with the reference `7-Zip` implementation.

## Features

- **LZMA2 compression** — full encoder and decoder
- **AES-256-CBC encryption** — password-protected archives
- **BCJ x86 filter** — executable pre-processing for better compression
- **Multi-coder pipelines** — chained coders (e.g., LZMA2 + AES, BCJ + LZMA2)
- **Copy method** — store files without compression
- **Encoded headers** — metadata stream compression
- **CRC-32 verification** — integrity checks on all data streams
- **C FFI boundary** — all functionality exposed through a C API
- **CLI tool** — create, extract, list, and test archives

## Building

Requires Zig 0.14.x:

```sh
zig build              # build the CLI
zig build test         # run all tests (91 tests)
```

## Usage

```sh
# Create an archive
z7z create archive.7z file1.txt file2.txt

# Create with encryption
z7z create -p mypassword archive.7z secret.txt

# Extract
z7z extract archive.7z output_dir/

# Extract encrypted archive
z7z extract -p mypassword archive.7z output_dir/

# List contents
z7z list archive.7z

# Test integrity
z7z test archive.7z
```

## Benchmarks

Compared against `7zz` (p7zip) at `-mx=5` on macOS/ARM64:

### Compression

| File | Size | z7z ratio | 7z ratio | z7z speed | 7z speed |
|------|------|-----------|----------|-----------|----------|
| text_1mb.txt | 928K | 20.0% | 15.7% | 34 MB/s | 7 MB/s |
| source_2mb.zig | 1399K | 26.4% | 19.1% | 31 MB/s | 7 MB/s |
| biased_exp_512k.bin | 512K | 27.0% | 21.8% | 17 MB/s | 5 MB/s |
| random_512k.bin | 512K | 100.0% | 100.0% | 12 MB/s | 14 MB/s |

**z7z compresses 3-6x faster** than 7z, achieving ~70-85% of 7z's compression ratio.

### Extraction

| File | z7z | 7z | Winner |
|------|-----|-----|--------|
| text_1mb.txt | 88 MB/s | 60 MB/s | z7z 1.5x |
| source_2mb.zig | 80 MB/s | 72 MB/s | z7z 1.1x |
| biased_exp_512k.bin | 60 MB/s | 38 MB/s | z7z 1.6x |

## Architecture

```
CLI (z7z) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

All business logic lives in the Zig core with no I/O. The C FFI is the public API — the CLI itself calls through it, dogfooding the same interface that external consumers use.

## Status

This is an active work in progress. See [PLAN.md](PLAN.md) for the roadmap.

## License

[MIT](LICENSE)
