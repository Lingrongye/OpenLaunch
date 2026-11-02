import AppKit
import CryptoKit
import ImageIO
struct ApplicationRecord {
    let id: String
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let searchAliases: [String]

    init(id: String, url: URL, name: String, bundleIdentifier: String?, searchAliases: [String] = []) {
        self.id = id; self.url = url; self.name = name
        self.bundleIdentifier = bundleIdentifier; self.searchAliases = searchAliases
    }
    func matches(_ query: String) -> Bool {
        ([name] + searchAliases).contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
final class ApplicationCatalog {
    private let icons = NSCache<NSString, NSImage>()
    private let preheatQueue = DispatchQueue(label: "local.openlaunch.icon-preheat", qos: .utility)
    private let preheatLock = NSLock()
    private var preheatGeneration = 0
    private var pendingImages: [String: [(NSImage) -> Void]] = [:]
    private let iconDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OpenLaunch/Icons")
    init() { icons.totalCostLimit = 24 * 1024 * 1024; icons.countLimit = 180 }
    static func scan() -> [ApplicationRecord] {
        let fm = FileManager.default
        let roots = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/System/Applications", "/System/Cryptexes/App/System/Applications"]
        var found: [ApplicationRecord] = [], seen = Set<String>(), bundleVersions = Set<String>()
        for root in roots {
            guard let iterator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator {
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                    guard seen.insert(canonical.path).inserted, let bundle = Bundle(url: canonical), bundle.bundleIdentifier != "local.openlaunch" else { continue }
                    if let identifier = bundle.bundleIdentifier {
                        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
                        // Source order prefers /Applications, then user applications,
                        // then system locations. Keep explicitly different versions.
                        if !bundleVersions.insert(identifier + "|" + version).inserted { continue }
                    }
                    // With CFBundleAllowMixedLocalizations, Foundation resolves each
                    // target's resources using the user's language instead of our fallback.
                    let localized = bundle.localizedInfoDictionary ?? [:]
                    let name = [localized["CFBundleDisplayName"], localized["CFBundleName"],
                                bundle.infoDictionary?["CFBundleDisplayName"], bundle.infoDictionary?["CFBundleName"]]
                        .compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        ?? url.deletingPathExtension().lastPathComponent
                    let aliases = [bundle.infoDictionary?["CFBundleDisplayName"] as? String,
                                   bundle.infoDictionary?["CFBundleName"] as? String,
                                   url.deletingPathExtension().lastPathComponent].compactMap { $0 }
                    found.append(ApplicationRecord(id: canonical.path, url: canonical, name: name, bundleIdentifier: bundle.bundleIdentifier, searchAliases: aliases))
                } else if url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count > 3 { iterator.skipDescendants() }
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func icon(for record: ApplicationRecord, pixelSize: Int? = nil) -> NSImage {
        let pixels = pixelSize ?? min(256, max(96, Int(96 * (NSScreen.main?.backingScaleFactor ?? 2))))
        let memoryKey = "\(record.id)|\(pixels)" as NSString
        if let image = icons.object(forKey: memoryKey) { return image }
        let modified = (try? record.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let digest = SHA256.hash(data: Data("\(record.id)|\(modified)|\(pixels)".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = iconDirectory.appendingPathComponent(digest + ".png")
        if FileManager.default.fileExists(atPath: file.path), let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldCache: true] as CFDictionary) {
            let cached = NSImage(cgImage: decoded, size: NSSize(width: 96, height: 96))
            icons.setObject(cached, forKey: memoryKey, cost: pixels * pixels * 4); return cached
        }
        let source = NSWorkspace.shared.icon(forFile: record.url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return source }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 96, y: CGFloat(pixels) / 96)
        source.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 96, height: 96)); bitmap.size = NSSize(width: 96, height: 96); image.addRepresentation(bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        icons.setObject(image, forKey: memoryKey, cost: pixels * pixels * 4)
        return image
    }
    func cachedIcon(for record: ApplicationRecord, scale: CGFloat) -> NSImage? {
        let pixels = min(256, max(96, Int(96 * scale)))
        return icons.object(forKey: "\(record.id)|\(pixels)" as NSString)
    }
    /// Called on main; decoding/rasterization/PNG writes stay on the serial image queue.
    func requestIcon(for record: ApplicationRecord, scale: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let cached = cachedIcon(for: record, scale: scale) { completion(cached); return }
        let pixels = min(256, max(96, Int(96 * scale))), key = "\(record.id)|\(pixels)"
        if pendingImages[key] != nil { pendingImages[key]?.append(completion); return }
        pendingImages[key] = [completion]
        preheatQueue.async { [weak self] in
            guard let self else { return }
            let image = autoreleasepool { self.icon(for: record, pixelSize: pixels) }
            DispatchQueue.main.async {
                let callbacks = self.pendingImages.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }
    func prewarm(_ records: [ApplicationRecord], scale: CGFloat) {
        let pixels = min(256, max(96, Int(96 * scale)))
        let bounded = Array(records.prefix(80))
        preheatLock.lock(); preheatGeneration += 1; let generation = preheatGeneration; preheatLock.unlock()
        preheatQueue.async { [weak self] in
            guard let self else { return }
            for record in bounded {
                self.preheatLock.lock(); let current = self.preheatGeneration; self.preheatLock.unlock()
                guard current == generation else { return }
                autoreleasepool { _ = self.icon(for: record, pixelSize: pixels) }
            }
        }
    }
    func clearIcons() { icons.removeAllObjects() }
    func pruneDiskCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: iconDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        guard files.count > 256 else { return }
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in ordered.dropFirst(256) where file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }
    }
}
