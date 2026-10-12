// SPDX-License-Identifier: GPL-3.0-or-later
#include "NTFSBridge.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ntfs-3g/config.h>
#include <ntfs-3g/types.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/logging.h>

struct nd_volume {
    ntfs_volume *engine;
    nd_source source;
    nd_io_stats stats;
    int64_t cursor;
    int owned_fd;
};

static int fail(int code) { errno = code; return -1; }
static struct nd_volume *state(struct ntfs_device *dev) { return dev->d_private; }

static int device_open(struct ntfs_device *dev, int flags) {
    if ((flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT | O_TRUNC | O_APPEND))) {
        state(dev)->stats.denied_backend_writes++;
        return fail(EROFS);
    }
    NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int device_close(struct ntfs_device *dev) {
    NDevClearOpen(dev);
    return 0;
}

static s64 device_seek(struct ntfs_device *dev, s64 offset, int whence) {
    struct nd_volume *v = state(dev);
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = v->cursor; break;
        case SEEK_END: base = (int64_t)v->source.byte_count; break;
        default: return fail(EINVAL);
    }
    if ((offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && offset < -base)) return fail(EINVAL);
    int64_t position = base + offset;
    if (position < 0 || (uint64_t)position > v->source.byte_count) return fail(EINVAL);
    v->cursor = position;
    return position;
}

static s64 device_pread(struct ntfs_device *dev, void *buffer, s64 count, s64 offset) {
    struct nd_volume *v = state(dev);
    if (offset < 0 || count < 0 || (uint64_t)offset > v->source.byte_count ||
        (uint64_t)count > SIZE_MAX || (!buffer && count)) return fail(EINVAL);
    uint64_t remaining = v->source.byte_count - (uint64_t)offset;
    size_t length = (uint64_t)count > remaining ? (size_t)remaining : (size_t)count;
    if (length > 1024 * 1024) length = 1024 * 1024;
    if (!length) return 0;
    v->stats.backend_reads++;
    ssize_t result = v->source.read(v->source.context, buffer, length, (uint64_t)offset);
    if (result > (ssize_t)length) return fail(EIO);
    return result;
}

static s64 device_read(struct ntfs_device *dev, void *buffer, s64 count) {
    struct nd_volume *v = state(dev);
    s64 result = device_pread(dev, buffer, count, v->cursor);
    if (result > 0) v->cursor += result;
    return result;
}

static s64 deny_write(struct ntfs_device *dev, const void *buffer, s64 count) {
    (void)buffer; (void)count;
    state(dev)->stats.denied_backend_writes++;
    return fail(EROFS);
}

static s64 deny_pwrite(struct ntfs_device *dev, const void *buffer, s64 count, s64 offset) {
    (void)offset;
    return deny_write(dev, buffer, count);
}

static int device_sync(struct ntfs_device *dev) { (void)dev; return 0; }

static int device_stat(struct ntfs_device *dev, struct stat *result) {
    memset(result, 0, sizeof(*result));
    result->st_mode = S_IFREG | 0444;
    result->st_size = (off_t)state(dev)->source.byte_count;
    result->st_blksize = state(dev)->source.sector_size;
    return 0;
}

static int device_ioctl(struct ntfs_device *dev, unsigned long request, void *argument) {
    if (!argument) return fail(EINVAL);
    if (request == DKIOCGETBLOCKSIZE) {
        *(uint32_t *)argument = state(dev)->source.sector_size;
        return 0;
    }
    if (request == DKIOCGETBLOCKCOUNT) {
        *(uint64_t *)argument = state(dev)->source.byte_count / state(dev)->source.sector_size;
        return 0;
    }
    return fail(ENOTTY);
}

static struct ntfs_device_operations operations = {
    device_open, device_close, device_seek, device_read, deny_write,
    device_pread, deny_pwrite, device_sync, device_stat, device_ioctl
};

