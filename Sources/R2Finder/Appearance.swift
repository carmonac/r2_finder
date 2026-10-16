// Appearance.swift
// User-chosen colors from the Settings window: file-area background, borders
// (grid lines / column separators) and folder icon tint. nil means "use the
// system default". Changes are posted as `Appearance.didChange` so every
// window restyles live.

import AppKit

@MainActor
enum Appearance {
    static let didChange = Notification.Name("R2FinderAppearanceDidChange")

    enum Key: String, CaseIterable {
        case background = "R2FinderBackgroundColor"
        case border = "R2FinderBorderColor"
        case folder = "R2FinderFolderColor"
    }

    // ── Storage ─────────────────────────────────────────────────────────────

    static func customColor(_ key: Key) -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    /// nil resets to the system default.
    static func setCustomColor(_ color: NSColor?, for key: Key) {
        // sRGB so the archive never holds a catalog/dynamic color.
        if let color = color?.usingColorSpace(.sRGB),
           let data = try? NSKeyedArchiver.archivedData(withRootObject: color,
                                                        requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: key.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        if key == .folder { tintCache.removeAllObjects() }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // ── Effective colors ────────────────────────────────────────────────────

    static var background: NSColor { customColor(.background) ?? .controlBackgroundColor }

    /// The views draw their borders with different system colors (grid lines
    /// vs. column separators), so each passes its own default.
    static func border(default systemColor: NSColor) -> NSColor {
        customColor(.border) ?? systemColor
    }

    static func systemDefault(_ key: Key) -> NSColor {
        switch key {
        case .background: return .controlBackgroundColor
        case .border: return .gridColor
        case .folder: return .systemBlue
        }
    }

    // ── Folder tint ─────────────────────────────────────────────────────────

    private static let tintCache = NSCache<NSImage, NSImage>()
    private static var packageCache: [String: Bool] = [:]

    /// The icon to show for an entry: folders get the custom tint, files and
    /// packages (.app etc. — directories, but not folders to the user) don't.
    static func icon(for entry: FileEntry) -> NSImage? {
        guard entry.isDir, let icon = entry.icon, let color = customColor(.folder),
              !isPackage(entry.path) else { return entry.icon }
        if let cached = tintCache.object(forKey: icon) { return cached }
        let tinted = tint(icon, with: color)
        tintCache.setObject(tinted, forKey: icon)
        return tinted
    }

    private static func isPackage(_ path: String) -> Bool {
        // Only names with an extension can be packages; skip the lookup for
        // the rest (most folders), and remember the answer per path.
        guard !(path as NSString).pathExtension.isEmpty else { return false }
        if let known = packageCache[path] { return known }
        let result = NSWorkspace.shared.isFilePackage(atPath: path)
        packageCache[path] = result
        return result
    }

    /// Recolor keeping the icon's shading: `.color` takes hue and saturation
    /// from the tint and luminosity from the icon, then the icon's own alpha
    /// masks the result. Drawn lazily, so it stays sharp at any size.
    private static func tint(_ image: NSImage, with color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .color)
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        return out
    }
}
