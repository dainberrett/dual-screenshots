import AppKit

extension NSScreen {
    /// Stable identifier for a physical display, survives NSScreen object churn on
    /// configuration changes (docking, resolution changes, etc.).
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// A single borderless, non-activating overlay panel that hosts one thumbnail.
/// Never becomes key or main, so clicking it never activates our app or deactivates
/// whatever the user was working in.
final class ThumbnailWindow: NSPanel {

    /// The physical display this window belongs to. Used to re-find the live NSScreen
    /// after a configuration change instead of holding a possibly-stale object.
    let displayID: CGDirectDisplayID?

    let thumbView: ThumbnailContentView

    init(url: URL, image: NSImage, screen: NSScreen) {
        self.displayID = screen.displayID
        let scale = screen.backingScaleFactor
        self.thumbView = ThumbnailContentView(url: url, image: image, backingScale: scale)

        let size = ThumbnailContentView.Layout.windowSize
        let origin = ThumbnailWindow.origin(for: screen, size: size)

        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false

        contentView = thumbView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Bottom-right of the screen's visibleFrame, inset 20pt from the right and bottom
    /// so the card clears the Dock (visibleFrame excludes it). The window is larger
    /// than the card by the shadow margin, so we offset by that margin.
    static func origin(for screen: NSScreen, size: NSSize) -> NSPoint {
        let vf = screen.visibleFrame
        let margin = ThumbnailContentView.Layout.shadowMargin
        let inset: CGFloat = 20
        let card = ThumbnailContentView.Layout.cardSize
        let x = vf.maxX - inset - card.width - margin
        let y = vf.minY + inset - margin
        return NSPoint(x: x, y: y)
    }

    /// Recompute position against the given (live) screen's current visibleFrame.
    func reposition(on screen: NSScreen) {
        let size = ThumbnailContentView.Layout.windowSize
        setFrameOrigin(ThumbnailWindow.origin(for: screen, size: size))
    }
}
