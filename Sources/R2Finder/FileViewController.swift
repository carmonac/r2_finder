// FileViewController.swift
// Port of FileViewController.m (core half): view construction, FSEvents
// monitoring, data loading, clipboard/transfer/archive actions.
// The view datasources/delegates, drag & drop, Quick Look, context menus and
// inline rename live in FileViewController+Views.swift.

import AppKit
import CoreServices
import Quartz
import R2FinderServices
import UniformTypeIdentifiers

enum FileViewMode: Int {
    case icon = 0
    case list = 1
    case columns = 2
    case gallery = 3
}

@MainActor
protocol FileViewControllerDelegate: AnyObject {
    func fileViewController(_ vc: FileViewController, didNavigateToPath path: String)
}

final class FileViewController: NSViewController {

    weak var delegate: FileViewControllerDelegate?
    private(set) var currentPath: String

    static var showHidden = false

    var viewMode: FileViewMode = .list {
        didSet {
            scrollView.isHidden = true
            iconScrollView.isHidden = true
            columnView.isHidden = true
            switch viewMode {
            case .list:
                scrollView.isHidden = false
            case .icon:
                iconScrollView.isHidden = false
                collectionView.reloadData()
            case .columns:
                columnView.isHidden = false
                columnView.reload(fromPath: currentPath)
            case .gallery:
                // Gallery not yet implemented – fall back to list
                scrollView.isHidden = false
            }
        }
    }

    // Views
    let scrollView = NSScrollView()                     // list view
    let outlineView = ContextMenuOutlineView()
    let iconScrollView = NSScrollView()                 // icon view
    let collectionView = ContextMenuCollectionView()
    let columnView = MillerColumnView()                 // column view
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingSpinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

    // Model
    var entries: [FileEntry] = []
    var renameRow = -1

    // Outline expansion/selection, tracked live as the user drives them rather
    // than read back from the outline at reload time. A reload always follows a
    // change to `entries`, and querying rows in that window makes AppKit
    // materialize stale rows through the data source (itemAtRow: →
    // outlineView(_:child:ofItem:)) with indices the new model no longer has.
    var expandedOutlinePaths: Set<String> = []
    var selectedOutlinePaths: Set<String> = []
    // Set while reloadOutlinePreservingState() re-applies the snapshot, so the
    // expand/collapse/selection callbacks it triggers don't overwrite it.
    var isRestoringOutlineState = false
    // Folders whose children are being listed off-main, by path, so repeated
    // data-source queries during an expansion enqueue the listing only once.
    // It doubles as backpressure: while a folder's refresh is in flight, the
    // next FSEvents tick won't queue another listing of it behind the first.
    private var childrenLoading: Set<String> = []
    // The `showHidden` setting the on-screen entries were listed with. A
    // mismatch means carried-over subtrees were filtered differently and can't
    // be reused.
    private var loadedShowHidden = FileViewController.showHidden

    // The selection the Quick Look panel was last told about, so a refresh
    // that re-applies the same selection doesn't make it re-render (see
    // syncPreviewPanel).
    private var previewedPaths: [String] = []

    // Loading
    private let loadQueue = DispatchQueue(label: "com.r2finder.dirload")
    // nonisolated(unsafe): mutated only on the main actor; the background
    // icon/listing loops read it as an advisory early-exit check, where a
    // stale value is harmless (the main-actor guard re-checks on delivery).
    private nonisolated(unsafe) var loadGeneration = 0
    private var isLoading = false

    // FSEvents — nonisolated(unsafe) so deinit (nonisolated) can clean up;
    // both are otherwise only touched on the main actor.
    private nonisolated(unsafe) var fsEventStream: FSEventStreamRef?
    private nonisolated(unsafe) var reloadDebounce: DispatchSourceTimer?

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Init / View
    // ─────────────────────────────────────────────────────────────────────────

