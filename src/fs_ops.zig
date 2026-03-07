// fs_ops.zig
// All file-system operations exposed to the ObjC layer via the C ABI
// defined in include/bridge.h.
//
// Threading model:
//   • zig_copy_files / zig_move_files spawn a detached thread.
//   • Callbacks are invoked on that thread; ObjC side must dispatch_async
//     to the main queue before touching UI.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

// ---------------------------------------------------------------------------
// Global allocator (thread-safe GPA)
// ---------------------------------------------------------------------------

var gpa_state = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
const gpa = gpa_state.allocator();

// App-level Io instance backed by a proper threaded implementation.
// Initialized at runtime in init() because Threaded.init calls sysctlbyname.
var app_io_instance: Io.Threaded = Io.Threaded.init_single_threaded;
var app_io_initialized = false;

fn getIo() Io {
    if (builtin.is_test) return std.testing.io;
    if (app_io_initialized) return app_io_instance.io();
    // Fallback before init — shouldn't happen in practice
    return app_io_instance.ioBasic();
}

pub fn init() void {
    app_io_instance = Io.Threaded.init(gpa_state.allocator(), .{});
    app_io_initialized = true;
}

export fn zig_init() void {
    init();
}

// ---------------------------------------------------------------------------
// C types mirroring include/bridge.h
// ---------------------------------------------------------------------------

const ZigDirEntry = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
    is_dir: bool,
    is_symlink: bool,
    size: u64,
    mtime: i64,
};

const ZigDirListing = extern struct {
    entries: [*]ZigDirEntry,
    count: u64,
};

const ZigVolume = extern struct {
    name: [*:0]const u8,
    path: [*:0]const u8,
};

const ZigVolumeList = extern struct {
    volumes: [*]ZigVolume,
    count: u64,
};

const ZigProgressCallback = *const fn (
    ctx: ?*anyopaque,
    progress: f64,
    bytes_transferred: u64,
    total_bytes: u64,
    speed: f64,
    eta_secs: i64,
) callconv(.c) void;

const ZigCompletionCallback = *const fn (
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

fn c_getenv(name: [*:0]const u8) ?[*:0]const u8 {
    return @ptrCast(c.getenv(name));
}

// ---------------------------------------------------------------------------
// zig_list_directory
// ---------------------------------------------------------------------------

export fn zig_list_directory(path: [*:0]const u8) ?*ZigDirListing {
    return listDirectory(path) catch null;
}

fn listDirectory(path: [*:0]const u8) !*ZigDirListing {
    const io = getIo();
    const path_slice = std.mem.sliceTo(path, 0);
    var dir = try Dir.openDirAbsolute(io, path_slice, .{ .iterate = true });
    defer dir.close(io);

    var entries_list = std.array_list.Managed(ZigDirEntry).init(gpa);
    errdefer {
        for (entries_list.items) |e| {
            gpa.free(std.mem.sliceTo(e.name, 0));
            gpa.free(std.mem.sliceTo(e.path, 0));
        }
        entries_list.deinit();
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Build full path
        const full_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ path_slice, entry.name }, 0);
        const name_z = try gpa.dupeZ(u8, entry.name);

        var size: u64 = 0;
        var mtime: i64 = 0;
        var is_symlink = false;

        if (Dir.openFileAbsolute(io, full_path, .{})) |f| {
            defer f.close(io);
            if (f.stat(io)) |st| {
                size = st.size;
                mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            } else |_| {}
        } else |_| {}

        is_symlink = (entry.kind == .sym_link);

        try entries_list.append(.{
            .name = name_z,
            .path = full_path,
            .is_dir = (entry.kind == .directory or (is_symlink and isSymlinkDir(full_path))),
            .is_symlink = is_symlink,
            .size = size,
            .mtime = mtime,
        });
    }

    // Sort: directories first, then alphabetically
    std.mem.sort(ZigDirEntry, entries_list.items, {}, struct {
        fn lessThan(_: void, a: ZigDirEntry, b: ZigDirEntry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            const na = std.mem.sliceTo(a.name, 0);
            const nb = std.mem.sliceTo(b.name, 0);
            return std.ascii.orderIgnoreCase(na, nb) == .lt;
        }
    }.lessThan);

    const listing = try gpa.create(ZigDirListing);
    const slice = try entries_list.toOwnedSlice();
    listing.* = .{ .entries = slice.ptr, .count = slice.len };
    return listing;
}

fn isSymlinkDir(path: [*:0]const u8) bool {
    const io = getIo();
    const path_slice = std.mem.sliceTo(path, 0);
    var buf: [Dir.max_path_bytes]u8 = undefined;
    const len = Dir.realPathFileAbsolute(io, path_slice, &buf) catch return false;
    var d = Dir.openDirAbsolute(io, buf[0..len], .{}) catch return false;
    d.close(io);
    return true;
}

export fn zig_free_dir_listing(listing: ?*ZigDirListing) void {
    const l = listing orelse return;
    for (l.entries[0..l.count]) |e| {
        gpa.free(std.mem.sliceTo(e.name, 0));
        gpa.free(std.mem.sliceTo(e.path, 0));
    }
    gpa.free(l.entries[0..l.count]);
    gpa.destroy(l);
}

