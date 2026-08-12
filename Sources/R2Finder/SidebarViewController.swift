// SidebarViewController.swift
// Port of SidebarViewController.m: favourites / volumes / network source list.
//
// Network discovery still uses NSNetServiceBrowser (deprecated) exactly like
// the ObjC version did — migrating to NWBrowser is a separate, bisectable
// change (see SWIFT_MIGRATION.md, "Not in scope").

import AppKit
import Darwin
import R2FinderServices

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelectPath path: String)
    func sidebar(_ sidebar: SidebarViewController,
                 dropFilePaths paths: [String], toDir dstDir: String, isMove: Bool)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Internal model
// ─────────────────────────────────────────────────────────────────────────────

private final class SidebarItem {
    let name: String
    let path: String?
    let icon: NSImage?
    let isHeader: Bool
    let networkHostname: String?  // non-nil for network hosts
    /// Non-nil for rows that run a command instead of navigating
    /// ("Conectar al servidor…").
    let action: Selector?
    var children: [SidebarItem] = []

    init(header title: String) {
        name = title
        path = nil
        icon = nil
        isHeader = true
        networkHostname = nil
        action = nil
    }

    init(name: String, path: String, icon: NSImage?) {
        self.name = name
        self.path = path
        self.icon = icon
        isHeader = false
        networkHostname = nil
        action = nil
    }

    init(networkHost name: String, hostname: String, icon: NSImage?) {
        self.name = name
        path = nil
        self.icon = icon
        isHeader = false
        networkHostname = hostname
        action = nil
    }

