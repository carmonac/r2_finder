// MillerColumnView.swift
// Finder-style Miller columns — replacement for the deprecated NSBrowser
// (SWIFT_MIGRATION.md, Phase 7). A horizontal scroll view containing one
// NSTableView per directory level; selecting a directory trims the deeper
// columns and appends its children as a new column.

import AppKit

@MainActor
protocol MillerColumnViewDelegate: AnyObject {
    /// Provide the entries (with icons) for one column. Listing a directory and
    /// fetching its icons are both blocking I/O, so the entries come back
    /// through `completion` — possibly after the column has been removed again.
    func columnView(_ v: MillerColumnView, entriesForPath path: String,
                    completion: @escaping @MainActor ([FileEntry]) -> Void)
    /// A directory row was selected: it becomes the current path.
    func columnView(_ v: MillerColumnView, didSelectDirectory path: String)
    /// A file row was selected: its *containing* directory becomes current.
    func columnView(_ v: MillerColumnView, didSelectFileInDirectory path: String)
    /// A file was double-clicked (directories never reach this).
    func columnView(_ v: MillerColumnView, open entry: FileEntry)
    /// Right-click: same menu as the other view modes (nil entry = background).
    func columnView(_ v: MillerColumnView, contextMenuFor entry: FileEntry?) -> NSMenu?
    /// Files dropped onto a column (or onto a directory row inside it).
    func columnView(_ v: MillerColumnView, dropPaths paths: [String],
                    toDir dstDir: String, isMove: Bool)
}

// ─────────────────────────────────────────────────────────────────────────────
// Column table – forwards ←/→, ⏎ and right-clicks to the owning column view
// ─────────────────────────────────────────────────────────────────────────────

final class ColumnTableView: NSTableView {
    weak var owner: MillerColumnView?

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .some(.rightArrow):
            if owner?.focusNextColumn(from: self) == true { return }
        case .some(.leftArrow):
            if owner?.focusPreviousColumn(from: self) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        return owner?.contextMenu(for: self, clickedRow: row(at: loc))
            ?? super.menu(for: event)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MillerColumnView
// ─────────────────────────────────────────────────────────────────────────────

final class MillerColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: MillerColumnViewDelegate?

    static let columnWidth: CGFloat = 180

    private struct Column {
        /// Identifies the column across an async entries load — indices shift as
        /// deeper columns are trimmed, and the column may be gone by then.
        let id: Int
        let path: String
        var entries: [FileEntry]
        let table: ColumnTableView
        let scroll: NSScrollView
    }

    private let hScroll = NSScrollView()
    private let stack = NSStackView()
    private var columns: [Column] = []
    private var nextColumnID = 0
    /// Index of the column the user last interacted with (feeds selectedPaths).
    private var activeColumnIndex = 0
    /// Guard so programmatic reloads don't re-enter the selection logic.
    private var isRebuilding = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // Thin separator lines between columns show through the stack spacing.
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor

