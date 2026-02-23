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

Requires Zig 0.14+:

```sh
zig build              # build the CLI
zig build test         # run all tests (92 tests)
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

Compared against `7z` at `-mx=5` on macOS/ARM64:

### Compression

| File | Size | z7z ratio | 7z ratio |
|------|------|-----------|----------|
| text_1mb.txt | 928K | 15.8% | 15.7% |
| source_2mb.zig | 1399K | 19.7% | 19.0% |
| text_5mb.txt | 4639K | 3.1% | 3.1% |
| biased_exp_512k.bin | 512K | 22.1% | 21.7% |
| random_512k.bin | 512K | 100.0% | 100.0% |

z7z uses a BT4 binary tree match finder, forward optimal parser with price-based decisions, continuous LZMA state across chunks, and dictionary carry-across. It **matches `7z -mx=5`** compression quality across all tested file types.

## Architecture

```
CLI (z7z) ──> C FFI boundary ──> Zig core (pure logic, no I/O)
```

All business logic lives in the Zig core with no I/O. The C FFI is the public API — the CLI itself calls through it, dogfooding the same interface that external consumers use.

## Status

This is an active work in progress. See [PLAN.md](PLAN.md) for the roadmap.

## License

[MIT](LICENSE)
