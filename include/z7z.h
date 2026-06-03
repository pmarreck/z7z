/* z7z.h — C FFI for the z7z cleanroom 7z implementation.
 *
 * All functions are safe to call from any thread.
 * Memory returned by z7z_open is freed by z7z_close.
 * Memory returned by z7z_create is freed by z7z_free.
 */

#ifndef Z7Z_H
#define Z7Z_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes */
enum {
	Z7Z_OK                    = 0,
	Z7Z_ERR_NOT_ARCHIVE       = 1,
	Z7Z_ERR_CHECKSUM          = 2,
	Z7Z_ERR_TRUNCATED         = 3,
	Z7Z_ERR_STRUCTURAL        = 4,
	Z7Z_ERR_UNSUPPORTED       = 5,
	Z7Z_ERR_OUT_OF_MEMORY     = 6,
	Z7Z_ERR_INVALID_ARG       = 7,
	Z7Z_ERR_INDEX_OUT_OF_BOUNDS = 8,
	Z7Z_ERR_PASSWORD_REQUIRED = 9,
	Z7Z_ERR_INTERNAL          = 10,
};

/* Opaque archive handle */
typedef struct z7z_archive z7z_archive;

/* Open a .7z archive from a memory buffer.
 * Returns Z7Z_OK on success, error code otherwise.
 * On success, *out receives an opaque handle (free with z7z_close). */
int z7z_open(const uint8_t *data, size_t len, z7z_archive **out);

/* Number of files in the archive. Returns 0 if handle is NULL. */
size_t z7z_file_count(const z7z_archive *archive);

/* File name at index (UTF-8, null-terminated). Returns NULL on error. */
const char *z7z_file_name(const z7z_archive *archive, size_t index);

/* Pointer to file's uncompressed data. Returns NULL if empty or error. */
const uint8_t *z7z_file_data(const z7z_archive *archive, size_t index);

/* File's uncompressed size. Returns 0 on error. */
size_t z7z_file_size(const z7z_archive *archive, size_t index);

/* Returns 1 if the entry at index is a directory, 0 otherwise. */
int z7z_file_is_dir(const z7z_archive *archive, size_t index);

/* Returns 1 if the entry at index is a symbolic link, 0 otherwise.
 * Symlink target path is available via z7z_file_data()/z7z_file_size(). */
int z7z_file_is_symlink(const z7z_archive *archive, size_t index);

/* Get file's modification time as Unix timestamp (seconds since epoch).
 * Returns 0 if mtime not stored or on error. */
int64_t z7z_file_mtime(const z7z_archive *archive, size_t index);

/* Get file's creation/birth time as Unix timestamp (seconds since epoch).
 * Returns 0 if ctime not stored or on error. */
int64_t z7z_file_ctime(const z7z_archive *archive, size_t index);

/* Get file's access time as Unix timestamp (seconds since epoch).
 * Returns 0 if atime not stored or on error. */
int64_t z7z_file_atime(const z7z_archive *archive, size_t index);

/* Get file's win_attrib (POSIX mode in upper 16 bits, Windows attrs in lower).
 * Returns 0 if not stored or on error. */
uint32_t z7z_file_attrib(const z7z_archive *archive, size_t index);

/* Get file's xattr blob pointer. Sets *out_len to blob length.
 * Returns NULL if no xattrs stored or on error. */
const uint8_t *z7z_file_xattrs(const z7z_archive *archive, size_t index,
                                size_t *out_len);

/* Close an archive and free all memory. Safe to call with NULL. */
void z7z_close(z7z_archive *archive);

/* File entry flags */
#define Z7Z_FLAG_DIRECTORY  0x01   /* entry is a directory (no data) */
#define Z7Z_FLAG_SYMLINK    0x02   /* entry is a symbolic link (data = target path) */

/* Special values: timestamp not set (pass to z7z_file_entry fields) */
#define Z7Z_NO_MTIME  0
#define Z7Z_NO_CTIME  0
#define Z7Z_NO_ATIME  0

/* File entry for creating archives. */
typedef struct {
	const char *name;          /* null-terminated UTF-8 filename */
	const uint8_t *data;       /* file content (NULL for directories) */
	size_t data_len;           /* length of data (0 for directories) */
	uint32_t flags;            /* Z7Z_FLAG_* bitmask */
	int64_t mtime;             /* Unix timestamp (0 = not set) */
	uint32_t win_attrib;       /* POSIX mode<<16 | win_flags (0 = not set) */
	int64_t ctime;             /* creation/birth time Unix timestamp (0 = not set) */
	int64_t atime;             /* access time Unix timestamp (0 = not set) */
	const uint8_t *xattrs;     /* serialized xattr blob (NULL if none) */
	size_t xattrs_len;         /* length of xattr blob */
	uint32_t group_index;      /* solid block group (0 = default) */
} z7z_file_entry;

/* Create a .7z archive from file entries.
 * Returns Z7Z_OK on success. Caller must free *out_data with z7z_free.
 * Uses LZMA2 compression with optimal parsing. */
int z7z_create(const z7z_file_entry *files, size_t count,
               uint8_t **out_data, size_t *out_len);

/* Progress callback type: (bytes_done, bytes_total, user_data).
 * Called during compression/decompression to report progress. */
typedef void (*z7z_progress_fn)(uint64_t bytes_done, uint64_t bytes_total,
                                void *user_data);

/* Open a .7z archive with progress reporting during decompression.
 * The callback fires per-folder with packed bytes decompressed. */
int z7z_open_ex(const uint8_t *data, size_t len,
                z7z_progress_fn progress, void *user_data,
                z7z_archive **out);

/* Open a .7z archive with password and progress reporting. */
int z7z_open_ex_pw(const uint8_t *data, size_t len,
                   const char *password,
                   z7z_progress_fn progress, void *user_data,
                   z7z_archive **out);

/* Create a .7z archive with progress reporting during compression.
 * The callback fires per-chunk/block with uncompressed bytes processed. */
int z7z_create_ex(const z7z_file_entry *files, size_t count,
                  z7z_progress_fn progress, void *user_data,
                  uint8_t **out_data, size_t *out_len);

/* Default compression level (matches 7zz -mx=5). */
#define Z7Z_DEFAULT_LEVEL 5

/* Create a .7z archive with optional password encryption, compression level, and progress.
 * Uses LZMA2+AES when password is non-NULL, plain LZMA2 otherwise.
 * level: 0 (fastest) to 9 (best compression). Values > 9 are clamped to 9. */
int z7z_create_ex_pw(const z7z_file_entry *files, size_t count,
                     const char *password, uint8_t level,
                     z7z_progress_fn progress, void *user_data,
                     uint8_t **out_data, size_t *out_len);

/* Create a .7z archive with full options: password, level, threads, header encryption, progress.
 * thread_count: 0 = auto-detect, 1 = single-threaded, N = use N threads.
 * encrypt_header: 1 = encrypt header (-mhe=on), 0 = plaintext header.
 * Uses LZMA2+AES when password is non-NULL, plain LZMA2 otherwise. */
int z7z_create_ex2(const z7z_file_entry *files, size_t count,
                   const char *password, uint8_t level,
                   uint32_t thread_count, int encrypt_header,
                   z7z_progress_fn progress, void *user_data,
                   uint8_t **out_data, size_t *out_len);

/* Free archive data returned by z7z_create / z7z_create_ex. */
void z7z_free(uint8_t *data, size_t len);

/* Human-readable error message for an error code. Never returns NULL. */
const char *z7z_error_string(int code);

#ifdef __cplusplus
}
#endif

#endif /* Z7Z_H */
