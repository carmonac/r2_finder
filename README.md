# R2 Finder

<!-- DOWNLOAD_SECTION_START -->
## Download

[**R2 Finder v1.1.1 — Download DMG**](https://github.com/carmonac/r2_finder/releases/download/v1.1.1/R2.Finder.dmg)

Drag **R2 Finder.app** from the DMG to your `/Applications` folder.

**Important:** Since the application is not notarized, macOS will quarantine it the
first time. Run this command in Terminal **before** opening it:

```bash
xattr -d com.apple.quarantine /Applications/R2\ Finder.app
```
<!-- DOWNLOAD_SECTION_END -->

## Why does this exist?

macOS Finder has a long-standing problem when copying files to volumes exposed over **Samba (SMB)** — particularly in certain NAS or server configurations. Depending on the SMB dialect, server quirks, or extended-attribute support, Finder will frequently throw cryptic errors like:

> *"The operation can't be completed because an unexpected error occurred (error code -36), (error: 100093). etc..."*

or silently stall mid-transfer, leaving partial files behind. The root cause is that Finder tries to copy macOS-specific metadata (resource forks, extended attributes, `.DS_Store` entries) alongside the actual file data, and many Samba configurations reject or mishandle those writes.

**R2 Finder solves this by using `rsync` for all copy and move operations** instead of the Finder/kernel copy APIs.

### Why rsync works where Finder doesn't

macOS ships `/usr/bin/rsync` (Apple's `openrsync`) as a first-class tool. R2 Finder invokes it with:

```
rsync -a -P [--ignore-existing] [--remove-source-files] <sources> <destination>/
```

- **`-a` (archive mode)** — preserves permissions, timestamps, and symlinks without attempting to push macOS-specific resource forks that Samba rejects.
- **`-P`** — combines `--partial` (resume interrupted transfers) and per-file progress reporting.
- **`--ignore-existing`** — safe copy without overwriting, used when no collision override is chosen.
- **`--remove-source-files`** — clean atomic move, only deletes the source after the destination is fully written.

Because rsync speaks the remote filesystem's language and skips the extended-attribute overhead, transfers to Samba shares complete reliably where Finder fails.

## Features

- Browse the local filesystem and any mounted volumes (including Samba shares)
- Copy and move files using rsync — progress window with speed and ETA
- Cut / Copy / Paste with support for files copied from macOS Finder
- Paste with **Option key** held → force move (`Trasladar aquí`)
- Drag-and-drop between windows and from/to other apps
- Quick Look preview with **Space bar**
- Rename files inline
- Create new folders (toolbar button or Cmd+Shift+N)
- Show / hide hidden files (dotfiles)
- Sidebar with favourites (home, desktop, documents, downloads, etc.) and mounted volumes — auto-refreshes on mount/unmount
- Back / Forward navigation history per window
- Multiple independent windows

## Building

Requires **Zig 0.15** and macOS 13+.

```bash
# Build and run directly
zig build run

# Create R2 Finder.app in zig-out/
zig build bundle

# Run filesystem unit tests (no UI dependencies)
zig build test-fs
```

The `.app` bundle is self-contained — copy `zig-out/R2 Finder.app` anywhere to install.

## Architecture

| Layer | Language | Responsibility |
|-------|----------|----------------|
| `src/fs_ops.zig` | Zig | Filesystem operations: list, copy/move (rsync), delete (Trash), create directory, rename, volumes, special dirs |
| `include/bridge.h` | C | ABI boundary between Zig and Objective-C |
| `objc/` | Objective-C / Cocoa | All UI: windows, toolbar, sidebar, file table, progress, Quick Look |

Copy and move operations run on a background thread spawned by Zig. Progress callbacks are dispatched back to the main queue so the UI stays responsive during large transfers.