// ---------------------------------------------------------------------------
// zig_get_volumes  (mounted volumes under /Volumes)
// ---------------------------------------------------------------------------

export fn zig_get_volumes() ?*ZigVolumeList {
    return getVolumes() catch null;
}

fn getVolumes() !*ZigVolumeList {
    const io = getIo();
    var list = std.array_list.Managed(ZigVolume).init(gpa);
    errdefer list.deinit();

    var vols_dir = Dir.openDirAbsolute(io, "/Volumes", .{ .iterate = true }) catch {
        return makeEmptyVolumeList();
    };
    defer vols_dir.close(io);

    var it = vols_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const path = try std.fmt.allocPrintSentinel(gpa, "/Volumes/{s}", .{entry.name}, 0);
        const name = try gpa.dupeZ(u8, entry.name);
        try list.append(.{ .name = name, .path = path });
    }

    return finishVolumeList(&list);
}

fn makeEmptyVolumeList() !*ZigVolumeList {
    var empty = std.array_list.Managed(ZigVolume).init(gpa);
    return finishVolumeList(&empty);
}

fn finishVolumeList(list: *std.array_list.Managed(ZigVolume)) !*ZigVolumeList {
    const vl = try gpa.create(ZigVolumeList);
    const slice = try list.toOwnedSlice();
    vl.* = .{ .volumes = slice.ptr, .count = slice.len };
    return vl;
}

// ---------------------------------------------------------------------------
// zig_get_special_dirs
// ---------------------------------------------------------------------------

export fn zig_get_special_dirs() ?*ZigVolumeList {
    return getSpecialDirs() catch null;
}

fn getSpecialDirs() !*ZigVolumeList {
    const io = getIo();
    const home_ptr = c_getenv("HOME") orelse return makeEmptyVolumeList();
    const home = std.mem.sliceTo(home_ptr, 0);
    var list = std.array_list.Managed(ZigVolume).init(gpa);
    errdefer list.deinit();

    const dirs = [_]struct { name: []const u8, rel: []const u8 }{
        .{ .name = "Inicio", .rel = "" },
        .{ .name = "Escritorio", .rel = "/Desktop" },
        .{ .name = "Documentos", .rel = "/Documents" },
        .{ .name = "Descargas", .rel = "/Downloads" },
        .{ .name = "Música", .rel = "/Music" },
        .{ .name = "Imágenes", .rel = "/Pictures" },
        .{ .name = "Películas", .rel = "/Movies" },
        .{ .name = "Aplicaciones", .rel = "/Applications" },
    };

    for (dirs) |d| {
        const full = if (d.rel.len == 0)
            try gpa.dupeZ(u8, home)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, d.rel }, 0);
        // Only add if the directory actually exists
        var dir = Dir.openDirAbsolute(io, std.mem.sliceTo(full, 0), .{}) catch {
            gpa.free(full);
            continue;
        };
        dir.close(io);
        const name = try gpa.dupeZ(u8, d.name);
        try list.append(.{ .name = name, .path = full });
    }

    return finishVolumeList(&list);
}

export fn zig_free_volume_list(list: ?*ZigVolumeList) void {
    const l = list orelse return;
    for (l.volumes[0..l.count]) |v| {
        gpa.free(std.mem.sliceTo(v.name, 0));
        gpa.free(std.mem.sliceTo(v.path, 0));
    }
    gpa.free(l.volumes[0..l.count]);
    gpa.destroy(l);
}

// ---------------------------------------------------------------------------
// zig_check_collision
// ---------------------------------------------------------------------------

export fn zig_check_collision(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
) bool {
    const io = getIo();
    const dst = std.mem.sliceTo(dst_dir, 0);
    for (src_paths[0..src_count]) |sp| {
        const src = std.mem.sliceTo(sp, 0);
        const basename = std.fs.path.basename(src);
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dst, basename }) catch continue;
        Dir.accessAbsolute(io, std.mem.sliceTo(candidate, 0), .{}) catch continue;
        return true; // exists
    }
    return false;
}

// ---------------------------------------------------------------------------
// Copy / Move  (async, rsync-based)
// ---------------------------------------------------------------------------

const TransferJob = struct {
    src_paths: [][:0]u8,
    dst_dir: [:0]u8,
    overwrite: bool,
    is_move: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
};

export fn zig_copy_files(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    spawnTransfer(src_paths, src_count, dst_dir, overwrite, false, ctx, on_progress, on_done);
}

export fn zig_move_files(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    spawnTransfer(src_paths, src_count, dst_dir, overwrite, true, ctx, on_progress, on_done);
}

