import AppKit

/// The visual + interactive surface of a single overlay thumbnail.
///
/// Layout: the view is larger than the card by `Layout.shadowMargin` on every side
/// so the drop shadow has room to render (the window clips to its own frame). All
/// visible content lives inside `rootLayer`, whose anchor point is the centre so the
/// present/dismiss transforms scale and translate cleanly.
final class ThumbnailContentView: NSView, NSDraggingSource {

    enum Layout {
        static let cardSize = NSSize(width: 240, height: 160)
        static let shadowMargin: CGFloat = 24
        static let cornerRadius: CGFloat = 8

        static var windowSize: NSSize {
            NSSize(width: cardSize.width + shadowMargin * 2,
                   height: cardSize.height + shadowMargin * 2)
        }
        static var cardFrame: NSRect {
            NSRect(x: shadowMargin, y: shadowMargin,
                   width: cardSize.width, height: cardSize.height)
        }
    }

    let url: URL
    private let image: NSImage
    private let scale: CGFloat

    /// Dismiss the entire set. Set by the owning window; the view performs its own
    /// file actions (open/reveal/copy/delete) and calls this when the set should go.
    var dismissSet: (() -> Void)?

    private let rootLayer = CALayer()
    private let cardLayer = CALayer()

    // Click-vs-drag discrimination.
    private var mouseDownPoint: NSPoint?
    private var didBeginDrag = false
    private let dragThreshold: CGFloat = 6

    // Swipe-to-dismiss accumulation across one scroll gesture.
    private var swipeTravel: CGFloat = 0

    init(url: URL, image: NSImage, backingScale: CGFloat) {
        self.url = url
        self.image = image
        self.scale = backingScale
        super.init(frame: NSRect(origin: .zero, size: Layout.windowSize))
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    // MARK: - Layer construction

    private func buildLayers() {
        guard let hostLayer = layer else { return }

        rootLayer.frame = bounds
        rootLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rootLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        rootLayer.masksToBounds = false

        let card = Layout.cardFrame
        let cardPath = CGPath(roundedRect: card,
                              cornerWidth: Layout.cornerRadius,
                              cornerHeight: Layout.cornerRadius,
                              transform: nil)

        // Shadow lives on the root so it scales/fades with the content.
        rootLayer.shadowColor = NSColor.black.cgColor
        rootLayer.shadowOpacity = 0.30
        rootLayer.shadowRadius = 12
        rootLayer.shadowOffset = CGSize(width: 0, height: -4)
        rootLayer.shadowPath = cardPath

        // The card clips the image to a rounded rect and preserves the image's own
        // alpha — window captures keep their transparent shadow margin (no opaque fill).
        cardLayer.frame = card
        cardLayer.cornerRadius = Layout.cornerRadius
        cardLayer.masksToBounds = true
        cardLayer.backgroundColor = NSColor.clear.cgColor
        cardLayer.borderWidth = 1
        cardLayer.borderColor = NSColor.white.cgColor
        cardLayer.contentsGravity = .resizeAspect
        cardLayer.contentsScale = scale
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cardLayer.contents = cg
        }

        rootLayer.addSublayer(cardLayer)
        hostLayer.addSublayer(rootLayer)
    }

    // MARK: - Present / dismiss animations

    func animateIn() {
        rootLayer.opacity = 1
        rootLayer.transform = CATransform3DIdentity

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 0.9
        scaleAnim.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, fade]
        group.duration = 0.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rootLayer.add(group, forKey: "present")
    }

    /// Fade to 0 with a ~40pt rightward drift. Calls `completion` when done.
    func animateOut(completion: @escaping () -> Void) {
        let drift: CGFloat = 40
        let translate = CABasicAnimation(keyPath: "transform.translation.x")
        translate.fromValue = currentTranslationX()
        translate.toValue = currentTranslationX() + drift
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = rootLayer.presentation()?.opacity ?? rootLayer.opacity
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [translate, fade]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        rootLayer.opacity = 0
        rootLayer.add(group, forKey: "dismiss")
        CATransaction.commit()
    }

    private func currentTranslationX() -> CGFloat {
        rootLayer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat
            ?? (rootLayer.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0)
    }

    // MARK: - Mouse: click vs. drag-out

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didBeginDrag else { return }
        let p = event.locationInWindow
        if hypot(p.x - start.x, p.y - start.y) > dragThreshold {
            didBeginDrag = true
            beginFileDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didBeginDrag else { return }
        // A plain click opens the file, then the set dismisses.
        NSWorkspace.shared.open(url)
        dismissSet?()
    }

    private func beginFileDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        var frame = Layout.cardFrame
        frame = frame.insetBy(dx: 0, dy: 0)
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Dismiss only on a successful drop somewhere.
        if operation != [] {
            dismissSet?()
        }
    }

    // MARK: - Swipe to dismiss (two-finger scroll)

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            swipeTravel = 0
        }
        // Rightward travel. Sign convention assumes natural scrolling; if this ever
        // reads reversed, flip the negation here.
        swipeTravel += -event.scrollingDeltaX
        let rightward = max(0, swipeTravel)
        applyInteractiveTranslation(rightward)

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if rightward > 60 {
                dismissSet?()
            } else {
                springBack()
            }
        }
    }

    private func applyInteractiveTranslation(_ dx: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.transform = CATransform3DMakeTranslation(dx, 0, 0)
        rootLayer.opacity = Float(max(0.2, 1 - dx / 200))
        CATransaction.commit()
    }

    private func springBack() {
        let back = CABasicAnimation(keyPath: "transform.translation.x")
        back.fromValue = currentTranslationX()
        back.toValue = 0
        back.duration = 0.2
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rootLayer.transform = CATransform3DIdentity
        rootLayer.opacity = 1
        rootLayer.add(back, forKey: "springBack")
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Open", #selector(ctxOpen))
        add("Reveal in Finder", #selector(ctxReveal))
        add("Copy", #selector(ctxCopy))
        menu.addItem(.separator())
        add("Delete", #selector(ctxDelete))
        add("Dismiss", #selector(ctxDismiss))
        return menu
    }

    @objc private func ctxOpen() {
        NSWorkspace.shared.open(url)
        dismissSet?()
    }

    @objc private func ctxReveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismissSet?()
    }

    @objc private func ctxCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items: [NSPasteboardWriting] = [url as NSURL]
        if let img = NSImage(contentsOf: url) { items.append(img) }
        pb.writeObjects(items)
        // Leave the set up after a copy.
    }

    @objc private func ctxDelete() {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        dismissSet?()
    }

    @objc private func ctxDismiss() {
        dismissSet?()
    }
}
