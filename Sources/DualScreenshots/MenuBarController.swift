import AppKit
import ServiceManagement

/// The status-bar item and its menu. Reflects the current watch directory and the
/// native-thumbnail state, and exposes settings. Never writes to
/// `com.apple.screencapture` except via the explicit warning action.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// Current resolved watch directory, kept fresh by the app delegate.
    var watchDirectory: URL {
        didSet { rebuildMenu() }
    }

    /// Set by the app delegate when the watch directory becomes unreadable.
    var directoryUnavailable = false {
        didSet { rebuildMenu() }
    }

    init(watchDirectory: URL) {
        self.watchDirectory = watchDirectory
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                   accessibilityDescription: "Dual Screenshots")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    // Refresh volatile state (native-thumbnail flag, launch-at-login) each open.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Warning row — only when the native thumbnail is still on.
        if ScreencaptureDefaults.nativeThumbnailEnabled() {
            let warn = NSMenuItem(title: "Native thumbnail is on — click to disable",
                                  action: #selector(disableNativeThumbnail),
                                  keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                 accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        // Watch directory (informational).
        let dirTitle = directoryUnavailable
            ? "Watch folder unavailable — retrying…"
            : "Watching: \(watchDirectory.path)"
        let dirItem = NSMenuItem(title: dirTitle, action: nil, keyEquivalent: "")
        dirItem.isEnabled = false
        menu.addItem(dirItem)
        menu.addItem(.separator())

        // Auto-dismiss submenu.
        let showItem = NSMenuItem(title: "Show for", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = Settings.shared.autoDismissSeconds
        func option(_ title: String, seconds: Double) {
            let item = NSMenuItem(title: title, action: #selector(setAutoDismiss(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (current == seconds) ? .on : .off
            submenu.addItem(item)
        }
        option("3 seconds", seconds: 3)
        option("5 seconds", seconds: 5)
        option("10 seconds", seconds: 10)
        submenu.addItem(.separator())
        option("Never auto-dismiss", seconds: 0)
        showItem.submenu = submenu
        menu.addItem(showItem)

        // Launch at login.
        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Dual Screenshots",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func disableNativeThumbnail() {
        let ok = ScreencaptureDefaults.disableNativeThumbnail()
        if !ok {
            let alert = NSAlert()
            alert.messageText = "Couldn't disable the native thumbnail"
            alert.informativeText = "Try running this in Terminal:\n\ndefaults write com.apple.screencapture show-thumbnail -bool false\nkillall SystemUIServer"
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func setAutoDismiss(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        Settings.shared.autoDismissSeconds = seconds
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
