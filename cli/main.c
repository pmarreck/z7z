/* z7z CLI — dogfoods the C FFI.
 *
 * Usage:
 *   z7z list   <archive.7z>
 *   z7z extract [--no-ctime] [--no-xattr] <archive.7z> [output-dir]
 *   z7z create  [--dereference|-L] [--no-ctime] [--atime] [--no-xattr]
 *               <archive.7z> <file1|dir1> [file2|dir2 ...]
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dirent.h>
#include <unistd.h>

#ifdef __APPLE__
#include <sys/attr.h>
#include <sys/xattr.h>
#elif defined(__linux__)
#include <sys/xattr.h>
#include <sys/sysmacros.h>
#include <linux/stat.h>   /* statx */
#include <fcntl.h>        /* AT_FDCWD, AT_SYMLINK_NOFOLLOW */
#endif

#ifdef _WIN32
#include <direct.h>
#define mkdir(path, mode) _mkdir(path)
#define lstat stat
#define readlink(p, b, s) (-1)
#define symlink(t, l) (-1)
#ifndef S_ISDIR
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#endif
#ifndef S_ISREG
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#endif
#ifndef S_ISLNK
#define S_ISLNK(m) (0)
#endif
#else
#ifndef S_ISLNK
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)
#endif
#endif

#include "z7z.h"

/* Global flags */
static int g_dereference = 0;
static int g_no_ctime = 0;
static int g_atime = 0;
static int g_no_xattr = 0;

static void usage(const char *prog) {
	fprintf(stderr,
		"Usage:\n"
		"  %s list    <archive.7z>\n"
		"  %s extract [--no-ctime] [--no-xattr] <archive.7z> [output-dir]\n"
		"  %s create  [--dereference|-L] [--no-ctime] [--atime] [--no-xattr]\n"
		"             <archive.7z> <file1|dir1> [file2|dir2 ...]\n",
		prog, prog, prog);
}

/* Read entire file into malloc'd buffer. Caller frees. */
static uint8_t *read_file(const char *path, size_t *out_len) {
	FILE *f = fopen(path, "rb");
	if (!f) {
		fprintf(stderr, "error: cannot open '%s': %s\n", path, strerror(errno));
		return NULL;
	}

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	if (sz < 0) {
		fprintf(stderr, "error: cannot determine size of '%s'\n", path);
		fclose(f);
		return NULL;
	}
	fseek(f, 0, SEEK_SET);

	uint8_t *buf = malloc((size_t)sz);
	if (!buf) {
		fprintf(stderr, "error: out of memory reading '%s'\n", path);
		fclose(f);
		return NULL;
	}

	size_t nread = fread(buf, 1, (size_t)sz, f);
	fclose(f);

	if (nread != (size_t)sz) {
		fprintf(stderr, "error: short read on '%s'\n", path);
		free(buf);
		return NULL;
	}

	*out_len = (size_t)sz;
	return buf;
}

/* Write buffer to file. Returns 0 on success. */
static int write_file(const char *path, const uint8_t *data, size_t len) {
	FILE *f = fopen(path, "wb");
	if (!f) {
		fprintf(stderr, "error: cannot create '%s': %s\n", path, strerror(errno));
		return 1;
	}

	if (len > 0) {
		size_t nwritten = fwrite(data, 1, len, f);
		if (nwritten != len) {
			fprintf(stderr, "error: short write on '%s'\n", path);
			fclose(f);
			return 1;
		}
	}

	fclose(f);
	return 0;
}

/* Extract basename from a path (last component after / or \). */
static const char *basename_of(const char *path) {
	const char *last = path;
	for (const char *p = path; *p; p++) {
		if (*p == '/' || *p == '\\')
			last = p + 1;
	}
	return last;
}

/* Ensure a single directory level exists. */
static int ensure_dir(const char *path) {
	struct stat st;
	if (stat(path, &st) == 0) {
		if (S_ISDIR(st.st_mode)) return 0;
		fprintf(stderr, "error: '%s' exists but is not a directory\n", path);
		return 1;
	}
	if (mkdir(path, 0755) != 0 && errno != EEXIST) {
		fprintf(stderr, "error: cannot create directory '%s': %s\n", path, strerror(errno));
		return 1;
	}
	return 0;
}

/* Create all directories along a path (like mkdir -p). */
static int ensure_dir_recursive(const char *path) {
	char buf[4096];
	size_t len = strlen(path);
	if (len == 0 || len >= sizeof(buf)) return 1;
	memcpy(buf, path, len + 1);

	/* Strip trailing separators */
	while (len > 1 && (buf[len - 1] == '/' || buf[len - 1] == '\\'))
		buf[--len] = '\0';

	for (size_t i = 1; i <= len; i++) {
		if (buf[i] == '/' || buf[i] == '\\' || buf[i] == '\0') {
			char saved = buf[i];
			buf[i] = '\0';
			if (ensure_dir(buf) != 0) return 1;
			buf[i] = saved;
		}
	}
	return 0;
}

