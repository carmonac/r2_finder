#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

typedef struct {
    const char *name;       // owned by caller – do NOT free
    const char *path;
    bool        is_dir;
    bool        is_symlink;
    uint64_t    size;       // bytes
    int64_t     mtime;      // unix timestamp seconds
} ZigDirEntry;

typedef struct {
    ZigDirEntry *entries;
    uint64_t     count;
} ZigDirListing;

typedef struct {
    const char *name;
    const char *path;
} ZigVolume;

typedef struct {
    ZigVolume *volumes;
    uint64_t   count;
} ZigVolumeList;

// ---------------------------------------------------------------------------
// Callbacks (called from Zig worker threads – must be thread-safe on ObjC side)
// ---------------------------------------------------------------------------

// progress: 0.0 – 1.0  |  speed_bytes_per_sec: bytes/s  |  eta_secs: remaining
typedef void (*ZigProgressCallback)(void *ctx,
                                    double progress,
                                    uint64_t bytes_transferred,
                                    uint64_t total_bytes,
                                    double speed_bytes_per_sec,
                                    int64_t eta_secs);

typedef void (*ZigCompletionCallback)(void *ctx, bool success, const char *error_msg);

// ---------------------------------------------------------------------------
// Zig exports – implemented in src/fs_ops.zig
// ---------------------------------------------------------------------------

// List directory; returns heap-allocated listing; caller must call zig_free_dir_listing.
ZigDirListing *zig_list_directory(const char *path);
void           zig_free_dir_listing(ZigDirListing *listing);

// Mounted volumes (DMG, network drives, external drives, etc.)
ZigVolumeList *zig_get_volumes(void);
void           zig_free_volume_list(ZigVolumeList *list);

// Special well-known directories (Home, Desktop, Documents, Downloads, Applications …)
// Returns a ZigVolumeList reusing the same struct (name = display name, path = fs path).
ZigVolumeList *zig_get_special_dirs(void);

// Async copy (uses bundled rsync - spawns a thread).
// ctx is passed back verbatim to the callbacks.
void zig_copy_files(const char       *rsync_path,
                    const char *const *src_paths,
                    uint64_t          src_count,
                    const char       *dst_dir,
                    bool              overwrite,
                    void             *ctx,
                    ZigProgressCallback on_progress,
                    ZigCompletionCallback on_done);

// Async move (rsync + rm source on success).
void zig_move_files(const char       *rsync_path,
                    const char *const *src_paths,
                    uint64_t          src_count,
                    const char       *dst_dir,
                    bool              overwrite,
                    void             *ctx,
                    ZigProgressCallback on_progress,
                    ZigCompletionCallback on_done);

// Check whether a file with the same basename already exists in dst_dir.
// Returns true if any of the src_paths would collide.
bool zig_check_collision(const char *const *src_paths,
                         uint64_t           src_count,
                         const char        *dst_dir);

// Synchronous delete (sends to Trash via Zig → applescript, falls back to rm -rf).
bool zig_delete_files(const char *const *paths, uint64_t count, char *err_buf, uint64_t err_buf_len);

// Create new folder
bool zig_create_directory(const char *path, char *err_buf, uint64_t err_buf_len);

// Rename / move single item (same-volume fast path)
bool zig_rename(const char *src, const char *dst, char *err_buf, uint64_t err_buf_len);

// Async compress (7z archive).  sevenzz_path = path to the 7zz binary.
void zig_compress(const char        *sevenzz_path,
                  const char *const *src_paths,
                  uint64_t           src_count,
                  const char        *dst_archive,
                  void              *ctx,
                  ZigProgressCallback   on_progress,
                  ZigCompletionCallback on_done);

// Async compress + split into volumes of volume_size_mb megabytes.
void zig_compress_split(const char        *sevenzz_path,
                        const char *const *src_paths,
                        uint64_t           src_count,
                        const char        *dst_archive,
                        uint32_t           volume_size_mb,
                        void              *ctx,
                        ZigProgressCallback   on_progress,
                        ZigCompletionCallback on_done);

// Async uncompress (7z / zip archive).
void zig_uncompress(const char *sevenzz_path,
                    const char *archive_path,
                    const char *dst_dir,
                    void       *ctx,
                    ZigProgressCallback   on_progress,
                    ZigCompletionCallback on_done);

// Initialise Zig runtime (call once from main before anything else)
void zig_init(void);

#ifdef __cplusplus
}
#endif