    init(path: String) {
        currentPath = path
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clipboardDidChange(_:)),
                                               name: FileClipboard.changedNotification,
                                               object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        // Inline cleanup: deinit is nonisolated and cannot call the
        // main-actor-isolated stopWatching().
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        reloadDebounce?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func clipboardDidChange(_ note: Notification) {
        reloadAllViews()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        view.wantsLayer = true

        // Status bar at bottom
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Loading spinner (centered, hidden when stopped)
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isDisplayedWhenStopped = false
        view.addSubview(loadingSpinner)

        // Outline view (supports expandable folders)
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnResizing = true
        outlineView.allowsColumnReordering = false
        outlineView.rowSizeStyle = .medium
        outlineView.gridStyleMask = .solidHorizontalGridLineMask
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.indentationPerLevel = 18
        outlineView.autoresizesOutlineColumn = true
        outlineView.doubleAction = #selector(tableViewDoubleClicked(_:))
        outlineView.target = self

        // Drag source
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Drag destination
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.draggingDestinationFeedbackStyle = .regular

        // Columns
        let columnDefs: [(id: String, title: String, width: CGFloat)] = [
            ("name", "Nombre", 340),
            ("size", "Tamaño", 100),
            ("date", "Fecha de modificación", 180),
            ("kind", "Tipo", 120),
        ]
        for (i, def) in columnDefs.enumerated() {
            let col = NSTableColumn(identifier: .init(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = 60
            col.sortDescriptorPrototype = NSSortDescriptor(key: def.id, ascending: true)
            outlineView.addTableColumn(col)
            if i == 0 {
                outlineView.outlineTableColumn = col // disclosure triangles in Name column
            }
        }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Icon view (NSCollectionView)
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 90, height: 90)
        flow.minimumInteritemSpacing = 10
        flow.minimumLineSpacing = 10
        flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        collectionView.collectionViewLayout = flow
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.register(IconCollectionViewItem.self,
                                forItemWithIdentifier: .init("IconItem"))
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        iconScrollView.hasVerticalScroller = true
        iconScrollView.hasHorizontalScroller = false
        iconScrollView.documentView = collectionView
        iconScrollView.translatesAutoresizingMaskIntoConstraints = false
        iconScrollView.isHidden = true // start with list view
        view.addSubview(iconScrollView)

        // Column view (Miller columns)
        columnView.translatesAutoresizingMaskIntoConstraints = false
        columnView.isHidden = true
        columnView.delegate = self
        view.addSubview(columnView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            iconScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            iconScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iconScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            iconScrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            columnView.topAnchor.constraint(equalTo: view.topAnchor),
            columnView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columnView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columnView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -2),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),

            loadingSpinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadPath(currentPath)
    }

