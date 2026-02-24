/* z7z CLI — dogfoods the C FFI.
 *
 * Usage:
 *   z7z list   <archive.7z>
 *   z7z extract <archive.7z> [output-dir]
 *   z7z create  [--dereference|-L] <archive.7z> <file1|dir1> [file2|dir2 ...]
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

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

/* Global flag: --dereference / -L */
static int g_dereference = 0;

static void usage(const char *prog) {
	fprintf(stderr,
		"Usage:\n"
		"  %s list   <archive.7z>\n"
		"  %s extract <archive.7z> [output-dir]\n"
		"  %s create  [--dereference|-L] <archive.7z> <file1|dir1> [file2|dir2 ...]\n",
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
	uint8_t **bufs;   /* file data buffers (NULL for directories) */
	char **names;      /* allocated name strings */
	size_t count;
	size_t capacity;
} entry_list;

static int entry_list_init(entry_list *list, size_t initial_cap) {
	list->count = 0;
	list->capacity = initial_cap;
	list->entries = calloc(initial_cap, sizeof(z7z_file_entry));
	list->bufs = calloc(initial_cap, sizeof(uint8_t *));
	list->names = calloc(initial_cap, sizeof(char *));
	return (list->entries && list->bufs && list->names) ? 0 : 1;
}

static int entry_list_grow(entry_list *list) {
	size_t new_cap = list->capacity * 2;
	z7z_file_entry *ne = realloc(list->entries, new_cap * sizeof(z7z_file_entry));
	uint8_t **nb = realloc(list->bufs, new_cap * sizeof(uint8_t *));
	char **nn = realloc(list->names, new_cap * sizeof(char *));
	if (!ne || !nb || !nn) return 1;
	memset(ne + list->capacity, 0, (new_cap - list->capacity) * sizeof(z7z_file_entry));
	memset(nb + list->capacity, 0, (new_cap - list->capacity) * sizeof(uint8_t *));
	memset(nn + list->capacity, 0, (new_cap - list->capacity) * sizeof(char *));
	list->entries = ne;
	list->bufs = nb;
	list->names = nn;
	list->capacity = new_cap;
	return 0;
}

static void entry_list_free(entry_list *list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->bufs[i]);
		free(list->names[i]);
	}
	free(list->entries);
	free(list->bufs);
	free(list->names);
}

static int entry_list_add_dir(entry_list *list, const char *name) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	list->bufs[idx] = NULL;
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = NULL;
	list->entries[idx].data_len = 0;
	list->entries[idx].flags = Z7Z_FLAG_DIRECTORY;
	list->count++;
	return 0;
}

static int entry_list_add_file(entry_list *list, const char *name,
                               uint8_t *data, size_t data_len) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	list->bufs[idx] = data;  /* takes ownership */
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = data;
	list->entries[idx].data_len = data_len;
	list->entries[idx].flags = 0;
	list->count++;
	return 0;
}

static int entry_list_add_symlink(entry_list *list, const char *name,
                                  const char *target) {
	if (list->count >= list->capacity && entry_list_grow(list) != 0) return 1;
	size_t idx = list->count;
	list->names[idx] = strdup(name);
	if (!list->names[idx]) return 1;
	size_t tlen = strlen(target);
	list->bufs[idx] = (uint8_t *)strdup(target);
	if (!list->bufs[idx]) return 1;
	list->entries[idx].name = list->names[idx];
	list->entries[idx].data = list->bufs[idx];
	list->entries[idx].data_len = tlen;
	list->entries[idx].flags = Z7Z_FLAG_SYMLINK;
	list->count++;
	return 0;
}

/* ========================================================================== */
/* Recursive directory walking                                                */
/* ========================================================================== */

/* Read symlink target and add as entry. Returns 0 on success. */
static int add_symlink_entry(entry_list *list, const char *fs_path,
                             const char *archive_name) {
	char target[4096];
	ssize_t tlen = readlink(fs_path, target, sizeof(target) - 1);
	if (tlen < 0) {
		fprintf(stderr, "warning: cannot read symlink '%s': %s\n",
			fs_path, strerror(errno));
		return 1;
	}
	target[tlen] = '\0';
	return entry_list_add_symlink(list, archive_name, target);
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
			if (add_symlink_entry(list, full_path, rel_path) != 0) {
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
				if (entry_list_add_dir(list, dir_name) != 0) {
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
				if (entry_list_add_file(list, rel_path, data, flen) != 0) {
					free(data);
					closedir(d);
					return 1;
				}
			}
		} else if (S_ISDIR(st.st_mode)) {
			char dir_name[4096];
			snprintf(dir_name, sizeof(dir_name), "%s/", rel_path);
			if (entry_list_add_dir(list, dir_name) != 0) {
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
			if (entry_list_add_file(list, rel_path, data, flen) != 0) {
				free(data);
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
		if (z7z_file_is_dir(ar, i)) {
			printf("%-12s  %s\n", "<dir>", name ? name : "(unnamed)");
		} else if (z7z_file_is_symlink(ar, i)) {
			/* Show symlink with target path */
			const uint8_t *tdata = z7z_file_data(ar, i);
			if (tdata && size > 0) {
				char target[4096];
				size_t tlen = size < sizeof(target) - 1 ? size : sizeof(target) - 1;
				memcpy(target, tdata, tlen);
				target[tlen] = '\0';
				printf("<symlink>     %s -> %s\n", name ? name : "(unnamed)", target);
			} else {
				printf("<symlink>     %s\n", name ? name : "(unnamed)");
			}
		} else {
			printf("%-12zu  %s\n", size, name ? name : "(unnamed)");
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
				}
			}
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
			if (add_symlink_entry(&list, file_paths[i], basename_of(file_paths[i])) != 0) {
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
			if (entry_list_add_dir(&list, prefix) != 0) {
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
			if (entry_list_add_file(&list, basename_of(file_paths[i]), data, flen) != 0) {
				fprintf(stderr, "error: out of memory\n");
				free(data);
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
		const char *out_dir = (argc >= 4) ? argv[3] : NULL;
		return cmd_extract(argv[2], out_dir);
	} else if (strcmp(cmd, "create") == 0 || strcmp(cmd, "a") == 0) {
		/* Parse optional flags before archive path */
		int arg_start = 2;
		for (int i = 2; i < argc; i++) {
			if (strcmp(argv[i], "--dereference") == 0 || strcmp(argv[i], "-L") == 0) {
				g_dereference = 1;
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
