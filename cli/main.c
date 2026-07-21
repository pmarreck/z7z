/* z7z CLI — dogfoods the C FFI.
 * See usage() or run z7z --help for command syntax.
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
#include <fcntl.h>        /* AT_FDCWD, AT_SYMLINK_NOFOLLOW */
#endif

#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <fcntl.h>
#include <sys/utime.h>
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

#ifndef _WIN32
#include <magic.h>
#endif

#define Z7Z_VERSION "0.1.0"

/* Global flags */
static int g_dereference = 0;
static int g_no_ctime = 0;
static int g_atime = 0;
static int g_no_xattr = 0;
static int g_verbose = 0;
static int g_no_progress = 0;
static int g_level = Z7Z_DEFAULT_LEVEL;  /* compression level 0-9, default 5 */
static const char *g_password = NULL;
static const char *g_lang = "en";  /* default language; overridden by Z7Z_LANG or --lang */
static int g_yes = 0;              /* -y: assume Yes on overwrite prompts */
static int g_flat_extract = 0;     /* 1 when using 'e' command (flat extract) */
static const char *g_out_dir = NULL; /* -o<dir> output directory override */
static int g_mmt = -1;            /* -mmt=N: thread count (-1 = auto) */
static int g_header_encrypt = 0;  /* -mhe=on: encrypt archive headers */

/* Solid block grouping mode */
typedef enum { SOLID_AUTO, SOLID_ON, SOLID_OFF } solid_mode_t;
static solid_mode_t g_solid_mode = SOLID_AUTO;

/* libmagic handle for MIME detection */
#ifndef _WIN32
static magic_t g_magic = NULL;
#endif

static int init_magic(void) {
#ifndef _WIN32
	g_magic = magic_open(MAGIC_MIME_TYPE | MAGIC_SYMLINK);
	if (!g_magic) return 1;
	if (magic_load(g_magic, NULL) != 0) {
		magic_close(g_magic);
		g_magic = NULL;
		return 1;
	}
	return 0;
#else
	return 1; /* libmagic not available */
#endif
}

static void cleanup_magic(void) {
#ifndef _WIN32
	if (g_magic) {
		magic_close(g_magic);
		g_magic = NULL;
	}
#endif
}

/* Detect MIME type for a filesystem path. Returns malloc'd string or NULL. */
static char *detect_mime(const char *fs_path) {
#ifndef _WIN32
	if (!g_magic) return NULL;
	const char *mime = magic_file(g_magic, fs_path);
	return mime ? strdup(mime) : strdup("application/octet-stream");
#else
	(void)fs_path;
	return NULL;
#endif
}

/* ============================================================================
 * Progress (via progrez library)
 * ============================================================================ */

#include <time.h>
#include "progrez.h"

static double elapsed_since(const struct timespec *start) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return (double)(now.tv_sec - start->tv_sec) +
	       (double)(now.tv_nsec - start->tv_nsec) / 1e9;
}

static void format_size(double bytes, char *buf, size_t buf_size) {
	if (bytes >= 1e9) snprintf(buf, buf_size, "%.1f GB", bytes / 1e9);
	else if (bytes >= 1e6) snprintf(buf, buf_size, "%.1f MB", bytes / 1e6);
	else if (bytes >= 1e3) snprintf(buf, buf_size, "%.1f KB", bytes / 1e3);
	else snprintf(buf, buf_size, "%.0f B", bytes);
}

/* Adapter: bridges z7z's (done, total, user_data) callback to progrez's update API */
static void progrez_adapter(uint64_t done, uint64_t total, void *user_data) {
	(void)total;
	progrez_update((progrez_ctx *)user_data, 0, done);
}

