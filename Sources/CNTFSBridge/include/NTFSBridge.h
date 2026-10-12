// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef NTFSDRIVER_BRIDGE_H
#define NTFSDRIVER_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct nd_volume nd_volume;
typedef ssize_t (*nd_read_callback)(void *context, void *buffer, size_t count, uint64_t offset);
typedef struct {
    uint64_t byte_count;
    uint32_t sector_size;
    void *context;
    nd_read_callback read;
} nd_source;

typedef struct {
    uint64_t backend_reads;
    uint64_t denied_backend_writes;
} nd_io_stats;

typedef struct {
    uint64_t reference;
    uint64_t size;
    uint64_t allocated_size;
    uint32_t flags;
    uint32_t link_count;
    uint8_t directory;
    int64_t birth_seconds, modify_seconds, change_seconds, access_seconds;
    int32_t birth_nanoseconds, modify_nanoseconds, change_nanoseconds, access_nanoseconds;
} nd_item_info;

typedef struct {
    uint8_t major_version, minor_version;
    uint16_t volume_flags;
    uint32_t cluster_size;
    uint64_t total_clusters;
    uint64_t free_clusters;
} nd_volume_info;

// Callback returns 0 to continue, 1 to stop successfully, or -1 with errno on error.
// Name memory is borrowed only for the duration of the callback.
// Type is the NTFS directory-entry type: 4 directory, 8 regular file, others unsupported.
typedef int (*nd_entry_callback)(void *context, const char *name, uint64_t reference,
                                uint8_t type, int64_t next_cookie);

// All operations must be serialized by the owner. Source context remains owned by the caller.
int nd_open_source(nd_source source, nd_volume **result);
int nd_open_image(const char *path, nd_volume **result);
int nd_get_volume_info(nd_volume *volume, nd_volume_info *result);
const char *nd_volume_name(nd_volume *volume);
int nd_get_item_info(nd_volume *volume, uint64_t reference, nd_item_info *result);
int nd_lookup(nd_volume *volume, uint64_t parent, const char *name, uint64_t *result);
int nd_enumerate(nd_volume *volume, uint64_t directory, int64_t *cookie,
                 void *context, nd_entry_callback callback);
ssize_t nd_read_file(nd_volume *volume, uint64_t reference, uint64_t offset,
                     void *buffer, size_t count);
int nd_get_stats(nd_volume *volume, nd_io_stats *result);
// Consumes the handle on success AND failure. Never retry close with the same handle.
int nd_close(nd_volume *volume, nd_io_stats *final_stats);
// Exercises the real denying callbacks without opening or reading any media.
int nd_verify_write_guards(void);
#endif
