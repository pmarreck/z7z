# MIME-Grouped Solid Archive Creation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** z7z defaults to grouping files by exact MIME type (via libmagic) into separate solid blocks (folders) for better compression of mixed-content archives.

**Architecture:** libmagic is linked via C in the CLI layer. During file collection, each file gets its MIME type detected and a group index assigned. The group indices are passed through the FFI to the Zig core, which creates one folder per group. The existing multi-folder extraction code already handles reading these archives.

**Tech Stack:** libmagic (BSD-2-Clause C library), Zig 0.15.x, C11 CLI, Nix flake for deps

---

### Task 1: Add libmagic to build dependencies

**Files:**
- Modify: `flake.nix:52-58` (devShells.default.buildInputs)
- Modify: `flake.nix:19` (z7z package nativeBuildInputs)
- Modify: `flake.nix:38` (test check nativeBuildInputs)
- Modify: `build.zig:37-40` (CLI compile flags / link)

**Step 1: Add `file` package to flake.nix**

In `flake.nix`, add `pkgs.file` to all three places:
- `nativeBuildInputs` in the `z7z` derivation (line 19): add `pkgs.file`
- `nativeBuildInputs` in the `checks.test` derivation (line 38): add `pkgs.file`
- `buildInputs` in `devShells.default` (line 53): add `pkgs.file`

The `file` package in nixpkgs provides both the `file` CLI and `libmagic.so`/`libmagic.a` + headers.

**Step 2: Link libmagic in build.zig**

Add `cli.root_module.addSystemLibrary("magic");` after the `cli.linkLibrary(lib);` line (after line 42 in build.zig). This tells the Zig build to link `-lmagic`.

**Step 3: Verify build still works**

Run: `nix develop -c zig build -Doptimize=ReleaseFast`
Expected: Builds without errors. The CLI binary is now linked against libmagic.

**Step 4: Verify libmagic is linkable**

Run: `nix develop -c bash -c 'ldd zig-out/bin/z7z 2>&1 || otool -L zig-out/bin/z7z 2>&1' | grep -i magic`
Expected: Shows libmagic in the linked libraries.

**Step 5: Commit**

```bash
git add flake.nix build.zig
git commit -m "Add libmagic dependency for MIME-based solid block grouping"
```

---

### Task 2: Add group_index to FFI file entry struct

**Files:**
- Modify: `include/z7z.h:92-103` (z7z_file_entry struct)
- Modify: `src/ffi.zig:216-227` (Z7zFileEntry struct)
- Modify: `src/archive.zig:52-62` (FileEntry struct)

**Step 1: Write failing test — FileEntry with group_index**

In `src/archive.zig`, add a test after the existing tests (after line ~1260):

```zig
test "archive: FileEntry accepts group_index field" {
    const f = FileEntry{
        .name = "test.txt",
        .data = "hello",
        .group_index = 2,
    };
    try std.testing.expectEqual(@as(u32, 2), f.group_index);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test`
Expected: Compilation error — `FileEntry` has no field `group_index`.

**Step 3: Add group_index to FileEntry struct**

In `src/archive.zig` FileEntry struct (line 62, before the closing `}`), add:
```zig
    group_index: u32 = 0,
```

Default of 0 means "all in one group" — backward compatible with existing code.

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test`
Expected: All tests pass.

**Step 5: Add group_index to C header**

In `include/z7z.h`, add to the `z7z_file_entry` struct (after `xattrs_len`):
```c
	uint32_t group_index;       /* solid block group (0 = default) */
```

**Step 6: Add group_index to Zig FFI struct**

In `src/ffi.zig`, the `Z7zFileEntry` struct mirror needs the same field. Add after `xattrs_len`:
```zig
    group_index: u32,
```

**Step 7: Thread group_index through FFI conversion**

In the FFI create functions (`z7z_create_ex_pw`, `z7z_create_ex`, `z7z_create`), where `Z7zFileEntry` fields are copied to `FileEntry`, add:
```zig
    .group_index = cf.group_index,