/* Ensure the parent directory of a file path exists. */
static int ensure_parent_dir(const char *filepath) {
	const char *last_sep = NULL;
	for (const char *p = filepath; *p; p++) {
		if (*p == '/' || *p == '\\') last_sep = p;
	}
	if (!last_sep) return 0; /* no parent dir component */

	char buf[4096];
	size_t len = (size_t)(last_sep - filepath);
	if (len == 0 || len >= sizeof(buf)) return 0;
	memcpy(buf, filepath, len);
	buf[len] = '\0';
	return ensure_dir_recursive(buf);
}

/* Check if a symlink target is safe for extraction.
 * Rejects absolute paths and paths that escape the extraction root via "..". */
static int symlink_target_is_safe(const char *target) {
	/* Reject absolute targets */
	if (target[0] == '/' || target[0] == '\\')
		return 0;
#ifdef _WIN32
	/* Reject Windows drive letter paths like C:\ */
	if (strlen(target) >= 2 && target[1] == ':')
		return 0;
#endif
	/* Reject targets that start with ../ or are exactly ".." */
	if (strncmp(target, "../", 3) == 0 || strcmp(target, "..") == 0)
		return 0;
	/* Reject targets containing /../ */
	if (strstr(target, "/../") != NULL)
		return 0;
	/* Reject targets ending with /.. */
	size_t tlen = strlen(target);
	if (tlen >= 3 && strcmp(target + tlen - 3, "/..") == 0)
		return 0;

	return 1;
}

/* ========================================================================== */
/* Dynamic entry list for directory walking                                   */
/* ========================================================================== */

typedef struct {
	z7z_file_entry *entries;
	uint8_t **bufs;       /* file data buffers (NULL for directories) */
	char **names;          /* allocated name strings */
	uint8_t **xattr_bufs; /* xattr blob buffers (NULL if none) */
	size_t count;
	size_t capacity;
} entry_list;

static int entry_list_init(entry_list *list, size_t initial_cap) {
	list->count = 0;
	list->capacity = initial_cap;
	list->entries = calloc(initial_cap, sizeof(z7z_file_entry));
	list->bufs = calloc(initial_cap, sizeof(uint8_t *));
	list->names = calloc(initial_cap, sizeof(char *));
	list->xattr_bufs = calloc(initial_cap, sizeof(uint8_t *));
	return (list->entries && list->bufs && list->names && list->xattr_bufs) ? 0 : 1;
}

static int entry_list_grow(entry_list *list) {
	size_t new_cap = list->capacity * 2;
	z7z_file_entry *ne = realloc(list->entries, new_cap * sizeof(z7z_file_entry));
	uint8_t **nb = realloc(list->bufs, new_cap * sizeof(uint8_t *));
	char **nn = realloc(list->names, new_cap * sizeof(char *));
	uint8_t **nx = realloc(list->xattr_bufs, new_cap * sizeof(uint8_t *));
	if (!ne || !nb || !nn || !nx) return 1;
	memset(ne + list->capacity, 0, (new_cap - list->capacity) * sizeof(z7z_file_entry));
	memset(nb + list->capacity, 0, (new_cap - list->capacity) * sizeof(uint8_t *));
	memset(nn + list->capacity, 0, (new_cap - list->capacity) * sizeof(char *));
	memset(nx + list->capacity, 0, (new_cap - list->capacity) * sizeof(uint8_t *));
	list->entries = ne;
	list->bufs = nb;
	list->names = nn;
	list->xattr_bufs = nx;
	list->capacity = new_cap;
	return 0;
}

static void entry_list_free(entry_list *list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->bufs[i]);
		free(list->names[i]);
		free(list->xattr_bufs[i]);
	}
	free(list->entries);
	free(list->bufs);
	free(list->names);
	free(list->xattr_bufs);
}

static int entry_list_add_dir(entry_list *list, const char *name,
                              int64_t mtime, int64_t ctime, int64_t atime,
                              uint32_t win_attrib) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	list->bufs[idx] = NULL;
	list->xattr_bufs[idx] = NULL;
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = NULL;
	list->entries[idx].data_len = 0;
	list->entries[idx].flags = Z7Z_FLAG_DIRECTORY;
	list->entries[idx].mtime = mtime;
	list->entries[idx].ctime = ctime;
	list->entries[idx].atime = atime;
	list->entries[idx].win_attrib = win_attrib;
	list->entries[idx].xattrs = NULL;
	list->entries[idx].xattrs_len = 0;
	list->count++;
	return 0;
}

static int entry_list_add_file(entry_list *list, const char *name,
                               uint8_t *data, size_t data_len,
                               int64_t mtime, int64_t ctime, int64_t atime,
                               uint32_t win_attrib,
                               uint8_t *xattr_blob, size_t xattr_len) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	list->bufs[idx] = data;  /* takes ownership */
	list->xattr_bufs[idx] = xattr_blob; /* takes ownership (may be NULL) */
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = data;
	list->entries[idx].data_len = data_len;
	list->entries[idx].flags = 0;
	list->entries[idx].mtime = mtime;
	list->entries[idx].ctime = ctime;
	list->entries[idx].atime = atime;
	list->entries[idx].win_attrib = win_attrib;
	list->entries[idx].xattrs = xattr_blob;
	list->entries[idx].xattrs_len = xattr_len;
	list->count++;
	return 0;
}

