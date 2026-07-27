import AppKit

/// Owns the set of overlay windows — one per screen — and their shared lifecycle.
/// A single presentation shows the same image on every display and dismisses all of
/// them together, by every dismissal path.
final class ThumbnailPresenter {

    private var windows: [ThumbnailWindow] = []
    private var dismissTimer: Timer?
    private var isDismissing = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var hasActiveSet: Bool { !windows.isEmpty && !isDismissing }

    // MARK: - Presentation

    func present(url: URL, image: NSImage) {
        // A new screenshot replaces any current set immediately, no animation.
        tearDownImmediately()

        for screen in NSScreen.screens {
            let window = ThumbnailWindow(url: url, image: image, screen: screen)
            window.thumbView.dismissSet = { [weak self] in
                self?.dismiss(animated: true)
            }
            window.orderFrontRegardless()
            window.thumbView.animateIn()
            windows.append(window)
        }

        guard !windows.isEmpty else { return }
        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let interval = Settings.shared.autoDismissInterval else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    // MARK: - Dismissal

    func dismiss(animated: Bool) {
        guard hasActiveSet else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard animated else { tearDownImmediately(); return }

        isDismissing = true
        let closing = windows
        windows = []

        let group = DispatchGroup()
        for window in closing {
            group.enter()
            window.thumbView.animateOut {
                window.orderOut(nil)
                window.close()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.isDismissing = false
        }
    }

    private func tearDownImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for window in windows {
            window.thumbView.layer?.removeAllAnimations()
            window.orderOut(nil)
            window.close()
        }
        windows = []
        isDismissing = false
    }

    // MARK: - Screen configuration changes

    @objc private func screenParametersChanged() {
        guard !windows.isEmpty else { return }

        // Live display IDs → live NSScreen, so we never touch a stale screen object.
        var liveByID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { liveByID[id] = screen }
        }

        // Drop windows whose display is gone.
        var survivors: [ThumbnailWindow] = []
        for window in windows {
            if let id = window.displayID, let screen = liveByID[id] {
                window.reposition(on: screen)
                survivors.append(window)
            } else {
                window.orderOut(nil)
                window.close()
            }
        }
        windows = survivors

        // If a set is still visible, extend it onto any newly-attached displays.
        guard hasActiveSet, let template = survivors.first else { return }
        let coveredIDs = Set(survivors.compactMap { $0.displayID })
        for (id, screen) in liveByID where !coveredIDs.contains(id) {
            let window = ThumbnailWindow(
                url: template.thumbView.url,
                image: templateImage(from: template),
                screen: screen
            )
            window.thumbView.dismissSet = { [weak self] in
                self?.dismiss(animated: true)
            }
            window.orderFrontRegardless()
            window.thumbView.animateIn()
            windows.append(window)
        }
    }

    /// Re-load the image for a freshly-attached screen from the same URL so its
    /// backing scale is honoured.
    private func templateImage(from window: ThumbnailWindow) -> NSImage {
        ImageLoader.loadImage(from: window.thumbView.url)
            ?? NSImage(size: ThumbnailContentView.Layout.cardSize)
    }
}
