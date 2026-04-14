// fs_ops.zig
// Root module for file-system operations exposed to the ObjC layer via the
// C ABI defined in include/bridge.h.
//
// Submodules:
//   • dir_listing.zig  – zig_list_directory, zig_free_dir_listing
//   • volumes.zig      – zig_get_volumes, zig_get_special_dirs, zig_free_volume_list
//   • transfer.zig     – zig_check_collision, zig_copy_files, zig_move_files
//   • archive.zig      – zig_compress, zig_uncompress
//   • file_ops.zig     – zig_delete_files, zig_create_directory, zig_rename
//
// Threading model:
//   • zig_copy_files / zig_move_files spawn a detached thread.
//   • Callbacks are invoked on that thread; ObjC side must dispatch_async
//     to the main queue before touching UI.

const std = @import("std");
const builtin = @import("builtin");

// Import submodules and force their export symbols to be linked.
pub const dir_listing = @import("dir_listing.zig");
pub const volumes = @import("volumes.zig");
pub const transfer = @import("transfer.zig");
pub const archive = @import("archive.zig");
pub const file_ops = @import("file_ops.zig");

comptime {
    @export(&dir_listing.zig_list_directory, .{ .name = "zig_list_directory" });
    @export(&dir_listing.zig_free_dir_listing, .{ .name = "zig_free_dir_listing" });
    @export(&volumes.zig_get_volumes, .{ .name = "zig_get_volumes" });
    @export(&volumes.zig_get_special_dirs, .{ .name = "zig_get_special_dirs" });
    @export(&volumes.zig_free_volume_list, .{ .name = "zig_free_volume_list" });
    @export(&transfer.zig_check_collision, .{ .name = "zig_check_collision" });
    @export(&transfer.zig_copy_files, .{ .name = "zig_copy_files" });
    @export(&transfer.zig_move_files, .{ .name = "zig_move_files" });
    @export(&archive.zig_compress, .{ .name = "zig_compress" });
    @export(&archive.zig_compress_split, .{ .name = "zig_compress_split" });
    @export(&archive.zig_uncompress, .{ .name = "zig_uncompress" });
    @export(&file_ops.zig_delete_files, .{ .name = "zig_delete_files" });
    @export(&file_ops.zig_create_directory, .{ .name = "zig_create_directory" });
    @export(&file_ops.zig_rename, .{ .name = "zig_rename" });
}

// ---------------------------------------------------------------------------
// Global allocator (thread-safe GPA)
// ---------------------------------------------------------------------------

var gpa_state: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
pub const gpa = gpa_state.allocator();

// App-level Io instance backed by a proper threaded implementation.
// Initialized at runtime in init() because Threaded.init calls sysctlbyname.
const Io = std.Io;
var app_io_instance: Io.Threaded = Io.Threaded.init_single_threaded;

pub fn getIo() Io {
    if (builtin.is_test) return std.testing.io;
    return app_io_instance.io();
}

pub fn init() void {
    app_io_instance = Io.Threaded.init(gpa_state.allocator(), .{});
}

export fn zig_init() void {
    init();
}

// ---------------------------------------------------------------------------
// C types mirroring include/bridge.h
// ---------------------------------------------------------------------------

pub const ZigDirEntry = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
    is_dir: bool,
    is_symlink: bool,
    size: u64,
    mtime: i64,
};

pub const ZigDirListing = extern struct {
    entries: [*]ZigDirEntry,
    count: u64,
};

pub const ZigVolume = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
};

pub const ZigVolumeList = extern struct {
    volumes: [*]ZigVolume,
    count: u64,
};

pub const ZigProgressCallback = *const fn (
    ctx: ?*anyopaque,
    progress: f64,
    bytes_transferred: u64,
    total_bytes: u64,
    speed: f64,
    eta_secs: i64,
) callconv(.c) void;

pub const ZigCompletionCallback = *const fn (
    ctx: ?*anyopaque,
    success: bool,
    error_msg: ?[*:0]const u8,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// C interop helpers
// ---------------------------------------------------------------------------

const c = @cImport({
    @cInclude("stdlib.h");
});

pub fn c_getenv(name: [*:0]const u8) ?[*:0]const u8 {
    return @ptrCast(c.getenv(name));
}

// ---------------------------------------------------------------------------
// Shared test utilities
// ---------------------------------------------------------------------------

const Dir = Io.Dir;
const File = Io.File;

pub fn testBasePath() ![]const u8 {
    const tio = getIo();
    const cwd = try std.process.currentPathAlloc(tio, gpa);
    defer gpa.free(cwd);
    const result = try gpa.alloc(u8, cwd.len + "/test_dir".len);
    @memcpy(result[0..cwd.len], cwd);
    @memcpy(result[cwd.len..], "/test_dir");
    return result;
}

pub fn testRsyncPath() ![:0]u8 {
    const tio = getIo();
    const cwd = try std.process.currentPathAlloc(tio, gpa);
    defer gpa.free(cwd);
    return try std.fmt.allocPrintSentinel(gpa, "{s}/bin/rsync", .{cwd}, 0);
}

/// Callback context used by the async copy/move/archive tests.
pub const DoneCtx = struct {
    done: std.atomic.Value(bool) = .init(false),
    success: std.atomic.Value(bool) = .init(false),

    pub fn onProgress(_: ?*anyopaque, _: f64, _: u64, _: u64, _: f64, _: i64) callconv(.c) void {}

    pub fn onDone(raw: ?*anyopaque, ok: bool, _: ?[*:0]const u8) callconv(.c) void {
        const self: *DoneCtx = @ptrCast(@alignCast(raw.?));
        self.success.store(ok, .release);
        self.done.store(true, .release);
    }

    pub fn wait(self: *DoneCtx) bool {
        while (!self.done.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        return self.success.load(.acquire);
    }
};