static int entry_list_add_symlink(entry_list *list, const char *name,
                                  const char *target,
                                  int64_t mtime, int64_t ctime, int64_t atime,
                                  uint32_t win_attrib,
                                  uint8_t *xattr_blob, size_t xattr_len) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	size_t tlen = strlen(target);
	list->bufs[idx] = (uint8_t *)strdup(target);
	if (!list->bufs[idx]) return 1;
	list->xattr_bufs[idx] = xattr_blob; /* takes ownership (may be NULL) */
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = list->bufs[idx];
	list->entries[idx].data_len = tlen;
	list->entries[idx].flags = Z7Z_FLAG_SYMLINK;
	list->entries[idx].mtime = mtime;
	list->entries[idx].ctime = ctime;
	list->entries[idx].atime = atime;
	list->entries[idx].win_attrib = win_attrib;
	list->entries[idx].xattrs = xattr_blob;
	list->entries[idx].xattrs_len = xattr_len;
	list->count++;
	return 0;
}

/* ========================================================================== */
/* Metadata helpers                                                           */
/* ========================================================================== */

/* Compute win_attrib from POSIX st_mode: (st_mode << 16) | 0x8020.
 * 0x8000 = POSIX bits present, 0x0020 = ARCHIVE flag.
 * For directories, also sets FILE_ATTRIBUTE_DIRECTORY (0x10). */
static uint32_t win_attrib_from_mode(mode_t mode) {
	uint32_t attrib = ((uint32_t)mode << 16) | 0x8020;
	if (S_ISDIR(mode))
		attrib |= 0x10; /* FILE_ATTRIBUTE_DIRECTORY */
	return attrib;
}

/* Set file mtime (and optionally atime) using utimes(). Returns 0 on success.
 * If atime_ts > 0, use it for atime; otherwise mirror mtime. */
static int set_times(const char *path, int64_t mtime_ts, int64_t atime_ts) {
	if (mtime_ts <= 0 && atime_ts <= 0) return 0;
	struct timeval tv[2];
	tv[0].tv_sec = (time_t)(atime_ts > 0 ? atime_ts : mtime_ts);  /* atime */
	tv[0].tv_usec = 0;
	tv[1].tv_sec = (time_t)(mtime_ts > 0 ? mtime_ts : atime_ts);  /* mtime */
	tv[1].tv_usec = 0;
	return utimes(path, tv);
}

/* Set file permissions from win_attrib (POSIX mode in upper 16 bits).
 * Only sets if POSIX bits are present (0x8000 flag in lower word). */
static int set_permissions(const char *path, uint32_t attrib) {
	if (attrib == 0) return 0;
	/* Check for POSIX_PRESENT flag */
	if (!(attrib & 0x8000)) return 0;
	mode_t mode = (mode_t)(attrib >> 16) & 07777; /* permission bits only */
	if (mode == 0) return 0;
	return chmod(path, mode);
}

/* ========================================================================== */
/* Birthtime (creation time) helpers                                          */
/* ========================================================================== */

/* Capture birthtime as Unix timestamp. Returns 0 if unavailable. */
static int64_t capture_birthtime(const char *path, const struct stat *st) {
	if (g_no_ctime) return 0;
	(void)path; /* used on Linux path */
#ifdef __APPLE__
	return (int64_t)st->st_birthtimespec.tv_sec;
#elif defined(__linux__)
	(void)st;
	struct statx sx;
	if (statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW, STATX_BTIME, &sx) == 0
	    && (sx.stx_mask & STATX_BTIME))
		return (int64_t)sx.stx_btime.tv_sec;
	return 0;
#else
	(void)st;
	return 0;
#endif
}

/* Capture atime as Unix timestamp. Returns 0 if --atime not set. */
static int64_t capture_atime(const struct stat *st) {
	if (!g_atime) return 0;
#ifdef __APPLE__
	return (int64_t)st->st_atimespec.tv_sec;
#else
	return (int64_t)st->st_atime;
#endif
}

#ifdef __APPLE__
/* Restore birthtime on macOS using setattrlist. Returns 0 on success. */
static int set_birthtime(const char *path, int64_t unix_ts) {
	if (unix_ts <= 0) return 0;
	struct attrlist al;
	memset(&al, 0, sizeof(al));
	al.bitmapcount = ATTR_BIT_MAP_COUNT;
	al.commonattr = ATTR_CMN_CRTIME;
	struct timespec ts;
	ts.tv_sec = (time_t)unix_ts;
	ts.tv_nsec = 0;
	return setattrlist(path, &al, &ts, sizeof(ts), 0);
}
#endif

/* ========================================================================== */
/* Extended attribute helpers                                                 */
/* ========================================================================== */

#if defined(__APPLE__) || defined(__linux__)

