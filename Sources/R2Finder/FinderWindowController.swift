// FinderWindowController.swift
// Port of FinderWindowController.m: window + toolbar + navigation history,
// hosting the (still Objective-C) sidebar and file view controllers.

import AppKit

final class FinderWindowController: NSWindowController, NSToolbarDelegate,
                                    SidebarViewControllerDelegate,
                                    FileViewControllerDelegate {

    private var splitVC = NSSplitViewController()
    private let sidebarVC = SidebarViewController()
    private let fileVC: FileViewController

    // Navigation stack
    private var history: [String] = []
    private var historyIndex = -1

    // Toolbar items
    private var navControl: NSSegmentedControl?      // back / forward segments
    private var viewModeControl: NSSegmentedControl?
    private var pathLabel: NSTextField?

    init(path: String) {
        fileVC = FileViewController(path: path)

        // Create window programmatically
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered,
                           defer: false)
        win.title = "R2 Finder"
        win.minSize = NSSize(width: 640, height: 400)
        win.center()

        super.init(window: win)

        setupToolbar()
        setupContent()
        pushPath(path, updateContent: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // ───────────────────────────────────────────────
    // MARK: – Toolbar
    // ───────────────────────────────────────────────

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "R2FinderToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.titlebarAppearsTransparent = false
    }

    // ───────────────────────────────────────────────
    // MARK: – Content
    // ───────────────────────────────────────────────

    private func setupContent() {
        sidebarVC.delegate = self
        fileVC.delegate = self

        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 280

        let contentItem = NSSplitViewItem(viewController: fileVC)
        contentItem.minimumThickness = 300

        splitVC.addSplitViewItem(sideItem)
        splitVC.addSplitViewItem(contentItem)

        window?.contentViewController = splitVC
    }

    // ───────────────────────────────────────────────
    // MARK: – Navigation
    // ───────────────────────────────────────────────

    private func pushPath(_ path: String, updateContent: Bool) {
        // Truncate forward history
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(path)
        historyIndex = history.count - 1
        updateToolbarState()
        if updateContent { fileVC.loadPath(path) }
        showCurrent(path)
    }

    func navigateToPath(_ path: String) {
        pushPath(path, updateContent: true)
        sidebarVC.highlightPath(path)
    }

    private func goToHistoryEntry(at index: Int) {
        guard history.indices.contains(index) else { return }
        historyIndex = index
        let path = history[index]
        fileVC.loadPath(path)
        showCurrent(path)
        sidebarVC.highlightPath(path)
        updateToolbarState()
    }

    @IBAction func goBack(_ sender: Any?) {
        goToHistoryEntry(at: historyIndex - 1)
    }

    @IBAction func goForward(_ sender: Any?) {
        goToHistoryEntry(at: historyIndex + 1)
    }

    private func showCurrent(_ path: String) {
        let last = (path as NSString).lastPathComponent
        window?.title = last.isEmpty ? path : last
        pathLabel?.stringValue = path
    }

    private func updateToolbarState() {
        navControl?.setEnabled(historyIndex > 0, forSegment: 0)
        navControl?.setEnabled(historyIndex < history.count - 1, forSegment: 1)
    }

    // ───────────────────────────────────────────────
    // MARK: – NSToolbarDelegate
    // ───────────────────────────────────────────────

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("AppLogo"), .init("BackForward"), .init("ViewMode"),
         .flexibleSpace, .init("PathLabel"), .flexibleSpace,
         .init("NewFolder"), .init("GoToFolder")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    private static var logo: NSImage? = {
        var imgPath = Bundle.main.path(forResource: "r2_finder", ofType: "png")
        if imgPath == nil, let exePath = Bundle.main.executablePath {
            imgPath = ((exePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("../../r2_finder.png")
        }
        let image = imgPath.flatMap { NSImage(contentsOfFile: $0) }
        return image ?? NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                accessibilityDescription: "R2 Finder")
    }()

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier.rawValue {
        case "AppLogo":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            if let copy = Self.logo?.copy() as? NSImage {
                copy.size = NSSize(width: 20, height: 20)
                item.image = copy
            }
            item.label = "R2 Finder"
            item.toolTip = "R2 Finder"
            return item

        case "BackForward":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            // .momentary: each click ALWAYS fires the action with a valid
            // selectedSegment (0 or 1). No toggle confusion.
            let control = NSSegmentedControl(
                images: [
                    NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Atrás")!,
                    NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Adelante")!,
                ],
                trackingMode: .momentary,
                target: self,
                action: #selector(backForwardAction(_:)))
            control.segmentStyle = .separated
            control.setEnabled(false, forSegment: 0)
            control.setEnabled(false, forSegment: 1)
            navControl = control
            item.view = control
            return item

        case "ViewMode":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let control = NSSegmentedControl()
            control.segmentCount = 3
            control.trackingMode = .selectOne
            control.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Iconos"), forSegment: 0)
            control.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Lista"), forSegment: 1)
            control.setImage(NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Columnas"), forSegment: 2)
            control.selectedSegment = 1
            control.target = self
            control.action = #selector(viewModeAction(_:))
            control.sizeToFit()
            viewModeControl = control
            item.view = control
            return item

        case "PathLabel":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "")
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.preferredMaxLayoutWidth = 400
            pathLabel = label
            item.view = label
            return item

        case "NewFolder":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Nueva carpeta")
            item.label = "Nueva carpeta"
            item.target = self
            item.action = #selector(createNewFolder(_:))
            return item

        case "GoToFolder":
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: "Ir a carpeta")
            item.label = "Ir a carpeta"
            item.target = self
            item.action = #selector(goToFolderAction(_:))
            return item

        default:
            return nil
        }
    }

    @IBAction func viewModeAction(_ seg: NSSegmentedControl) {
        fileVC.viewMode = FileViewMode(rawValue: seg.selectedSegment) ?? .list
    }

    @IBAction func backForwardAction(_ seg: NSSegmentedControl) {
        if seg.selectedSegment == 0 { goBack(seg) } else { goForward(seg) }
    }

    @IBAction func createNewFolder(_ sender: Any?) {
        // Use the FileViewController's own currentPath — it is always up to
        // date even if the history stack and the file view diverge momentarily.
        let current = fileVC.currentPath.isEmpty
            ? (historyIndex >= 0 ? history[historyIndex] : nil)
            : fileVC.currentPath
        guard let current else { return }
        fileVC.createNewFolder(inPath: current)
    }

    @IBAction func connectToServerAction(_ sender: Any?) {
        sidebarVC.presentConnectToServer(sender)
    }

    @IBAction func goToFolderAction(_ sender: Any?) {
        GoToFolderPanel.runAsSheet(on: window) { [weak self] path in
            if let path { self?.navigateToPath(path) }
        }
    }

    // ───────────────────────────────────────────────
    // MARK: – SidebarViewControllerDelegate
    // ───────────────────────────────────────────────

    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String) {
        pushPath(path, updateContent: true)
    }

    func sidebar(_ sidebar: SidebarViewController,
                 dropFilePaths paths: [String], toDir dstDir: String, isMove: Bool) {
        fileVC.performTransfer(fromPaths: paths, toDir: dstDir, isMove: isMove)
    }

    // ───────────────────────────────────────────────
    // MARK: – FileViewControllerDelegate
    // ───────────────────────────────────────────────

    func fileViewController(_ vc: FileViewController, didNavigateToPath path: String) {
        pushPath(path, updateContent: false) // content already updated by fileVC
        sidebarVC.highlightPath(path)
    }
}