fn spawnTransfer(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    is_move: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    var paths = gpa.alloc([:0]u8, src_count) catch {
        on_done(ctx, false, "sin memoria");
        return;
    };
    for (src_paths[0..src_count], 0..) |p, i| {
        paths[i] = gpa.dupeZ(u8, std.mem.sliceTo(p, 0)) catch {
            for (paths[0..i]) |prev| gpa.free(prev);
            gpa.free(paths);
            on_done(ctx, false, "sin memoria");
            return;
        };
    }
    const job = gpa.create(TransferJob) catch {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
        on_done(ctx, false, "sin memoria");
        return;
    };
    job.* = .{
        .src_paths = paths,
        .dst_dir = gpa.dupeZ(u8, std.mem.sliceTo(dst_dir, 0)) catch {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .overwrite = overwrite,
        .is_move = is_move,
        .ctx = ctx,
        .on_progress = on_progress,
        .on_done = on_done,
    };
    const thread = std.Thread.spawn(.{}, transferThread, .{job}) catch {
        freeJob(job);
        on_done(ctx, false, "no se pudo crear hilo");
        return;
    };
    thread.detach();
}

fn freeJob(job: *TransferJob) void {
    for (job.src_paths) |p| gpa.free(p);
    gpa.free(job.src_paths);
    gpa.free(job.dst_dir);
    gpa.destroy(job);
}

fn transferThread(job: *TransferJob) void {
    defer freeJob(job);
    runTransfer(job) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: {}", .{err}) catch "error desconocido";
        job.on_done(job.ctx, false, msg.ptr);
    };
}

fn runTransfer(job: *TransferJob) !void {
    const io = getIo();
    const raw_dst = std.mem.sliceTo(job.dst_dir, 0);

    // Destination needs a trailing slash: rsync copies sources *into* the dir.
    const dst_with_slash = if (std.mem.endsWith(u8, raw_dst, "/"))
        try gpa.dupeZ(u8, raw_dst)
    else
        try std.fmt.allocPrintSentinel(gpa, "{s}/", .{raw_dst}, 0);
    defer gpa.free(dst_with_slash);

    var argv = std.array_list.Managed([]const u8).init(gpa);
    defer argv.deinit();

    try argv.append("/usr/bin/rsync");
    try argv.append("-a"); // archive: recursive, preserve attrs/symlinks/perms
    try argv.append("-v"); // verbose: list files being transferred
    try argv.append("--progress"); // per-file progress output
    if (!job.overwrite) try argv.append("--ignore-existing");
    if (job.is_move) try argv.append("--remove-source-files"); // atomic move

    for (job.src_paths) |p| try argv.append(std.mem.sliceTo(p, 0));
    try argv.append(std.mem.sliceTo(dst_with_slash, 0));

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Drain stderr in a separate thread so the pipe never fills and deadlocks rsync.
    const DrainCtx = struct {
        file: File,
        io_handle: Io,
        buf: [8192]u8 = undefined,
        len: usize = 0,
        fn run(ctx: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            while (true) {
                const n = ctx.file.readStreaming(ctx.io_handle, &.{&read_buf}) catch break;
                if (n == 0) break;
                const space = ctx.buf.len - 1 - ctx.len;
                if (space > 0) {
                    const copy_len = @min(n, space);
                    @memcpy(ctx.buf[ctx.len .. ctx.len + copy_len], read_buf[0..copy_len]);
                    ctx.len += copy_len;
                }
            }
        }
    };

    var stderrCtx = DrainCtx{ .file = child.stderr.?, .io_handle = io };
    const stderrThread = try std.Thread.spawn(.{}, DrainCtx.run, .{&stderrCtx});

    // Read stdout, parsing rsync --progress per-file output.
    // Format: "  10485760 100%  352.23MB/s   00:00:00 (xfer#1, to-check=5/10)"
    {
        const stdout = child.stdout.?;
        var line_buf: [1024]u8 = undefined;
        var line_len: usize = 0;
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n' or byte == '\r') {
                    if (line_len > 0) {
                        const info = parseRsyncProgress(line_buf[0..line_len]);
                        if (info.overall_progress != null) {
                            job.on_progress(
                                job.ctx,
                                info.overall_progress.?,
                                info.bytes,
                                0,
                                info.speed,
                                info.eta,
                            );
                        }
                        line_len = 0;
                    }
                } else {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = byte;
                        line_len += 1;
                    }
                }
            }
        }
    }

    stderrThread.join();

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c2| c2,
        else => 255,
    };
    const success = exit_code == 0;

    if (!success) {
        const se = std.mem.trim(u8, stderrCtx.buf[0..stderrCtx.len], " \t\r\n");
        var eb: [512]u8 = undefined;
        const msg = if (se.len > 0)
            std.fmt.bufPrintZ(&eb, "rsync: {s}", .{se}) catch "rsync falló"
        else
            std.fmt.bufPrintZ(&eb, "rsync salió con código {d}", .{exit_code}) catch "rsync falló";
        job.on_done(job.ctx, false, msg.ptr);
        return;
    }

    // For a move, --remove-source-files only removes files (not empty dirs).
    // Clean up leftover empty directories.
    if (job.is_move) {
        for (job.src_paths) |p| {
            const src = std.mem.sliceTo(p, 0);
            var rmc = try std.process.spawn(io, .{
                .argv = &.{ "/bin/rm", "-rf", src },
                .stdout = .ignore,
                .stderr = .ignore,
            });
            _ = rmc.wait(io) catch {};
        }
    }

    job.on_done(job.ctx, true, null);
}

// ---------------------------------------------------------------------------
// zig_delete_files
// ---------------------------------------------------------------------------

