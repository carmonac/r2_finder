// SettingsWindowController.swift
// Settings window (R2 Finder ▸ Settings…, ⌘,): pick the background, border and
// folder colors. Every change applies immediately through Appearance.

import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var wells: [Appearance.Key: NSColorWell] = [:]

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = String(localized: "Settings")
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        buildUI()
        win.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let rows: [(Appearance.Key, String)] = [
            (.background, String(localized: "Background:")),
            (.border, String(localized: "Borders:")),
            (.folder, String(localized: "Folders:")),
        ]

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12

        for (key, title) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right

            let well = NSColorWell()
            well.color = Appearance.customColor(key) ?? Appearance.systemDefault(key)
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 60).isActive = true
            wells[key] = well

            let reset = NSButton(title: String(localized: "Default"), target: self,
                                 action: #selector(resetColor(_:)))
            reset.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
            reset.bezelStyle = .rounded

            grid.addRow(with: [label, well, reset])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }

        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            grid.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
        ])
    }

    private func key(of sender: NSView) -> Appearance.Key? {
        sender.identifier.flatMap { Appearance.Key(rawValue: $0.rawValue) }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let key = key(of: sender) else { return }
        Appearance.setCustomColor(sender.color, for: key)
    }

    @objc private func resetColor(_ sender: NSButton) {
        guard let key = key(of: sender) else { return }
        Appearance.setCustomColor(nil, for: key)
        wells[key]?.color = Appearance.systemDefault(key)
    }

    func windowWillClose(_ notification: Notification) {
        // The shared color panel would otherwise keep editing the last well.
        wells.values.forEach { $0.deactivate() }
        NSColorPanel.shared.close()
    }
}