/* Blocklist: xattrs that should NOT be preserved. */
static int xattr_is_blocked(const char *name) {
	return strcmp(name, "com.apple.quarantine") == 0
		|| strcmp(name, "com.apple.genstore") == 0
		|| strncmp(name, "com.apple.diskimages.", 21) == 0;
}

/* Serialize xattrs from a file into a blob.
 * Format: varint:count, then for each: varint:name_len, name, varint:val_len, val
 * Returns malloc'd blob (caller frees) or NULL if none/error. Sets *out_len. */
static uint8_t *capture_xattrs(const char *path, size_t *out_len) {
	*out_len = 0;
	if (g_no_xattr) return NULL;

#ifdef __APPLE__
	ssize_t list_size = listxattr(path, NULL, 0, XATTR_NOFOLLOW);
#else
	ssize_t list_size = llistxattr(path, NULL, 0);
#endif
	if (list_size <= 0) return NULL;

	char *name_buf = malloc((size_t)list_size);
	if (!name_buf) return NULL;

#ifdef __APPLE__
	ssize_t got = listxattr(path, name_buf, (size_t)list_size, XATTR_NOFOLLOW);
#else
	ssize_t got = llistxattr(path, name_buf, (size_t)list_size);
#endif
	if (got <= 0) { free(name_buf); return NULL; }

	/* Count non-blocked xattrs and compute total size */
	size_t count = 0;
	size_t total_data = 0;
	for (char *p = name_buf; p < name_buf + got; ) {
		size_t nlen = strlen(p);
		if (!xattr_is_blocked(p)) {
#ifdef __APPLE__
			ssize_t vlen = getxattr(path, p, NULL, 0, 0, XATTR_NOFOLLOW);
#else
			ssize_t vlen = lgetxattr(path, p, NULL, 0);
#endif
			if (vlen < 0) vlen = 0;
			count++;
			total_data += nlen + (size_t)vlen;
		}
		p += nlen + 1;
	}
	if (count == 0) { free(name_buf); return NULL; }

	/* Allocate generous buffer: count_varint + per-xattr (2 varints + name + value)
	 * Each varint is at most 9 bytes. */
	size_t buf_size = 9 + count * 18 + total_data;
	uint8_t *blob = malloc(buf_size);
	if (!blob) { free(name_buf); return NULL; }
	size_t pos = 0;

	/* Write count as varint (7z-style: values < 128 are 1 byte) */
	blob[pos++] = (uint8_t)count; /* count will be < 128 in practice */

	for (char *p = name_buf; p < name_buf + got; ) {
		size_t nlen = strlen(p);
		if (!xattr_is_blocked(p)) {
			/* name_len varint */
			blob[pos++] = (uint8_t)nlen; /* names < 128 bytes */
			memcpy(blob + pos, p, nlen);
			pos += nlen;

			/* Get value */
#ifdef __APPLE__
			ssize_t vlen = getxattr(path, p, NULL, 0, 0, XATTR_NOFOLLOW);
#else
			ssize_t vlen = lgetxattr(path, p, NULL, 0);
#endif
			if (vlen < 0) vlen = 0;

			/* value_len varint */
			if ((size_t)vlen < 128) {
				blob[pos++] = (uint8_t)vlen;
			} else {
				/* 2-byte varint for values 128-16383 */
				blob[pos++] = (uint8_t)(0x80 | ((uint8_t)vlen & 0x3F));
				blob[pos++] = (uint8_t)(vlen >> 6);
			}

			if (vlen > 0) {
#ifdef __APPLE__
				getxattr(path, p, blob + pos, (size_t)vlen, 0, XATTR_NOFOLLOW);
#else
				lgetxattr(path, p, blob + pos, (size_t)vlen);
#endif
				pos += (size_t)vlen;
			}
		}
		p += nlen + 1;
	}

	free(name_buf);
	*out_len = pos;
	return blob;
}

/* Read a simple varint from blob. Returns value and advances *pos. */
static size_t read_xattr_varint(const uint8_t *blob, size_t blob_len, size_t *pos) {
	if (*pos >= blob_len) return 0;
	uint8_t b = blob[(*pos)++];
	if (b < 0x80) return b;
	if (*pos >= blob_len) return 0;
	uint8_t b2 = blob[(*pos)++];
	return (size_t)(b & 0x3F) | ((size_t)b2 << 6);
}

/* Restore xattrs from a serialized blob onto a file path. */
static void restore_xattrs(const char *path, const uint8_t *blob, size_t blob_len) {
	if (!blob || blob_len == 0 || g_no_xattr) return;

	size_t pos = 0;
	size_t count = read_xattr_varint(blob, blob_len, &pos);

	for (size_t i = 0; i < count && pos < blob_len; i++) {
		size_t nlen = read_xattr_varint(blob, blob_len, &pos);
		if (pos + nlen > blob_len) break;
		char name[256];
		if (nlen >= sizeof(name)) { pos += nlen; continue; } /* skip oversized names */
		memcpy(name, blob + pos, nlen);
		name[nlen] = '\0';
		pos += nlen;

		size_t vlen = read_xattr_varint(blob, blob_len, &pos);
		if (pos + vlen > blob_len) break;
		const void *val = blob + pos;
		pos += vlen;

		/* Apply the xattr */
#ifdef __APPLE__
		setxattr(path, name, val, vlen, 0, XATTR_NOFOLLOW);
#else
		lsetxattr(path, name, val, vlen, 0);
#endif
	}
}

