// App.swift
// Application entry point + delegate (port of AppDelegate.m and the old
// objc_run_app()/main.swift pair).

import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // NSApplication.delegate is weak — keep the delegate alive for the whole
    // run in a static so ARC can't release it.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }

    /// Strong-retain every FinderWindowController so ARC doesn't release it
    /// when openNewWindow's local goes out of scope. NSWindow.windowController
    /// is a non-retaining property, so without this the controller would be
    /// immediately deallocated, turning all weak delegate references into nil
    /// and making sidebar/toolbar clicks silently do nothing.
    private var openControllers: [FinderWindowController] = []

    // ───────────────────────────────────────────────
    // MARK: - App lifecycle
    // ───────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        openNewWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openNewWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // ───────────────────────────────────────────────
    // MARK: - Main menu
    // ───────────────────────────────────────────────

    private func buildMainMenu() {
        let main = NSMenu(title: "")
        NSApp.mainMenu = main

        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }

        // ── R2 Finder ─────────────────────────────────────────────────────────
        let appMenu = submenu("R2 Finder")
        appMenu.addItem(withTitle: String(localized: "About R2 Finder"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"),
                        action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: String(localized: "Services"))
        appMenu.addItem(withTitle: String(localized: "Services"), action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide R2 Finder"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit R2 Finder"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // ── Archivo ───────────────────────────────────────────────────────────
        let fileMenu = submenu(String(localized: "File"))
        let newWin = fileMenu.addItem(withTitle: String(localized: "New Window"),
                                      action: #selector(openNewWindow), keyEquivalent: "n")
        newWin.target = self

        // target = nil → first-responder chain reaches FinderWindowController
        fileMenu.addItem(withTitle: String(localized: "New Folder"),
                         action: #selector(FinderWindowController.createNewFolder(_:)),
                         keyEquivalent: "N") // Cmd+Shift+N

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Go to Folder…"),
                         action: #selector(FinderWindowController.goToFolderAction(_:)),
                         keyEquivalent: "G") // Cmd+Shift+G
        fileMenu.addItem(withTitle: String(localized: "Connect to Server…"),
                         action: #selector(FinderWindowController.connectToServerAction(_:)),
                         keyEquivalent: "k") // Cmd+K, as in Finder

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close Window"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // ── Edición ───────────────────────────────────────────────────────────
        let editMenu = submenu(String(localized: "Edit"))
        // target = nil → first-responder chain reaches FileViewController
        editMenu.addItem(withTitle: String(localized: "Copy"),
                         action: #selector(FileViewController.copySelected(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Cut"),
                         action: #selector(FileViewController.cutSelected(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Paste"),
                         action: #selector(FileViewController.pasteHere(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Select All"),
                         action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")

        // ── Ventana ───────────────────────────────────────────────────────────
        let windowMenu = submenu(String(localized: "Window"))
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: String(localized: "Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: String(localized: "Bring All to Front"),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    // ───────────────────────────────────────────────
    // MARK: - Dock context menu
    // ───────────────────────────────────────────────

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")

        let newWin = NSMenuItem(title: String(localized: "New Window"),
                                action: #selector(openNewWindow), keyEquivalent: "")
        newWin.target = self
        menu.addItem(newWin)

        let goTo = NSMenuItem(title: String(localized: "Go to Folder…"),
                              action: #selector(goToFolder), keyEquivalent: "")
        goTo.target = self
        menu.addItem(goTo)

        return menu
    }

    // ───────────────────────────────────────────────
    // MARK: - Actions
    // ───────────────────────────────────────────────

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(sender)
    }

    @objc func openNewWindow() {
        let wc = FinderWindowController(path: NSHomeDirectory())
        openControllers.append(wc) // retain so ARC doesn't free it
        if let window = wc.window {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(windowWillClose(_:)),
                                                   name: NSWindow.willCloseNotification,
                                                   object: window)
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        NotificationCenter.default.removeObserver(self,
                                                  name: NSWindow.willCloseNotification,
                                                  object: note.object)
        // Remove the controller whose window just closed; ARC will then free it.
        let closing = note.object as? NSWindow
        openControllers.removeAll { $0.window == closing }
    }

    @objc func goToFolder() {
        var parent = NSApp.mainWindow
        if parent == nil {
            // No window yet – open one first
            openNewWindow()
            parent = NSApp.mainWindow
        }

        GoToFolderPanel.runAsSheet(on: parent) { path in
            guard let path else { return }
            // If a FinderWindowController is front, navigate it; else open a new window.
            if let wc = parent?.windowController as? FinderWindowController {
                wc.navigateToPath(path)
            } else {
                FinderWindowController(path: path).showWindow(nil)
            }
        }
    }
}