```

**Step 8: Run all tests**

Run: `nix develop -c zig build test && nix develop -c ./test-cli`
Expected: All tests pass. Existing code uses group_index=0 everywhere (default).

**Step 9: Commit**

```bash
git add src/archive.zig src/ffi.zig include/z7z.h
git commit -m "Add group_index field to FileEntry for multi-folder solid grouping"
```

---

### Task 3: Implement createMultiFolder in Zig core (LZMA2 only, no encryption)

This is the core algorithm change. `createLzma2` currently creates 1 folder with all files. The new `createMultiFolder` creates N folders, one per unique group_index.

**Files:**
- Modify: `src/archive.zig` (new function + modify createWithProgress dispatch)

**Step 1: Write failing test — multi-folder roundtrip**

In `src/archive.zig`, add test:

```zig
test "archive: createMultiFolder groups files into separate folders" {
    const allocator = std.testing.allocator;

    // 3 files in 2 groups
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "hello from group 0", .group_index = 0 },
        .{ .name = "b.bin", .data = "binary group 1 data", .group_index = 1 },
        .{ .name = "c.txt", .data = "more text group 0", .group_index = 0 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(archive_data);

    // Read it back
    var contents = try read(archive_data, allocator);
    defer contents.deinit();

    // Verify file contents (extraction reorders by folder, but file_infos preserve order)
    try std.testing.expectEqual(@as(usize, 3), contents.file_data.len);
    // Files should be readable regardless of folder grouping
    // The metadata preserves original file order, data maps correctly
    try std.testing.expectEqualStrings("hello from group 0", contents.file_data[0]);
    try std.testing.expectEqualStrings("binary group 1 data", contents.file_data[1]);
    try std.testing.expectEqualStrings("more text group 0", contents.file_data[2]);
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test`
Expected: Compilation error — `createMultiFolder` not defined.

**Step 3: Implement createMultiFolder**

In `src/archive.zig`, add the new function. The algorithm:

1. Discover unique group indices and their file counts
2. For each group: concatenate file data, compress with LZMA2, build folder metadata
3. Build multi-folder SubStreamInfo with correct `num_unpack_per_folder`
4. Build file_infos preserving original file order (critical for metadata alignment)
5. Track which original file index maps to which folder and substream position
6. Assemble: signature + all compressed blocks concatenated + encoded header

Key insight: files in the metadata (`FileInfo`) must stay in original order, but the data is reordered by group. The `readWithProgress` extraction code uses `num_unpack_per_folder` to know how many files belong to each folder, assigning them sequentially. So the file_infos must be reordered to match: all files from folder 0 first, then folder 1, etc.

```zig
pub fn createMultiFolder(
    files: []const FileEntry,
    method: Method,
    password: ?[]const u8,
    progress: ProgressContext,
    allocator: std.mem.Allocator,
) ![]u8 {
    // If method is encrypted, delegate to multi-folder AES variant
    if (method == .lzma2_aes) {
        return createMultiFolderAes(files, password, progress, allocator);
    }

    // 1. Discover unique groups and sort files by group_index
    //    Build a mapping: sorted_index -> original_index
    var sorted_indices = try allocator.alloc(usize, files.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*si, i| si.* = i;

    // Sort by group_index (stable: preserves walk order within groups)
    std.mem.sortUnstable(usize, sorted_indices, files, struct {
        pub fn lessThan(ctx: []const FileEntry, a: usize, b: usize) bool {
            const fa = ctx[a];
            const fb = ctx[b];
            // Directories always come last (no data)
            if (fa.is_dir != fb.is_dir) return !fa.is_dir;
            return fa.group_index < fb.group_index;
        }
    }.lessThan);

    // 2. Count groups and files per group (skip dirs)
    var group_count: usize = 0;
    var data_file_count: usize = 0;
    {
        var prev_group: ?u32 = null;
        for (sorted_indices) |si| {
            const f = files[si];
            if (f.is_dir) continue;
            data_file_count += 1;
            if (prev_group == null or f.group_index != prev_group.?) {
                group_count += 1;
                prev_group = f.group_index;
            }
        }
    }
    if (group_count == 0) group_count = 1; // edge case: all dirs

    // 3. For each group: concat data, compress, build folder
    var folders = try allocator.alloc(meta.Folder, group_count);
    var pack_sizes = try allocator.alloc(u64, group_count);
    var compressed_blocks = try allocator.alloc([]u8, group_count);
    var num_per_folder = try allocator.alloc(u64, group_count);
    // ... (per-file substream sizes and digests)
    var all_sub_sizes = try allocator.alloc(u64, data_file_count);
    var all_sub_digests = try allocator.alloc(?u32, data_file_count);

    var folder_idx: usize = 0;
    var sub_idx: usize = 0;
    var sorted_pos: usize = 0;

    while (sorted_pos < sorted_indices.len) {
        const si = sorted_indices[sorted_pos];
        if (files[si].is_dir) {
            sorted_pos += 1;
            continue;
        }

        const current_group = files[si].group_index;
        var group_total_size: u64 = 0;
        var group_file_count: usize = 0;

        // Count files in this group
        var peek = sorted_pos;
        while (peek < sorted_indices.len) : (peek += 1) {
            const pf = files[sorted_indices[peek]];
            if (pf.is_dir) continue;
            if (pf.group_index != current_group) break;
            group_total_size += pf.data.len;
            group_file_count += 1;
        }

        // Concatenate group data
        var raw_data = try allocator.alloc(u8, @intCast(group_total_size));
        defer allocator.free(raw_data);
        {
            var offset: usize = 0;
            var j = sorted_pos;
            while (j < sorted_indices.len) : (j += 1) {
                const f = files[sorted_indices[j]];
                if (f.is_dir) continue;
                if (f.group_index != current_group) break;
                @memcpy(raw_data[offset .. offset + f.data.len], f.data);
                all_sub_sizes[sub_idx] = f.data.len;
                all_sub_digests[sub_idx] = crc32.hash(f.data);
                sub_idx += 1;
                offset += f.data.len;
            }
        }

        // Compress this group
        const compressed = try codec.compressLzma2(raw_data, progress, allocator);
        compressed_blocks[folder_idx] = compressed;
        pack_sizes[folder_idx] = compressed.len;
        num_per_folder[folder_idx] = group_file_count;

        // Build folder metadata (single LZMA2 coder)
        // [same coder setup as existing createLzma2, one per folder]
        const method_id = try allocator.alloc(u8, 1);
        method_id[0] = 0x21;
        const props = try allocator.alloc(u8, 1);
        props[0] = calcLzma2DictProp(@intCast(@min(group_total_size, 0xFFFFFFFF)));
        var coders = try allocator.alloc(meta.Coder, 1);
        coders[0] = .{
            .method_id = method_id,
            .properties = props,
            .num_in_streams = 1,
            .num_out_streams = 1,
        };
        const unpack_sizes = try allocator.alloc(u64, 1);
        unpack_sizes[0] = group_total_size;
        folders[folder_idx] = .{
            .coders = coders,
            .bind_pairs = &.{},
            .packed_indices = &.{},
            .unpack_sizes = unpack_sizes,
            .unpack_crc = null,
        };

        folder_idx += 1;
        sorted_pos = peek; // advance past this group
    }

    // 4. Build file_infos in SORTED order (grouped by folder)
    var file_infos = try allocator.alloc(meta.FileInfo, files.len);
    // First: non-dir files in group order (matching folder data order)
    var fi_idx: usize = 0;
    for (sorted_indices) |si| {
        if (files[si].is_dir) continue;
        const f = files[si];
        file_infos[fi_idx] = .{
            .name = try allocator.dupe(u8, f.name),
            .is_empty_stream = false,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
        };
        fi_idx += 1;
    }
    // Then: directories at the end (empty streams)
    for (sorted_indices) |si| {
        if (!files[si].is_dir) continue;
        const f = files[si];
        file_infos[fi_idx] = .{
            .name = try allocator.dupe(u8, f.name),
            .is_empty_stream = true,
            .is_empty_file = false,
            .is_anti = false,
            .ctime = f.ctime,
            .atime = f.atime,
            .mtime = f.mtime,
            .win_attrib = computeWinAttrib(f),
            .start_pos = null,
            .xattrs = if (f.xattrs) |x| try allocator.dupe(u8, x) else null,
        };
        fi_idx += 1;
    }

    // 5. Assemble archive
    var archive_meta = meta.ArchiveMetadata{
        .pack_info = .{ .pack_pos = 0, .pack_sizes = pack_sizes, .pack_crcs = null },
        .folders = folders,
        .sub_streams = .{
            .num_unpack_per_folder = num_per_folder,
            .unpack_sizes = all_sub_sizes,
            .digests = all_sub_digests,
        },
        .files = file_infos,
        .allocator = allocator,
    };
    defer archive_meta.deinit();

    const next_header = try encoder.encodeNextHeader(archive_meta, allocator);
    defer allocator.free(next_header);

    // Total compressed data = sum of all blocks
    var total_compressed: usize = 0;
    for (compressed_blocks[0..folder_idx]) |cb| total_compressed += cb.len;

    const total_size = sig_header.HEADER_SIZE + total_compressed + next_header.len;
    const archive_out = try allocator.alloc(u8, total_size);

    const sig = sig_header.encode(.{
        .major_version = 0,
        .minor_version = 4,
        .next_header_offset = @intCast(total_compressed),
        .next_header_size = next_header.len,
        .next_header_crc = crc32.hash(next_header),
    });
    @memcpy(archive_out[0..sig_header.HEADER_SIZE], &sig);

    var write_offset: usize = sig_header.HEADER_SIZE;
    for (compressed_blocks[0..folder_idx]) |cb| {
        @memcpy(archive_out[write_offset .. write_offset + cb.len], cb);
        write_offset += cb.len;
        allocator.free(cb);
    }
    @memcpy(archive_out[write_offset..], next_header);

    return archive_out;
}
```

**Step 4: Wire createMultiFolder into createWithProgress**

Modify `createWithProgress` (line 95) to detect when files have mixed group_indices and dispatch to `createMultiFolder`:

```zig
pub fn createWithProgress(files: []const FileEntry, method: Method, password: ?[]const u8, progress: ProgressContext, allocator: std.mem.Allocator) ![]u8 {
    // Check if multi-folder is needed (any non-zero group_index)
    var needs_multi = false;
    var first_group: ?u32 = null;
    for (files) |f| {
        if (f.is_dir) continue;
        if (first_group == null) {
            first_group = f.group_index;
        } else if (f.group_index != first_group.?) {
            needs_multi = true;
            break;
        }
    }

    if (needs_multi) {
        return createMultiFolder(files, method, password, progress, allocator);
    }

    // Existing single-folder path
    return switch (method) {
        .copy => createCopy(files, allocator),
        .lzma2 => createLzma2(files, progress, allocator),
        .lzma2_aes => createLzma2Aes(files, password orelse return error.PasswordRequired, progress, allocator),
    };
}
```

**Step 5: Run test to verify it passes**

Run: `nix develop -c zig build test`
Expected: All tests pass, including the new multi-folder roundtrip test.

**Step 6: Commit**

```bash
git add src/archive.zig
git commit -m "Implement createMultiFolder for MIME-grouped solid blocks"
```

---

### Task 4: Multi-folder with encryption (createMultiFolderAes)

**Files:**
- Modify: `src/archive.zig` (new function)

**Step 1: Write failing test**

```zig
test "archive: createMultiFolder with encryption groups files into separate folders" {
    const allocator = std.testing.allocator;
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "secret text", .group_index = 0 },
        .{ .name = "b.bin", .data = "secret binary", .group_index = 1 },
    };

    const archive_data = try createMultiFolder(&files, .lzma2_aes, "password123", .{}, allocator);
    defer allocator.free(archive_data);

    var contents = try readWithPassword(archive_data, "password123", allocator);
    defer contents.deinit();

    try std.testing.expectEqual(@as(usize, 2), contents.file_data.len);
    try std.testing.expectEqualStrings("secret text", contents.file_data[0]);
    try std.testing.expectEqualStrings("secret binary", contents.file_data[1]);
}
```

**Step 2: Run to verify failure**

Run: `nix develop -c zig build test`
Expected: Fails — `createMultiFolderAes` not defined (referenced from createMultiFolder).

**Step 3: Implement createMultiFolderAes**

Same structure as `createMultiFolder` but each folder gets the 2-coder pipeline (LZMA2 + 7zAES) identical to how `createLzma2Aes` builds its single folder. The per-folder loop compresses then encrypts each group independently.

**Step 4: Run tests**

Run: `nix develop -c zig build test`
Expected: All pass.

**Step 5: Commit**

```bash
git add src/archive.zig
git commit -m "Add encrypted multi-folder support (createMultiFolderAes)"
```

---

### Task 5: Add 7zz interop tests for multi-folder archives

**Files:**
- Modify: `test-cli` (bash CLI tests)

**Step 1: Write failing CLI tests**

Add to `test-cli`:

```bash
# --- Multi-folder / solid block tests ---
echo "=== Multi-folder solid block tests ==="