#else /* !(APPLE || linux) */

static uint8_t *capture_xattrs(const char *path, size_t *out_len) {
	(void)path;
	*out_len = 0;
	return NULL;
}

static void restore_xattrs(const char *path, const uint8_t *blob, size_t blob_len) {
	(void)path; (void)blob; (void)blob_len;
}

#endif /* __APPLE__ || __linux__ */

/* ========================================================================== */
/* Recursive directory walking                                                */
/* ========================================================================== */

/* Read symlink target and add as entry. Returns 0 on success. */
static int add_symlink_entry(entry_list *list, const char *fs_path,
                             const char *archive_name, const struct stat *st) {
	char target[4096];
	ssize_t tlen = readlink(fs_path, target, sizeof(target) - 1);
	if (tlen < 0) {
		fprintf(stderr, "warning: cannot read symlink '%s': %s\n",
			fs_path, strerror(errno));
		return 1;
	}
	target[tlen] = '\0';
	size_t xlen = 0;
	uint8_t *xblob = capture_xattrs(fs_path, &xlen);
	return entry_list_add_symlink(list, archive_name, target,
	                              (int64_t)st->st_mtime,
	                              capture_birthtime(fs_path, st),
	                              capture_atime(st),
	                              win_attrib_from_mode(st->st_mode),
	                              xblob, xlen);
}

static int walk_directory(entry_list *list, const char *fs_path,
                          const char *archive_prefix) {
	DIR *d = opendir(fs_path);
	if (!d) {
		fprintf(stderr, "error: cannot open directory '%s': %s\n",
			fs_path, strerror(errno));
		return 1;
	}

	struct dirent *ent;
	while ((ent = readdir(d)) != NULL) {
		if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
			continue;

		char full_path[4096];
		char rel_path[4096];
		snprintf(full_path, sizeof(full_path), "%s/%s", fs_path, ent->d_name);
		snprintf(rel_path, sizeof(rel_path), "%s%s", archive_prefix, ent->d_name);

		struct stat st;
		if (lstat(full_path, &st) != 0) {
			fprintf(stderr, "warning: cannot stat '%s': %s\n",
				full_path, strerror(errno));
			continue;
		}

		if (S_ISLNK(st.st_mode) && !g_dereference) {
			/* Symlink — store as link */
			if (add_symlink_entry(list, full_path, rel_path, &st) != 0) {
				closedir(d);
				return 1;
			}
		} else if (S_ISLNK(st.st_mode) && g_dereference) {
			/* Dereference: stat the target, store as regular file */
			struct stat target_st;
			if (stat(full_path, &target_st) != 0) {
				fprintf(stderr, "warning: cannot stat symlink target '%s': %s\n",
					full_path, strerror(errno));
				continue;
			}
			if (S_ISDIR(target_st.st_mode)) {
				char dir_name[4096];
				snprintf(dir_name, sizeof(dir_name), "%s/", rel_path);
				if (entry_list_add_dir(list, dir_name,
				                       (int64_t)target_st.st_mtime,
				                       capture_birthtime(full_path, &target_st),
				                       capture_atime(&target_st),
				                       win_attrib_from_mode(target_st.st_mode)) != 0) {
					closedir(d);
					return 1;
				}
				if (walk_directory(list, full_path, dir_name) != 0) {
					closedir(d);
					return 1;
				}
			} else if (S_ISREG(target_st.st_mode)) {
				size_t flen = 0;
				uint8_t *data = read_file(full_path, &flen);
				if (!data) {
					closedir(d);
					return 1;
				}
				size_t xlen = 0;
				uint8_t *xblob = capture_xattrs(full_path, &xlen);
				if (entry_list_add_file(list, rel_path, data, flen,
				                        (int64_t)target_st.st_mtime,
				                        capture_birthtime(full_path, &target_st),
				                        capture_atime(&target_st),
				                        win_attrib_from_mode(target_st.st_mode),
				                        xblob, xlen) != 0) {
					free(data);
					free(xblob);
					closedir(d);
					return 1;
				}
			}
		} else if (S_ISDIR(st.st_mode)) {
			char dir_name[4096];
			snprintf(dir_name, sizeof(dir_name), "%s/", rel_path);
			if (entry_list_add_dir(list, dir_name,
			                       (int64_t)st.st_mtime,
			                       capture_birthtime(full_path, &st),
			                       capture_atime(&st),
			                       win_attrib_from_mode(st.st_mode)) != 0) {
				closedir(d);
				return 1;
			}
			if (walk_directory(list, full_path, dir_name) != 0) {
				closedir(d);
				return 1;
			}
		} else if (S_ISREG(st.st_mode)) {
			size_t flen = 0;
			uint8_t *data = read_file(full_path, &flen);
			if (!data) {
				closedir(d);
				return 1;
			}
			size_t xlen = 0;
			uint8_t *xblob = capture_xattrs(full_path, &xlen);
			if (entry_list_add_file(list, rel_path, data, flen,
			                        (int64_t)st.st_mtime,
			                        capture_birthtime(full_path, &st),
			                        capture_atime(&st),
			                        win_attrib_from_mode(st.st_mode),
			                        xblob, xlen) != 0) {
				free(data);
				free(xblob);
				closedir(d);
				return 1;
			}
		}
		/* Skip devices, sockets, etc. */
	}

	closedir(d);
	return 0;
}