export fn zig_delete_files(
    paths: [*]const [*:0]const u8,
    count: u64,
    err_buf: [*]u8,
    err_buf_len: u64,
) bool {
    const io = getIo();
    for (paths[0..count]) |p| {
        const path_slice = std.mem.sliceTo(p, 0);
        var child = std.process.spawn(io, .{
            .argv = &.{ "/bin/rm", "-rf", path_slice },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "no se pudo eliminar: {s}", .{path_slice}) catch {};
            return false;
        };
        const term = child.wait(io) catch {
            _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "no se pudo eliminar: {s}", .{path_slice}) catch {};
            return false;
        };
        switch (term) {
            .exited => |code| if (code != 0) {
                _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "rm falló en: {s}", .{path_slice}) catch {};
                return false;
            },
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// zig_create_directory
// ---------------------------------------------------------------------------

export fn zig_create_directory(path: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) bool {
    const io = getIo();
    Dir.createDirAbsolute(io,std.mem.sliceTo(path, 0), File.Permissions.default_dir) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// zig_rename
// ---------------------------------------------------------------------------

export fn zig_rename(src: [*:0]const u8, dst: [*:0]const u8, err_buf: [*]u8, err_buf_len: u64) bool {
    const io = getIo();
    Dir.renameAbsolute(std.mem.sliceTo(src, 0), std.mem.sliceTo(dst, 0), io) catch |err| {
        _ = std.fmt.bufPrint(err_buf[0..err_buf_len], "error: {}", .{err}) catch {};
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Compress / Uncompress  (async, 7zz-based)
// ---------------------------------------------------------------------------

const ArchiveJob = struct {
    sevenzz_path: [:0]u8,
    src_paths: ?[][:0]u8, // null for uncompress
    archive_path: [:0]u8, // dst archive (compress) or src archive (uncompress)
    dst_dir: ?[:0]u8, // only for uncompress
    is_compress: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
};

export fn zig_compress(
    sevenzz_path: [*:0]const u8,
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_archive: [*:0]const u8,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    var paths = gpa.alloc([:0]u8, src_count) catch {
        on_done(ctx, false, "sin memoria");
        return;
    };
    for (src_paths[0..src_count], 0..) |p, i| {
        paths[i] = gpa.dupeZ(u8, std.mem.sliceTo(p, 0)) catch {
            for (paths[0..i]) |prev| gpa.free(prev);
            gpa.free(paths);
            on_done(ctx, false, "sin memoria");
            return;
        };
    }
    const job = gpa.create(ArchiveJob) catch {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
        on_done(ctx, false, "sin memoria");
        return;
    };
    job.* = .{
        .sevenzz_path = gpa.dupeZ(u8, std.mem.sliceTo(sevenzz_path, 0)) catch {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .src_paths = paths,
        .archive_path = gpa.dupeZ(u8, std.mem.sliceTo(dst_archive, 0)) catch {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .dst_dir = null,
        .is_compress = true,
        .ctx = ctx,
        .on_progress = on_progress,
        .on_done = on_done,
    };
    const thread = std.Thread.spawn(.{}, archiveThread, .{job}) catch {
        freeArchiveJob(job);
        on_done(ctx, false, "no se pudo crear hilo");
        return;
    };
    thread.detach();
}

export fn zig_uncompress(
    sevenzz_path: [*:0]const u8,
    archive_path: [*:0]const u8,
    dst_dir: [*:0]const u8,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) void {
    const job = gpa.create(ArchiveJob) catch {
        on_done(ctx, false, "sin memoria");
        return;
    };
    job.* = .{
        .sevenzz_path = gpa.dupeZ(u8, std.mem.sliceTo(sevenzz_path, 0)) catch {
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .src_paths = null,
        .archive_path = gpa.dupeZ(u8, std.mem.sliceTo(archive_path, 0)) catch {
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .dst_dir = gpa.dupeZ(u8, std.mem.sliceTo(dst_dir, 0)) catch {
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
        .is_compress = false,
        .ctx = ctx,
        .on_progress = on_progress,
        .on_done = on_done,
    };
    const thread = std.Thread.spawn(.{}, archiveThread, .{job}) catch {
        freeArchiveJob(job);
        on_done(ctx, false, "no se pudo crear hilo");
        return;
    };
    thread.detach();
}

fn freeArchiveJob(job: *ArchiveJob) void {
    if (job.src_paths) |paths| {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
    gpa.free(job.sevenzz_path);
    gpa.free(job.archive_path);
    if (job.dst_dir) |d| gpa.free(d);
    gpa.destroy(job);
}

fn archiveThread(job: *ArchiveJob) void {
    defer freeArchiveJob(job);
    runArchive(job) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "Error: {}", .{err}) catch "error desconocido";
        job.on_done(job.ctx, false, msg.ptr);
    };
}

fn runArchive(job: *ArchiveJob) !void {
    const io = getIo();
    var argv = std.array_list.Managed([]const u8).init(gpa);
    defer argv.deinit();

    try argv.append(std.mem.sliceTo(job.sevenzz_path, 0));

    if (job.is_compress) {
        try argv.append("a");
        try argv.append("-y");
        try argv.append("-bsp1"); // enable progress to stdout
        try argv.append(std.mem.sliceTo(job.archive_path, 0));
        if (job.src_paths) |paths| {
            for (paths) |p| try argv.append(std.mem.sliceTo(p, 0));
        }
    } else {
        try argv.append("x");
        try argv.append("-y");
        try argv.append("-bsp1"); // enable progress to stdout
        try argv.append(std.mem.sliceTo(job.archive_path, 0));
    }

    // Build -o flag outside the if/else so its lifetime covers spawn+wait
    var out_flag: ?[]u8 = null;
    defer if (out_flag) |f| gpa.free(f);
    if (!job.is_compress) {
        out_flag = try std.fmt.allocPrint(gpa, "-o{s}", .{
            std.mem.sliceTo(job.dst_dir.?, 0),
        });
        // Insert -o flag before the archive path (which is the last element)
        const archive_path = argv.pop().?;
        try argv.append(out_flag.?);
        try argv.append(archive_path);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // Drain stderr in a separate thread (just capture it for error reporting)
    const DrainCtx = struct {
        file: File,
        io_handle: Io,
        buf: [8192]u8 = undefined,
        len: usize = 0,
        fn run(ctx: *@This()) void {
            var read_buf: [4096]u8 = undefined;
            while (true) {
                const n = ctx.file.readStreaming(ctx.io_handle, &.{&read_buf}) catch break;
                if (n == 0) break;
                const space = ctx.buf.len - 1 - ctx.len;
                if (space > 0) {
                    const copy_len = @min(n, space);
                    @memcpy(ctx.buf[ctx.len .. ctx.len + copy_len], read_buf[0..copy_len]);
                    ctx.len += copy_len;
                }
            }
        }
    };

    var stderrCtx = DrainCtx{ .file = child.stderr.?, .io_handle = io };
    const stderrThread = try std.Thread.spawn(.{}, DrainCtx.run, .{&stderrCtx});

    // Read stdout in this thread, parsing 7zz progress lines (e.g. " 42%" or "100%")
    {
        const stdout = child.stdout.?;
        var line_buf: [1024]u8 = undefined;
        var line_len: usize = 0;
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n' or byte == '\r') {
                    if (line_len > 0) {
                        const pct = parseSevenZPercent(line_buf[0..line_len]);
                        if (pct) |p| {
                            job.on_progress(job.ctx, p / 100.0, 0, 0, 0, 0);
                        }
                        line_len = 0;
                    }
                } else {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = byte;
                        line_len += 1;
                    }
                }
            }
        }
    }

    stderrThread.join();

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c2| c2,
        else => 255,
    };
    const success = exit_code == 0;

    if (!success) {
        const se = std.mem.trim(u8, stderrCtx.buf[0..stderrCtx.len], " \t\r\n");
        var eb: [512]u8 = undefined;
        const msg = if (se.len > 0)
            std.fmt.bufPrintZ(&eb, "7zz: {s}", .{se}) catch "7zz falló"
        else
            std.fmt.bufPrintZ(&eb, "7zz salió con código {d}", .{exit_code}) catch "7zz falló";
        job.on_done(job.ctx, false, msg.ptr);
        return;
    }

    job.on_done(job.ctx, true, null);
}

/// Parse a percentage from 7zz progress output lines like " 42%" or "100%".
fn parseSevenZPercent(line: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, line, " \t");
    // Look for a number followed by '%'
    if (std.mem.indexOfScalar(u8, trimmed, '%')) |pct_pos| {
        if (pct_pos == 0) return null;
        // Find the start of the number (scan backwards from '%')
        var start: usize = pct_pos;
        while (start > 0 and (trimmed[start - 1] >= '0' and trimmed[start - 1] <= '9')) {
            start -= 1;
        }
        if (start == pct_pos) return null;
        const num_str = trimmed[start..pct_pos];
        const val = std.fmt.parseInt(u32, num_str, 10) catch return null;
        return @floatFromInt(val);
    }
    return null;
}

const RsyncProgress = struct {
    overall_progress: ?f64 = null, // 0.0 .. 1.0
    bytes: u64 = 0,
    speed: f64 = 0,
    eta: i64 = 0,
};

/// Parse rsync --progress per-file output line.
/// Format: "  10485760 100%  352.23MB/s   00:00:00 (xfer#1, to-check=5/10)"
fn parseRsyncProgress(line: []const u8) RsyncProgress {
    var result = RsyncProgress{};
    const trimmed = std.mem.trim(u8, line, " \t");

    // Split by whitespace and parse each token
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");

    // First token: bytes transferred (may contain commas)
    if (it.next()) |bytes_str| {
        result.bytes = parseCommaNumber(bytes_str);
    } else return result;

    // Second token: percentage (e.g. "100%") — per-file percentage, skip
    _ = it.next() orelse return result;

    // Third token: speed (e.g. "352.23MB/s")
    if (it.next()) |speed_str| {
        result.speed = parseRsyncSpeed(speed_str);
    } else return result;

    // Fourth token: time (e.g. "00:00:00")
    if (it.next()) |eta_str| {
        result.eta = parseTimeToSeconds(eta_str);
    } else return result;

    // Remaining tokens may contain "(xfer#1, to-check=5/10)"
    // Look for "to-check=" in the rest of the line
    if (std.mem.indexOf(u8, trimmed, "to-check=")) |pos| {
        const after = trimmed[pos + "to-check=".len ..];
        // Parse "X/Y)"
        if (std.mem.indexOfScalar(u8, after, '/')) |slash| {
            var end = slash + 1;
            while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
            const checked = std.fmt.parseInt(u64, after[0..slash], 10) catch return result;
            const total = std.fmt.parseInt(u64, after[slash + 1 .. end], 10) catch return result;
            if (total > 0) {
                // macOS openrsync: to-check counts UP (files checked so far)
                result.overall_progress = @as(f64, @floatFromInt(checked)) / @as(f64, @floatFromInt(total));
            }
        }
    }

    return result;
}

fn parseCommaNumber(s: []const u8) u64 {
    var val: u64 = 0;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            val = val * 10 + (ch - '0');
        }
        // skip commas and dots used as thousand separators
    }
    return val;
}

fn parseRsyncSpeed(s: []const u8) f64 {
    // Find where the unit starts (first non-digit, non-dot character)
    var end: usize = 0;
    for (s, 0..) |ch, i| {
        if ((ch >= '0' and ch <= '9') or ch == '.') {
            end = i + 1;
        } else break;
    }
    if (end == 0) return 0;
    const num = parseSimpleFloat(s[0..end]);
    const unit = s[end..];
    if (std.mem.startsWith(u8, unit, "GB/s")) return num * 1024 * 1024 * 1024;
    if (std.mem.startsWith(u8, unit, "MB/s")) return num * 1024 * 1024;
    if (std.mem.startsWith(u8, unit, "kB/s")) return num * 1024;
    return num; // B/s
}

fn parseSimpleFloat(s: []const u8) f64 {
    var int_part: f64 = 0;
    var frac_part: f64 = 0;
    var frac_div: f64 = 1;
    var past_dot = false;
    for (s) |ch| {
        if (ch == '.') {
            past_dot = true;
        } else if (ch >= '0' and ch <= '9') {
            if (past_dot) {
                frac_div *= 10;
                frac_part += @as(f64, @floatFromInt(ch - '0')) / frac_div;
            } else {
                int_part = int_part * 10 + @as(f64, @floatFromInt(ch - '0'));
            }
        }
    }
    return int_part + frac_part;
}

fn parseTimeToSeconds(s: []const u8) i64 {
    // Format: "H:MM:SS" or "M:SS" or just seconds
    var parts: [3]i64 = .{ 0, 0, 0 };
    var part_count: usize = 0;
    var current: i64 = 0;
    for (s) |ch| {
        if (ch == ':') {
            if (part_count < 3) {
                parts[part_count] = current;
                part_count += 1;
            }
            current = 0;
        } else if (ch >= '0' and ch <= '9') {
            current = current * 10 + (ch - '0');
        }
    }
    if (part_count < 3) {
        parts[part_count] = current;
        part_count += 1;
    }
    return switch (part_count) {
        1 => parts[0],
        2 => parts[0] * 60 + parts[1],
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        else => 0,
    };
}

// ===========================================================================
// Unit tests  –  run with:  zig build test-fs
// Each test creates its own subdirectory inside test_dir/, operates on dummy
// files, then cleans up.  test_dir/ itself must exist at the project root.
// ===========================================================================

/// Callback context used by the async copy/move tests.
const DoneCtx = struct {
    done: std.atomic.Value(bool) = .init(false),
    success: std.atomic.Value(bool) = .init(false),

    fn onProgress(_: ?*anyopaque, _: f64, _: u64, _: u64, _: f64, _: i64) callconv(.c) void {}

    fn onDone(raw: ?*anyopaque, ok: bool, _: ?[*:0]const u8) callconv(.c) void {
        const self: *DoneCtx = @ptrCast(@alignCast(raw.?));
        self.success.store(ok, .release);
        self.done.store(true, .release);
    }

    fn wait(self: *DoneCtx) bool {
        while (!self.done.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        return self.success.load(.acquire);
    }
};

fn testBasePath() ![]const u8 {
    const tio = getIo();
    const cwd = try std.process.currentPathAlloc(tio, gpa);
    defer gpa.free(cwd);
    const result = try gpa.alloc(u8, cwd.len + "/test_dir".len);
    @memcpy(result[0..cwd.len], cwd);
    @memcpy(result[cwd.len..], "/test_dir");
    return result;
}

// ---------------------------------------------------------------------------
// zig_create_directory
// ---------------------------------------------------------------------------

test "zig_create_directory creates a new directory" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var pb: [Dir.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/create_test", .{base});
    Dir.deleteTree(.cwd(), io, path) catch {};

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(zig_create_directory(path.ptr, &err_buf, err_buf.len));

    var d = try Dir.openDirAbsolute(io, path, .{});
    d.close(io);

    Dir.deleteTree(.cwd(), io, path) catch {};
}

test "zig_create_directory fails on existing path" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var pb: [Dir.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&pb, "{s}/create_exists", .{base});
    Dir.deleteTree(.cwd(), io, path) catch {};
    Dir.createDirAbsolute(io,path, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, path) catch {};

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(!zig_create_directory(path.ptr, &err_buf, err_buf.len));
}

// ---------------------------------------------------------------------------
// zig_rename
// ---------------------------------------------------------------------------

test "zig_rename renames a file" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var sb: [Dir.max_path_bytes + 1]u8 = undefined;
    var db: [Dir.max_path_bytes + 1]u8 = undefined;
    const src = try std.fmt.bufPrintZ(&sb, "{s}/rename_src.txt", .{base});
    const dst = try std.fmt.bufPrintZ(&db, "{s}/rename_dst.txt", .{base});
    Dir.deleteFileAbsolute(io, src) catch {};
    Dir.deleteFileAbsolute(io, dst) catch {};

    const fh = try Dir.createFileAbsolute(io, src, .{});
    fh.close(io);

    var err_buf: [256]u8 = undefined;
    try std.testing.expect(zig_rename(src.ptr, dst.ptr, &err_buf, err_buf.len));

    // src must be gone, dst must exist
    if (Dir.accessAbsolute(io, src, .{})) |_| return error.SrcStillExists else |_| {}
    try Dir.accessAbsolute(io, dst, .{});
    Dir.deleteFileAbsolute(io, dst) catch {};
}

