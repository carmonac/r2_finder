# R2 Finder

<!-- DOWNLOAD_SECTION_START -->
## Download

[**R2 Finder v2.1.0 — Download DMG**](https://github.com/carmonac/r2_finder/releases/download/v2.1.0/R2.Finder.dmg)

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

Requires **Swift 6.0+** (Xcode command-line tools) and macOS 13+. The package
builds in Swift 6 language mode (strict concurrency).

```bash
# Build and run directly (debug; uses the repo's bin/rsync and bin/7zz)
swift run

# Build
swift build -c release

# Create R2 Finder.app in .build/ and open it
Scripts/bundle.sh
open ".build/R2 Finder.app"

# Run unit tests (services: listing, transfers, archives, parsers)
swift test
```

The `.app` bundle is self-contained — copy `.build/R2 Finder.app` anywhere to install.

## Architecture

The app is 100 % Swift (migrated from Zig + Objective-C — see `SWIFT_MIGRATION.md`).

| Layer | Responsibility |
|-------|----------------|
| `Sources/R2FinderServices/` | Filesystem services: list, copy/move (rsync), delete, create directory, rename, volumes, 7z archives |
| `Sources/R2Finder/` | The app: entry point + AppKit UI (windows, toolbar, sidebar, file views, progress, Quick Look) |

Copy and move operations run on background threads inside the service layer; the UI dispatches progress callbacks onto the main queue so it stays responsive during large transfers.