static pthread_once_t logging_once = PTHREAD_ONCE_INIT;
static void initialize_logging(void) {
    ntfs_log_set_handler(ntfs_log_handler_stderr);
    ntfs_log_clear_levels(UINT32_MAX);
    ntfs_log_set_levels(NTFS_LOG_LEVEL_WARNING | NTFS_LOG_LEVEL_ERROR |
                        NTFS_LOG_LEVEL_PERROR | NTFS_LOG_LEVEL_CRITICAL);
}

static int open_volume(struct nd_volume *v, nd_volume **result) {
    pthread_once(&logging_once, initialize_logging);
    struct ntfs_device *dev = ntfs_device_alloc("ntfsdriver-readonly", 0, &operations, v);
    if (!dev) return -1;
    v->engine = ntfs_device_mount(dev, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!v->engine) {
        int error = errno;
        ntfs_device_free(dev); // Failed mount releases the volume, but not this device.
        return fail(error);
    }
    // Preserve exact stored names. Case-insensitive lookup is a later compatibility gate.
    NVolSetCaseSensitive(v->engine);
    ntfs_set_shown_files(v->engine, FALSE, TRUE, FALSE);
    int space_error = ntfs_volume_get_free_space(v->engine) ? errno : 0;
    // Upstream counts every bitmap bit, including padding beyond the volume geometry.
    if (!space_error && (v->engine->nr_clusters <= 0 || v->engine->free_clusters < 0 ||
                         v->engine->free_clusters > v->engine->nr_clusters)) space_error = EIO;
    if (v->stats.denied_backend_writes || space_error) {
        ntfs_umount(v->engine, FALSE);
        v->engine = NULL;
        return fail(space_error ? space_error : EROFS);
    }
    *result = v;
    return 0;
}

int nd_open_source(nd_source source, nd_volume **result) {
    if (!result) return fail(EINVAL);
    *result = NULL;
    if (!source.read || source.byte_count < 512 || source.byte_count > INT64_MAX ||
        source.sector_size < 512 || source.sector_size > 4096 ||
        (source.sector_size & (source.sector_size - 1))) return fail(EINVAL);
    struct nd_volume *v = calloc(1, sizeof(*v));
    if (!v) return -1;
    v->source = source;
    v->owned_fd = -1;
    if (open_volume(v, result)) { int error = errno; free(v); return fail(error); }
    return 0;
}

static ssize_t file_read(void *context, void *buffer, size_t count, uint64_t offset) {
    struct nd_volume *v = context;
    ssize_t result;
    do { result = pread(v->owned_fd, buffer, count, (off_t)offset); } while (result < 0 && errno == EINTR);
    return result;
}

int nd_open_image(const char *path, nd_volume **result) {
    if (!path || !result) return fail(EINVAL);
    *result = NULL;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat info;
    int error = 0;
    if (fstat(fd, &info)) error = errno;
    else if (!S_ISREG(info.st_mode) || info.st_size < 512) error = EINVAL;
    if (error) { close(fd); return fail(error); }
    struct nd_volume *v = calloc(1, sizeof(*v));
    if (!v) { error = errno; close(fd); return fail(error); }
    v->owned_fd = fd;
    v->source = (nd_source){(uint64_t)info.st_size, 512, v, file_read};
    if (open_volume(v, result)) { error = errno; close(fd); free(v); return fail(error); }
    return 0;
}

int nd_get_volume_info(nd_volume *volume, nd_volume_info *result) {
    if (!volume || !result) return fail(EINVAL);
    ntfs_volume *v = volume->engine;
    *result = (nd_volume_info){v->major_ver, v->minor_ver, le16_to_cpu(v->flags),
                              v->cluster_size, (uint64_t)v->nr_clusters, (uint64_t)v->free_clusters};
    return 0;
}

const char *nd_volume_name(nd_volume *volume) { return volume ? volume->engine->vol_name : NULL; }

