// SPDX-License-Identifier: GPL-3.0-or-later
// Development-only FUSE 2 adapter. All disk I/O uses the existing rejecting bridge.
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include "NTFSBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static nd_volume *volume;

static int read_guard(void) {
    nd_io_stats stats;
    if (nd_get_stats(volume, &stats)) return -errno;
    return stats.denied_backend_writes ? -EROFS : 0;
}

static int lookup(const char *path, uint64_t *reference) {
    int guard = read_guard();
    if (guard) return guard;
    if (!path || path[0] != '/' || strlen(path) > 4096) return -EINVAL;
    char *copy = strdup(path);
    if (!copy) return -ENOMEM;
    *reference = 5;
    char *save = NULL;
    int result = 0;
    for (char *name = strtok_r(copy, "/", &save); name; name = strtok_r(NULL, "/", &save)) {
        if (nd_lookup(volume, *reference, name, reference)) { result = -errno; break; }
    }
    free(copy);
    return result ? result : read_guard();
}

static int item_stat(uint64_t reference, struct stat *stat) {
    int guard = read_guard();
    if (guard) return guard;
    nd_item_info info;
    if (nd_get_item_info(volume, reference, &info)) return -errno;
    memset(stat, 0, sizeof(*stat));
    stat->st_ino = info.reference & 0x0000ffffffffffffULL;
    stat->st_mode = info.directory ? S_IFDIR | 0555 : S_IFREG | 0444;
    stat->st_nlink = info.link_count;
    stat->st_uid = getuid(); stat->st_gid = getgid();
    stat->st_size = info.size;
    stat->st_blocks = (info.allocated_size + 511) / 512;
    stat->st_blksize = 4096;
    stat->st_flags = info.flags & 2 ? UF_HIDDEN : 0;
    stat->st_birthtimespec = (struct timespec){info.birth_seconds, info.birth_nanoseconds};
    stat->st_mtimespec = (struct timespec){info.modify_seconds, info.modify_nanoseconds};
    stat->st_ctimespec = (struct timespec){info.change_seconds, info.change_nanoseconds};
    stat->st_atimespec = (struct timespec){info.access_seconds, info.access_nanoseconds};
    return read_guard();
}

static int attributes(const char *path, struct stat *stat) {
    uint64_t reference;
    int result = lookup(path, &reference);
    return result ? result : item_stat(reference, stat);
}

struct directory_buffer { void *buffer; fuse_fill_dir_t fill; };
static int entry(void *context, const char *name, uint64_t reference, uint8_t type, int64_t cookie) {
    struct directory_buffer *buffer = context;
    struct stat stat;
    int result = item_stat(reference, &stat);
    if (result) { errno = -result; return -1; }
    if (type != 4 && type != 8) stat.st_mode = 0; // Unsupported entry, never a made-up regular file.
    return buffer->fill(buffer->buffer, name, &stat, cookie) ? 1 : 0;
}

static int directory(const char *path, void *buffer, fuse_fill_dir_t fill, off_t offset,
                     struct fuse_file_info *file) {
    (void)file;
    uint64_t reference;
    int result = lookup(path, &reference);
    if (result) return result;
    int64_t cookie = offset;
    struct directory_buffer state = {buffer, fill};
    return nd_enumerate(volume, reference, &cookie, &state, entry) ? -errno : 0;
}

static int open_file(const char *path, struct fuse_file_info *file) {
    // FSKit's FUSE backend opens even read-only files as O_RDWR. This is not device write permission.
    if ((file->flags & O_ACCMODE) == O_WRONLY || (file->flags & (O_TRUNC | O_APPEND | O_CREAT))) return -EROFS;
    uint64_t reference;
    int result = lookup(path, &reference);
    if (result) return result;
    nd_item_info info;
    if (nd_get_item_info(volume, reference, &info)) return -errno;
    if (info.directory) return -EISDIR;
    file->fh = reference;
    return 0;
}