# Create mixed-type directory
mkdir -p "$TMPDIR/mixed"
echo "hello world" > "$TMPDIR/mixed/a.txt"
echo "more text"   > "$TMPDIR/mixed/b.txt"
printf '\x00\x01\x02\x03' > "$TMPDIR/mixed/c.bin"
echo '{"key":"val"}' > "$TMPDIR/mixed/d.json"

# z7z with --no-solid should create one block per file
OUT=$("$Z7Z" create --no-solid "$TMPDIR/nosolid.7z" "$TMPDIR/mixed" 2>&1)
# 7zz should be able to extract it
nix develop -c 7zz x -y -o"$TMPDIR/nosolid_out" "$TMPDIR/nosolid.7z" > /dev/null 2>&1
assert_file_exists "no-solid: 7zz extracts a.txt" "$TMPDIR/nosolid_out/mixed/a.txt"
assert_file_exists "no-solid: 7zz extracts c.bin" "$TMPDIR/nosolid_out/mixed/c.bin"

# z7z with --solid should create one block for all files
OUT=$("$Z7Z" create --solid "$TMPDIR/solid.7z" "$TMPDIR/mixed" 2>&1)
nix develop -c 7zz x -y -o"$TMPDIR/solid_out" "$TMPDIR/solid.7z" > /dev/null 2>&1
assert_file_exists "solid: 7zz extracts a.txt" "$TMPDIR/solid_out/mixed/a.txt"

