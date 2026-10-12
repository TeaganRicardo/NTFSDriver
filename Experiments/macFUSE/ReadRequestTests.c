// SPDX-License-Identifier: GPL-3.0-or-later
#include "ReadRequest.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

enum behavior { complete, short_reads, io_failure, early_zero, oversized, unset_error };
struct source { enum behavior behavior; size_t calls; uint64_t next; };

static ssize_t read_source(void *context, uint64_t reference, uint64_t offset,
                           void *buffer, size_t count) {
    struct source *source = context;
    assert(reference == 42 && offset == source->next);
    assert(count > 0 && count <= 1024 * 1024);
    source->calls++;
    if (source->behavior == oversized) return (ssize_t)count + 1;
    if (source->behavior == unset_error) return -1;
    if (source->calls > 1 && source->behavior == io_failure) { errno = EIO; return -1; }
    if (source->calls > 1 && source->behavior == early_zero) return 0;
    if (source->behavior != complete && count > 128 * 1024) count = 128 * 1024;
    for (size_t i = 0; i < count; i++) ((unsigned char *)buffer)[i] = (offset + i) % 251;
    source->next += count;
    return (ssize_t)count;
}

static void verify(const char *buffer, size_t count, uint64_t offset) {
    for (size_t i = 0; i < count; i++) assert((unsigned char)buffer[i] == (offset + i) % 251);
}

int main(void) {
    const size_t length = 2 * 1024 * 1024 + 17;
    char *buffer = malloc(length);
    assert(buffer);
    struct source source = {complete, 0, 7};
    assert(nd_read_request(&source, read_source, 42, length + 7, 7, buffer, length) == (int)length);
    assert(source.calls == 3); verify(buffer, length, 7);

    source = (struct source){short_reads, 0, 7};
    assert(nd_read_request(&source, read_source, 42, length + 7, 7, buffer, length) == (int)length);
    assert(source.calls == 17); verify(buffer, length, 7);

    source = (struct source){io_failure, 0, 0};
    assert(nd_read_request(&source, read_source, 42, length, 0, buffer, length) == -EIO);
    assert(source.calls == 2);
    source = (struct source){early_zero, 0, 0};
    assert(nd_read_request(&source, read_source, 42, length, 0, buffer, length) == -EIO);
    assert(source.calls == 2);

    source = (struct source){complete, 0, 90};
    assert(nd_read_request(&source, read_source, 42, 100, 90, buffer, length) == 10);
    assert(source.calls == 1); verify(buffer, 10, 90);
    source = (struct source){complete, 0, 0};
    assert(nd_read_request(&source, read_source, 42, 100, 101, buffer, length) == 0);
    assert(nd_read_request(&source, read_source, 42, 0, 0, buffer, length) == 0);
    assert(nd_read_request(&source, read_source, 42, 100, 0, buffer, 0) == 0);
    assert(source.calls == 0);

    source = (struct source){oversized, 0, 0};
    assert(nd_read_request(&source, read_source, 42, length, 0, buffer, length) == -EIO);
    source = (struct source){unset_error, 0, 0};
    assert(nd_read_request(&source, read_source, 42, length, 0, buffer, length) == -EIO);
    source = (struct source){complete, 0, 0};
    assert(nd_read_request(&source, read_source, 42, UINT64_MAX, 0, buffer, (size_t)INT_MAX + 1) == -EOVERFLOW);
    assert(source.calls == 0);
    free(buffer);
    puts("FUSE read boundary: full request, partial I/O, faults, EOF and overflow passed.");
    return 0;
}