/* ========================================================================== */
/* Commands                                                                   */
/* ========================================================================== */

static int cmd_list(const char *archive_path) {
	size_t data_len = 0;
	uint8_t *data = read_file(archive_path, &data_len);
	if (!data) return 1;

	z7z_archive *ar = NULL;
	int rc = z7z_open(data, data_len, &ar);
	free(data);

	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		return 1;
	}

	size_t count = z7z_file_count(ar);
	printf("Files: %zu\n", count);
	printf("%-12s  %s\n", "Size", "Name");
	printf("%-12s  %s\n", "----", "----");

	for (size_t i = 0; i < count; i++) {
		const char *name = z7z_file_name(ar, i);
		size_t size = z7z_file_size(ar, i);
		size_t xlen = 0;
		const char *xattr_marker = z7z_file_xattrs(ar, i, &xlen) ? " [+xattr]" : "";
		if (z7z_file_is_dir(ar, i)) {
			printf("%-12s  %s%s\n", "<dir>", name ? name : "(unnamed)", xattr_marker);
		} else if (z7z_file_is_symlink(ar, i)) {
			/* Show symlink with target path */
			const uint8_t *tdata = z7z_file_data(ar, i);
			if (tdata && size > 0) {
				char target[4096];
				size_t tlen = size < sizeof(target) - 1 ? size : sizeof(target) - 1;
				memcpy(target, tdata, tlen);
				target[tlen] = '\0';
				printf("<symlink>     %s -> %s%s\n", name ? name : "(unnamed)", target, xattr_marker);
			} else {
				printf("<symlink>     %s%s\n", name ? name : "(unnamed)", xattr_marker);
			}
		} else {
			printf("%-12zu  %s%s\n", size, name ? name : "(unnamed)", xattr_marker);
		}
	}

	z7z_close(ar);
	return 0;
}

