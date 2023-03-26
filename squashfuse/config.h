/* config.h.  Generated from config.h.in by configure.  */
/* config.h.in.  Generated from configure.ac by autoheader.  */


#ifndef SQFS_CONFIG_H
#define SQFS_CONFIG_H


/* Version of FUSE API to use */
#define FUSE_USE_VERSION 32

/* Define if FUSE xattr operations take a position argument */
/* #undef FUSE_XATTR_POSITION */

/* Define to 1 if you have the <asm/byteorder.h> header file. */
#define HAVE_ASM_BYTEORDER_H 1

/* Define to 1 if you have the <attr/xattr.h> header file. */
/* #undef HAVE_ATTR_XATTR_H */

/* Define to 1 if you have the declaration of `fuse_add_dirent', and to 0 if
   you don't. */
#define HAVE_DECL_FUSE_ADD_DIRENT 0

/* Define to 1 if you have the declaration of `fuse_add_direntry', and to 0 if
   you don't. */
#define HAVE_DECL_FUSE_ADD_DIRENTRY 1

/* Define to 1 if you have the declaration of `fuse_daemonize', and to 0 if
   you don't. */
#define HAVE_DECL_FUSE_DAEMONIZE 1

/* Define to 1 if you have the declaration of `fuse_session_remove_chan', and
   to 0 if you don't. */
#define HAVE_DECL_FUSE_SESSION_REMOVE_CHAN 0

/* Define to 1 if you have the <dlfcn.h> header file. */
#define HAVE_DLFCN_H 1

/* Define to 1 if you have the <endian.h> header file. */
#define HAVE_ENDIAN_H 1

/* Define to 1 if you have the <inttypes.h> header file. */
#define HAVE_INTTYPES_H 1

/* Define if <linux/types.h> defines the type __le16 */
#define HAVE_LINUX_TYPES_LE16 1

/* Define to 1 if you have the <lz4.h> header file. */
#define HAVE_LZ4_H 1

/* Define to 1 if you have the <lzma.h> header file. */
#define HAVE_LZMA_H 1

/* Define to 1 if you have the <lzo/lzo1x.h> header file. */
/* #undef HAVE_LZO_LZO1X_H */

/* Define to 1 if you have the <machine/endian.h> header file. */
/* #undef HAVE_MACHINE_ENDIAN_H */

/* Define if we have two-argument fuse_unmount */
#define HAVE_NEW_FUSE_UNMOUNT 1

/* Define to 1 if you have the <stdint.h> header file. */
#define HAVE_STDINT_H 1

/* Define to 1 if you have the <stdio.h> header file. */
#define HAVE_STDIO_H 1

/* Define to 1 if you have the <stdlib.h> header file. */
#define HAVE_STDLIB_H 1

/* Define to 1 if you have the <strings.h> header file. */
#define HAVE_STRINGS_H 1

/* Define to 1 if you have the <string.h> header file. */
#define HAVE_STRING_H 1

/* Define to 1 if you have the <sys/mkdev.h> header file. */
/* #undef HAVE_SYS_MKDEV_H */

/* Define to 1 if you have the <sys/stat.h> header file. */
#define HAVE_SYS_STAT_H 1

/* Define to 1 if you have the <sys/sysmacros.h> header file. */
#define HAVE_SYS_SYSMACROS_H 1

/* Define to 1 if you have the <sys/types.h> header file. */
#define HAVE_SYS_TYPES_H 1

/* Define to 1 if you have the <unistd.h> header file. */
#define HAVE_UNISTD_H 1

/* Define to 1 if you have the <zlib.h> header file. */
#define HAVE_ZLIB_H 1

/* Define to 1 if you have the <zstd.h> header file. */
#define HAVE_ZSTD_H 1

/* Define to the sub-directory where libtool stores uninstalled libraries. */
#define LT_OBJDIR ".libs/"

/* Extra definition needed by non-POSIX daemon */
/* #undef NONSTD_DAEMON_DEF */

/* Extra definition needed by non-POSIX ENOATTR */
/* #undef NONSTD_ENOATTR_DEF */

/* Extra definition needed by non-POSIX makedev */
/* #undef NONSTD_MAKEDEV_DEF */

/* Extra definition needed by non-POSIX pread */
#define NONSTD_PREAD_DEF CHANGE_XOPEN_SOURCE

/* Extra definition needed by non-POSIX symlink */
/* #undef NONSTD_SYMLINK_DEF */

/* Extra definition needed by non-POSIX S_IFSOCK */
#define NONSTD_S_IFSOCK_DEF CHANGE_XOPEN_SOURCE

/* Name of package */
#define PACKAGE "squashfuse"

/* Define to the address where bug reports for this package should be sent. */
#define PACKAGE_BUGREPORT "dave@vasilevsky.ca"

/* Define to the full name of this package. */
#define PACKAGE_NAME "squashfuse"

/* Define to the full name and version of this package. */
#define PACKAGE_STRING "squashfuse 0.1.104"

/* Define to the one symbol short name of this package. */
#define PACKAGE_TARNAME "squashfuse"

/* Define to the home page for this package. */
#define PACKAGE_URL ""

/* Define to the version of this package. */
#define PACKAGE_VERSION "0.1.104"

/* define if makedev() is QNX-style */
/* #undef QNX_MAKEDEV */

/* Define to 1 if all of the C90 standard headers exist (not just the ones
   required in a freestanding environment). This macro is provided for
   backward compatibility; new code need not use it. */
#define STDC_HEADERS 1

/* Version number of package */
#define VERSION "0.1.104"

/* Number of bits in a file offset, on hosts where this is settable. */
/* #undef _FILE_OFFSET_BITS */

/* Define for large files, on AIX-style hosts. */
/* #undef _LARGE_FILES */

/* POSIX 2001 compatibility */
#define _POSIX_C_SOURCE 200112L

/* Define to `__inline__' or `__inline' if that's what the C compiler
   calls it, or to nothing if 'inline' is not supported under any name.  */
#ifndef __cplusplus
/* #undef inline */
#endif

#endif
