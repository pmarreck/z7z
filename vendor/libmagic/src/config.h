/*
 * config.h -- Hand-written portable configuration for Zig build system.
 * Replaces autoconf-generated config.h with compile-time platform detection.
 */
#ifndef CONFIG_H
#define CONFIG_H

#define VERSION "5.46"
#define PACKAGE_VERSION "5.46"

/* Standard headers — universally available */
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#define HAVE_MEMORY_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1

/* Standard functions — universally available */
#define HAVE_MEMMOVE 1
#define HAVE_STRERROR 1
#define HAVE_STRTOLL 1
#define HAVE_STRTOF 1

/* ELF support (built-in) */
#define BUILTIN_ELF 1
#define ELFCORE 1

/*
 * Note: ENABLE_CONDITIONALS is defined in file.h unconditionally,
 * so we do NOT define it here to avoid redefinition warnings.
 */

#ifdef _WIN32
  /* ---- Windows (MinGW) ---- */
  /* No fork/pipe/mmap */

#else
  /* ---- Unix-like (Linux, macOS, *BSD) ---- */
  #define HAVE_UNISTD_H 1
  #define HAVE_SYS_PARAM_H 1
  #define HAVE_SYS_MMAN_H 1
  #define HAVE_SYS_WAIT_H 1
  #define HAVE_SIGNAL_H 1
  #define HAVE_MMAP 1
  #define HAVE_FORK 1
  #define HAVE_PIPE 1
  #define HAVE_REGEX_H 1
  #define HAVE_VISIBILITY 1
  #define HAVE_PREAD 1
  #define HAVE_CTIME_R 1
  #define HAVE_ASCTIME_R 1
  #define HAVE_GMTIME_R 1
  #define HAVE_LOCALTIME_R 1
  #define HAVE_GETLINE 1
  #define HAVE_DPRINTF 1
  #define HAVE_VASPRINTF 1
  #define HAVE_ASPRINTF 1
  #define HAVE_WCWIDTH 1
  #define HAVE_MKSTEMP 1
  #define HAVE_UTIMES 1
  #define HAVE_STRLCPY 1
  #define HAVE_STRLCAT 1
  #define HAVE_STRCASESTR 1

  #ifdef __APPLE__
    #define HAVE_FMTCHECK 1
  #endif

  #ifdef __linux__
    #define HAVE_ELF_H 1
    #define HAVE_PIPE2 1
    /* fmtcheck not available in glibc or musl */
  #endif

  #if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    #define HAVE_ELF_H 1
    #define HAVE_FMTCHECK 1
  #endif
#endif

#endif /* CONFIG_H */
