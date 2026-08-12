// ConnectToServerPanel.swift
// "Conectar al servidor…" sheet: the escape hatch for machines that neither
// Bonjour nor the subnet scan turn up (Windows PCs that only speak
// WS-Discovery, hosts on another subnet, servers reached over a VPN).
//
// Entered addresses are remembered so the second connection is one click.

import AppKit

@MainActor
enum ConnectToServerPanel {

    private static let recentsKey = "R2FinderRecentServers"
    private static let maxRecents = 10

    static var recents: [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    /// Record a successfully mounted address as the most recent one.
    static func remember(_ address: String) {
        var list = recents.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        list.insert(address, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxRecents)), forKey: recentsKey)
    }

    /// Present the sheet on `window` (modal when nil). Calls `handler` with the
    /// address the user typed, or nil if they cancelled.
    static func run(on window: NSWindow?,
                    completionHandler handler: @escaping @MainActor (String?) -> Void) {
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        field.isEditable = true
        field.completes = true
        field.numberOfVisibleItems = maxRecents
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "smb://servidor  o  192.168.1.10"
        field.addItems(withObjectValues: recents)
        field.stringValue = recents.first ?? "smb://"

        let alert = NSAlert()
        alert.messageText = "Conectar al servidor"
        alert.informativeText = "Escribe la dirección del servidor (smb://, afp://, nfs://). "
            + "Sin protocolo se usa SMB."
        alert.addButton(withTitle: "Conectar")
        alert.addButton(withTitle: "Cancelar")
        alert.accessoryView = field

        func finish(_ response: NSApplication.ModalResponse) {
            guard response == .alertFirstButtonReturn else { handler(nil); return }
            let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            handler(entered.isEmpty ? nil : entered)
        }

        if let window {
            alert.beginSheetModal(for: window) { finish($0) }
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
            }
        } else {
            finish(alert.runModal())
        }
    }
}