static int read_file(const char *path, char *buffer, size_t count, off_t offset,
                     struct fuse_file_info *file) {
    (void)path;
    int guard = read_guard();
    if (guard) return guard;
    if (offset < 0) return -EINVAL;
    if (count > 1024 * 1024) count = 1024 * 1024;
    ssize_t result = nd_read_file(volume, file->fh, (uint64_t)offset, buffer, count);
    if (result < 0) return -errno;
    guard = read_guard();
    return guard ? guard : (int)result;
}

static int statistics(const char *path, struct statvfs *stat) {
    (void)path;
    int guard = read_guard();
    if (guard) return guard;
    nd_volume_info info;
    if (nd_get_volume_info(volume, &info)) return -errno;
    memset(stat, 0, sizeof(*stat));
    stat->f_bsize = stat->f_frsize = info.cluster_size;
    stat->f_blocks = info.total_clusters; stat->f_bfree = info.free_clusters;
    stat->f_bavail = 0; stat->f_namemax = 255; stat->f_flag = ST_RDONLY;
    return 0;
}

static int deny_path(const char *p) { (void)p; return -EROFS; }
static int deny_pair(const char *a, const char *b) { (void)a; (void)b; return -EROFS; }
static int deny_mode(const char *p, mode_t m) { (void)p; (void)m; return -EROFS; }
static int deny_node(const char *p, mode_t m, dev_t d) { (void)p; (void)m; (void)d; return -EROFS; }
static int deny_owner(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; return -EROFS; }
static int deny_size(const char *p, off_t n) { (void)p; (void)n; return -EROFS; }
static int deny_times(const char *p, const struct timespec t[2]) { (void)p; (void)t; return -EROFS; }
static int deny_write(const char *p, const char *b, size_t n, off_t o, struct fuse_file_info *f) {
    (void)p; (void)b; (void)n; (void)o; (void)f; return -EROFS;
}

int main(int argc, char **argv) {
    const char *prefix = "/Volumes/NTFSDriverReadOnlyTest-";
    if (argc != 3 || strncmp(argv[2], prefix, strlen(prefix)) ||
        !argv[2][strlen(prefix)] || strchr(argv[2] + strlen(prefix), '/')) {
        fprintf(stderr, "Usage: ntfs-fuse-readonly <disposable image> /Volumes/NTFSDriverReadOnlyTest-<unique name>\n");
        return 64;
    }
    struct stat stat;
    if (!lstat(argv[2], &stat) || errno != ENOENT) {
        fprintf(stderr, "Mount point must not already exist.\n"); return 1;
    }
    if (nd_open_image(argv[1], &volume)) { perror("nd_open_image"); return 1; }
    struct fuse_operations operations = {
        .getattr = attributes, .readdir = directory, .open = open_file, .read = read_file,
        .statfs = statistics, .mknod = deny_node, .mkdir = deny_mode, .unlink = deny_path,
        .rmdir = deny_path, .symlink = deny_pair, .rename = deny_pair, .link = deny_pair,
        .chmod = deny_mode, .chown = deny_owner, .truncate = deny_size, .utimens = deny_times,
        .write = deny_write
    };
    // Single-threaded callbacks preserve the bridge's serialization contract.
    char options[] = "backend=fskit,ro,local,default_permissions,max_read=1048576,volname=NTFSDriverReadOnlyTest";
    char *arguments[] = {argv[0], "-f", "-s", "-o", options, argv[2]};
    int result = fuse_main(6, arguments, &operations, NULL);
    nd_io_stats final;
    int closed = nd_close(volume, &final); // Always consumes the handle.
    fprintf(stderr, "backendReads=%llu deniedBackendWrites=%llu close=%d\n",
            (unsigned long long)final.backend_reads, (unsigned long long)final.denied_backend_writes, closed);
    return result || closed ? 1 : 0;
}
