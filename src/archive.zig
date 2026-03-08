// archive.zig
// Async compress/uncompress operations via 7zz

const std = @import("std");
const root = @import("fs_ops.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const gpa = root.gpa;
const getIo = root.getIo;
const ZigProgressCallback = root.ZigProgressCallback;
const ZigCompletionCallback = root.ZigCompletionCallback;

const ArchiveJob = struct {
    sevenzz_path: [:0]u8,
    src_paths: ?[][:0]u8, // null for uncompress
    archive_path: [:0]u8, // dst archive (compress) or src archive (uncompress)
    dst_dir: ?[:0]u8, // only for uncompress
    is_compress: bool,
    volume_size_mb: u32, // 0 = no split, >0 = split into volumes of this size
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
};

pub fn zig_compress(
    sevenzz_path: [*:0]const u8,
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_archive: [*:0]const u8,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) callconv(.c) void {
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
        .volume_size_mb = 0,
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

pub fn zig_compress_split(
    sevenzz_path: [*:0]const u8,
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_archive: [*:0]const u8,
    volume_size_mb: u32,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) callconv(.c) void {
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
        .volume_size_mb = volume_size_mb,
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

pub fn zig_uncompress(
    sevenzz_path: [*:0]const u8,
    archive_path: [*:0]const u8,
    dst_dir: [*:0]const u8,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) callconv(.c) void {
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
        .volume_size_mb = 0,
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

    // Build -v flag outside the if/else so its lifetime covers spawn+wait
    var vol_flag: ?[]u8 = null;
    defer if (vol_flag) |f| gpa.free(f);

    if (job.is_compress) {
        try argv.append("a");
        try argv.append("-y");
        try argv.append("-bsp1"); // enable progress to stdout
        if (job.volume_size_mb > 0) {
            vol_flag = try std.fmt.allocPrint(gpa, "-v{d}m", .{job.volume_size_mb});
            try argv.append(vol_flag.?);
        }
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

// ===========================================================================
// Tests
// ===========================================================================

test "zig_compress and zig_uncompress round-trip" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var wb: [Dir.max_path_bytes + 1]u8 = undefined;
    const work_dir = try std.fmt.bufPrintZ(&wb, "{s}/archive_test", .{base});
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

    var comp_ctx = root.DoneCtx{};
    const comp_ptrs = [_][*:0]const u8{src_file.ptr};
    zig_compress(sevenzz, &comp_ptrs, 1, archive.ptr, &comp_ctx, root.DoneCtx.onProgress, root.DoneCtx.onDone);
    try std.testing.expect(comp_ctx.wait());

    // Archive must exist
    try Dir.accessAbsolute(io, archive, .{});

    // 2) Delete original file so we can verify the uncompress recreates it
    Dir.deleteFileAbsolute(io, src_file) catch {};

    // 3) Uncompress
    var unc_ctx = root.DoneCtx{};
    zig_uncompress(sevenzz, archive.ptr, work_dir.ptr, &unc_ctx, root.DoneCtx.onProgress, root.DoneCtx.onDone);
    try std.testing.expect(unc_ctx.wait());

    // Original file should be back
    try Dir.accessAbsolute(io, src_file, .{});
}
