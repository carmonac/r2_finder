const std = @import("std");

// R2 Finder – macOS Finder clone
// Build with:  zig build
// Run  with:   zig build run
// App bundle:  zig build bundle  →  zig-out/R2 Finder.app
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "App version string for Info.plist") orelse "0.0.0-dev";

    // ── Executable ───────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "rs_2finder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const mod = exe.root_module;

    // ── Objective-C source files ─────────────────────────────────────────────
    const objc_flags = &[_][]const u8{
        "-fobjc-arc",
        "-std=gnu11",
        "-fno-sanitize=undefined",
    };

    mod.addCSourceFiles(.{
        .files = &[_][]const u8{
            "objc/AppDelegate.m",
            "objc/FinderWindowController.m",
            "objc/SidebarViewController.m",
            "objc/FileViewController.m",
            "objc/ProgressWindowController.m",
            "objc/GoToFolderPanel.m",
        },
        .flags = objc_flags,
    });

    // ── Include paths ────────────────────────────────────────────────────────
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("objc"));

    // ── macOS frameworks ─────────────────────────────────────────────────────
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("UniformTypeIdentifiers", .{});
    mod.linkFramework("Quartz", .{});
    mod.linkFramework("CoreServices", .{});

    // ── libc (required for ObjC runtime) ────────────────────────────────────
    mod.link_libc = true;

    // ── Install ──────────────────────────────────────────────────────────────
    b.installArtifact(exe);

    // ── zig build run ────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Compilar y ejecutar rs_2finder");
    run_step.dependOn(&run_cmd.step);

    // ── zig build bundle  (creates R2 Finder.app in zig-out/) ───────────────
    const bundle_step = b.step("bundle", "Crear R2 Finder.app en zig-out/");
    const bundle = makeBundleStep(b, exe, version);
    bundle_step.dependOn(bundle);

    // ── zig build test / test-fs  (Zig unit tests, no ObjC deps needed) ─────
    const fs_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fs_ops.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_tests = b.addTest(.{ .root_module = fs_test_mod });
    const run_fs_tests = b.addRunArtifact(fs_tests);
    const fs_test_step = b.step("test-fs", "Ejecutar los tests unitarios de fs_ops");
    fs_test_step.dependOn(&run_fs_tests.step);
    const test_step = b.step("test", "Ejecutar todos los tests unitarios de Zig");
    test_step.dependOn(&run_fs_tests.step);
}

// ─────────────────────────────────────────────────────────────────────────────
// Bundle helper – builds "R2 Finder.app"/{Contents/{MacOS,Resources},Info.plist}
// ─────────────────────────────────────────────────────────────────────────────
fn makeBundleStep(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) *std.Build.Step {
    // Strip a leading 'v' from tag-style versions (e.g. "v1.4.0" -> "1.4.0")
    const clean_version = if (version.len > 0 and version[0] == 'v') version[1..] else version;

    // 1) Write Info.plist
    const plist = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\ "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleName</key>              <string>R2 Finder</string>
        \\  <key>CFBundleDisplayName</key>       <string>R2 Finder</string>
        \\  <key>CFBundleIdentifier</key>        <string>com.example.r2finder</string>
        \\  <key>CFBundleVersion</key>           <string>{s}</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleExecutable</key>        <string>rs_2finder</string>
        \\  <key>CFBundleIconFile</key>          <string>AppIcon</string>
        \\  <key>CFBundlePackageType</key>       <string>APPL</string>
        \\  <key>CFBundleSignature</key>         <string>????</string>
        \\  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
        \\  <key>NSHighResolutionCapable</key>   <true/>
        \\  <key>NSPrincipalClass</key>          <string>NSApplication</string>
        \\  <key>NSSupportsAutomaticTermination</key><false/>
        \\  <key>NSAppleEventsUsageDescription</key>
        \\    <string>R2 Finder uses AppleScript to move files to the Trash.</string>
        \\</dict>
        \\</plist>
    , .{ clean_version, clean_version });
    const gen_plist = b.addWriteFile("Info.plist", plist);
    const install_plist = b.addInstallFile(
        gen_plist.getDirectory().path(b, "Info.plist"),
        "R2 Finder.app/Contents/Info.plist",
    );
    install_plist.step.dependOn(&gen_plist.step);

    // 2) Copy executable into bundle
    const copy_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "R2 Finder.app/Contents/MacOS" } },
    });
    copy_exe.step.dependOn(&exe.step);

    // 3) Copy AppIcon.icns into Resources/
    const copy_icon = b.addInstallFile(
        b.path("AppIcon.icns"),
        "R2 Finder.app/Contents/Resources/AppIcon.icns",
    );

    // 3b) Copy r2_finder.png into Resources/
    const copy_logo = b.addInstallFile(
        b.path("r2_finder.png"),
        "R2 Finder.app/Contents/Resources/r2_finder.png",
    );

    // 4) Copy 7zz binary into Resources/
    const copy_7zz = b.addInstallFile(
        b.path("bin/7zz"),
        "R2 Finder.app/Contents/Resources/7zz",
    );

    // 5) Copy rsync binary into Resources/
    const copy_rsync = b.addInstallFile(
        b.path("bin/rsync"),
        "R2 Finder.app/Contents/Resources/rsync",
    );

    // Combine into a single step via a dummy WriteFile
    const done = b.addWriteFile("R2 Finder.app/.built", "ok");
    done.step.dependOn(&install_plist.step);
    done.step.dependOn(&copy_exe.step);
    done.step.dependOn(&copy_icon.step);
    done.step.dependOn(&copy_7zz.step);
    done.step.dependOn(&copy_rsync.step);
    done.step.dependOn(&copy_logo.step);
    return &done.step;
}