static int cmd_extract(const char *archive_path, const char *out_dir) {
	size_t data_len = 0;
	uint8_t *data = read_file(archive_path, &data_len);
	if (!data) return 1;

	z7z_archive *ar = NULL;
	int rc = z7z_open(data, data_len, &ar);
	free(data);

	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		return 1;
	}

	if (out_dir && ensure_dir(out_dir) != 0) {
		z7z_close(ar);
		return 1;
	}

	size_t count = z7z_file_count(ar);
	int errors = 0;

	/* Track directory paths and their mtimes for deferred restoration.
	 * Directory mtime must be set AFTER all contents are extracted,
	 * because writing files inside a dir updates its mtime. */
	char **dir_paths = NULL;
	int64_t *dir_mtimes = NULL;
	size_t dir_count = 0;
	size_t dir_cap = 0;

	for (size_t i = 0; i < count; i++) {
		const char *name = z7z_file_name(ar, i);
		if (!name) {
			fprintf(stderr, "warning: skipping unnamed file at index %zu\n", i);
			continue;
		}

		/* Build output path */
		char out_path[4096];
		if (out_dir) {
			snprintf(out_path, sizeof(out_path), "%s/%s", out_dir, name);
		} else {
			snprintf(out_path, sizeof(out_path), "%s", name);
		}

		if (z7z_file_is_dir(ar, i)) {
			/* Directory entry — create it */
			if (ensure_dir_recursive(out_path) != 0) {
				errors++;
			} else {
				printf("  %s (directory)\n", name);
				/* Defer directory mtime restoration */
				int64_t mt = z7z_file_mtime(ar, i);
				if (mt > 0) {
					if (dir_count >= dir_cap) {
						size_t new_cap = dir_cap == 0 ? 16 : dir_cap * 2;
						char **np = realloc(dir_paths, new_cap * sizeof(char *));
						int64_t *nm = realloc(dir_mtimes, new_cap * sizeof(int64_t));
						if (np && nm) {
							dir_paths = np;
							dir_mtimes = nm;
							dir_cap = new_cap;
						}
					}
					if (dir_count < dir_cap) {
						dir_paths[dir_count] = strdup(out_path);
						dir_mtimes[dir_count] = mt;
						dir_count++;
					}
				}
				/* Restore directory permissions */
				uint32_t attrib = z7z_file_attrib(ar, i);
				set_permissions(out_path, attrib);
			}
		} else if (z7z_file_is_symlink(ar, i)) {
			/* Symlink entry — create symbolic link */
			const uint8_t *tdata = z7z_file_data(ar, i);
			size_t tsize = z7z_file_size(ar, i);
			if (!tdata || tsize == 0) {
				fprintf(stderr, "warning: symlink '%s' has no target, skipping\n", name);
				errors++;
				continue;
			}
			/* Build null-terminated target string */
			char target[4096];
			size_t tlen = tsize < sizeof(target) - 1 ? tsize : sizeof(target) - 1;
			memcpy(target, tdata, tlen);
			target[tlen] = '\0';

			/* Security: reject unsafe targets */
			if (!symlink_target_is_safe(target)) {
				fprintf(stderr, "warning: skipping symlink '%s' with absolute or traversal target '%s'\n",
					name, target);
				errors++;
				continue;
			}

			if (ensure_parent_dir(out_path) != 0) {
				errors++;
			} else {
				/* Remove existing file/symlink at target path if present */
				unlink(out_path);
				if (symlink(target, out_path) != 0) {
					fprintf(stderr, "error: cannot create symlink '%s' -> '%s': %s\n",
						out_path, target, strerror(errno));
					errors++;
				} else {
					printf("  %s -> %s (symlink)\n", name, target);
				}
			}
		} else {
			/* File entry — ensure parent exists, then write */
			if (ensure_parent_dir(out_path) != 0) {
				errors++;
			} else {
				const uint8_t *file_data = z7z_file_data(ar, i);
				size_t file_size = z7z_file_size(ar, i);
				if (write_file(out_path, file_data, file_size) != 0) {
					errors++;
				} else {
					printf("  %s (%zu bytes)\n", name, file_size);
					/* Restore permissions */
					uint32_t attrib = z7z_file_attrib(ar, i);
					set_permissions(out_path, attrib);
					/* Restore mtime + atime */
					int64_t mt = z7z_file_mtime(ar, i);
					int64_t at = z7z_file_atime(ar, i);
					set_times(out_path, mt, at);
					/* Restore birthtime */
					if (!g_no_ctime) {
						int64_t ct = z7z_file_ctime(ar, i);
#ifdef __APPLE__
						set_birthtime(out_path, ct);
#else
						(void)ct;
#endif
					}
					/* Restore xattrs */
					size_t xlen = 0;
					const uint8_t *xblob = z7z_file_xattrs(ar, i, &xlen);
					restore_xattrs(out_path, xblob, xlen);
				}
			}
		}
	}

	/* Restore directory mtimes in reverse order (deepest first),
	 * so parent dirs don't get their mtime clobbered by child restoration. */
	for (size_t i = dir_count; i > 0; i--) {
		set_times(dir_paths[i - 1], dir_mtimes[i - 1], 0);
		free(dir_paths[i - 1]);
	}
	free(dir_paths);
	free(dir_mtimes);

	/* Warnings */
	if (g_no_ctime) {
		int has_ctime = 0;
		for (size_t i = 0; i < count; i++) {
			if (z7z_file_ctime(ar, i) > 0) { has_ctime = 1; break; }
		}
		if (!has_ctime) {
			fprintf(stderr, "note: --no-ctime specified but archive contained no creation times\n");
		}
	}
	if (g_no_xattr) {
		int has_xattr = 0;
		for (size_t i = 0; i < count; i++) {
			size_t xlen = 0;
			if (z7z_file_xattrs(ar, i, &xlen)) { has_xattr = 1; break; }
		}
		if (has_xattr) {
			fprintf(stderr, "note: --no-xattr specified; xattr data in archive was not restored\n");
		}
	}

	z7z_close(ar);
	return errors > 0 ? 1 : 0;
}

