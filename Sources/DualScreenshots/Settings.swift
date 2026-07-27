import Foundation

/// App-owned preferences. We never write to `com.apple.screencapture` from here —
/// that only happens via the explicit menu-bar warning action (see ScreencaptureDefaults).
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let autoDismissSeconds = "autoDismissSeconds"
    }

    private init() {
        defaults.register(defaults: [
            Key.autoDismissSeconds: 5.0
        ])
    }

    /// Seconds before the thumbnail set auto-dismisses. A value <= 0 means "never".
    var autoDismissSeconds: Double {
        get { defaults.double(forKey: Key.autoDismissSeconds) }
        set { defaults.set(newValue, forKey: Key.autoDismissSeconds) }
    }

    /// Convenience: nil when auto-dismiss is disabled.
    var autoDismissInterval: TimeInterval? {
        let s = autoDismissSeconds
        return s > 0 ? s : nil
    }
}
