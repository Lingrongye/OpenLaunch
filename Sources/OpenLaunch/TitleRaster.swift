import AppKit

/// Immutable, prepared title pixels. Motion never asks an offscreen NSTextField to draw.
final class TitleRaster {
    static let shared = TitleRaster()
    private final class Entry { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private let cache = NSCache<NSString, Entry>()
    private init() { cache.countLimit = 140; cache.totalCostLimit = 6 * 1024 * 1024 }
    func image(text: String, size: NSSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let key = "\(text)|\(size.width)|\(size.height)|\(scale)" as NSString
        if let ready = cache.object(forKey: key) { return ready.image }
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow])
        label.draw(with: NSRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        cache.setObject(Entry(image), forKey: key, cost: width * height * 4)
        return image
    }
}