static int cmd_create(const char *archive_path, int file_count, char **file_paths) {
	entry_list list;
	if (entry_list_init(&list, 64) != 0) {
		fprintf(stderr, "error: out of memory\n");
		return 1;
	}

	for (int i = 0; i < file_count; i++) {
		struct stat st;
		if (lstat(file_paths[i], &st) != 0) {
			fprintf(stderr, "error: cannot stat '%s': %s\n",
				file_paths[i], strerror(errno));
			entry_list_free(&list);
			return 1;
		}

		if (S_ISLNK(st.st_mode) && !g_dereference) {
			/* Top-level symlink argument — store as symlink */
			if (add_symlink_entry(&list, file_paths[i], basename_of(file_paths[i]), &st) != 0) {
				fprintf(stderr, "error: out of memory\n");
				entry_list_free(&list);
				return 1;
			}
		} else if (S_ISLNK(st.st_mode) && g_dereference) {
			/* Dereference: stat the target */
			struct stat target_st;
			if (stat(file_paths[i], &target_st) != 0) {
				fprintf(stderr, "error: cannot stat symlink target '%s': %s\n",
					file_paths[i], strerror(errno));
				entry_list_free(&list);
				return 1;
			}
			/* Use target_st for metadata when dereferencing */
			memcpy(&st, &target_st, sizeof(st));
			if (S_ISDIR(target_st.st_mode)) {
				goto handle_dir;
			} else {
				goto handle_file;
			}
		} else if (S_ISDIR(st.st_mode)) {
handle_dir:;
			/* Strip trailing slashes */
			char clean[4096];
			size_t plen = strlen(file_paths[i]);
			if (plen >= sizeof(clean)) {
				fprintf(stderr, "error: path too long: '%s'\n", file_paths[i]);
				entry_list_free(&list);
				return 1;
			}
			memcpy(clean, file_paths[i], plen + 1);
			while (plen > 1 && (clean[plen - 1] == '/' || clean[plen - 1] == '\\'))
				clean[--plen] = '\0';

			/* Use basename as archive prefix */
			const char *dir_base = basename_of(clean);
			char prefix[4096];
			snprintf(prefix, sizeof(prefix), "%s/", dir_base);

			/* Add the directory entry itself */
			if (entry_list_add_dir(&list, prefix,
			                       (int64_t)st.st_mtime,
			                       capture_birthtime(clean, &st),
			                       capture_atime(&st),
			                       win_attrib_from_mode(st.st_mode)) != 0) {
				fprintf(stderr, "error: out of memory\n");
				entry_list_free(&list);
				return 1;
			}

			/* Walk contents */
			if (walk_directory(&list, clean, prefix) != 0) {
				entry_list_free(&list);
				return 1;
			}
		} else {
handle_file:;
			/* Regular file — use basename only */
			size_t flen = 0;
			uint8_t *data = read_file(file_paths[i], &flen);
			if (!data) {
				entry_list_free(&list);
				return 1;
			}
			size_t xlen = 0;
			uint8_t *xblob = capture_xattrs(file_paths[i], &xlen);
			if (entry_list_add_file(&list, basename_of(file_paths[i]), data, flen,
			                        (int64_t)st.st_mtime,
			                        capture_birthtime(file_paths[i], &st),
			                        capture_atime(&st),
			                        win_attrib_from_mode(st.st_mode),
			                        xblob, xlen) != 0) {
				fprintf(stderr, "error: out of memory\n");
				free(data);
				free(xblob);
				entry_list_free(&list);
				return 1;
			}
		}
	}

	uint8_t *out_data = NULL;
	size_t out_len = 0;
	int rc = z7z_create(list.entries, list.count, &out_data, &out_len);
	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		entry_list_free(&list);
		return 1;
	}

	int ret = 0;
	if (write_file(archive_path, out_data, out_len) != 0) {
		ret = 1;
	} else {
		printf("Created %s (%zu bytes, %zu entries)\n",
			archive_path, out_len, list.count);
	}

	z7z_free(out_data, out_len);
	entry_list_free(&list);
	return ret;
}

int main(int argc, char **argv) {
	if (argc < 3) {
		usage(argv[0]);
		return 1;
	}

	const char *cmd = argv[1];

	if (strcmp(cmd, "list") == 0 || strcmp(cmd, "l") == 0) {
		return cmd_list(argv[2]);
	} else if (strcmp(cmd, "extract") == 0 || strcmp(cmd, "x") == 0) {
		/* Parse optional flags before archive path */
		int arg_start = 2;
		for (int i = 2; i < argc; i++) {
			if (strcmp(argv[i], "--no-ctime") == 0) {
				g_no_ctime = 1;
				arg_start = i + 1;
			} else if (strcmp(argv[i], "--no-xattr") == 0) {
				g_no_xattr = 1;
				arg_start = i + 1;
			} else {
				break;
			}
		}
		if (arg_start >= argc) {
			fprintf(stderr, "error: extract requires archive path\n");
			usage(argv[0]);
			return 1;
		}
		const char *out_dir = (arg_start + 1 < argc) ? argv[arg_start + 1] : NULL;
		return cmd_extract(argv[arg_start], out_dir);
	} else if (strcmp(cmd, "create") == 0 || strcmp(cmd, "a") == 0) {
		/* Parse optional flags before archive path */
		int arg_start = 2;
		for (int i = 2; i < argc; i++) {
			if (strcmp(argv[i], "--dereference") == 0 || strcmp(argv[i], "-L") == 0) {
				g_dereference = 1;
				arg_start = i + 1;
			} else if (strcmp(argv[i], "--no-ctime") == 0) {
				g_no_ctime = 1;
				arg_start = i + 1;
			} else if (strcmp(argv[i], "--atime") == 0) {
				g_atime = 1;
				arg_start = i + 1;
			} else if (strcmp(argv[i], "--no-xattr") == 0) {
				g_no_xattr = 1;
				arg_start = i + 1;
			} else {
				break;
			}
		}
		if (arg_start >= argc || arg_start + 1 >= argc) {
			fprintf(stderr, "error: create requires archive path and at least one input file or directory\n");
			usage(argv[0]);
			return 1;
		}
		return cmd_create(argv[arg_start], argc - arg_start - 1, argv + arg_start + 1);
	} else {
		fprintf(stderr, "error: unknown command '%s'\n", cmd);
		usage(argv[0]);
		return 1;
	}
}