# z7z default (MIME-grouped) should create multiple blocks
OUT=$("$Z7Z" create "$TMPDIR/grouped.7z" "$TMPDIR/mixed" 2>&1)
nix develop -c 7zz x -y -o"$TMPDIR/grouped_out" "$TMPDIR/grouped.7z" > /dev/null 2>&1
assert_file_exists "grouped: 7zz extracts a.txt" "$TMPDIR/grouped_out/mixed/a.txt"
assert_file_exists "grouped: 7zz extracts c.bin" "$TMPDIR/grouped_out/mixed/c.bin"
assert_file_exists "grouped: 7zz extracts d.json" "$TMPDIR/grouped_out/mixed/d.json"

# Verify z7z can read back its own multi-folder archive
OUT=$("$Z7Z" list "$TMPDIR/grouped.7z" 2>&1)
assert_contains "grouped: z7z lists a.txt" "$OUT" "a.txt"
assert_contains "grouped: z7z lists c.bin" "$OUT" "c.bin"
```

**Step 2: Run to verify failure**

Run: `nix develop -c ./test-cli`
Expected: Fails — `--no-solid` and `--solid` flags not yet implemented in CLI.

**Step 3: These tests will pass after Tasks 6-7 (CLI implementation)**

Hold these tests as the target. They drive the CLI work.

**Step 4: Commit test file**

```bash
git add test-cli
git commit -m "Add CLI tests for multi-folder solid block modes"
```

---

### Task 6: Add libmagic integration to C CLI

**Files:**
- Modify: `cli/main.c` (add MIME detection + entry_list extension)

**Step 1: Add libmagic include and initialization**

At top of `cli/main.c`, add:
```c
#include <magic.h>
```

Add a global magic handle:
```c
static magic_t g_magic = NULL;
```

Add init/cleanup helpers:
```c
static int init_magic(void) {
	g_magic = magic_open(MAGIC_MIME_TYPE | MAGIC_SYMLINK);
	if (!g_magic) return 1;
	if (magic_load(g_magic, NULL) != 0) {
		magic_close(g_magic);
		g_magic = NULL;
		return 1;
	}
	return 0;
}

