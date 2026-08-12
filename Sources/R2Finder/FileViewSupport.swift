// FileViewSupport.swift
// Support types for FileViewController: the FileEntry model, the shared
// clipboard, and the small view subclasses that add context-menu /
// double-click hooks.

import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// FileEntry – lightweight model object for directory entries
// ─────────────────────────────────────────────────────────────────────────────

// @unchecked Sendable: entries are constructed and populated on a loader
// thread, then handed to the main actor; after handoff only the main actor
// mutates them (icon fill-in).
final class FileEntry: @unchecked Sendable {
    var name = ""
    var path = ""
    var isDir = false
    var isSymlink = false
    var size: UInt64 = 0
    var mtime: Int64 = 0
    var icon: NSImage?
    /// False while `icon` is still the cheap placeholder, so a refresh only
    /// re-fetches the icons it is actually missing (icon(forFile:) does
    /// synchronous metadata I/O — expensive over SMB).
    var hasRealIcon = false
    var children: [FileEntry] = []
    var childrenLoaded = false

    /// Same file, same state on disk? Compares what a directory listing can
    /// see, not the derived UI state (icons, loaded children).
    func matchesListing(of other: FileEntry) -> Bool {
        path == other.path && isDir == other.isDir && isSymlink == other.isSymlink
            && size == other.size && mtime == other.mtime
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared clipboard – copy/cut in one window can be pasted in another.
// Mutated only on the main thread (menu/keyboard actions).
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
enum FileClipboard {
    enum Operation { case none, copy, cut }

    static let changedNotification = Notification.Name("R2FinderClipboardChanged")

    private(set) static var paths: [String] = []
    private(set) static var operation: Operation = .none

    static func set(_ newPaths: [String], operation op: Operation) {
        paths = newPaths
        operation = op
        // Mirror to the system pasteboard for copy so external apps
        // (incl. Finder) can paste.
        if op == .copy, !newPaths.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(newPaths.map { NSURL(fileURLWithPath: $0) })
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func clear() {
        set([], operation: .none)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenuOutlineView – NSOutlineView subclass with per-row context menus
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
protocol ContextMenuOutlineViewDelegate: NSOutlineViewDelegate {
    func contextMenu(forOutlineView ov: NSOutlineView, clickedRow row: Int) -> NSMenu?
}

final class ContextMenuOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: loc)
        if let d = delegate as? ContextMenuOutlineViewDelegate {
            return d.contextMenu(forOutlineView: self, clickedRow: clickedRow)
        }
        return super.menu(for: event)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ContextMenuCollectionView – NSCollectionView with right-click menu and
// double-click support
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
protocol ContextMenuCollectionViewDelegate: NSCollectionViewDelegate {
    func contextMenu(forCollectionView cv: NSCollectionView, at point: NSPoint) -> NSMenu?
    func collectionViewDidDoubleClick(_ cv: NSCollectionView, at indexPath: IndexPath)
}

final class ContextMenuCollectionView: NSCollectionView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        if let d = delegate as? ContextMenuCollectionViewDelegate {
            return d.contextMenu(forCollectionView: self, at: loc)
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let loc = convert(event.locationInWindow, from: nil)
            if let ip = indexPathForItem(at: loc),
               let d = delegate as? ContextMenuCollectionViewDelegate {
                d.collectionViewDidDoubleClick(self, at: ip)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// IconCollectionViewItem – NSCollectionViewItem for icon grid view
// ─────────────────────────────────────────────────────────────────────────────

final class IconCollectionViewItem: NSCollectionViewItem {

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 90))
        container.wantsLayer = true

        let iv = NSImageView(frame: .zero)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.imageScaling = .scaleProportionallyDown
        iv.imageAlignment = .alignCenter
        container.addSubview(iv)

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 2
        tf.font = .systemFont(ofSize: 11)
        container.addSubview(tf)

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            iv.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 64),
            iv.heightAnchor.constraint(equalToConstant: 64),
            tf.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 2),
            tf.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        ])

        view = container
        imageView = iv
        textField = tf
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.cgColor
                : NSColor.clear.cgColor
            view.layer?.cornerRadius = 6
        }
    }
}