// ---------------------------------------------------------------------------
// zig_list_directory  +  zig_free_dir_listing
// ---------------------------------------------------------------------------

test "zig_list_directory lists entries, dirs first" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var lb: [Dir.max_path_bytes + 1]u8 = undefined;
    const list_path = try std.fmt.bufPrintZ(&lb, "{s}/list_test", .{base});
    Dir.deleteTree(.cwd(), io, list_path) catch {};
    Dir.createDirAbsolute(io,list_path, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, list_path) catch {};

    // create file.txt then subdir/
    const file_path = try std.fmt.allocPrintSentinel(gpa, "{s}/file.txt", .{list_path}, 0);
    defer gpa.free(file_path);
    const f = try Dir.createFileAbsolute(io, file_path, .{});
    f.writeStreamingAll(io, "hello") catch {};
    f.close(io);

    const sub_path = try std.fmt.allocPrintSentinel(gpa, "{s}/subdir", .{list_path}, 0);
    defer gpa.free(sub_path);
    Dir.createDirAbsolute(io,sub_path, File.Permissions.default_dir) catch {};

    const listing = zig_list_directory(list_path.ptr);
    try std.testing.expect(listing != null);
    defer zig_free_dir_listing(listing);

    try std.testing.expectEqual(@as(u64, 2), listing.?.count);
    // directory comes first
    try std.testing.expect(listing.?.entries[0].is_dir);
    try std.testing.expect(!listing.?.entries[1].is_dir);
    // file has non-zero size
    try std.testing.expect(listing.?.entries[1].size > 0);
}

