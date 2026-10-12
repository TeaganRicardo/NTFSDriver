// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef NTFS_DRIVER_READ_REQUEST_H
#define NTFS_DRIVER_READ_REQUEST_H
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <sys/types.h>

typedef ssize_t (*nd_request_reader)(void *, uint64_t, uint64_t, void *, size_t);

// FUSE pads positive short reads with zeroes. Only the known file size establishes EOF.
static inline int nd_read_request(void *context, nd_request_reader read,
                                  uint64_t reference, uint64_t file_size,
                                  uint64_t offset, char *buffer, size_t count) {
    if (offset >= file_size) return 0;
    uint64_t available = file_size - offset;
    size_t expected = available < count ? (size_t)available : count;
    if (expected > INT_MAX) return -EOVERFLOW;
    size_t received = 0;
    while (received < expected) {
        size_t chunk = expected - received;
        if (chunk > 1024 * 1024) chunk = 1024 * 1024;
        errno = 0;
        ssize_t result = read(context, reference, offset + received, buffer + received, chunk);
        if (result < 0) return errno ? -errno : -EIO;
        if (result == 0 || (size_t)result > chunk) return -EIO;
        received += (size_t)result;
    }
    return (int)received;
}
#endif