static void cleanup_magic(void) {
	if (g_magic) {
		magic_close(g_magic);
		g_magic = NULL;
	}
}
```

**Step 2: Add MIME type tracking to entry_list**

Extend `entry_list` struct:
```c
typedef struct {
	z7z_file_entry *entries;
	uint8_t **bufs;
	char **names;
	uint8_t **xattr_bufs;
	char **mime_types;     /* NEW: MIME type string per entry (NULL for dirs) */
	size_t count;
	size_t capacity;
} entry_list;
```

Update `entry_list_init`, `entry_list_grow`, and `entry_list_free` to handle the new array.

**Step 3: Detect MIME type in entry_list_add_file**

After reading a file, if `g_magic` is available, call:
```c
const char *mime = magic_file(g_magic, full_path);
list->mime_types[list->count] = mime ? strdup(mime) : strdup("application/octet-stream");
```

For directories and symlinks, set `mime_types[idx] = NULL`.

**Step 4: Add group assignment function**

```c
/* Assign group_index to entries based on MIME types.
 * Files with the same MIME type get the same group index.
 * Directories get group 0 (they carry no data). */
static void assign_mime_groups(entry_list *list) {
	/* Collect unique MIME types */
	char *unique_mimes[256];
	size_t unique_count = 0;

	for (size_t i = 0; i < list->count; i++) {
		if (!list->mime_types[i]) {
			list->entries[i].group_index = 0;
			continue;
		}
		/* Find or insert MIME type */
		uint32_t group = 0;
		int found = 0;
		for (size_t j = 0; j < unique_count; j++) {
			if (strcmp(unique_mimes[j], list->mime_types[i]) == 0) {
				group = (uint32_t)j;
				found = 1;
				break;
			}
		}
		if (!found && unique_count < 256) {
			unique_mimes[unique_count] = list->mime_types[i];
			group = (uint32_t)unique_count;
			unique_count++;
		}
		list->entries[i].group_index = group;
	}
}
```

**Step 5: Run tests**

Run: `nix develop -c zig build -Doptimize=ReleaseFast && nix develop -c zig build test`
Expected: Builds and unit tests pass.

**Step 6: Commit**

```bash
git add cli/main.c
git commit -m "Add libmagic MIME detection and group assignment to CLI"
```

---

### Task 7: Add --solid / --no-solid flags and wire into cmd_create

**Files:**
- Modify: `cli/main.c` (flag parsing + cmd_create changes)

**Step 1: Add global flag**

```c
typedef enum { SOLID_AUTO, SOLID_ON, SOLID_OFF } solid_mode_t;
static solid_mode_t g_solid_mode = SOLID_AUTO;
```

**Step 2: Parse flags in the flag parsing section**

In the flag parsing loop, add:
```c
if (strcmp(arg, "--solid") == 0 || strcmp(arg, "-ms=on") == 0) {
	g_solid_mode = SOLID_ON;
} else if (strcmp(arg, "--no-solid") == 0 || strcmp(arg, "-ms=off") == 0) {
	g_solid_mode = SOLID_OFF;
}
```

**Step 3: Apply solid mode in cmd_create**

After collecting all files and before calling `z7z_create_ex_pw`:

```c
/* Apply solid mode */
if (g_solid_mode == SOLID_AUTO) {
	/* Default: MIME-grouped (already assigned by assign_mime_groups) */
	if (!init_magic()) {
		assign_mime_groups(&list);
		cleanup_magic();
	}
	/* If magic init failed, all entries keep group_index=0 (single solid block) */
} else if (g_solid_mode == SOLID_ON) {
	/* Force all files into one group */
	for (size_t i = 0; i < list.count; i++)
		list.entries[i].group_index = 0;
} else { /* SOLID_OFF */
	/* Each file gets its own group */
	uint32_t g = 0;
	for (size_t i = 0; i < list.count; i++) {
		if (list.entries[i].flags & Z7Z_FLAG_DIRECTORY) continue;
		list.entries[i].group_index = g++;
	}
}
```

**Step 4: Run CLI tests**

Run: `nix develop -c zig build -Doptimize=ReleaseFast && nix develop -c ./test-cli`
Expected: All tests pass including the new multi-folder/solid block tests from Task 5.

**Step 5: Commit**

```bash
git add cli/main.c
git commit -m "Add --solid/--no-solid flags with MIME-grouped default"
```

---

### Task 8: Update --help text and documentation

**Files:**
- Modify: `cli/main.c` (help text)
- Modify: `PLAN.md`
- Modify: `CODE_MINIMAP.md`

**Step 1: Update help text**

Add to the create section of the `--help` output:
```
  --solid         Force all files into one solid block
  --no-solid      One file per block (no solid compression)
  (default)       Group files by MIME type into solid blocks