    override func keyDown(with event: NSEvent) {
        if renameRow >= 0 { return } // let the rename field handle all keys
        let cmd = event.modifierFlags.contains(.command)
        // Finder behavior: ⏎ renames, ⌘↓ / ⌘O opens.
        if event.specialKey == .carriageReturn, !cmd {
            renameSelected(nil)
            return
        }
        if cmd, event.specialKey == .downArrow { openSelected(nil); return }
        if cmd, event.charactersIgnoringModifiers == "o" { openSelected(nil); return }
        if event.specialKey == .delete { deleteSelected(nil); return }
        if event.characters == " " {
            if let panel = QLPreviewPanel.shared() {
                if panel.isVisible {
                    panel.orderOut(nil)
                } else {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – FSEvents directory monitoring
    // ─────────────────────────────────────────────────────────────────────────

    /// Coalesce bursts of FSEvents (e.g. rsync deleting many files in a row
    /// over SMB) into a single reload that fires after a short quiet period.
    func scheduleReload() {
        if reloadDebounce == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                reloadDebounce?.schedule(deadline: .distantFuture)
                loadPath(currentPath)
            }
            timer.resume()
            reloadDebounce = timer
        }
        reloadDebounce?.schedule(deadline: .now() + .milliseconds(400),
                                 repeating: .never,
                                 leeway: .milliseconds(50))
    }

    private func startWatching(path: String) {
        stopWatching()
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let vc = Unmanaged<FileViewController>.fromOpaque(info).takeUnretainedValue()
            // Events are delivered on the main queue (SetDispatchQueue below).
            MainActor.assumeIsolated {
                vc.scheduleReload()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // 500ms latency – batches rapid changes
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        // (The ObjC version used the deprecated ScheduleWithRunLoop; the
        // dispatch-queue API is its direct replacement with identical
        // main-thread delivery.)
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        fsEventStream = stream
    }

    private func stopWatching() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Data loading
    // ─────────────────────────────────────────────────────────────────────────

    func loadPath(_ path: String) {
        let pathChanged = currentPath != path
        currentPath = path
        if pathChanged { startWatching(path: path) }

        // On navigation, blank the view immediately so the user sees they've
        // moved. On in-place refresh (FSEvents), keep the existing entries on
        // screen so the UI doesn't flicker through "Cargando…" every time
        // rsync deletes a file.
        if pathChanged {
            // The old directory's expansion/selection means nothing here, and
            // keeping it would re-expand same-named folders in the new one.
            expandedOutlinePaths.removeAll()
            selectedOutlinePaths.removeAll()
            entries.removeAll()
            reloadAllViews()
            isLoading = true
            loadingSpinner.startAnimation(nil)
            updateStatusBar()
        }

        // Capture generation to detect superseded loads
        loadGeneration += 1
        let thisGeneration = loadGeneration
        let showHidden = Self.showHidden

        loadQueue.async { [weak self] in
            let newEntries = Self.entriesList(forPath: path, showHidden: showHidden)

            // Assign cheap placeholder icons synchronously (no I/O) so the UI
            // can render immediately. Real per-file icons are fetched
            // off-main below.
            let folderPlaceholder = NSImage(named: NSImage.folderName)
            let filePlaceholder = NSImage(named: NSImage.multipleDocumentsName)
            folderPlaceholder?.size = NSSize(width: 16, height: 16)
            filePlaceholder?.size = NSSize(width: 16, height: 16)
            for fe in newEntries {
                fe.icon = fe.isDir ? folderPlaceholder : filePlaceholder
            }

            Task { @MainActor in
                guard let self, self.loadGeneration == thisGeneration else { return }

                self.isLoading = false
                self.loadingSpinner.stopAnimation(nil)

                // An in-place refresh that produced exactly the same listing
                // must not touch the views: rebuilding the rows re-applies the
                // selection, which makes the Quick Look panel re-render, and
                // re-fetches every icon over the wire. Network volumes report
                // a directory change on almost any access — including the
                // Quick Look daemon reading the file being previewed — so
                // these no-op refreshes arrive continuously.
                if !pathChanged, showHidden == self.loadedShowHidden,
                   self.entries.count == newEntries.count,
                   zip(self.entries, newEntries).allSatisfy({ $0.matchesListing(of: $1) }) {
                    self.updateStatusBar()
                    // FSEvents is recursive, so the change may be inside an
                    // expanded subfolder even when this level is untouched.
                    for fe in self.entries
                    where fe.childrenLoaded && self.expandedOutlinePaths.contains(fe.path) {
                        self.loadChildren(for: fe, force: true)
                    }
                    // No-op unless icons are still missing (e.g. the refresh
                    // landed mid fill-in).
                    self.fillIcons(for: self.entries, generation: thisGeneration)
                    return
                }

                // On an in-place refresh (FSEvents during a transfer or
                // extraction), carry over the already-loaded icons by path —
                // otherwise every reload flashes placeholder icons until the
                // background fill-in catches up ("blinking").
                var oldEntries: [String: FileEntry] = [:]
                for e in self.entries { oldEntries[e.path] = e }
                if !oldEntries.isEmpty {
                    for fe in newEntries {
                        guard let old = oldEntries[fe.path], old.icon != nil else { continue }
                        fe.icon = old.icon
                        fe.hasRealIcon = old.hasRealIcon
                    }
                }

                // The previewed file itself changed on disk (a transfer into
                // it finished, say) – that is a real reason to re-render.
                let previewStale = newEntries.contains { fe in
                    guard self.previewedPaths.contains(fe.path),
                          let old = oldEntries[fe.path] else { return false }
                    return !old.matchesListing(of: fe)
                }

                // Likewise carry over expanded subtrees. Children now load
                // asynchronously, so without this an expanded folder would empty
                // out on every FSEvents refresh and repopulate a beat later.
                // Only expanded ones: a collapsed folder can re-list on demand.
                var oldChildren: [String: [FileEntry]] = [:]
                if showHidden == self.loadedShowHidden {
                    for e in self.entries
                    where e.childrenLoaded && self.expandedOutlinePaths.contains(e.path) {
                        oldChildren[e.path] = e.children
                    }
                }
                for fe in newEntries {
                    if let kids = oldChildren[fe.path] {
                        fe.children = kids
                        fe.childrenLoaded = true
                    }
                }

                self.entries = newEntries
                self.loadedShowHidden = showHidden
                self.reloadAllViews()
                self.updateStatusBar()
                if previewStale { self.syncPreviewPanel(force: true) }

                // The carried-over subtrees are the *previous* listing; refresh
                // them off-main so an expanded folder tracks the transfer too.
                for fe in newEntries where oldChildren[fe.path] != nil {
                    self.loadChildren(for: fe, force: true)
                }

                // Fill real icons in the background. icon(forFile:) can do
                // synchronous metadata I/O — on Samba shares this blocks the
                // main thread for hundreds of round-trips.
                self.fillIcons(for: newEntries, generation: thisGeneration)
            }
        }
    }

    /// Build FileEntry objects for a directory (no icons).
    nonisolated static func entriesList(forPath path: String, showHidden: Bool) -> [FileEntry] {
        guard let listed = DirectoryLister.list(path: path) else { return [] }
        return listed.compactMap { e in
            if !showHidden && e.name.hasPrefix(".") { return nil }
            let fe = FileEntry()
            fe.name = e.name
            fe.path = e.path
            fe.isDir = e.isDir
            fe.isSymlink = e.isSymlink
            fe.size = e.size
            fe.mtime = e.mtime
            return fe
        }
    }

    private func fillIcons(for entries: [FileEntry], generation: Int) {
        // Only what's still showing a placeholder: on a refresh the icons
        // carried over from the previous listing are already the real ones,
        // and re-fetching them means another round of metadata I/O per file.
        let pending = entries.filter { !$0.hasRealIcon }
        guard !pending.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ws = NSWorkspace.shared
            for fe in pending {
                guard let self, self.loadGeneration == generation else { return }
                let img = ws.icon(forFile: fe.path)
                img.size = NSSize(width: 16, height: 16)
                Task { @MainActor in
                    guard self.loadGeneration == generation else { return }
                    fe.icon = img
                    fe.hasRealIcon = true
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.reloadAllViews()
            }
        }
    }

    func reloadAllViews() {
        reloadOutlinePreservingState()
        collectionView.reloadData()
        if viewMode == .columns {
            columnView.reload(fromPath: currentPath)
        }
    }

    /// Reload the outline without losing the user's place. Reloads rebuild the
    /// FileEntry objects (and fire asynchronously — FSEvents, icon fill-in,
    /// clipboard changes), so a plain reloadData() would collapse every
    /// expanded folder and drop the selection mid-interaction. Expansion and
    /// selection are restored by path from the snapshot kept in
    /// `expandedOutlinePaths`/`selectedOutlinePaths`; the outline itself is only
    /// queried *after* reloadData(), when its rows match `entries` again.
    private func reloadOutlinePreservingState() {
        let expanded = expandedOutlinePaths

        isRestoringOutlineState = true
        defer {
            isRestoringOutlineState = false
            // One sync with the final selection, instead of one per
            // intermediate state the rebuild passes through.
            syncPreviewPanel()
        }

        outlineView.reloadData()
        guard !expanded.isEmpty || !selectedOutlinePaths.isEmpty else { return }

        // Re-expand parents before children so nested rows materialize.
        for path in expanded.sorted(by: { $0.count < $1.count }) {
            for row in 0..<outlineView.numberOfRows {
                if let e = outlineView.item(atRow: row) as? FileEntry, e.path == path {
                    outlineView.expandItem(e)
                    break
                }
            }
        }

        restoreOutlineSelection()
    }

    /// Re-select the rows whose paths are in `selectedOutlinePaths`. Every
    /// reload rebuilds the FileEntry objects, so selection only survives by path.
    /// Only safe once the outline's rows agree with `entries` again.
    private func restoreOutlineSelection() {
        guard !selectedOutlinePaths.isEmpty else { return }
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let e = outlineView.item(atRow: row) as? FileEntry,
               selectedOutlinePaths.contains(e.path) {
                indexes.insert(row)
            }
        }
        if !indexes.isEmpty {
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    func updateStatusBar() {
        if isLoading {
            statusLabel.stringValue = "Cargando…"
            return
        }
        let folders = entries.lazy.filter(\.isDir).count
        let files = entries.count - folders
        statusLabel.stringValue = "\(folders) carpeta\(folders == 1 ? "" : "s"), "
            + "\(files) archivo\(files == 1 ? "" : "s")"
    }

    /// Column-view listing, off-main. Icons are fetched on the same background
    /// pass rather than filled in later: a column's rows are all visible at
    /// once, and reloadAllViews() — which the icon fill-in ends with — would
    /// rebuild the columns and throw away the user's place in them.
    func loadColumnEntries(forPath path: String,
                           completion: @escaping @MainActor ([FileEntry]) -> Void) {
        let showHidden = Self.showHidden
        loadQueue.async {
            let result = Self.entriesList(forPath: path, showHidden: showHidden)
            let ws = NSWorkspace.shared
            for fe in result {
                let icon = ws.icon(forFile: fe.path)
                icon.size = NSSize(width: 16, height: 16)
                fe.icon = icon
            }
            let sorted = result.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            Task { @MainActor in completion(sorted) }
        }
    }

    /// Load an expanded folder's children off the main thread.
    ///
    /// Both halves of this used to run inline in
    /// `outlineView(_:numberOfChildrenOfItem:)`: the directory listing and one
    /// `NSWorkspace.icon(forFile:)` per child, each a synchronous round-trip.
    /// On an SMB share that froze the UI for the whole expansion. The data
    /// source now reports zero children until the listing lands, then the item
    /// is reloaded (and re-expanded, since expanding an empty folder leaves the
    /// outline with nothing to show).
    ///
    /// `force` re-lists a folder whose children are already loaded — used when
    /// an in-place refresh carries an expanded subtree over to fresh entries.
    func loadChildren(for entry: FileEntry, force: Bool = false) {
        guard force || !entry.childrenLoaded else { return }
        guard !childrenLoading.contains(entry.path) else { return }
        childrenLoading.insert(entry.path)

        let path = entry.path
        let showHidden = Self.showHidden
        let generation = loadGeneration

        loadQueue.async { [weak self] in
            let children = Self.entriesList(forPath: path, showHidden: showHidden)

            // Cheap placeholders (no I/O); fillIcons replaces them off-main.
            let folderPlaceholder = NSImage(named: NSImage.folderName)
            let filePlaceholder = NSImage(named: NSImage.multipleDocumentsName)
            folderPlaceholder?.size = NSSize(width: 16, height: 16)
            filePlaceholder?.size = NSSize(width: 16, height: 16)
            for fe in children {
                fe.icon = fe.isDir ? folderPlaceholder : filePlaceholder
            }

            Task { @MainActor in
                guard let self else { return }
                self.childrenLoading.remove(path)
                // A newer load replaced the whole tree — `entry` is orphaned.
                guard self.loadGeneration == generation else { return }

                // Nothing changed in this subtree – leave its rows alone, for
                // the same reason loadPath bails out on an identical listing.
                if entry.childrenLoaded, entry.children.count == children.count,
                   zip(entry.children, children).allSatisfy({ $0.matchesListing(of: $1) }) {
                    self.fillIcons(for: entry.children, generation: generation)
                    return
                }

                // Keep icons already fetched for this subtree (in-place refresh).
                var oldEntries: [String: FileEntry] = [:]
                for e in entry.children where e.icon != nil { oldEntries[e.path] = e }
                for fe in children {
                    guard let old = oldEntries[fe.path] else { continue }
                    fe.icon = old.icon
                    fe.hasRealIcon = old.hasRealIcon
                }

                entry.children = children
                entry.childrenLoaded = true

                // Guarded: reloading the subtree drops any selection inside it,
                // which would otherwise erase those paths from the snapshot
                // before restoreOutlineSelection() can put the rows back.
                self.isRestoringOutlineState = true
                self.outlineView.reloadItem(entry, reloadChildren: true)
                // The outline may already consider the folder expanded (the user
                // clicked its triangle while it still reported zero children), or
                // it may be a subtree we're restoring after a refresh.
                if self.outlineView.isItemExpanded(entry)
                    || self.expandedOutlinePaths.contains(path) {
                    self.expandedOutlinePaths.insert(path)
                    self.outlineView.expandItem(entry)
                }
                self.restoreOutlineSelection()
                self.isRestoringOutlineState = false
                // Listing a subfolder doesn't change what's selected, so this
                // normally does nothing — which is the point: on a network
                // share these completions arrive one per subfolder, and each
                // one used to re-render the Quick Look preview.
                self.syncPreviewPanel()

                self.fillIcons(for: children, generation: generation)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    func createNewFolder(inPath path: String) {
        let alert = NSAlert()
        alert.messageText = "Nueva carpeta"
        alert.informativeText = "Nombre de la nueva carpeta:"
        alert.addButton(withTitle: "Crear")
        alert.addButton(withTitle: "Cancelar")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Carpeta sin titulo"
        input.stringValue = "Carpeta sin titulo"
        alert.accessoryView = input
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            let name = input.stringValue
            guard !name.isEmpty else { return }
            let newPath = (path as NSString).appendingPathComponent(name)
            if let error = FileService.createDirectory(path: newPath) {
                showErrorMessage(error)
            } else {
                loadPath(currentPath)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Navigation
    // ─────────────────────────────────────────────────────────────────────────

    /// Column-view navigation updates the path without reloading — the
    /// columns already display the content.
    func setCurrentPathFromColumns(_ path: String) {
        currentPath = path
    }

    func openEntry(_ e: FileEntry) {
        if e.isDir {
            loadPath(e.path)
            delegate?.fileViewController(self, didNavigateToPath: e.path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: e.path))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Clipboard actions
    // ─────────────────────────────────────────────────────────────────────────

    /// The internal clipboard if set, otherwise file URLs on the system
    /// pasteboard (e.g. files copied from Finder or another app).
    func effectiveClipboardPaths() -> [String] {
        if !FileClipboard.paths.isEmpty { return FileClipboard.paths }
        guard let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return urls.map(\.path)
    }

    /// Reload the Quick Look panel, but only when the selection actually
    /// changed. Every listing refresh rebuilds the outline and re-applies the
    /// selection by path, which fires selectionDidChange with an identical
    /// selection. On a network volume those refreshes arrive constantly — the
    /// SMB server reports a directory change whenever anything touches it,
    /// including the Quick Look daemon reading the file being previewed — so
    /// reloading unconditionally makes the preview re-render in a loop.
    func syncPreviewPanel(force: Bool = false) {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return }
        let paths = selectedPaths()
        guard force || paths != previewedPaths else { return }
        previewedPaths = paths
        QLPreviewPanel.shared().reloadData()
    }

    /// Called when the panel opens: whatever is selected then is what it shows.
    func notePreviewPanelOpened() {
        previewedPaths = selectedPaths()
    }

    func selectedPaths() -> [String] {
        switch viewMode {
        case .icon:
            return collectionView.selectionIndexPaths.compactMap { ip in
                ip.item < entries.count ? entries[ip.item].path : nil
            }
        case .columns:
            return columnView.selectedPaths
        default:
            return outlineView.selectedRowIndexes.compactMap { idx in
                (outlineView.item(atRow: idx) as? FileEntry)?.path
            }
        }
    }

    @IBAction func openSelected(_ sender: Any?) {
        // Path-based (not a lookup in the top-level entries array) so it also
        // works for rows nested under expanded folders and for column mode.
        for path in selectedPaths() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                loadPath(path)
                delegate?.fileViewController(self, didNavigateToPath: path)
                return
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    @IBAction func copySelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .copy)
    }

    @IBAction func cutSelected(_ sender: Any?) {
        FileClipboard.set(selectedPaths(), operation: .cut)
    }

    @IBAction func pasteHere(_ sender: Any?) {
        let paths = effectiveClipboardPaths()
        guard !paths.isEmpty else { return }
        let isMove = !FileClipboard.paths.isEmpty && FileClipboard.operation == .cut
        performTransfer(fromPaths: paths, toDir: currentPath, isMove: isMove)
        if isMove { FileClipboard.clear() }
    }

    @IBAction func moveHere(_ sender: Any?) {
        let paths = effectiveClipboardPaths()
        guard !paths.isEmpty else { return }
        performTransfer(fromPaths: paths, toDir: currentPath, isMove: true)
        FileClipboard.clear()
    }

    @IBAction func newFolderAction(_ sender: Any?) {
        createNewFolder(inPath: currentPath)
    }

    @IBAction func toggleHidden(_ sender: Any?) {
        Self.showHidden.toggle()
        loadPath(currentPath)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Transfers
    // ─────────────────────────────────────────────────────────────────────────

    func performTransfer(fromPaths paths: [String], toDir dstDir: String, isMove: Bool) {
        if FileService.checkCollision(sources: paths, dstDir: dstDir) {
            let alert = NSAlert()
            alert.messageText = "Ya existe un elemento con ese nombre"
            alert.informativeText = "Deseas reemplazar los archivos existentes?"
            alert.addButton(withTitle: "Reemplazar")
            alert.addButton(withTitle: "Cancelar")
            alert.addButton(withTitle: "Mantener ambos")
            let resp = alert.runModal()
            if resp == .alertSecondButtonReturn { return }
            startTransfer(paths: paths, dstDir: dstDir,
                          overwrite: resp == .alertFirstButtonReturn, isMove: isMove)
        } else {
            startTransfer(paths: paths, dstDir: dstDir, overwrite: false, isMove: isMove)
        }
    }

    /// Wrap a ProgressWindowController into main-thread service handlers.
    /// (The services invoke callbacks on background threads.)
    private func progressHandlers(_ pwc: ProgressWindowController)
        -> (TransferService.ProgressHandler, TransferService.CompletionHandler) {
        let onProgress: TransferService.ProgressHandler = { p, bytes, total, speed, eta in
            Task { @MainActor in
                pwc.updateProgress(p, bytesTransferred: bytes, totalBytes: total,
                                   speed: speed, etaSecs: eta)
            }
        }
        let onDone: TransferService.CompletionHandler = { ok, msg in
            Task { @MainActor in
                pwc.finish(success: ok, errorMessage: msg)
            }
        }
        return (onProgress, onDone)
    }

    private func makeProgressWindow(title: String, destination: String) -> ProgressWindowController {
        let pwc = ProgressWindowController(title: title, destinationFolder: destination) { [weak self] in
            guard let self else { return }
            loadPath(currentPath)
        }
        pwc.showWindow(nil)
        return pwc
    }

    private func startTransfer(paths: [String], dstDir: String, overwrite: Bool, isMove: Bool) {
        guard let rsync = Self.rsyncPath else {
            showErrorMessage("No se encontró el binario rsync")
            return
        }
        let pwc = makeProgressWindow(title: isMove ? "Moviendo" : "Copiando", destination: dstDir)
        let (onProgress, onDone) = progressHandlers(pwc)
        if isMove {
            TransferService.move(rsyncPath: rsync, sources: paths, dstDir: dstDir,
                                 overwrite: overwrite, onProgress: onProgress, onDone: onDone)
        } else {
            TransferService.copy(rsyncPath: rsync, sources: paths, dstDir: dstDir,
                                 overwrite: overwrite, onProgress: onProgress, onDone: onDone)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Delete
    // ─────────────────────────────────────────────────────────────────────────

    @IBAction func deleteSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        // Check if the volume supports Trash by looking at the volume root.
        // Boot volume (/) always supports trash. External volumes need .Trashes.
        var volumeSupportsTrash = true
        let testURL = URL(fileURLWithPath: paths[0])
        if let volumeURL = try? testURL.resourceValues(forKeys: [.volumeURLKey]).volume,
           volumeURL.path != "/" {
            let trashes = volumeURL.appendingPathComponent(".Trashes").path
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: trashes, isDirectory: &isDir) || !isDir.boolValue {
                volumeSupportsTrash = false
            }
        }

        if volumeSupportsTrash {
            confirmTrashDelete(paths)
        } else {
            confirmPermanentDelete(paths)
        }
    }

    private func confirmTrashDelete(_ paths: [String]) {
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Mover \"\((paths[0] as NSString).lastPathComponent)\" a la papelera?"
            : "Mover \(paths.count) elementos a la papelera?"
        alert.addButton(withTitle: "Mover a la papelera")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .warning
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            for path in paths {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path),
                                                      resultingItemURL: nil)
                } catch {
                    // Trash failed — fall back to offering permanent deletion
                    confirmPermanentDelete(paths)
                    return
                }
            }
            loadPath(currentPath)
        }
    }

    private func confirmPermanentDelete(_ paths: [String]) {
        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "\"\((paths[0] as NSString).lastPathComponent)\" se eliminará permanentemente."
            : "\(paths.count) elementos se eliminarán permanentemente."
        alert.informativeText = "Este volumen no tiene papelera. Esta acción no se puede deshacer."
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        alert.alertStyle = .critical
        // Make the "Eliminar" button visually destructive
        alert.buttons.first?.hasDestructiveAction = true
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            if let error = FileService.deleteFiles(paths: paths) {
                showErrorMessage(error)
            }
            loadPath(currentPath)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Archive actions
    // ─────────────────────────────────────────────────────────────────────────

    /// Extensions the bundled 7zz can extract (from `7zz i`, filtered to
    /// archive-like formats a user would actually right-click — executables,
    /// disk images the OS mounts, and zip-based document formats like .docx
    /// are deliberately excluded). Drives "Descomprimir" in the context menu.
    /// "001" covers the split volumes this app itself creates.
    static let extractableExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "r00", "tar", "tgz", "tbz", "tbz2",
        "txz", "taz", "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "z",
        "lzh", "lha", "arj", "cab", "iso", "cpio", "rpm", "deb", "wim",
        "xar", "pkg", "001",
    ]

    /// Formats that are already compressed — splitting these uses -mx0
    /// (store only) since re-compressing buys nothing.
    static let compressedExtensions: Set<String> = [
        "7z", "zip", "zipx", "rar", "tar", "tgz", "tbz", "tbz2", "txz",
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "z",
    ]

    @IBAction func compressSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        // Archive name: based on the first selected item
        let baseName = ((paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension
        let archive = (currentPath as NSString).appendingPathComponent(baseName + ".7z")

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage("No se encontró el binario 7zz")
            return
        }

        let pwc = makeProgressWindow(title: "Comprimiendo", destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        ArchiveService.compress(sevenzzPath: sevenzz, sources: paths, archivePath: archive,
                                onProgress: onProgress, onDone: onDone)
    }

    @IBAction func splitSelected(_ sender: Any?) {
        let paths = selectedPaths()
        guard !paths.isEmpty else { return }

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage("No se encontró el binario 7zz")
            return
        }

        // Input panel asking for the part size in MB
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Ej: 100"
        field.font = .systemFont(ofSize: 13)
        field.stringValue = "100"

        let alert = NSAlert()
        alert.messageText = "Dividir en partes"
        alert.informativeText = "Tamaño de cada parte en MB:"
        alert.addButton(withTitle: "Dividir")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = field

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }

            let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sizeMB = Int(input), sizeMB > 0 else {
                showErrorMessage("El tamaño debe ser un número mayor que 0")
                return
            }

            // Detect if all selected files are already compressed archives
            let storeOnly = paths.allSatisfy {
                Self.compressedExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }

            let baseName = ((paths[0] as NSString).lastPathComponent as NSString).deletingPathExtension
            let archive = (currentPath as NSString).appendingPathComponent(baseName + ".7z")

            let pwc = makeProgressWindow(title: "Dividiendo", destination: currentPath)
            let (onProgress, onDone) = progressHandlers(pwc)
            ArchiveService.compress(sevenzzPath: sevenzz, sources: paths, archivePath: archive,
                                    volumeSizeMB: UInt32(sizeMB), storeOnly: storeOnly,
                                    onProgress: onProgress, onDone: onDone)
        }
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
        }
    }

    @IBAction func uncompressSelected(_ sender: Any?) {
        // Selection-based (not outlineView rows) so it works from the icon
        // and column views too.
        guard let archivePath = selectedPaths().first else { return }

        guard let sevenzz = Self.sevenzzPath else {
            showErrorMessage("No se encontró el binario 7zz")
            return
        }

        // Extract to a folder with the archive's base name; split volumes
        // (x.7z.001) shed both extensions.
        var baseName = ((archivePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        if (archivePath as NSString).pathExtension == "001" {
            baseName = (baseName as NSString).deletingPathExtension
        }
        let dstDir = (currentPath as NSString).appendingPathComponent(baseName)

        let pwc = makeProgressWindow(title: "Descomprimiendo", destination: currentPath)
        let (onProgress, onDone) = progressHandlers(pwc)
        ArchiveService.uncompress(sevenzzPath: sevenzz, archivePath: archivePath, dstDir: dstDir,
                                  onProgress: onProgress, onDone: onDone)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Bundled binaries
    // ─────────────────────────────────────────────────────────────────────────

    private static func bundledBinary(_ name: String) -> String? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourcePath {
            let bundled = (resources as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }
        // Development fallback (swift run / bare .build binaries): walk up
        // from the executable looking for the repo's bin/<name>. The binary
        // sits at .build/<config>/ or .build/<triple>/<config>/ depending on
        // how it was launched, so a fixed ../.. is not reliable.
        if let exePath = Bundle.main.executablePath {
            var dir = URL(fileURLWithPath: exePath)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("bin/\(name)").path
                if fm.isExecutableFile(atPath: candidate) { return candidate }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    static var sevenzzPath: String? { bundledBinary("7zz") }
    static var rsyncPath: String? { bundledBinary("rsync") }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Helpers
    // ─────────────────────────────────────────────────────────────────────────

    func showErrorMessage(_ msg: String?) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = msg ?? "Operacion fallida"
        alert.alertStyle = .critical
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func formattedSize(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1_048_576 { return String(format: "%.1f KB", v / 1024.0) }
        if v < 1_073_741_824 { return String(format: "%.1f MB", v / 1_048_576.0) }
        return String(format: "%.2f GB", v / 1_073_741_824.0)
    }

    func formattedDate(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Localized "Tipo" column text.
    ///
    /// Resolved from the filename extension, cached, because the previous
    /// `resourceValues(forKeys: [.contentTypeKey])` hit the filesystem once per
    /// visible row on every redraw — a per-row round-trip on a network volume.
    /// Extensionless files still need the file itself to say what it is.
    func kind(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty {
            let key = ext.lowercased()
            if let cached = Self.kindCache[key] { return cached }
            if let description = UTType(filenameExtension: ext)?.localizedDescription {
                Self.kindCache[key] = description
                return description
            }
        }
        if let type = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.contentTypeKey]).contentType,
           let description = type.localizedDescription {
            return description
        }
        let upper = ext.uppercased()
        return upper.isEmpty ? "Archivo" : "Archivo \(upper)"
    }

    private static var kindCache: [String: String] = [:]
}