test "zig_list_directory returns null for non-existent path" {
    const bad: [*:0]const u8 = "/tmp/__nonexistent_rs2finder_xyz__";
    try std.testing.expect(zig_list_directory(bad) == null);
}

// ---------------------------------------------------------------------------
// zig_check_collision
// ---------------------------------------------------------------------------

test "zig_check_collision detects name clash" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var db: [Dir.max_path_bytes + 1]u8 = undefined;
    const dst = try std.fmt.bufPrintZ(&db, "{s}/collision_dst", .{base});
    Dir.deleteTree(.cwd(), io, dst) catch {};
    Dir.createDirAbsolute(io,dst, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst) catch {};

    // place clash.txt inside dst
    const clash = try std.fmt.allocPrintSentinel(gpa, "{s}/clash.txt", .{dst}, 0);
    defer gpa.free(clash);
    const fh = try Dir.createFileAbsolute(io, clash, .{});
    fh.close(io);

    // src has same basename → should collide
    var src1b: [Dir.max_path_bytes + 1]u8 = undefined;
    const src1 = try std.fmt.bufPrintZ(&src1b, "/tmp/clash.txt", .{});
    const ptrs1 = [_][*:0]const u8{src1.ptr};
    try std.testing.expect(zig_check_collision(&ptrs1, 1, dst.ptr));

    // src with different basename → no collision
    var src2b: [Dir.max_path_bytes + 1]u8 = undefined;
    const src2 = try std.fmt.bufPrintZ(&src2b, "/tmp/unique_xyz_rs2finder.txt", .{});
    const ptrs2 = [_][*:0]const u8{src2.ptr};
    try std.testing.expect(!zig_check_collision(&ptrs2, 1, dst.ptr));
}

