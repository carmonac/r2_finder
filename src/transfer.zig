// transfer.zig
// Async file copy/move operations via rsync, plus collision detection

const std = @import("std");
const root = @import("fs_ops.zig");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const gpa = root.gpa;
const getIo = root.getIo;
const ZigProgressCallback = root.ZigProgressCallback;
const ZigCompletionCallback = root.ZigCompletionCallback;

// ---------------------------------------------------------------------------
// zig_check_collision
// ---------------------------------------------------------------------------

pub fn zig_check_collision(
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
) callconv(.c) bool {
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
    rsync_path: [:0]u8,
    src_paths: [][:0]u8,
    dst_dir: [:0]u8,
    overwrite: bool,
    is_move: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
};

pub fn zig_copy_files(
    rsync_path: [*:0]const u8,
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) callconv(.c) void {
    spawnTransfer(rsync_path, src_paths, src_count, dst_dir, overwrite, false, ctx, on_progress, on_done);
}

pub fn zig_move_files(
    rsync_path: [*:0]const u8,
    src_paths: [*]const [*:0]const u8,
    src_count: u64,
    dst_dir: [*:0]const u8,
    overwrite: bool,
    ctx: ?*anyopaque,
    on_progress: ZigProgressCallback,
    on_done: ZigCompletionCallback,
) callconv(.c) void {
    spawnTransfer(rsync_path, src_paths, src_count, dst_dir, overwrite, true, ctx, on_progress, on_done);
}

