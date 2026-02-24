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

/* Close an archive and free all memory. Safe to call with NULL. */
void z7z_close(z7z_archive *archive);

/* File entry flags */
#define Z7Z_FLAG_DIRECTORY  0x01   /* entry is a directory (no data) */

/* File entry for creating archives. */
typedef struct {
	const char *name;          /* null-terminated UTF-8 filename */
	const uint8_t *data;       /* file content (NULL for directories) */
	size_t data_len;           /* length of data (0 for directories) */
	uint32_t flags;            /* Z7Z_FLAG_* bitmask */
} z7z_file_entry;

/* Create a .7z archive from file entries.
 * Returns Z7Z_OK on success. Caller must free *out_data with z7z_free.
 * Uses LZMA2 compression with optimal parsing. */
int z7z_create(const z7z_file_entry *files, size_t count,
               uint8_t **out_data, size_t *out_len);

/* Free archive data returned by z7z_create. */
void z7z_free(uint8_t *data, size_t len);

/* Human-readable error message for an error code. Never returns NULL. */
const char *z7z_error_string(int code);

#ifdef __cplusplus
}
#endif

#endif /* Z7Z_H */
