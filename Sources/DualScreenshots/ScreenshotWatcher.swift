import Foundation
import AppKit

/// Watches the resolved screenshot directory and reports newly-written screenshot
/// files. Matches on extension + freshness + write-stability, never on filename
/// (the prefix and timestamp format are localized and user-configurable).
final class ScreenshotWatcher {

    /// Called on the main queue with the URL of a settled screenshot file.
    var onScreenshot: ((URL) -> Void)?

    /// Called on the main queue whenever the resolved directory changes, so the
    /// menu bar can reflect it.
    var onDirectoryChange: ((URL) -> Void)?

    private(set) var directory: URL

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.dualscreenshots.watcher")

    // Per-path debounce timers and the last-fired times for dedup.
    private var pendingWork: [String: DispatchWorkItem] = [:]
    private var lastFired: [String: Date] = [:]

    private var reResolveTimer: Timer?

    // Tunables from the spec.
    private let freshnessWindow: TimeInterval = 3.0
    private let dedupWindow: TimeInterval = 2.0
    private let debounce: TimeInterval = 0.150
    private let stabilityGap: TimeInterval = 0.050

    init() {
        self.directory = ScreencaptureDefaults.resolvedScreenshotDirectory()
    }

    // MARK: - Lifecycle

    func start() {
        startStream()
        // Re-resolve the directory periodically; the user can move it at any time.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.revalidate()
        }
        RunLoop.main.add(timer, forMode: .common)
        reResolveTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        stopStream()
        reResolveTimer?.invalidate()
        reResolveTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleWake() {
        reResolveDirectory()
    }

    // MARK: - Directory resolution

    private func reResolveDirectory() {
        let resolved = ScreencaptureDefaults.resolvedScreenshotDirectory()
        guard resolved != directory else { return }
        directory = resolved
        restartStream()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onDirectoryChange?(self.directory)
        }
    }

    /// Force a re-resolve + restart, e.g. after the watch dir became unreadable.
    func revalidate() {
        reResolveDirectory()
        if stream == nil { startStream() }
    }

    // MARK: - FSEvents

    private func restartStream() {
        stopStream()
        startStream()
    }

    private func startStream() {
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [directory.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |   // deliver eventPaths as a CFArray<CFString>, not char**
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // latency
            flags
        ) else {
            // Balance the retain we took for the (unused) context.
            Unmanaged<ScreenshotWatcher>.fromOpaque(info).release()
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // Release the +1 retain we handed to the stream context.
        Unmanaged.passUnretained(self).release()
        self.stream = nil
    }

    // Called on `queue` from the C callback for each changed path.
    fileprivate func handleChangedPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard isCandidate(url) else { return }

        // Debounce: wait for events to settle for this path, then confirm stability.
        pendingWork[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.confirmAndFire(url)
        }
        pendingWork[path] = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Cheap structural checks that don't touch file contents.
    private func isCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ScreencaptureDefaults.allExtensions.contains(ext) else { return false }
        // Direct child of the watch dir only, not a nested subdirectory.
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        guard parent == directory.standardizedFileURL.path else { return false }
        return true
    }

    private func confirmAndFire(_ url: URL) {
        pendingWork[url.path] = nil

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        // Freshness: ignore pre-existing files that merely got touched.
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) <= freshnessWindow else {
            return
        }

        // Write-stability: size must be unchanged across two reads. A 6K screenshot
        // is large; a naive read can catch a truncated PNG.
        guard let size1 = fileSize(url) else { return }
        Thread.sleep(forTimeInterval: stabilityGap)
        guard let size2 = fileSize(url), size1 == size2, size1 > 0 else { return }

        // Dedup: FSEvents fires repeatedly for one creation.
        let now = Date()
        if let last = lastFired[url.path], now.timeIntervalSince(last) < dedupWindow {
            return
        }
        lastFired[url.path] = now
        pruneDedupCache(now: now)

        DispatchQueue.main.async { [weak self] in
            self?.onScreenshot?(url)
        }
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.uint64Value
    }

    private func pruneDedupCache(now: Date) {
        lastFired = lastFired.filter { now.timeIntervalSince($0.value) < dedupWindow * 4 }
    }

    deinit {
        stopStream()
    }
}

// FSEvents C callback. `clientCallBackInfo` carries the retained watcher.
private func eventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()

    let paths = unsafeBitCast(eventPaths, to: NSArray.self)
    for i in 0..<count {
        guard let path = paths[i] as? String else { continue }
        watcher.handleChangedPath(path)
    }
}
