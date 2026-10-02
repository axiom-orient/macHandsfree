#include "CPlatformSupport.h"

#include <errno.h>
#include <stdio.h>

#if defined(__APPLE__)
#include <sys/stdio.h>

int mac_handsfree_rename_noreplace(const char *source, const char *destination) {
    return renamex_np(source, destination, RENAME_EXCL);
}

int mac_handsfree_rename_exchange(const char *first, const char *second) {
    return renamex_np(first, second, RENAME_SWAP);
}
#elif defined(__linux__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <fcntl.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <unistd.h>

int mac_handsfree_rename_noreplace(const char *source, const char *destination) {
    return (int)syscall(
        SYS_renameat2,
        AT_FDCWD,
        source,
        AT_FDCWD,
        destination,
        RENAME_NOREPLACE
    );
}

int mac_handsfree_rename_exchange(const char *first, const char *second) {
    return (int)syscall(
        SYS_renameat2,
        AT_FDCWD,
        first,
        AT_FDCWD,
        second,
        RENAME_EXCHANGE
    );
}
#else
int mac_handsfree_rename_noreplace(const char *source, const char *destination) {
    (void)source;
    (void)destination;
    errno = ENOTSUP;
    return -1;
}


int mac_handsfree_rename_exchange(const char *first, const char *second) {
    (void)first;
    (void)second;
    errno = ENOTSUP;
    return -1;
}
#endif