// ---------------------------------------------------------------------------
// zig_get_volumes  +  zig_free_volume_list
// ---------------------------------------------------------------------------

test "zig_get_volumes returns a non-null list" {
    const list = zig_get_volumes();
    try std.testing.expect(list != null);
    zig_free_volume_list(list);
}

// ---------------------------------------------------------------------------
// zig_get_special_dirs
// ---------------------------------------------------------------------------

test "zig_get_special_dirs includes home directory" {
    const list = zig_get_special_dirs();
    try std.testing.expect(list != null);
    defer zig_free_volume_list(list);
    try std.testing.expect(list.?.count > 0);
}

// ---------------------------------------------------------------------------
// zig_copy_files  (async via rsync)
// ---------------------------------------------------------------------------

test "zig_copy_files copies file to destination" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io,src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io,dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.writeStreamingAll(io, "hello from rs_2finder\n") catch {};
    fh.close(io);

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_copy_files(&ptrs, 1, dst_dir.ptr, true, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst has the copy
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);
    try Dir.accessAbsolute(io, dst_file, .{});
    // original still present
    try Dir.accessAbsolute(io, src_file, .{});
}

test "zig_copy_files respects overwrite=false" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_noow_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_noow_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io,src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io,dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/data.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/data.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);

    // write "original" to dst first
    const pre = try Dir.createFileAbsolute(io, dst_file, .{});
    pre.writeStreamingAll(io, "original") catch {};
    pre.close(io);

    // write "new" to src
    const sf = try Dir.createFileAbsolute(io, src_file, .{});
    sf.writeStreamingAll(io, "new") catch {};
    sf.close(io);

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    // overwrite = false → rsync --ignore-existing
    zig_copy_files(&ptrs, 1, dst_dir.ptr, false, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst content should still be "original"
    const df = try Dir.openFileAbsolute(io, dst_file, .{});
    defer df.close(io);
    var content: [64]u8 = undefined;
    const n = df.readStreaming(io, &.{&content}) catch 0;
    try std.testing.expectEqualStrings("original", content[0..n]);
}