fn spawnTransfer(
    rsync_path: [*:0]const u8,
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
        .rsync_path = gpa.dupeZ(u8, std.mem.sliceTo(rsync_path, 0)) catch {
            for (paths) |p| gpa.free(p);
            gpa.free(paths);
            gpa.destroy(job);
            on_done(ctx, false, "sin memoria");
            return;
        },
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
    gpa.free(job.rsync_path);
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

    try argv.append(job.rsync_path);
    try argv.append("-a"); // archive: recursive, preserve attrs/symlinks/perms
    try argv.append("--info=progress2"); // overall progress
    try argv.append("--no-inc-recursive"); // scan all files upfront for accurate totals
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

    // Read stdout, parsing rsync --info=progress2 output.
    // Format: "  104857600  50%  399.88MB/s    0:00:00 (xfr#10, to-chk=10/21)"
    // Intermediate lines may lack the "(xfr#..., to-chk=...)" part.
    // The percentage is overall progress; the time field is elapsed (not ETA).
    //
    // After data transfer completes (100%), rsync keeps running while the OS
    // flushes writes to disk. During this phase we send progress > 1.0 so the
    // UI can show "Sincronizando…" with an indeterminate progress bar.
    // Timer context: when we first hit 100%, spawn a thread that waits
    // briefly and then sends the sync-phase signal. This is needed because
    // rsync keeps stdout open until process exit — the readStreaming loop
    // blocks during the OS write-cache flush, so we can't signal from there.
    const SyncSignalCtx = struct {
        job_ptr: *TransferJob,
        fn run(ctx: *@This()) void {
            // Wait a moment — if rsync exits quickly (SSD), doneCb will close
            // the window before this fires. On slow media, this switches the UI
            // to "Sincronizando…" during the flush.
            // Sleep 500ms using libc nanosleep (Zig 0.16 sleep requires Io)
            var ts = std.c.timespec{ .sec = 0, .nsec = 500_000_000 };
            _ = std.c.nanosleep(&ts, &ts);
            ctx.job_ptr.on_progress(ctx.job_ptr.ctx, 1.5, 0, 0, 0, 0);
        }
    };
    var sync_signal_ctx = SyncSignalCtx{ .job_ptr = job };
    var sync_thread: ?std.Thread = null;

    {
        const stdout = child.stdout.?;
        var line_buf: [1024]u8 = undefined;
        var line_len: usize = 0;
        var read_buf: [4096]u8 = undefined;
        var sent_complete = false;
        while (true) {
            const n = stdout.readStreaming(io, &.{&read_buf}) catch break;
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n' or byte == '\r') {
                    if (line_len > 0) {
                        const info = parseRsyncProgress(line_buf[0..line_len]);
                        if (info.progress >= 0) {
                            if (info.progress >= 1.0 and !sent_complete) {
                                sent_complete = true;
                                // Report the final 100% progress
                                const total_bytes: u64 = if (info.progress > 0)
                                    @intFromFloat(@as(f64, @floatFromInt(info.bytes)) / info.progress)
                                else
                                    0;
                                job.on_progress(
                                    job.ctx,
                                    info.progress,
                                    info.bytes,
                                    total_bytes,
                                    info.speed,
                                    0,
                                );
                                // Spawn timer thread to signal sync phase after 500ms
                                sync_thread = std.Thread.spawn(.{}, SyncSignalCtx.run, .{&sync_signal_ctx}) catch null;
                            } else if (!sent_complete) {
                                // Normal progress (< 100%)
                                var eta: i64 = 0;
                                if (info.speed > 0 and info.progress > 0 and info.progress < 1.0) {
                                    const total_est = @as(f64, @floatFromInt(info.bytes)) / info.progress;
                                    const remaining = total_est - @as(f64, @floatFromInt(info.bytes));
                                    eta = @intFromFloat(remaining / info.speed);
                                }
                                const total_bytes: u64 = if (info.progress > 0)
                                    @intFromFloat(@as(f64, @floatFromInt(info.bytes)) / info.progress)
                                else
                                    0;
                                job.on_progress(
                                    job.ctx,
                                    info.progress,
                                    info.bytes,
                                    total_bytes,
                                    info.speed,
                                    eta,
                                );
                            }
                            // After sent_complete, ignore further lines (timer handles sync UI)
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

    // Join the sync signal timer thread (if spawned) before we return,
    // since sync_signal_ctx lives on our stack.
    if (sync_thread) |t| t.join();

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
// rsync progress parsing
// ---------------------------------------------------------------------------

const RsyncProgress = struct {
    progress: f64 = -1, // 0.0 .. 1.0, negative = not a progress line
    bytes: u64 = 0,
    speed: f64 = 0,
};

/// Parse rsync --info=progress2 output line.
/// Format: "  104857600  50%  399.88MB/s    0:00:00 (xfr#10, to-chk=10/21)"
/// The percentage is overall transfer progress. Intermediate lines may omit the (xfr...) part.
fn parseRsyncProgress(line: []const u8) RsyncProgress {
    var result = RsyncProgress{};
    const trimmed = std.mem.trim(u8, line, " \t");

    // Split by whitespace and parse each token
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");

    // First token: bytes transferred (may contain commas)
    const bytes_str = it.next() orelse return result;
    result.bytes = parseCommaNumber(bytes_str);

    // Second token: percentage (e.g. "50%") — with --info=progress2 this is overall progress
    const pct_str = it.next() orelse return result;
    if (std.mem.indexOfScalar(u8, pct_str, '%')) |pct_pos| {
        if (pct_pos > 0) {
            const val = std.fmt.parseInt(u32, pct_str[0..pct_pos], 10) catch return result;
            result.progress = @as(f64, @floatFromInt(val)) / 100.0;
        }
    } else return result;

    // Third token: speed (e.g. "352.23MB/s")
    if (it.next()) |speed_str| {
        result.speed = parseRsyncSpeed(speed_str);
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

// ===========================================================================
// Tests
// ===========================================================================

test "zig_check_collision detects name clash" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/coll_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/coll_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io, src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io, dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/dup.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/dup.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);

    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.close(io);
    const fh2 = try Dir.createFileAbsolute(io, dst_file, .{});
    fh2.close(io);

    const ptrs = [_][*:0]const u8{src_file.ptr};
    try std.testing.expect(zig_check_collision(&ptrs, 1, dst_dir.ptr));
}

test "zig_copy_files copies file to destination" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io, src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io, dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/hello.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.writeStreamingAll(io, "hello from rs_2finder\n") catch {};
    fh.close(io);

    const rsync = try root.testRsyncPath();
    defer gpa.free(rsync);

    var ctx = root.DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_copy_files(rsync, &ptrs, 1, dst_dir.ptr, true, &ctx, root.DoneCtx.onProgress, root.DoneCtx.onDone);
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
    const base = try root.testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/copy_noow_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/copy_noow_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io, src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io, dst_dir, File.Permissions.default_dir) catch {};
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

    const rsync = try root.testRsyncPath();
    defer gpa.free(rsync);

    var ctx = root.DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    // overwrite = false → rsync --ignore-existing
    zig_copy_files(rsync, &ptrs, 1, dst_dir.ptr, false, &ctx, root.DoneCtx.onProgress, root.DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst content should still be "original"
    const df = try Dir.openFileAbsolute(io, dst_file, .{});
    defer df.close(io);
    var content: [64]u8 = undefined;
    const n = df.readStreaming(io, &.{&content}) catch 0;
    try std.testing.expectEqualStrings("original", content[0..n]);
}

test "zig_move_files moves file, removes source" {
    const io = getIo();
    const base = try root.testBasePath();
    defer gpa.free(base);

    var srcb: [Dir.max_path_bytes + 1]u8 = undefined;
    var dstb: [Dir.max_path_bytes + 1]u8 = undefined;
    const src_dir = try std.fmt.bufPrintZ(&srcb, "{s}/move_src", .{base});
    const dst_dir = try std.fmt.bufPrintZ(&dstb, "{s}/move_dst", .{base});
    Dir.deleteTree(.cwd(), io, src_dir) catch {};
    Dir.deleteTree(.cwd(), io, dst_dir) catch {};
    Dir.createDirAbsolute(io, src_dir, File.Permissions.default_dir) catch {};
    Dir.createDirAbsolute(io, dst_dir, File.Permissions.default_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, src_dir) catch {};
    defer Dir.deleteTree(.cwd(), io, dst_dir) catch {};

    const src_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{src_dir}, 0);
    defer gpa.free(src_file);
    const fh = try Dir.createFileAbsolute(io, src_file, .{});
    fh.writeStreamingAll(io, "move me\n") catch {};
    fh.close(io);

    const rsync = try root.testRsyncPath();
    defer gpa.free(rsync);

    var ctx = root.DoneCtx{};
    const ptrs = [_][*:0]const u8{src_file.ptr};
    zig_move_files(rsync, &ptrs, 1, dst_dir.ptr, true, &ctx, root.DoneCtx.onProgress, root.DoneCtx.onDone);
    try std.testing.expect(ctx.wait());

    // dst has the file
    const dst_file = try std.fmt.allocPrintSentinel(gpa, "{s}/move_me.txt", .{dst_dir}, 0);
    defer gpa.free(dst_file);
    try Dir.accessAbsolute(io, dst_file, .{});
    // src file is gone
    if (Dir.accessAbsolute(io, src_file, .{})) |_| return error.SrcFileStillExists else |_| {}
}
