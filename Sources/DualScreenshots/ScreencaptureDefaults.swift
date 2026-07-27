import Foundation

/// Reads (and, only on explicit user action, writes) the system's
/// `com.apple.screencapture` preference domain.
///
/// We read via CFPreferences rather than a cached UserDefaults(suiteName:) so we
/// pick up changes the user makes in the Screenshot app without a restart.
enum ScreencaptureDefaults {

    private static let domain = "com.apple.screencapture" as CFString

    /// The set of file extensions `screencapture` can emit. Driven by the `type`
    /// key but we accept any of them regardless — matching by extension, never name.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "pdf", "tiff"]

    // Structured so adding "mov" for screen recordings is a one-line change.
    static let videoExtensions: Set<String> = [] // e.g. ["mov"] to enable video.

    static var allExtensions: Set<String> { imageExtensions.union(videoExtensions) }

    /// Force cfprefsd to hand us the current on-disk values before we read.
    private static func synchronize() {
        CFPreferencesAppSynchronize(domain)
    }

    private static func value(_ key: String) -> CFPropertyList? {
        synchronize()
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    /// The user's configured screenshot save location, expanded, or nil if unusable.
    static func rawLocation() -> String? {
        guard let raw = value("location") as? String, !raw.isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
    }

    /// Resolve the directory screenshots actually land in. Falls back to ~/Desktop
    /// when the key is unset or points at a path that does not exist.
    static func resolvedScreenshotDirectory() -> URL {
        let fm = FileManager.default
        if let path = rawLocation() {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return desktop
    }

    /// Whether the native macOS post-capture thumbnail is still enabled.
    /// Defaults to `true` (Apple's default) when the key is absent.
    static func nativeThumbnailEnabled() -> Bool {
        guard let v = value("show-thumbnail") else { return true }
        // CFBoolean bridges to NSNumber.
        if let n = v as? NSNumber { return n.boolValue }
        return true
    }

    /// Disable the native thumbnail. Only ever called from an explicit menu action.
    /// Returns true if the write appears to have succeeded.
    @discardableResult
    static func disableNativeThumbnail() -> Bool {
        CFPreferencesSetAppValue("show-thumbnail" as CFString, kCFBooleanFalse, domain)
        let ok = CFPreferencesAppSynchronize(domain)
        restartUIServer()
        return ok
    }

    private static func restartUIServer() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["SystemUIServer"]
        // killall exits non-zero if no matching process; that's harmless here.
        try? task.run()
    }
}