static void usage(const char *prog) {
	fprintf(stderr,
		"Usage:\n"
		"  %s list    <archive.7z>\n"
		"  %s extract [options] <archive.7z> [file ...]\n"
		"  %s e       [options] <archive.7z> [file ...]\n"
		"  %s create  [options] <archive.7z> <file1|dir1> [file2|dir2 ...]\n"
		"  %s test    <archive.7z>\n"
		"\n"
		"Commands:\n"
		"  list, l       List archive contents\n"
		"  extract, x    Extract archive preserving directory structure\n"
		"  e             Extract archive without directory structure (flat)\n"
		"  create, a     Create archive from files/directories\n"
		"  test, t       Test archive integrity\n"
		"\n"
		"General options:\n"
		"  -h, --help            Show this help message\n"
		"  --about               Show version, platform, and architecture\n"
		"  -v, --verbose         Show individual file names during extract/create\n"
		"  --no-progress         Suppress progress indication\n"
		"  -p, --password <pw>   Encrypt/decrypt archive with password\n"
		"  -y                    Assume Yes on all prompts (overwrite existing files)\n"
		"  -o<dir>               Set output directory for extraction\n"
		"  --lang <code>         Set language (overrides Z7Z_LANG env var)\n"
		"\n"
		"Create options:\n"
		"  -N                    Compression level 0-9 (e.g. -0, -5, -9)\n"
		"  -mx=N                 Compression level 0-9 (7zz compatible)\n"
		"  --level N             Compression level 0-9 (default: 5)\n"
		"  -mmt=N                Thread count (0 = auto, 1 = single-threaded)\n"
		"  -mhe=on               Encrypt archive headers (requires -p)\n"
		"  -L, --dereference     Follow symbolic links\n"
		"  --no-ctime            Don't store file creation/birth times\n"
		"  --atime               Store file access times (off by default)\n"
		"  --no-xattr            Don't store extended attributes\n"
		"  --solid               Force all files into one solid block\n"
		"  --no-solid            Separate solid block per file (no solid)\n"
		"\n"
		"Extract options:\n"
		"  --no-ctime            Don't restore file creation/birth times\n"
		"  --no-xattr            Don't restore extended attributes\n"
		"\n"
		"Selective extraction:\n"
		"  %s extract archive.7z -o out/ file1.txt dir/  (extract only matching entries)\n",
		prog, prog, prog, prog, prog, prog);
}

static void about(void) {
	const char *os =
#if defined(__APPLE__)
		"macOS";
#elif defined(__linux__)
		"Linux";
#elif defined(_WIN32)
		"Windows";
#else
		"Unknown";
#endif
	const char *arch =
#if defined(__aarch64__) || defined(_M_ARM64)
		"aarch64";
#elif defined(__x86_64__) || defined(_M_X64)
		"x86_64";
#elif defined(__arm__) || defined(_M_ARM)
		"arm";
#elif defined(__i386__) || defined(_M_IX86)
		"x86";
#else
		"unknown";
#endif
	printf("z7z %s — cleanroom 7-Zip implementation (%s/%s)\n",
		Z7Z_VERSION, os, arch);
}

