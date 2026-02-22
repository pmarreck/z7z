/* z7z CLI — dogfoods the C FFI.
 *
 * Usage:
 *   z7z list   <archive.7z>
 *   z7z extract <archive.7z> [output-dir]
 *   z7z create  <archive.7z> <file1> [file2 ...]
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "z7z.h"

static void usage(const char *prog) {
	fprintf(stderr,
		"Usage:\n"
		"  %s list   <archive.7z>\n"
		"  %s extract <archive.7z> [output-dir]\n"
		"  %s create  <archive.7z> <file1> [file2 ...]\n",
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

/* Ensure a directory exists, creating it if needed. */
static int ensure_dir(const char *path) {
	struct stat st;
	if (stat(path, &st) == 0) {
		if (S_ISDIR(st.st_mode)) return 0;
		fprintf(stderr, "error: '%s' exists but is not a directory\n", path);
		return 1;
	}
	if (mkdir(path, 0755) != 0) {
		fprintf(stderr, "error: cannot create directory '%s': %s\n", path, strerror(errno));
		return 1;
	}
	return 0;
}

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
		printf("%-12zu  %s\n", size, name ? name : "(unnamed)");
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

		const uint8_t *file_data = z7z_file_data(ar, i);
		size_t file_size = z7z_file_size(ar, i);

		/* Build output path */
		char out_path[4096];
		if (out_dir) {
			snprintf(out_path, sizeof(out_path), "%s/%s", out_dir, name);
		} else {
			snprintf(out_path, sizeof(out_path), "%s", name);
		}

		if (write_file(out_path, file_data, file_size) != 0) {
			errors++;
		} else {
			printf("  %s (%zu bytes)\n", name, file_size);
		}
	}

	z7z_close(ar);
	return errors > 0 ? 1 : 0;
}

static int cmd_create(const char *archive_path, int file_count, char **file_paths) {
	z7z_file_entry *entries = calloc((size_t)file_count, sizeof(z7z_file_entry));
	if (!entries) {
		fprintf(stderr, "error: out of memory\n");
		return 1;
	}

	/* Buffers to free later */
	uint8_t **bufs = calloc((size_t)file_count, sizeof(uint8_t *));
	if (!bufs) {
		free(entries);
		fprintf(stderr, "error: out of memory\n");
		return 1;
	}

	int ret = 0;
	for (int i = 0; i < file_count; i++) {
		size_t flen = 0;
		bufs[i] = read_file(file_paths[i], &flen);
		if (!bufs[i]) {
			ret = 1;
			goto cleanup;
		}
		entries[i].name = basename_of(file_paths[i]);
		entries[i].data = bufs[i];
		entries[i].data_len = flen;
	}

	uint8_t *out_data = NULL;
	size_t out_len = 0;
	int rc = z7z_create(entries, (size_t)file_count, &out_data, &out_len);
	if (rc != Z7Z_OK) {
		fprintf(stderr, "error: %s\n", z7z_error_string(rc));
		ret = 1;
		goto cleanup;
	}

	if (write_file(archive_path, out_data, out_len) != 0) {
		ret = 1;
	} else {
		printf("Created %s (%zu bytes, %d files)\n", archive_path, out_len, file_count);
	}

	z7z_free(out_data, out_len);

cleanup:
	for (int i = 0; i < file_count; i++) {
		free(bufs[i]);
	}
	free(bufs);
	free(entries);
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
		if (argc < 4) {
			fprintf(stderr, "error: create requires at least one input file\n");
			usage(argv[0]);
			return 1;
		}
		return cmd_create(argv[2], argc - 3, argv + 3);
	} else {
		fprintf(stderr, "error: unknown command '%s'\n", cmd);
		usage(argv[0]);
		return 1;
	}
}
