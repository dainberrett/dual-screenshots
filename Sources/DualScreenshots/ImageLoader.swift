import AppKit
import AVFoundation

/// Source-agnostic loader: hand it any URL screencapture can produce and get back an
/// NSImage. Images load directly (alpha preserved); video uses the first frame so the
/// thumbnail view never needs to know what kind of file it is displaying.
enum ImageLoader {

    static func loadImage(from url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        if ScreencaptureDefaults.videoExtensions.contains(ext) {
            return firstFrame(of: url)
        }
        // NSImage(contentsOf:) preserves alpha for PNG/TIFF window captures.
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    private static func firstFrame(of url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