/* Check if a path refers to stdin. */
static int is_stdin_path(const char *path) {
	return strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

/* Check if a path refers to stdout. */
static int is_stdout_path(const char *path) {
	return strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0;
}

/* Read all of stdin into malloc'd buffer. Caller frees. */
static uint8_t *read_stdin(size_t *out_len) {
	size_t cap = 64 * 1024;
	size_t len = 0;
	uint8_t *buf = malloc(cap);
	if (!buf) {
		fprintf(stderr, "error: out of memory reading stdin\n");
		return NULL;
	}

#ifdef _WIN32
	_setmode(_fileno(stdin), _O_BINARY);
#endif

	while (1) {
		if (len >= cap) {
			cap *= 2;
			uint8_t *nb = realloc(buf, cap);
			if (!nb) {
				fprintf(stderr, "error: out of memory reading stdin\n");
				free(buf);
				return NULL;
			}
			buf = nb;
		}
		size_t n = fread(buf + len, 1, cap - len, stdin);
		if (n == 0) break;
		len += n;
	}

	*out_len = len;
	return buf;
}

/* Expand a leading ~ or ~/ (or ~\ on Windows) to the user's home directory.
 * Returns a newly malloc'd string the caller must free; on any path that does
 * NOT begin with a bare "~" segment (including "~user"), returns a strdup of the
 * original so the caller uniformly owns the result. Home resolves to $HOME
 * (Unix) with a fallback to %USERPROFILE% (Windows). Rationale: paths with
 * spaces must be quoted, and quoting suppresses the shell's own tilde
 * expansion, so the CLI must expand a leading tilde itself. */
static char *expand_tilde(const char *path) {
	if (path == NULL) return NULL;
	if (path[0] != '~') return strdup(path);
	char next = path[1];
	int bare = (next == '\0');
	int sep = (next == '/' || next == '\\');
	if (!bare && !sep) return strdup(path); /* ~user, ~+, etc. left untouched */

	const char *home = getenv("HOME");
	if (home == NULL || home[0] == '\0') home = getenv("USERPROFILE");
	if (home == NULL || home[0] == '\0') return strdup(path); /* cannot expand */

	const char *rest = bare ? "" : (path + 1); /* keep the leading separator */
	size_t hlen = strlen(home);
	size_t rlen = strlen(rest);
	char *out = malloc(hlen + rlen + 1);
	if (out == NULL) return NULL;
	memcpy(out, home, hlen);
	memcpy(out + hlen, rest, rlen);
	out[hlen + rlen] = '\0';
	return out;
}

/* Read entire file into malloc'd buffer. Caller frees. */
static uint8_t *read_file(const char *path, size_t *out_len) {
	if (is_stdin_path(path)) return read_stdin(out_len);

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
	if (is_stdout_path(path)) {
#ifdef _WIN32
		_setmode(_fileno(stdout), _O_BINARY);
#endif
		if (len > 0) {
			size_t nwritten = fwrite(data, 1, len, stdout);
			if (nwritten != len) {
				fprintf(stderr, "error: short write to stdout\n");
				return 1;
			}
		}
		fflush(stdout);
		return 0;
	}

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
/* Wildcard / selective extraction                                            */
/* ========================================================================== */

/* Simple wildcard match: supports * (any chars) and ? (single char).
 * Returns 1 if name matches pattern. */
static int wildcard_match(const char *pattern, const char *name) {
	while (*pattern && *name) {
		if (*pattern == '*') {
			pattern++;
			if (*pattern == '\0') return 1; /* trailing * matches all */
			while (*name) {
				if (wildcard_match(pattern, name)) return 1;
				name++;
			}
			return *pattern == '\0';
		} else if (*pattern == '?' || *pattern == *name) {
			pattern++;
			name++;
		} else {
			return 0;
		}
	}
	/* Skip trailing stars */
	while (*pattern == '*') pattern++;
	return *pattern == '\0' && *name == '\0';
}

/* Check if a file name matches any of the given filter patterns.
 * Also matches if the name starts with a pattern that ends with '/'.
 * Returns 1 if matched (or if no filters specified). */
static int matches_filter(const char *name, int filter_count, char **filters) {
	if (filter_count <= 0) return 1; /* no filter = match all */
	for (int i = 0; i < filter_count; i++) {
		/* Exact match or wildcard match */
		if (wildcard_match(filters[i], name)) return 1;
		/* Basename match: if filter has no path separator, try matching just the basename */
		if (!strchr(filters[i], '/') && !strchr(filters[i], '\\')) {
			const char *base = name;
			const char *p = name;
			while (*p) {
				if (*p == '/' || *p == '\\') base = p + 1;
				p++;
			}
			if (wildcard_match(filters[i], base)) return 1;
		}
		/* Prefix match for directories: "dir/" matches "dir/file.txt" */
		size_t flen = strlen(filters[i]);
		if (flen > 0 && filters[i][flen - 1] == '/') {
			if (strncmp(name, filters[i], flen) == 0) return 1;
		}
		/* Also match if filter is a prefix without trailing slash */
		if (strncmp(name, filters[i], flen) == 0 &&
		    (name[flen] == '/' || name[flen] == '\\')) return 1;
	}
	return 0;
}

/* ========================================================================== */
/* Dynamic entry list for directory walking                                   */
/* ========================================================================== */

typedef struct {
	z7z_file_entry *entries;
	uint8_t **bufs;       /* file data buffers (NULL for directories) */
	char **names;          /* allocated name strings */
	uint8_t **xattr_bufs; /* xattr blob buffers (NULL if none) */
	char **mime_types;     /* MIME type strings for MIME-grouped solid blocks */
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
	list->mime_types = calloc(initial_cap, sizeof(char *));
	return (list->entries && list->bufs && list->names && list->xattr_bufs && list->mime_types) ? 0 : 1;
}

static int entry_list_grow(entry_list *list) {
	size_t new_cap = list->capacity * 2;
	z7z_file_entry *ne = realloc(list->entries, new_cap * sizeof(z7z_file_entry));
	uint8_t **nb = realloc(list->bufs, new_cap * sizeof(uint8_t *));
	char **nn = realloc(list->names, new_cap * sizeof(char *));
	uint8_t **nx = realloc(list->xattr_bufs, new_cap * sizeof(uint8_t *));
	char **nm = realloc(list->mime_types, new_cap * sizeof(char *));
	if (!ne || !nb || !nn || !nx || !nm) return 1;
	memset(ne + list->capacity, 0, (new_cap - list->capacity) * sizeof(z7z_file_entry));
	memset(nb + list->capacity, 0, (new_cap - list->capacity) * sizeof(uint8_t *));
	memset(nn + list->capacity, 0, (new_cap - list->capacity) * sizeof(char *));
	memset(nx + list->capacity, 0, (new_cap - list->capacity) * sizeof(uint8_t *));
	memset(nm + list->capacity, 0, (new_cap - list->capacity) * sizeof(char *));
	list->entries = ne;
	list->bufs = nb;
	list->names = nn;
	list->xattr_bufs = nx;
	list->mime_types = nm;
	list->capacity = new_cap;
	return 0;
}

static void entry_list_free(entry_list *list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->bufs[i]);
		free(list->names[i]);
		free(list->xattr_bufs[i]);
		free(list->mime_types[i]);
	}
	free(list->entries);
	free(list->bufs);
	free(list->names);
	free(list->xattr_bufs);
	free(list->mime_types);
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

/* Set MIME type for the most recently added entry (must be called right after
 * entry_list_add_file/symlink/dir). For files, pass the filesystem path for
 * detection; for directories/symlinks, pass NULL to skip. */
static void entry_list_set_mime(entry_list *list, const char *fs_path) {
	if (list->count == 0) return;
	size_t idx = list->count - 1;
	if (fs_path) {
		list->mime_types[idx] = detect_mime(fs_path);
	}
	/* else: left as NULL from calloc/memset */
}

/* Assign group_index to each entry based on MIME type clustering.
 * Files with identical MIME types share a solid block group.
 * Directories/symlinks (NULL mime) go to group 0. */
static void assign_mime_groups(entry_list *list) {
	char *unique_mimes[4096];
	size_t unique_count = 0;

	for (size_t i = 0; i < list->count; i++) {
		if (!list->mime_types[i]) {
			list->entries[i].group_index = 0;
			continue;
		}
		uint32_t group = 0;
		int found = 0;
		for (size_t j = 0; j < unique_count; j++) {
			if (strcmp(unique_mimes[j], list->mime_types[i]) == 0) {
				group = (uint32_t)j;
				found = 1;
				break;
			}
		}
		if (!found && unique_count < 4096) {
			unique_mimes[unique_count] = list->mime_types[i];
			group = (uint32_t)unique_count;
			unique_count++;
		}
		list->entries[i].group_index = group;
	}
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

/* Set file mtime (and optionally atime). Returns 0 on success.
 * If atime_ts > 0, use it for atime; otherwise mirror mtime. */
static int set_times(const char *path, int64_t mtime_ts, int64_t atime_ts) {
	if (mtime_ts <= 0 && atime_ts <= 0) return 0;
#ifdef _WIN32
	struct _utimbuf ut;
	ut.actime = (time_t)(atime_ts > 0 ? atime_ts : mtime_ts);
	ut.modtime = (time_t)(mtime_ts > 0 ? mtime_ts : atime_ts);
	return _utime(path, &ut);
#else
	struct timeval tv[2];
	tv[0].tv_sec = (time_t)(atime_ts > 0 ? atime_ts : mtime_ts);  /* atime */
	tv[0].tv_usec = 0;
	tv[1].tv_sec = (time_t)(mtime_ts > 0 ? mtime_ts : atime_ts);  /* mtime */
	tv[1].tv_usec = 0;
	return utimes(path, tv);
#endif
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
				entry_list_set_mime(list, full_path);
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
			entry_list_set_mime(list, full_path);
		}
		/* Skip devices, sockets, etc. */
	}

	closedir(d);
	return 0;
}