```

**Step 2: Update PLAN.md**

Mark the solid archive task as complete.

**Step 3: Update CODE_MINIMAP.md**

Add `createMultiFolder()`, `createMultiFolderAes()`, libmagic integration, and new CLI flags.

**Step 4: Run full test suite**

Run: `nix develop -c ./test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add cli/main.c PLAN.md CODE_MINIMAP.md
git commit -m "Update docs and help text for MIME-grouped solid blocks"
```

---

### Task 9: Edge case tests and hardening

**Files:**
- Modify: `src/archive.zig` (add edge case tests)
- Modify: `test-cli` (add edge case CLI tests)

**Step 1: Zig unit tests for edge cases**

```zig
test "archive: createMultiFolder single group degenerates to one folder" {
    // All files same group → exactly like single-folder createLzma2
    const allocator = std.testing.allocator;
    const files = [_]FileEntry{
        .{ .name = "a.txt", .data = "aaa" },
        .{ .name = "b.txt", .data = "bbb" },
    };
    const data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(data);
    var contents = try read(data, allocator);
    defer contents.deinit();
    try std.testing.expectEqual(@as(usize, 2), contents.file_data.len);
}

test "archive: createMultiFolder with directories preserves them" {
    const allocator = std.testing.allocator;
    const files = [_]FileEntry{
        .{ .name = "dir/", .data = "", .is_dir = true },
        .{ .name = "dir/a.txt", .data = "hello", .group_index = 0 },
        .{ .name = "dir/b.bin", .data = "\x00\x01", .group_index = 1 },
    };
    const data = try createMultiFolder(&files, .lzma2, null, .{}, allocator);
    defer allocator.free(data);
    var contents = try read(data, allocator);
    defer contents.deinit();
    try std.testing.expectEqual(@as(usize, 3), contents.metadata.files.len);
}
```

**Step 2: CLI edge case tests**

- Single file → one block (no grouping needed)
- Empty directory → still works
- All files same type → one block (degenerate case)
- Symlinks with mixed file targets

**Step 3: Run all tests**

Run: `nix develop -c ./test`
Expected: All pass.

**Step 4: Commit**

```bash
git add src/archive.zig test-cli
git commit -m "Add edge case tests for multi-folder solid archives"
```

---

## Summary

| Task | What | Key Files |
|------|------|-----------|
| 1 | Add libmagic to build deps | flake.nix, build.zig |
| 2 | Add group_index field | archive.zig, ffi.zig, z7z.h |
| 3 | createMultiFolder (LZMA2) | archive.zig |
| 4 | createMultiFolderAes (encrypted) | archive.zig |
| 5 | CLI interop tests | test-cli |
| 6 | libmagic in CLI | cli/main.c |
| 7 | --solid/--no-solid flags | cli/main.c |
| 8 | Docs + help text | cli/main.c, PLAN.md, CODE_MINIMAP.md |
| 9 | Edge case hardening | archive.zig, test-cli |