        stack.orientation = .horizontal
        stack.spacing = 1
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        hScroll.hasHorizontalScroller = true
        hScroll.hasVerticalScroller = false
        hScroll.drawsBackground = false
        hScroll.documentView = stack
        hScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hScroll)

        NSLayoutConstraint.activate([
            hScroll.topAnchor.constraint(equalTo: topAnchor),
            hScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            hScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            hScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: hScroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: hScroll.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: hScroll.contentView.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    /// Reset to a single root column (parity with the old loadColumnZero).
    func reload(fromPath rootPath: String) {
        isRebuilding = true
        defer { isRebuilding = false }
        while !columns.isEmpty { removeLastColumn() }
        appendColumn(path: rootPath)
        activeColumnIndex = 0
    }

    /// Re-list every open column in place (FSEvents, show-hidden toggle,
    /// after a transfer), keeping the chain of open folders and the selection.
    /// Unlike reload(fromPath:) this never throws away the user's place.
    func refresh() {
        for column in columns {
            let id = column.id
            delegate?.columnView(self, entriesForPath: column.path) { [weak self] entries in
                self?.applyRefreshed(entries, toColumnID: id)
            }
        }
    }

    private func applyRefreshed(_ entries: [FileEntry], toColumnID id: Int) {
        guard let idx = columns.firstIndex(where: { $0.id == id }) else { return }
        let old = columns[idx].entries
        // Network volumes report changes on almost any access: an unchanged
        // listing must leave the rows (and the selection) alone.
        if old.count == entries.count,
           zip(old, entries).allSatisfy({ $0.matchesListing(of: $1) }) { return }

        let table = columns[idx].table
        let selected = Set(table.selectedRowIndexes.compactMap { $0 < old.count ? old[$0].path : nil })

        isRebuilding = true
        defer { isRebuilding = false }
        columns[idx].entries = entries
        table.reloadData()
        let rows = IndexSet(entries.indices.filter { selected.contains(entries[$0].path) })
        table.selectRowIndexes(rows, byExtendingSelection: false)

        // The folder this column had opened is gone: close the columns past it.
        if idx + 1 < columns.count,
           !entries.contains(where: { $0.isDir && $0.path == columns[idx + 1].path }) {
            while columns.count > idx + 1 { removeLastColumn() }
            activeColumnIndex = min(activeColumnIndex, idx)
            delegate?.columnView(self, didSelectFileInDirectory: columns[idx].path)
        }
    }

    /// Selected paths of the column the user last interacted with.
    var selectedPaths: [String] {
        guard activeColumnIndex < columns.count else { return [] }
        let column = columns[activeColumnIndex]
        return column.table.selectedRowIndexes.compactMap { idx in
            idx < column.entries.count ? column.entries[idx].path : nil
        }
    }

    /// The view that should receive forwarded key events (Quick Look arrows).
    var keyTarget: NSView? {
        activeColumnIndex < columns.count ? columns[activeColumnIndex].table : nil
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Column management
    // ─────────────────────────────────────────────────────────────────────────

    private func appendColumn(path: String) {
        let table = ColumnTableView()
        table.owner = self
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowSizeStyle = .medium
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let col = NSTableColumn(identifier: .init("col"))
        col.width = Self.columnWidth - 4
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        let id = nextColumnID
        nextColumnID += 1

        stack.addArrangedSubview(scroll)
        columns.append(Column(id: id, path: path, entries: [], table: table, scroll: scroll))
        table.reloadData()

        // The column shows up empty and fills in when the listing lands.
        delegate?.columnView(self, entriesForPath: path) { [weak self] entries in
            guard let self, let idx = self.columns.firstIndex(where: { $0.id == id }) else { return }
            self.columns[idx].entries = entries
            self.isRebuilding = true
            self.columns[idx].table.reloadData()
            self.isRebuilding = false
        }

        // Scroll the new column into view once layout has caught up.
        DispatchQueue.main.async { [weak self] in
            guard let self, let last = columns.last else { return }
            hScroll.contentView.scrollToVisible(last.scroll.frame)
        }
    }

    private func removeLastColumn() {
        guard let last = columns.popLast() else { return }
        stack.removeArrangedSubview(last.scroll)
        last.scroll.removeFromSuperview()
    }

    private func columnIndex(of table: NSTableView) -> Int? {
        columns.firstIndex { $0.table === table }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Selection semantics (parity with the old browserSingleClick)
    // ─────────────────────────────────────────────────────────────────────────

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuilding,
              let table = notification.object as? ColumnTableView,
              let colIdx = columnIndex(of: table) else { return }

        let selection = table.selectedRowIndexes
        guard !selection.isEmpty else { return } // empty click – keep columns

        activeColumnIndex = colIdx

        // Trim everything deeper than the clicked column.
        isRebuilding = true
        while columns.count > colIdx + 1 { removeLastColumn() }
        isRebuilding = false

        // Single directory selection expands a child column; anything else
        // (multi-selection, file) just updates the current path.
        let entries = columns[colIdx].entries
        if selection.count == 1, let row = selection.first, row < entries.count,
           entries[row].isDir {
            let entry = entries[row]
            appendColumn(path: entry.path)
            delegate?.columnView(self, didSelectDirectory: entry.path)
        } else {
            delegate?.columnView(self, didSelectFileInDirectory: columns[colIdx].path)
        }
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard activeColumnIndex < columns.count else { return }
        let column = columns[activeColumnIndex]
        let row = column.table.clickedRow
        guard row >= 0, row < column.entries.count else { return }
        let entry = column.entries[row]
        if !entry.isDir {
            delegate?.columnView(self, open: entry)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Keyboard (called from ColumnTableView)
    // ─────────────────────────────────────────────────────────────────────────

    func focusNextColumn(from table: ColumnTableView) -> Bool {
        guard let idx = columnIndex(of: table), idx + 1 < columns.count else { return false }
        let next = columns[idx + 1]
        window?.makeFirstResponder(next.table)
        activeColumnIndex = idx + 1
        if next.table.selectedRow < 0, !next.entries.isEmpty {
            next.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return true
    }

    func focusPreviousColumn(from table: ColumnTableView) -> Bool {
        guard let idx = columnIndex(of: table), idx > 0 else { return false }
        window?.makeFirstResponder(columns[idx - 1].table)
        activeColumnIndex = idx - 1
        return true
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Context menu (called from ColumnTableView)
    // ─────────────────────────────────────────────────────────────────────────

    func contextMenu(for table: ColumnTableView, clickedRow row: Int) -> NSMenu? {
        guard let idx = columnIndex(of: table) else { return nil }
        activeColumnIndex = idx
        let entries = columns[idx].entries
        if row >= 0, row < entries.count {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return delegate?.columnView(self, contextMenuFor: entries[row])
        }
        return delegate?.columnView(self, contextMenuFor: nil)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSTableViewDataSource / Delegate (cells, drag & drop)
    // ─────────────────────────────────────────────────────────────────────────

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let idx = columnIndex(of: tableView) else { return 0 }
        return columns[idx].entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let idx = columnIndex(of: tableView), row < columns[idx].entries.count else {
            return nil
        }
        let entry = columns[idx].entries[row]

        let identifier = NSUserInterfaceItemIdentifier("ColCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier
                let iv = NSImageView(frame: .zero)
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.imageScaling = .scaleProportionallyDown
                cell.addSubview(iv)
                cell.imageView = iv
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                cell.addSubview(tf)
                cell.textField = tf
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        cell.textField?.stringValue = entry.name
        cell.imageView?.image = entry.icon
        return cell
    }

    // ── Drag source ─────────────────────────────────────────────────────────

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let idx = columnIndex(of: tableView), row < columns[idx].entries.count else {
            return nil
        }
        return NSURL(fileURLWithPath: columns[idx].entries[row].path)
    }

    // ── Drag destination ────────────────────────────────────────────────────

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard let idx = columnIndex(of: tableView) else { return [] }
        // Dropping *onto* a non-directory row is not a valid target.
        if op == .on, row < columns[idx].entries.count, !columns[idx].entries[row].isDir {
            return []
        }
        if info.draggingSourceOperationMask.contains(.move) { return .move }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let idx = columnIndex(of: tableView),
              let urls = info.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        var dstDir = columns[idx].path
        if op == .on, row < columns[idx].entries.count, columns[idx].entries[row].isDir {
            dstDir = columns[idx].entries[row].path
        }
        let isMove = info.draggingSourceOperationMask.contains(.move)
        delegate?.columnView(self, dropPaths: urls.map(\.path), toDir: dstDir, isMove: isMove)
        return true
    }
}