/* ========================================================================== */
/* Commands                                                                   */
/* ========================================================================== */

static int cmd_test(const char *archive_path) {
	size_t data_len = 0;
	uint8_t *data = read_file(archive_path, &data_len);
	if (!data) return 1;

	struct timespec t_start;
	clock_gettime(CLOCK_MONOTONIC, &t_start);

	progrez_ctx *prog = NULL;
	if (!g_no_progress) {
		prog = progrez_create("Testing");
		progrez_set_identity(prog, "z7z", archive_path);
		progrez_set_determinate(prog, 0, (uint64_t)data_len);
	}

	z7z_archive *ar = NULL;
	int rc = z7z_open_ex_pw(data, data_len, g_password,
	                         prog ? progrez_adapter : NULL, prog, &ar);
	free(data);

	if (prog) { progrez_finish(prog); progrez_destroy(prog); }

	if (rc != Z7Z_OK) {
		fprintf(stderr, "ERROR: %s\n", z7z_error_string(rc));
		fprintf(stderr, "\nTest FAILED: %s\n", archive_path);
		return 1;
	}

	size_t count = z7z_file_count(ar);
	size_t total_size = 0;
	for (size_t i = 0; i < count; i++) {
		total_size += z7z_file_size(ar, i);
		if (g_verbose) {
			const char *name = z7z_file_name(ar, i);
			printf("  OK: %s\n", name ? name : "(unnamed)");
		}
	}

	double elapsed = elapsed_since(&t_start);
	char sz_str[32];
	format_size((double)total_size, sz_str, sizeof(sz_str));
	fprintf(stderr, "Everything is Ok\n\nFiles: %zu, Size: %s, Compressed: ", count, sz_str);
	format_size((double)data_len, sz_str, sizeof(sz_str));
	fprintf(stderr, "%s  %.1fs\n", sz_str, elapsed);

	z7z_close(ar);
	return 0;
}