// ---------------------------------------------------------------------------
// zig_move_files  (async via rsync --remove-source-files)
// ---------------------------------------------------------------------------

test "zig_move_files moves file, removes source" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/move_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/move_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io,src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io,dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.writeStreamingAll(io, "move me\n") catch {};
    fh.close(io);

    var ctx = DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_move_files(&ptrs, 1, dst_dir.ptr, true, &ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst has the file
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);
    try Dir.accessAbsolute(io, dst_file, .{});
    // src file is gone
    if (Dir.accessAbsolute(io, src_file, .{})) |_| return error.SrcFileStillExists else |_| {}
}

// ---------------------------------------------------------------------------
// zig_delete_files
// ---------------------------------------------------------------------------

test "zig_delete_files removes a file" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);
    var pb: [Dir.max_path_bytes + 1]u8 = undefined;
    const del_file = try std.fmt.bufPrintZ(&pb, "{s}/delete_me.txt", .{base});

    const fh = try Dir.createFileAbsolute(io, del_file, .{});
    fh.close(io);

    var err_buf: [256]u8 = undefined;
    const ptrs = [_][*:0]const u8{del_file.ptr};
    try std.testing.expect(zig_delete_files(&ptrs, 1, &err_buf, err_buf.len));
    if (Dir.accessAbsolute(io, del_file, .{})) |_| return error.FileStillExists else |_| {}
}

// ---------------------------------------------------------------------------
// zig_compress + zig_uncompress
// ---------------------------------------------------------------------------

test "zig_compress and zig_uncompress round-trip" {
    const io = getIo();
    const base = try testBasePath();
    defer gpa.free(base);

    // Setup: create a directory with a dummy file
    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    const work_dir = try std.fmt.bufPrintZ(&srcb, "{s}/compress_test", .{base});
    Dir.deleteTree(.cwd(), io, work_dir) catch {};
    Dir.createDirAbsolute(io, work_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, work_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{work_dir}, 0);
    defer gpa.free(src_file);
    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.writeStreamingAll(io, "hello 7z world\n") catch {};
    fh.close(io);

    // Find the 7zz binary (relative to project root)
    const tio = getIo();
    const cwd_path = try std.process.currentPathAlloc(tio, gpa);
    defer gpa.free(cwd_path);
    const sevenzz = try std.fmt.allocPrintSentinel(gpa, "{s}/bin/7zz", .{cwd_path}, 0);
    defer gpa.free(sevenzz);

    // 1) Compress
    const archive = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.7z", .{work_dir}, 0);
    defer gpa.free(archive);

    var comp_ctx = DoneCtx{};
    const comp_ptrs = [_][*:0]const u8{src_file.ptr};
    zig_compress(sevenzz, &comp_ptrs, 1, archive.ptr, &comp_ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(comp_ctx.wait());

    // Archive must exist
    try Dir.accessAbsolute(io, archive, .{});

    // 2) Delete original file so we can verify the uncompress recreates it
    Dir.deleteFileAbsolute(io, src_file) catch {};

    // 3) Uncompress into a sub-directory
    const extract_dir = try std.fmt.allocPrintSentinel(gpa, "{s}/extracted", .{work_dir}, 0);
    defer gpa.free(extract_dir);

    var decomp_ctx = DoneCtx{};
    zig_uncompress(sevenzz, archive.ptr, extract_dir.ptr, &decomp_ctx, DoneCtx.onProgress, DoneCtx.onDone);
    try std.testing.expect(decomp_ctx.wait());

    // The extracted file must exist
    const extracted_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{extract_dir}, 0);
    defer gpa.free(extracted_file);
    try Dir.accessAbsolute(io, extracted_file, .{});

    // Verify content
    const df = try Dir.openFileAbsolute(io, extracted_file, .{});
    defer df.close(io);
    var content: [64]u8 = undefined;
    const n = df.readStreaming(io, &.{&content}) catch 0;
    try std.testing.expectEqualStrings("hello 7z world\n", content[0..n]);
}