int nd_get_item_info(nd_volume *volume, uint64_t reference, nd_item_info *result) {
    if (!volume || !result) return fail(EINVAL);
    ntfs_inode *inode = ntfs_inode_open(volume->engine, reference);
    if (!inode) return -1;
    int directory = !!(inode->mrec->flags & MFT_RECORD_IS_DIRECTORY);
    if (!directory && (inode->data_size < 0 || inode->allocated_size < 0)) {
        ntfs_inode_close(inode);
        return fail(EIO);
    }
    memset(result, 0, sizeof(*result));
    result->reference = MK_MREF(inode->mft_no, le16_to_cpu(inode->mrec->sequence_number));
    result->directory = directory;
    result->size = inode->data_size < 0 ? 0 : (uint64_t)inode->data_size;
    result->allocated_size = inode->allocated_size < 0 ? 0 : (uint64_t)inode->allocated_size;
    result->flags = le32_to_cpu(inode->flags);
    result->link_count = le16_to_cpu(inode->mrec->link_count);
    struct timespec birth = ntfs2timespec(inode->creation_time);
    struct timespec modify = ntfs2timespec(inode->last_data_change_time);
    struct timespec change = ntfs2timespec(inode->last_mft_change_time);
    struct timespec access = ntfs2timespec(inode->last_access_time);
    result->birth_seconds = birth.tv_sec; result->birth_nanoseconds = (int32_t)birth.tv_nsec;
    result->modify_seconds = modify.tv_sec; result->modify_nanoseconds = (int32_t)modify.tv_nsec;
    result->change_seconds = change.tv_sec; result->change_nanoseconds = (int32_t)change.tv_nsec;
    result->access_seconds = access.tv_sec; result->access_nanoseconds = (int32_t)access.tv_nsec;
    return ntfs_inode_close(inode);
}

