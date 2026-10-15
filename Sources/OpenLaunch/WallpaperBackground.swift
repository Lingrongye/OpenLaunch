import AppKit
import CoreImage
import ImageIO

/// Decode and blur only when the selected wallpaper changes, never during paging.
final class WallpaperBackground: NSView {
    private var image: NSImage?
    private var identity: String?
    private var generation = 0
    private var loadingIdentity: String?
    private(set) var usesWallpaper = false
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 1).setFill(); bounds.fill()
        guard let image else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        NSColor.black.withAlphaComponent(0.16).setFill(); bounds.fill()
    }
    func load(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            generation += 1; identity = nil; loadingIdentity = nil; image = nil; usesWallpaper = false; needsDisplay = true; return
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(url.path)|\(modified)"
        guard key != identity && key != loadingIdentity else { return }
        generation += 1; let request = generation; loadingIdentity = key
        identity = nil; image = nil; usesWallpaper = false; needsDisplay = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1400, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                let input = CIImage(cgImage: thumbnail)
                let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 22]).cropped(to: input.extent)
                let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
                return context.createCGImage(blurred, from: input.extent)
            }
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                self.loadingIdentity = nil
                guard let output else { self.identity = nil; self.image = nil; self.usesWallpaper = false; self.needsDisplay = true; return }
                self.identity = key
                self.image = NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
                self.usesWallpaper = true; self.needsDisplay = true
            }
        }
    }
}