static int cmd_list(const char *archive_path) {
	size_t data_len = 0;
	uint8_t *data = read_file(archive_path, &data_len);
	if (!data) return 1;

	z7z_archive *ar = NULL;
	int rc = z7z_open_ex_pw(data, data_len, g_password, NULL, NULL, &ar);
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

static int cmd_extract(const char *archive_path, const char *out_dir,
                       int filter_count, char **filters) {
	size_t data_len = 0;
	uint8_t *data = read_file(archive_path, &data_len);
	if (!data) return 1;

	struct timespec t_start;
	clock_gettime(CLOCK_MONOTONIC, &t_start);

	progrez_ctx *prog = NULL;
	if (!g_no_progress) {
		prog = progrez_create("Extracting");
		progrez_set_identity(prog, "z7z", archive_path);
		progrez_set_determinate(prog, 0, (uint64_t)data_len);
	}

	z7z_archive *ar = NULL;
	int rc = z7z_open_ex_pw(data, data_len, g_password,
	                         prog ? progrez_adapter : NULL, prog, &ar);
	free(data);

	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		if (prog) { progrez_finish(prog); progrez_destroy(prog); }
		return 1;
	}

	/* Update file count now that archive is open */
	if (prog) {
		size_t fc = z7z_file_count(ar);
		progrez_set_determinate(prog, (uint64_t)fc, (uint64_t)data_len);
	}

	if (out_dir && ensure_dir(out_dir) != 0) {
		if (prog) { progrez_finish(prog); progrez_destroy(prog); }
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

		/* Selective extraction: skip entries that don't match filters */
		if (!matches_filter(name, filter_count, filters)) continue;

		/* Build output path */
		char out_path[4096];
		if (g_flat_extract) {
			/* Flat extract: use only the basename, no directory structure */
			const char *base = basename_of(name);
			if (out_dir) {
				snprintf(out_path, sizeof(out_path), "%s/%s", out_dir, base);
			} else {
				snprintf(out_path, sizeof(out_path), "%s", base);
			}
		} else {
			if (out_dir) {
				snprintf(out_path, sizeof(out_path), "%s/%s", out_dir, name);
			} else {
				snprintf(out_path, sizeof(out_path), "%s", name);
			}
		}

		if (z7z_file_is_dir(ar, i)) {
			/* Directory entry — create it (skip for flat extract) */
			if (g_flat_extract) continue;
			if (ensure_dir_recursive(out_path) != 0) {
				errors++;
			} else {
				if (g_verbose) printf("  %s (directory)\n", name);
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
					if (g_verbose) printf("  %s -> %s (symlink)\n", name, target);
				}
			}
		} else {
			/* File entry — ensure parent exists, then write */
			if (g_flat_extract) {
				/* Flat extract: ensure output dir exists, not parent of archive path */
				if (out_dir && ensure_dir(out_dir) != 0) {
					errors++;
					continue;
				}
			} else if (ensure_parent_dir(out_path) != 0) {
				errors++;
				continue;
			}
			/* Check for existing file (unless -y) */
			if (!g_yes && !is_stdout_path(out_path)) {
				struct stat st_check;
				if (lstat(out_path, &st_check) == 0) {
					fprintf(stderr, "warning: skipping existing file '%s' (use -y to overwrite)\n", out_path);
					continue;
				}
			}
			{
				const uint8_t *file_data = z7z_file_data(ar, i);
				size_t file_size = z7z_file_size(ar, i);
				if (write_file(out_path, file_data, file_size) != 0) {
					errors++;
				} else {
					if (g_verbose) printf("  %s (%zu bytes)\n", name, file_size);
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

	/* Finish progress bar */
	if (prog) { progrez_finish(prog); progrez_destroy(prog); }

	/* Print extraction summary */
	if (!errors) {
		double elapsed = elapsed_since(&t_start);
		size_t total_extracted = 0;
		for (size_t i = 0; i < count; i++) {
			total_extracted += z7z_file_size(ar, i);
		}
		char sz_str[32];
		format_size((double)total_extracted, sz_str, sizeof(sz_str));
		char ar_str[32];
		format_size((double)data_len, ar_str, sizeof(ar_str));
		double ratio = total_extracted > 0 ? (double)data_len / (double)total_extracted * 100.0 : 0.0;
		fprintf(stderr, "Extracted %zu entries  %s -> %s (%.1f%%)  %.1fs\n",
			count, ar_str, sz_str, ratio, elapsed);
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

	/* Initialize libmagic early so MIME detection works during file collection */
	if (g_solid_mode == SOLID_AUTO) {
		init_magic(); /* OK if this fails — detect_mime returns NULL, all stay group 0 */
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
			entry_list_set_mime(&list, file_paths[i]);
		}
	}

	/* Apply solid block mode */
	if (g_solid_mode == SOLID_AUTO) {
		/* MIME types were detected during file collection (init_magic called above).
		 * Now assign group indices based on MIME clustering. */
		assign_mime_groups(&list);
		cleanup_magic();
		/* If magic init failed, mime_types are all NULL and everything stays group 0 */
	} else if (g_solid_mode == SOLID_ON) {
		for (size_t i = 0; i < list.count; i++)
			list.entries[i].group_index = 0;
	} else { /* SOLID_OFF */
		uint32_t g = 0;
		for (size_t i = 0; i < list.count; i++) {
			if (list.entries[i].flags & Z7Z_FLAG_DIRECTORY) continue;
			if (list.entries[i].flags & Z7Z_FLAG_SYMLINK) continue;
			list.entries[i].group_index = g++;
		}
	}

	/* Compute total uncompressed size for stats */
	size_t total_input = 0;
	for (size_t i = 0; i < list.count; i++) {
		total_input += list.entries[i].data_len;
	}

	struct timespec t_start;
	clock_gettime(CLOCK_MONOTONIC, &t_start);

	progrez_ctx *prog = NULL;
	if (!g_no_progress) {
		prog = progrez_create("Compressing");
		progrez_set_identity(prog, "z7z", archive_path);
		progrez_set_determinate(prog, (uint64_t)list.count, (uint64_t)total_input);
	}

	uint8_t *out_data = NULL;
	size_t out_len = 0;
	uint32_t mmt = (g_mmt < 0) ? 0 : (uint32_t)g_mmt;
	int rc = z7z_create_ex2(list.entries, list.count,
	                         g_password, (uint8_t)g_level,
	                         mmt, g_header_encrypt,
	                         prog ? progrez_adapter : NULL, prog,
	                         &out_data, &out_len);
	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		if (prog) { progrez_finish(prog); progrez_destroy(prog); }
		entry_list_free(&list);
		return 1;
	}

	if (prog) { progrez_finish(prog); progrez_destroy(prog); }

	int ret = 0;
	if (write_file(archive_path, out_data, out_len) != 0) {
		ret = 1;
	} else {
		double elapsed = elapsed_since(&t_start);
		char in_str[32], out_str[32];
		format_size((double)total_input, in_str, sizeof(in_str));
		format_size((double)out_len, out_str, sizeof(out_str));
		double ratio = total_input > 0 ? (double)out_len / (double)total_input * 100.0 : 0.0;
		fprintf(stderr, "Created %s  %s -> %s (%.1f%%)  %zu entries  %.1fs\n",
			archive_path, in_str, out_str, ratio, list.count, elapsed);
	}

	z7z_free(out_data, out_len);
	entry_list_free(&list);
	return ret;
}

/* Parse a flag argument. Returns 1 if recognized, 0 otherwise. */
static int parse_flag(const char *arg) {
	if (strcmp(arg, "--no-ctime") == 0) { g_no_ctime = 1; return 1; }
	if (strcmp(arg, "--atime") == 0) { g_atime = 1; return 1; }
	if (strcmp(arg, "--no-xattr") == 0) { g_no_xattr = 1; return 1; }
	if (strcmp(arg, "--dereference") == 0 || strcmp(arg, "-L") == 0) { g_dereference = 1; return 1; }
	if (strcmp(arg, "-v") == 0 || strcmp(arg, "--verbose") == 0) { g_verbose = 1; return 1; }
	if (strcmp(arg, "--no-progress") == 0) { g_no_progress = 1; return 1; }
	if (strcmp(arg, "-y") == 0) { g_yes = 1; return 1; }
	if (strcmp(arg, "--solid") == 0) { g_solid_mode = SOLID_ON; return 1; }
	if (strcmp(arg, "--no-solid") == 0) { g_solid_mode = SOLID_OFF; return 1; }
	/* Output directory: -o<dir> (7zz compatible, no space) */
	if (strncmp(arg, "-o", 2) == 0 && arg[2] != '\0') {
		g_out_dir = arg + 2;
		return 1;
	}
	/* Compression level: -mx=N (7zz compatible) */
	if (strncmp(arg, "-mx=", 4) == 0) {
		int lvl = atoi(arg + 4);
		if (lvl >= 0 && lvl <= 9) { g_level = lvl; return 1; }
		fprintf(stderr, "warning: invalid compression level '%s', using default %d\n", arg + 4, Z7Z_DEFAULT_LEVEL);
		return 1;
	}
	/* Thread count: -mmt=N (7zz compatible) */
	if (strncmp(arg, "-mmt=", 5) == 0) {
		if (strcmp(arg + 5, "on") == 0) { g_mmt = 0; return 1; }
		if (strcmp(arg + 5, "off") == 0) { g_mmt = 1; return 1; }
		int n = atoi(arg + 5);
		if (n >= 0) { g_mmt = n; return 1; }
		fprintf(stderr, "warning: invalid thread count '%s'\n", arg + 5);
		return 1;
	}
	/* Header encryption: -mhe=on / -mhe=off (7zz compatible) */
	if (strcmp(arg, "-mhe=on") == 0) { g_header_encrypt = 1; return 1; }
	if (strcmp(arg, "-mhe=off") == 0) { g_header_encrypt = 0; return 1; }
	/* Compression level: -0 through -9 (Unix shorthand) */
	if (arg[0] == '-' && arg[1] >= '0' && arg[1] <= '9' && arg[2] == '\0') {
		g_level = arg[1] - '0';
		return 1;
	}
	return 0;
}

/* Parse a flag that takes a following argument. Returns 2 if consumed (flag + value), 0 otherwise. */
static int parse_flag_with_arg(const char *arg, const char *next_arg) {
	/* --level N */
	if (strcmp(arg, "--level") == 0 && next_arg != NULL) {
		int lvl = atoi(next_arg);
		if (lvl >= 0 && lvl <= 9) { g_level = lvl; return 2; }
		fprintf(stderr, "warning: invalid compression level '%s', using default %d\n", next_arg, Z7Z_DEFAULT_LEVEL);
		return 2;
	}
	return 0;
}

int main(int argc, char **argv) {
	/* Handle --help, --about, --version, --lang anywhere in args */
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			usage(argv[0]);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0 || strcmp(argv[i], "--version") == 0) {
			about();
			return 0;
		}
		if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
			g_lang = argv[++i];  /* consumed here; also picked up in flag loop */
		}
	}

	if (argc < 2) {
		usage(argv[0]);
		return 1;
	}

	/* Detect language from Z7Z_LANG env var (overridden by --lang) */
	const char *env_lang = getenv("Z7Z_LANG");
	if (env_lang && env_lang[0]) g_lang = env_lang;

	/* Find command and parse all flags (flags can appear before or after command).
	 * First non-flag argument is the command name. */
	const char *cmd = NULL;
	int cmd_idx = 0;
	for (int i = 1; i < argc; i++) {
		if ((strcmp(argv[i], "-p") == 0 || strcmp(argv[i], "--password") == 0) && i + 1 < argc) {
			g_password = argv[i + 1];
			i++;
		} else if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
			g_lang = argv[i + 1];
			i++;
		} else if (argv[i][0] == '-' && parse_flag(argv[i])) {
			/* boolean flag consumed */
		} else if (argv[i][0] == '-' && i + 1 < argc && parse_flag_with_arg(argv[i], argv[i + 1])) {
			i++;  /* skip the value argument */
		} else if (!cmd) {
			cmd = argv[i];
			cmd_idx = i;
		} else {
			break;  /* first non-flag after command found; stop flag parsing */
		}
	}

	if (!cmd) {
		usage(argv[0]);
		return 1;
	}

	/* arg_start points to first positional arg after the command */
	int arg_start = cmd_idx + 1;
	/* Continue parsing flags after command too */
	for (int i = arg_start; i < argc; i++) {
		if ((strcmp(argv[i], "-p") == 0 || strcmp(argv[i], "--password") == 0) && i + 1 < argc) {
			g_password = argv[i + 1];
			i++;
			arg_start = i + 1;
		} else if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
			g_lang = argv[i + 1];
			i++;
			arg_start = i + 1;
		} else if (argv[i][0] == '-' && parse_flag(argv[i])) {
			arg_start = i + 1;
		} else if (argv[i][0] == '-' && i + 1 < argc && parse_flag_with_arg(argv[i], argv[i + 1])) {
			i++;
			arg_start = i + 1;
		} else {
			break;
		}
	}

	/* Expand a leading ~ in every positional path argument and in -o<dir>.
	 * Paths with spaces must be quoted, which suppresses the shell's tilde
	 * expansion, so z7z does it itself. (Small allocations intentionally leaked;
	 * the process is short-lived.) */
	for (int i = arg_start; i < argc; i++) {
		argv[i] = expand_tilde(argv[i]);
	}
	if (g_out_dir) g_out_dir = expand_tilde(g_out_dir);

	if (strcmp(cmd, "list") == 0 || strcmp(cmd, "l") == 0) {
		if (arg_start >= argc) {
			fprintf(stderr, "error: list requires archive path\n");
			return 1;
		}
		return cmd_list(argv[arg_start]);
	} else if (strcmp(cmd, "test") == 0 || strcmp(cmd, "t") == 0) {
		if (arg_start >= argc) {
			fprintf(stderr, "error: test requires archive path\n");
			return 1;
		}
		return cmd_test(argv[arg_start]);
	} else if (strcmp(cmd, "extract") == 0 || strcmp(cmd, "x") == 0 ||
	           strcmp(cmd, "e") == 0) {
		if (arg_start >= argc) {
			fprintf(stderr, "error: extract requires archive path\n");
			return 1;
		}
		/* 'e' command = flat extract (strip directory structure) */
		if (strcmp(cmd, "e") == 0) g_flat_extract = 1;
		/* Determine output directory: -o<dir> takes precedence, then positional arg */
		const char *out_dir = g_out_dir;
		int filter_start = arg_start + 1;
		if (!out_dir && filter_start < argc && argv[filter_start][0] != '-') {
			/* Legacy positional: second arg is output dir IF no -o was given
			 * and we're using 'extract'/'x' (not 'e') and it looks like a dir path */
			/* But with selective extraction, remaining args are file filters.
			 * For backwards compat: if no -o flag, no selective filters expected
			 * from legacy usage. New style: always use -o for output dir. */
		}
		/* Remaining positional args after archive path are file filters */
		int filter_count = argc - filter_start;
		char **filters = filter_count > 0 ? argv + filter_start : NULL;
		/* If only one extra arg and no -o flag and no wildcards, treat as
		 * output dir for backwards compatibility (legacy behavior) */
		if (!out_dir && filter_count == 1 && !strchr(filters[0], '*') &&
		    !strchr(filters[0], '?')) {
			out_dir = filters[0];
			filter_count = 0;
			filters = NULL;
		}
		return cmd_extract(argv[arg_start], out_dir, filter_count, filters);
	} else if (strcmp(cmd, "create") == 0 || strcmp(cmd, "a") == 0) {
		if (arg_start >= argc || arg_start + 1 >= argc) {
			fprintf(stderr, "error: create requires archive path and at least one input file or directory\n");
			return 1;
		}
		/* Warn if -mhe=on without password */
		if (g_header_encrypt && !g_password) {
			fprintf(stderr, "warning: -mhe=on has no effect without -p/--password\n");
		}
		return cmd_create(argv[arg_start], argc - arg_start - 1, argv + arg_start + 1);
	} else {
		fprintf(stderr, "error: unknown command '%s'\n", cmd);
		usage(argv[0]);
		return 1;
	}
}