int nd_lookup(nd_volume *volume, uint64_t parent, const char *name, uint64_t *result) {
    if (!volume || !name || !result || !*name || strchr(name, '/')) return fail(EINVAL);
    ntfs_inode *directory = ntfs_inode_open(volume->engine, parent);
    if (!directory) return -1;
    if (!(directory->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        ntfs_inode_close(directory);
        return fail(ENOTDIR);
    }
    // The pinned mbsname helper passes NULL when its optional lookup cache is absent.
    // Convert explicitly and call the stable UTF-16 lookup API without requiring that cache.
    uint64_t reference = UINT64_MAX;
    if (!strcmp(name, ".") || (!strcmp(name, "..") && directory->mft_no == FILE_root)) {
        reference = MK_MREF(directory->mft_no, le16_to_cpu(directory->mrec->sequence_number));
    } else if (!strcmp(name, "..")) {
        ntfs_inode *ancestor = ntfs_dir_parent_inode(directory);
        if (ancestor) {
            reference = MK_MREF(ancestor->mft_no, le16_to_cpu(ancestor->mrec->sequence_number));
            if (ntfs_inode_close(ancestor)) reference = UINT64_MAX;
        }
    } else {
        ntfschar *unicode = NULL;
        int length = ntfs_mbstoucs(name, &unicode);
        if (length >= 0) reference = ntfs_inode_lookup_by_name(directory, unicode, length);
        free(unicode);
    }
    int error = reference == UINT64_MAX ? errno : 0;
    if (ntfs_inode_close(directory) && !error) error = errno;
    if (error) return fail(error);
    *result = reference;
    return 0;
}

struct enumeration {
    void *context;
    nd_entry_callback callback;
    int error;
    int stopped;
};

static int entry(void *context, const ntfschar *name, int length, int name_type,
                 s64 position, MFT_REF reference, unsigned type) {
    struct enumeration *e = context;
    if (name_type == FILE_NAME_DOS) return 0;
    if (length <= 0 || length > 255 || position < 0 || position == INT64_MAX) {
        e->error = EIO;
        return -1;
    }
    char *utf8 = NULL;
    int bytes = ntfs_ucstombs(name, length, &utf8, 0);
    if (bytes < 0) { e->error = errno; return -1; }
    if (memchr(utf8, 0, (size_t)bytes) || memchr(utf8, '/', (size_t)bytes)) {
        free(utf8); e->error = EIO; return -1;
    }
    int result = e->callback(e->context, utf8, reference, (uint8_t)type, position + 1);
    int error = errno;
    free(utf8);
    if (result > 0) e->stopped = 1;
    else if (result < 0) e->error = error ? error : EIO;
    return result;
}

int nd_enumerate(nd_volume *volume, uint64_t directory, int64_t *cookie,
                 void *context, nd_entry_callback callback) {
    if (!volume || !cookie || *cookie < 0 || !callback) return fail(EINVAL);
    ntfs_inode *inode = ntfs_inode_open(volume->engine, directory);
    if (!inode) return -1;
    struct enumeration e = {context, callback, 0, 0};
    s64 position = *cookie;
    int result = ntfs_readdir(inode, &position, &e, entry);
    int error = e.error ? e.error : (result < 0 && !e.stopped ? errno : 0);
    if (ntfs_inode_close(inode) && !error) error = errno;
    if (error) return fail(error);
    *cookie = position;
    return 0;
}

ssize_t nd_read_file(nd_volume *volume, uint64_t reference, uint64_t offset,
                     void *buffer, size_t count) {
    if (!volume || offset > INT64_MAX || count > 1024 * 1024 ||
        offset > INT64_MAX - count || (!buffer && count)) return fail(EINVAL);
    ntfs_inode *inode = ntfs_inode_open(volume->engine, reference);
    if (!inode) return -1;
    int error = 0;
    if (inode->mrec->flags & MFT_RECORD_IS_DIRECTORY) error = EISDIR;
    else if (inode->flags & FILE_ATTR_ENCRYPTED) error = EACCES;
    else if (inode->flags & FILE_ATTR_REPARSE_POINT) error = ENOTSUP;
    if (error) { ntfs_inode_close(inode); return fail(error); }
    ntfs_attr *data = ntfs_attr_open(inode, AT_DATA, AT_UNNAMED, 0);
    if (!data) { error = errno; ntfs_inode_close(inode); return fail(error); }
    s64 result = ntfs_attr_pread(data, (s64)offset, (s64)count, buffer);
    if (result < 0) error = errno;
    else if (result > (s64)count) error = EIO;
    ntfs_attr_close(data);
    if (ntfs_inode_close(inode) && !error) error = errno;
    if (error) return fail(error);
    return (ssize_t)result;
}

int nd_get_stats(nd_volume *volume, nd_io_stats *result) {
    if (!volume || !result) return fail(EINVAL);
    *result = volume->stats;
    return 0;
}

int nd_close(nd_volume *volume, nd_io_stats *final_stats) {
    if (!volume) return fail(EINVAL);
    // Pinned ntfs_umount consumes volume/device even if cleanup returns failure.
    int result = ntfs_umount(volume->engine, FALSE);
    int error = result ? errno : 0;
    if (volume->owned_fd >= 0 && close(volume->owned_fd) && !error) error = errno;
    if (volume->stats.denied_backend_writes && !error) error = EROFS;
    if (final_stats) *final_stats = volume->stats;
    free(volume);
    return error ? fail(error) : 0;
}

int nd_verify_write_guards(void) {
    struct nd_volume v = {.owned_fd = -1};
    struct ntfs_device dev = {.d_private = &v};
    char value = 0;
    if (device_open(&dev, O_RDWR) != -1 || errno != EROFS) return fail(EIO);
    if (deny_write(&dev, &value, 1) != -1 || errno != EROFS) return fail(EIO);
    if (deny_pwrite(&dev, &value, 1, 0) != -1 || errno != EROFS) return fail(EIO);
    return v.stats.denied_backend_writes == 3 ? 0 : fail(EIO);
}