    init(actionName name: String, icon: NSImage?, action: Selector) {
        self.name = name
        path = nil
        self.icon = icon
        isHeader = false
        networkHostname = nil
        self.action = action
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SidebarViewController
// ─────────────────────────────────────────────────────────────────────────────

final class SidebarViewController: NSViewController, NSOutlineViewDataSource,
                                   NSOutlineViewDelegate,
                                   @preconcurrency NetServiceBrowserDelegate,
                                   @preconcurrency NetServiceDelegate,
                                   NSMenuDelegate {

    weak var delegate: SidebarViewControllerDelegate?

    private var scrollView = NSScrollView()
    private var outlineView = NSOutlineView()
    private var sections: [SidebarItem] = []
    /// Set while highlightPath() is executing a programmatic selection so that
    /// outlineViewSelectionDidChange doesn't call back into the delegate (and
    /// hence pushPath) for a selection change we initiated ourselves.
    private var isHighlighting = false

    // Network discovery
    // nonisolated(unsafe): only assigned on the main actor; deinit
    // (nonisolated) needs to stop them.
    private nonisolated(unsafe) var browsers: [NetServiceBrowser] = []
    private var discoveredServices: [NetService] = []
    private var networkHeader = SidebarItem(header: "RED")
    /// Bumped on every rescan; probes from an older scan are ignored so a
    /// refresh can't be polluted by results the previous one is still yielding.
    private var discoveryGeneration = 0
    /// Addresses with a mount request in flight, so a second click (or a
    /// re-selection of the same row) doesn't stack up dialogs.
    private var mountsInFlight: Set<String> = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.wantsLayer = true

        outlineView = NSOutlineView(frame: view.bounds)
        outlineView.autoresizingMask = [.width, .height]
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 12
        outlineView.rowSizeStyle = .medium
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self

        // Drag destination – accept file drops onto sidebar items
        outlineView.registerForDraggedTypes([.fileURL])

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outlineView.addTableColumn(col)

        scrollView = NSScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        view.addSubview(scrollView)

        buildSections()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)

        // Right-click menu: connect / refresh on the RED section, connect on
        // a discovered host.
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        // Observe workspace notifications for volume mount/unmount
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)),
                           name: NSWorkspace.didUnmountNotification, object: nil)
        // Machines come and go while the app sits in the background; rescan
        // when it comes back to the front (throttled in refreshNetworkIfStale).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        browsers.forEach { $0.stop() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // ─────────────
    // Build model
    // ─────────────

    private func buildSections() {
        sections = []

        // ── Favourites ────────────────────────────────────────────────────
        let favHeader = SidebarItem(header: "FAVORITOS")
        for special in VolumeService.specialDirs() {
            favHeader.children.append(SidebarItem(
                name: special.name, path: special.path,
                icon: iconForSpecialDir(special.name, defaultPath: special.path)))
        }
        sections.append(favHeader)

        // ── Devices / Volumes ─────────────────────────────────────────────
        let volHeader = SidebarItem(header: "DISPOSITIVOS")
        populateVolumes(volHeader)
        sections.append(volHeader)

        // ── Network ───────────────────────────────────────────────────────
        networkHeader = SidebarItem(header: "RED")
        addConnectRow()
        sections.append(networkHeader)
        lastDiscoveryStart = Date()
        startNetworkDiscovery()
    }

    private func populateVolumes(_ header: SidebarItem) {
        header.children.removeAll()

        // Always add Macintosh HD (root)
        let hddIcon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.computerName)
        header.children.append(SidebarItem(name: "Macintosh HD", path: "/", icon: hddIcon))

        for vol in VolumeService.volumes() {
            // Skip the symlink that points to /
            if vol.path == "/Volumes/Macintosh HD" { continue }
            let icon = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
                ?? NSImage(named: NSImage.multipleDocumentsName)
            header.children.append(SidebarItem(name: vol.name, path: vol.path, icon: icon))
        }
    }

    private static let specialDirSymbols: [String: String] = [
        "Inicio": "house",
        "Escritorio": "desktopcomputer",
        "Documentos": "doc",
        "Descargas": "arrow.down.circle",
        "Música": "music.note",
        "Imágenes": "photo",
        "Películas": "film",
        "Aplicaciones": "square.grid.2x2",
    ]

    private func iconForSpecialDir(_ name: String, defaultPath path: String) -> NSImage {
        if let sym = Self.specialDirSymbols[name],
           let img = NSImage(systemSymbolName: sym, accessibilityDescription: name) {
            return img
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    // ─────────────
    // Volume changes
    // ─────────────

    @objc private func volumesChanged(_ note: Notification) {
        // NSWorkspace mount/unmount notifications are delivered on the main
        // thread; this @objc method is main-actor-isolated.
        // DISPOSITIVOS is the second section (index 1)
        guard sections.count >= 2 else { return }
        populateVolumes(sections[1])
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Network discovery
    // ─────────────────────────────────────────────────────────────────────────

    private func startNetworkDiscovery() {
        discoveredServices = []
        discoveryGeneration += 1

        // 1) Bonjour – finds servers that advertise via mDNS/Avahi.
        //    Requires local network access on macOS 15+; without the
        //    NSLocalNetworkUsageDescription / NSBonjourServices keys in
        //    Info.plist the browse silently returns nothing (see Scripts/bundle.sh).
        browsers.forEach { $0.stop() }
        browsers = []
        for type in ["_smb._tcp.", "_afpovertcp._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "")
            browsers.append(browser)
        }

        // 2) Port scan – finds SMB servers that don't advertise via Bonjour
        //    (Windows machines, most NAS boxes in their default config).
        scanSubnetForSMB(generation: discoveryGeneration)
    }

    /// Throw away what we found and look again.
    @objc func refreshNetwork(_ sender: Any?) {
        lastDiscoveryStart = Date()
        networkHeader.children.removeAll()
        addConnectRow()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        startNetworkDiscovery()
    }

    private var lastDiscoveryStart = Date.distantPast

    @objc private func appDidBecomeActive(_ note: Notification) {
        // Cheap enough to redo, but not on every cmd-tab.
        guard Date().timeIntervalSince(lastDiscoveryStart) > 60 else { return }
        refreshNetwork(nil)
    }

    /// The RED section always ends with a "Conectar al servidor…" row, so a
    /// host that discovery misses is still one click away.
    private func addConnectRow() {
        let icon = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        networkHeader.children.append(SidebarItem(
            actionName: "Conectar al servidor…", icon: icon,
            action: #selector(presentConnectToServer(_:))))
    }

    // ─── Bonjour delegate ────────────────────────────────────────────────────

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        discoveredServices.append(service)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService, moreComing: Bool) {
        discoveredServices.removeAll { $0 == service }
        networkHeader.children.removeAll { $0.name == service.name }
        if !moreComing {
            outlineView.reloadData()
            outlineView.expandItem(nil, expandChildren: true)
        }
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        var hostname = service.hostName ?? service.name
        if hostname.hasSuffix(".") { hostname.removeLast() }
        addNetworkHost(name: service.name, hostname: hostname)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        addNetworkHost(name: sender.name, hostname: sender.name)
    }

    // ─── Subnet scan for port 445 (SMB) ──────────────────────────────────────

    private func scanSubnetForSMB(generation: Int) {
        DispatchQueue.global().async { [weak self] in
            // Get local IPv4 addresses and their netmasks
            var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddrsPtr) == 0 else { return }
            defer { freeifaddrs(ifaddrsPtr) }

            var ifa = ifaddrsPtr
            while let cur = ifa {
                defer { ifa = cur.pointee.ifa_next }
                guard let addrPtr = cur.pointee.ifa_addr,
                      addrPtr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
                let flags = Int32(cur.pointee.ifa_flags)
                // Skip loopback; must be up and running
                if flags & IFF_LOOPBACK != 0 { continue }
                if flags & IFF_UP == 0 || flags & IFF_RUNNING == 0 { continue }

                let ip = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                guard let maskPtr = cur.pointee.ifa_netmask else { continue }
                let net = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let base = ip & net
                let bcast = base | ~net
                // Limit scan to /24 or smaller to avoid flooding large subnets
                let range = min(bcast - base, 254)

                let group = DispatchGroup()
                let queue = DispatchQueue(label: "smb.scan", attributes: .concurrent)

                for i in 1...max(range, 1) where base + i != ip { // skip self
                    let target = base + i
                    queue.async(group: group) { [weak self] in
                        self?.probeSMB(atIP: target, generation: generation)
                    }
                }

                _ = group.wait(timeout: .now() + 5)
            }
        }
    }

    /// Decode a NUL-terminated CChar buffer (replacement for the deprecated
    /// `String(cString: [CChar])` overload).
    nonisolated private static func string(fromCChars chars: [CChar]) -> String {
        let bytes = chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private func probeSMB(atIP ip: UInt32, generation: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(445).bigEndian
        addr.sin_addr.s_addr = ip.bigEndian

        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Wait up to 300ms for connection (poll ≡ the old select() wait)
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) > 0 else { return }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { return }

        // Port 445 is open – resolve hostname
        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = ip.bigEndian

        var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sa.sin_addr, &ipChars, socklen_t(INET_ADDRSTRLEN))
        let ipStr = Self.string(fromCChars: ipChars)

        var hostChars = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let resolved = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &hostChars, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }

        let displayName: String
        let hostname: String
        if resolved == 0 {
            // Got a DNS name – strip the domain suffix for display
            // (e.g. "server.local" → "server")
            let fullName = Self.string(fromCChars: hostChars)
            displayName = fullName.components(separatedBy: ".").first ?? fullName
            hostname = fullName
        } else {
            // No reverse DNS – use IP address
            displayName = ipStr
            hostname = ipStr
        }

        Task { @MainActor in
            // A refresh started after this probe – its results are stale.
            guard generation == self.discoveryGeneration else { return }
            self.addNetworkHost(name: displayName, hostname: hostname)
        }
    }

    // ─── Common helper ───────────────────────────────────────────────────────

    private func addNetworkHost(name: String, hostname: String) {
        // Avoid duplicates: the same machine can arrive twice, e.g. as
        // "nas.local" from Bonjour and as "nas.local" (or its IP) from the
        // port scan, so compare on the short name too.
        let shortName = Self.shortHostName(hostname)
        let known = networkHeader.children.contains { item in
            guard let existing = item.networkHostname else { return false }
            return existing.caseInsensitiveCompare(hostname) == .orderedSame
                || Self.shortHostName(existing).caseInsensitiveCompare(shortName) == .orderedSame
        }
        guard !known else { return }

        let icon = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.networkName)
        let item = SidebarItem(networkHost: name, hostname: hostname, icon: icon)
        // Keep "Conectar al servidor…" last.
        let insertAt = networkHeader.children.firstIndex { $0.action != nil }
            ?? networkHeader.children.count
        networkHeader.children.insert(item, at: insertAt)
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    /// "nas.local." / "192.168.1.10" → "nas" / "192.168.1.10"
    private static func shortHostName(_ host: String) -> String {
        var h = host
        if h.hasSuffix(".") { h.removeLast() }
        // Don't chop an IPv4 literal into "192".
        if h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }
        return h.components(separatedBy: ".").first ?? h
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Mounting
    // ─────────────────────────────────────────────────────────────────────────

    private func connectToNetworkHost(_ item: SidebarItem) {
        guard let hostname = item.networkHostname else { return }
        connectToServer(address: "smb://\(hostname)")
    }

    /// Ask the user for an address and mount it.
    @objc func presentConnectToServer(_ sender: Any?) {
        ConnectToServerPanel.run(on: view.window) { [weak self] address in
            guard let self, let address else { return }
            connectToServer(address: address)
        }
    }

    /// Mount `address` through NetFS — the same path Finder takes, so the
    /// standard authentication sheet and share picker appear — then navigate
    /// to the new mount point. DISPOSITIVOS refreshes itself from the
    /// NSWorkspace mount notification.
    private func connectToServer(address: String) {
        guard let url = NetworkMountService.normalizedURL(from: address) else {
            presentMountError("La dirección '\(address)' no es válida.", address: address)
            return
        }
        let key = url.absoluteString
        guard !mountsInFlight.contains(key) else { return }
        mountsInFlight.insert(key)

        NetworkMountService.mount(url) { [weak self] result in
            guard let self else { return }
            mountsInFlight.remove(key)
            switch result {
            case .success(let mountPoints):
                ConnectToServerPanel.remember(address)
                if sections.count >= 2 { populateVolumes(sections[1]) }
                outlineView.reloadData()
                outlineView.expandItem(nil, expandChildren: true)
                if let first = mountPoints.first {
                    delegate?.sidebar(self, didSelectPath: first)
                    highlightPath(first)
                }
            case .failure(.cancelled):
                break
            case .failure(let error):
                presentMountError(error.message, address: url.absoluteString)
            }
        }
    }

    private func presentMountError(_ message: String, address: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo conectar con \(address)"
        alert.informativeText = message
        alert.addButton(withTitle: "Aceptar")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API
    // ─────────────────────────────────────────────────────────────────────────

    /// Highlight the sidebar row matching the given path (best-effort).
    func highlightPath(_ path: String) {
        isHighlighting = true
        defer { isHighlighting = false }

        // Find the sidebar item whose path is the longest prefix of the
        // navigated path, so "/" (Macintosh HD) doesn't win over more specific
        // mount-points like "/Volumes/SambaShare".
        var bestMatch: SidebarItem?
        var bestLen = 0

        for section in sections {
            for item in section.children {
                guard let itemPath = item.path else { continue }
                let len = itemPath.utf16.count
                guard len > bestLen, path.hasPrefix(itemPath) else { continue }
                // Ensure the prefix ends at a path boundary: either the prefix
                // is "/" itself, the prefix equals the full path, or the
                // character right after the prefix is '/'.
                let pathLen = path.utf16.count
                if len == 1 || len == pathLen
                    || path[path.index(path.startIndex, offsetBy: len)] == "/" {
                    bestMatch = item
                    bestLen = len
                }
            }
        }

        if let bestMatch {
            let row = outlineView.row(forItem: bestMatch)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSOutlineViewDataSource
    // ─────────────────────────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let si = item as? SidebarItem else { return sections.count }
        return si.children.count
    }

    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let si = item as? SidebarItem else { return sections[index] }
        return si.children[index]
    }

    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarItem)?.children.isEmpty == false
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSOutlineViewDelegate
    // ─────────────────────────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader ?? false
    }

    func outlineView(_ ov: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.isHeader == false
    }

    func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
        guard let si = item as? SidebarItem else { return nil }

        if si.isHeader {
            let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = ov.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? {
                    let cell = NSTableCellView(frame: .zero)
                    cell.identifier = identifier
                    let tf = NSTextField(labelWithString: "")
                    tf.font = .systemFont(ofSize: 11, weight: .semibold)
                    tf.textColor = .tertiaryLabelColor
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return cell
                }()
            cell.textField?.stringValue = si.name
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("ItemCell")
        let cell = ov.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier

                let iv = NSImageView(frame: .zero)
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.imageScaling = .scaleProportionallyDown
                cell.addSubview(iv)
                cell.imageView = iv

                let tf = NSTextField(labelWithString: "")
                tf.font = .systemFont(ofSize: 13)
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                cell.addSubview(tf)
                cell.textField = tf

                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
        cell.textField?.stringValue = si.name
        let icon = si.icon ?? NSWorkspace.shared.icon(forFile: si.path ?? "/")
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if isHighlighting { return } // programmatic selection – don't push to history
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem,
              !item.isHeader else { return }

        if let action = item.action {
            // Action rows don't represent a location – drop the selection so
            // the row can be clicked again right away.
            outlineView.deselectAll(nil)
            NSApp.sendAction(action, to: self, from: nil)
            return
        }
        if item.networkHostname != nil {
            connectToNetworkHost(item)
            return
        }
        guard let path = item.path else { return }
        delegate?.sidebar(self, didSelectPath: path)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – NSMenuDelegate (right-click on the sidebar)
    // ─────────────────────────────────────────────────────────────────────────

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        let item = row >= 0 ? outlineView.item(atRow: row) as? SidebarItem : nil

        if let hostname = item?.networkHostname {
            let connect = menu.addItem(withTitle: "Conectar a \(hostname)",
                                       action: #selector(connectToClickedHost(_:)),
                                       keyEquivalent: "")
            connect.target = self
            menu.addItem(.separator())
        }

        let connectTo = menu.addItem(withTitle: "Conectar al servidor…",
                                     action: #selector(presentConnectToServer(_:)),
                                     keyEquivalent: "")
        connectTo.target = self
        let refresh = menu.addItem(withTitle: "Actualizar red",
                                   action: #selector(refreshNetwork(_:)),
                                   keyEquivalent: "")
        refresh.target = self
    }

    @objc private func connectToClickedHost(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
        connectToNetworkHost(item)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Drag destination
    // ─────────────────────────────────────────────────────────────────────────

    func outlineView(_ ov: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let si = item as? SidebarItem, !si.isHeader, si.path != nil else { return [] }
        if info.draggingSourceOperationMask.contains(.move) { return .move }
        return .copy
    }

    func outlineView(_ ov: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let si = item as? SidebarItem, !si.isHeader, let dstDir = si.path else { return false }
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let isMove = info.draggingSourceOperationMask.contains(.move)
        delegate?.sidebar(self, dropFilePaths: urls.map(\.path), toDir: dstDir, isMove: isMove)
        return true
    }
}
