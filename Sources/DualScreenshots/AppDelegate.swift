import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let watcher = ScreenshotWatcher()
    private let presenter = ThumbnailPresenter()
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(watchDirectory: watcher.directory)

        watcher.onScreenshot = { [weak self] url in
            self?.handleScreenshot(url)
        }
        watcher.onDirectoryChange = { [weak self] dir in
            self?.menuBar.watchDirectory = dir
            self?.menuBar.directoryUnavailable = false
        }
        watcher.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
    }

    private func handleScreenshot(_ url: URL) {
        // If the image fails to load, present nothing — never a broken card.
        guard let image = ImageLoader.loadImage(from: url) else {
            NSLog("Dual Screenshots: could not load image at \(url.path); skipping.")
            return
        }
        presenter.present(url: url, image: image)
    }
}
