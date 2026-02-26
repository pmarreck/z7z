# Solid Archive Creation — MIME-Grouped Blocks via libmagic

**Date:** 2026-02-26
**Status:** Approved

## Summary

z7z will default to MIME-grouped solid blocks: files with the same exact MIME type
(detected via libmagic) are concatenated into a single solid block and compressed
together. Each unique MIME type produces one folder in the 7z archive.

## Architecture

```
CLI (main.c)
  └── walk_directory() collects files + calls magic_file() per file
  └── sorts files by MIME type string
  └── passes file groups to FFI

FFI (ffi.zig)
  └── accepts file entries with group tags (group index per entry)

Zig core (archive.zig)
  └── new createMultiFolder() function
  └── for each group: concat files → LZMA2 compress → one folder
  └── build metadata with multiple folders + correct substream mapping
```

## Key Decisions

1. **libmagic via C** — linked via Nix (`file` package provides libmagic),
   called from `main.c` during file walk. `magic_open(MAGIC_MIME_TYPE)` →
   `magic_file(path)` per file. On Windows: fall back to extension-based grouping.

2. **Exact MIME type grouping** — `text/x-c`, `text/plain`, `application/json`
   each get their own solid block. Within a group, files are in walk order.

3. **Default ON** — MIME grouping is the default behavior. CLI flags:
   - `--solid` / `-ms=on` — force all files into one block (old behavior)
   - `--no-solid` / `-ms=off` — one file per block
   - Default (no flag) — MIME-grouped blocks

4. **Zig core stays I/O-free** — file grouping logic (libmagic calls, sorting,
   bucketing) lives entirely in the C CLI. The Zig FFI receives pre-grouped data.

5. **Encryption** — AES wraps each folder independently (same as 7zz).

6. **BCJ filter** — applied per-folder where the group is executable/object code.
   Detection: MIME types like `application/x-executable`, `application/x-mach-binary`,
   `application/x-object`.

7. **Progress** — callback fires per-group. Total progress = sum across all groups.

## Data Flow

### Creation

1. CLI walks directory, calls `magic_file()` per regular file → MIME string
2. CLI sorts entries by MIME type, assigns group indices
3. CLI passes entries + group indices to FFI
4. Zig core iterates groups: for each unique group index:
   - Concatenate file data in that group
   - Compress via LZMA2 (with optional BCJ + AES)
   - Record folder metadata (coders, pack size, unpack size)
   - Record per-file substream sizes and CRC digests
5. Build metadata with N folders, correct `num_unpack_per_folder`
6. Encode header, assemble archive

### Extraction (already works)

The existing `readWithProgress()` already handles multi-folder archives with
correct pack offset tracking and per-folder file mapping.

## FFI Interface Changes

```c
// Existing: all files in one group (solid)
int z7z_create_ex_pw(...);

// New: file entries carry a group_index field
// The Zig core groups by this index to create multiple folders
typedef struct {
    const char *name;
    const uint8_t *data;
    size_t data_len;
    int64_t mtime;
    int64_t ctime;
    int64_t atime;
    uint32_t win_attrib;
    const uint8_t *xattrs;
    size_t xattrs_len;
    uint32_t group_index;  // NEW: solid block group assignment
} z7z_file_entry_ex;
```

## Build Changes

- Add `file` (libmagic) to `flake.nix` buildInputs
- Link against `-lmagic` in build.zig for the C CLI
- Magic database: use system-installed magic file (standard path on macOS/Linux)

## Testing

- Unit tests: createMultiFolder with 2-3 groups, verify N folders in output
- CLI tests: directory with mixed types → verify Block assignments via list
- Interop: z7z multi-folder → 7zz extraction, 7zz multi-folder → z7z extraction
- Regression: single-file archives still work identically
- Edge cases: single MIME type (degenerates to one block), empty files, symlinks

## Flags Summary

| Flag | Behavior |
|------|----------|
| (default) | MIME-grouped solid blocks |
| `--solid` | All files in one block |
| `--no-solid` | One file per block |
