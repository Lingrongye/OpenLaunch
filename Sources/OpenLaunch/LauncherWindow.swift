import AppKit
import OpenLaunchCore

private extension NSRect { var center: NSPoint { NSPoint(x: midX, y: midY) } }
private final class VerticallyCenteredSearchFieldCell: NSSearchFieldCell {
    override func titleRect(forBounds bounds: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: bounds)
        title.origin.y = bounds.minY + (bounds.height - title.height) / 2
        return title
    }
    override func drawingRect(forBounds bounds: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: bounds)
        drawing.origin.y = bounds.minY + (bounds.height - drawing.height) / 2
        return drawing
    }
}
extension NSPasteboard.PasteboardType { static let launcherItem = NSPasteboard.PasteboardType("local.openlaunch.item") }
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onEscape: (() -> Void)?
    var onPage: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 123 { onPage?(-1); return }
        if event.keyCode == 124 { onPage?(1); return }
        super.keyDown(with: event)
    }
}
final class GridView: NSCollectionView {
    // These are bounded page buffers, never an unbounded scrolling list. Keep
    // their items prepared even while Core Animation moves a neighbor onscreen.
    override var visibleRect: NSRect { bounds }
    var onPage: ((Int) -> Void)?
    var onSwipeStart: (() -> Double?)?
    var onSwipeOffset: ((Double) -> Void)?
    var onSwipeFinish: ((Int, Double, Int) -> Void)?
    var canPrevious = false
    var canNext = false
    private var gesture = PagingGesture()
    private var swipeEvents = 0
    private var lastWheel: TimeInterval = 0
    private var phaselessDelta: CGFloat = 0
    private var dragEdge = 0
    private var edgeTimer: Timer?
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let edge = p.x < bounds.minX + 24 ? -1 : (p.x > bounds.maxX - 24 ? 1 : 0)
        if edge != dragEdge {
            edgeTimer?.invalidate(); edgeTimer = nil; dragEdge = edge
            if edge != 0 {
                edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in guard let self else { return }; self.onPage?(self.dragEdge) }
                if let timer = edgeTimer { RunLoop.main.add(timer, forMode: .common) }
            }
        }
        return super.draggingUpdated(sender)
    }
    private func clearDragEdge() { edgeTimer?.invalidate(); edgeTimer = nil; dragEdge = 0 }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDragEdge(); super.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearDragEdge(); super.draggingEnded(sender) }
    override func scrollWheel(with event: NSEvent) {
        if !event.momentumPhase.isEmpty {
            if gesture.isTracking { finishSwipe(cancelled: false) }
            return // A completed touch gesture cannot turn an extra page during momentum.
        }
        let phased = !event.phase.isEmpty
        if event.hasPreciseScrollingDeltas && phased {
            if !gesture.isTracking && !event.phase.contains(.ended) && !event.phase.contains(.cancelled) {
                guard let initialOffset = onSwipeStart?() else { return }
                gesture.begin(width: Double(bounds.width), canPrevious: canPrevious, canNext: canNext, initialOffset: initialOffset)
                swipeEvents = 0
            }
            if gesture.isTracking {
                swipeEvents += 1
                if !event.phase.contains(.cancelled) && (abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0.001) {
                    let offset = gesture.update(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), timestamp: event.timestamp)
                    onSwipeOffset?(offset)
                    if !gesture.isTracking { onSwipeFinish?(0, 0, swipeEvents); return }
                }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) { finishSwipe(cancelled: event.phase.contains(.cancelled)) }
            }
        } else {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                if event.timestamp - lastWheel > 0.25 || delta * phaselessDelta < 0 { phaselessDelta = 0 }
                lastWheel = event.timestamp; phaselessDelta += delta
                if abs(phaselessDelta) >= 40 { onPage?(phaselessDelta < 0 ? 1 : -1); phaselessDelta = 0 }
            } else if abs(delta) >= 0.5 && event.timestamp - lastWheel > 0.16 { lastWheel = event.timestamp; onPage?(delta < 0 ? 1 : -1) }
        }
    }
    func resetPagingState() { gesture.reset(); phaselessDelta = 0; clearDragEdge() }
    private func finishSwipe(cancelled: Bool) {
        let offset = gesture.offset
        let delta = gesture.end(cancelled: cancelled)
        onSwipeFinish?(delta, offset, swipeEvents)
    }
}
final class IconItem: NSCollectionViewItem {
    override func loadView() { view = IconTile(frame: NSRect(x: 0, y: 0, width: 130, height: 132)) }
}
final class IconTile: NSView, NSDraggingSource {
    let image = NSImageView()
    let title = NSTextField(labelWithString: "")
    private let titlePixels = CALayer()
    fileprivate let hoverLayer = CALayer()
    private var rasterKey = ""
    private var alphaMask: [UInt8] = []
    private var alphaMaskSize = NSSize.zero
    private var hoverIsActive = false
    var hasArtworkHover: Bool { hoverIsActive }
    var hasPreparedTitle: Bool { titlePixels.contents != nil }
    weak var owner: LauncherController?
    var node: LayoutNode? { didSet { clearHover() } }
    private var down: NSEvent?
    private var dragged = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverLayer.opacity = 0
        layer?.insertSublayer(hoverLayer, at: 0)
        image.imageScaling = .scaleProportionallyUpOrDown
        title.alignment = .center; title.textColor = .white; title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 2
        title.cell?.wraps = true
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.4); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1); title.shadow = shadow
        addSubview(image); layer?.addSublayer(titlePixels)
    }
    required init?(coder: NSCoder) { fatalError() }
    private var hover: NSTrackingArea?
    override func layout() {
        super.layout()
        // Icon size and title layout are independent of the highlight square.
        let side = max(40, min(100, min(bounds.width * 0.63, bounds.height - 56)))
        // Keep the title visible below the icon while leaving more room above it.
        let imageY = min(max((bounds.height - side) / 2, 38), bounds.height - side - 4)
        image.frame = NSRect(x: (bounds.width - side) / 2, y: imageY, width: side, height: side)
        // Grow as much as the icon's centered position allows, without clipping the tile.
        let shadowCenterY = image.frame.midY - 6
        let cellLimit = floor(min(bounds.width, bounds.height) - 4)
        let iconCenterLimit = floor(2 * min(
            image.frame.midX - bounds.minX,
            bounds.maxX - image.frame.midX,
            shadowCenterY - bounds.minY,
            bounds.maxY - shadowCenterY
        ) - 4)
        let hoverSide = max(1, min(cellLimit, iconCenterLimit))
        let titleWidth = max(32, bounds.width - 24)
        title.frame = NSRect(x: (bounds.width - titleWidth) / 2, y: image.frame.minY - 38, width: titleWidth, height: 34)
        hoverLayer.frame = CGRect(x: image.frame.midX - hoverSide / 2, y: shadowCenterY - hoverSide / 2, width: hoverSide, height: hoverSide)
        hoverLayer.cornerRadius = min(18, hoverSide * 0.16)
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        updateTitlePixels()
    }
    fileprivate var visibleTitleFrame: CGRect {
        let font = title.font ?? .systemFont(ofSize: 13, weight: .medium)
        let measured = (title.stringValue as NSString).size(withAttributes: [.font: font])
        let width = min(title.frame.width, ceil(measured.width))
        let lines = max(1, min(2, Int(ceil(measured.width / max(1, title.frame.width)))))
        let lineHeight = font.ascender - font.descender + font.leading
        let height = min(title.frame.height, ceil(lineHeight * CGFloat(lines)))
        return CGRect(x: title.frame.midX - width / 2, y: title.frame.midY - height / 2, width: width, height: height)
    }
    func updateTitlePixels() {
        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(title.stringValue)|\(title.frame)|\(scale)"
        guard key != rasterKey else { return }
        rasterKey = key
        CATransaction.begin(); CATransaction.setDisableActions(true)
        titlePixels.frame = title.frame; titlePixels.contentsScale = scale
        titlePixels.contents = TitleRaster.shared.image(text: title.stringValue, size: title.frame.size, scale: scale)
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hover == nil else { return }
        hover = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        if let hover { addTrackingArea(hover) }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: event.locationInWindow) }
    func updateHover(at windowPoint: NSPoint) {
        let shouldHover = owner?.allowsTileInteraction == true && containsIconArtwork(windowPoint)
        guard hoverIsActive != shouldHover else { return }
        hoverIsActive = shouldHover
        hoverLayer.opacity = shouldHover ? 1 : 0
    }
    func clearHover() { hoverIsActive = false; hoverLayer.opacity = 0 }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); clearHover() }
    override func mouseExited(with event: NSEvent) { clearHover() }
    func setIcon(_ value: NSImage?) {
        image.image = value
        alphaMask.removeAll(keepingCapacity: true)
        alphaMaskSize = .zero
        guard let cgImage = value?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if ok {
            alphaMask = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
            alphaMaskSize = NSSize(width: width, height: height)
        }
    }
    func containsIconArtwork(_ windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        guard image.frame.contains(point), !alphaMask.isEmpty, alphaMaskSize.width > 0, alphaMaskSize.height > 0 else { return false }
        let scale = min(image.frame.width / alphaMaskSize.width, image.frame.height / alphaMaskSize.height)
        let width = alphaMaskSize.width * scale, height = alphaMaskSize.height * scale
        let artwork = NSRect(x: image.frame.midX - width / 2, y: image.frame.midY - height / 2, width: width, height: height)
        guard artwork.contains(point) else { return false }
        let x = min(Int(alphaMaskSize.width) - 1, max(0, Int((point.x - artwork.minX) / artwork.width * alphaMaskSize.width)))
        let y = min(Int(alphaMaskSize.height) - 1, max(0, Int((point.y - artwork.minY) / artwork.height * alphaMaskSize.height)))
        return alphaMask[y * Int(alphaMaskSize.width) + x] > 16
    }
    override func mouseDown(with event: NSEvent) { down = event; dragged = false }
    override func mouseUp(with event: NSEvent) { if !dragged, down != nil, owner?.allowsTileInteraction == true, containsIconArtwork(event.locationInWindow), let node { owner?.activate(node) }; down = nil }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let node, let down, hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 5 else { return }
        dragged = true
        let pb = NSPasteboardItem(); pb.setString(node.id, forType: .launcherItem)
        if case .application(let id) = node { pb.setString(URL(fileURLWithPath: id).absoluteString, forType: .fileURL) }
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(image.frame, contents: image.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : .copy }
    override func accessibilityPerformPress() -> Bool { guard let node, let owner else { return false }; owner.activate(node); return true }
    override func rightMouseDown(with event: NSEvent) { if let node { owner?.contextMenu(node, event: event, view: self) } }
}
final class LauncherController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    let window: LauncherPanel
    let catalog = ApplicationCatalog()
    let search = NSSearchField()
    private(set) var collection = GridView()
    private var previousCollection = GridView()
    private var nextCollection = GridView()
    private let gestureReceiver = GridView()
    private let pageViewport = NSView()
    private let pageStrip = NSView()
    private var previousDisplayed: [LayoutNode] = []
    private var nextDisplayed: [LayoutNode] = []
    private var paging = false
    private var settlingTarget: Int?
    private var nativeContinuityError = 0.0
    var allowsTileInteraction: Bool { !paging && !pinchRevealing && !revealAnimating }
    private let reportQueue = DispatchQueue(label: "local.openlaunch.paging-reports", qos: .utility)
    private var currentOffset: Double = 0
    let countLabel = NSTextField(labelWithString: "")
    let breadcrumb = NSTextField(labelWithString: "")
    let pages = NSStackView()
    let statusLabel = NSTextField(labelWithString: "")
    private let folderBackdrop = NSVisualEffectView()
    private let wallpaper = WallpaperBackground(frame: .zero)
    private let searchSurface = NSVisualEffectView()
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var pinchRevealing = false
    private var pinchSuppressed = false
    private var revealAnimating = false
    private var revealClosing = false
    private var revealProgress: Double = 1
    private var revealToken = 0
    private var transitionID = 0
    private let frameMeter = PagingFrameMeter()
    private var pendingPagingReport: [String: Any]?
    private var priorPresentationOptions: NSApplication.PresentationOptions?
    private let flow = NSCollectionViewFlowLayout()
    private let scroll = NSScrollView()
    private var records: [String: ApplicationRecord] = [:]
    private var orderedRecords: [ApplicationRecord] = []
    private var dirtyFolderIDs = Set<String>()
    private let reportDirectory: URL
    private let store: LayoutStore
    private(set) var layoutModel: Layout
    private var lastSavedLayout: Layout?
    private var items: [LayoutNode] = []
    private var displayed: [LayoutNode] = []
    private var page = 0
    private var pageSize = 35
    private var folder: String?
    private var query = ""
    private var settings: NSWindow?
    private let input: InputController
    var onHide: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShortcutChanged: ((Int) -> Void)?
    private let settingsButton = NSButton()
    private let backButton = NSButton()
    private let defaults = UserDefaults.standard
    private(set) var scanDuration: Double = 0
    private(set) var loadError: String?
    private var statusObserver: NSObjectProtocol?
    private var iconScale: CGFloat { window.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var appCount: Int { records.count }
    var smokeImageStatus: [String: Any] {
        let apps = displayed.flatMap(\.apps).compactMap { records[$0] }
        let ready = apps.filter { catalog.cachedIcon(for: $0, scale: iconScale) != nil }.count
        let labels = nextDisplayed.indices.compactMap { nextCollection.item(at: IndexPath(item: $0, section: 0))?.view as? IconTile }
        return ["wallpaper": wallpaper.usesWallpaper, "visible_apps": apps.count, "visible_icon_rasters_ready": ready, "neighbor_title_pixels_ready": labels.filter(\.hasPreparedTitle).count, "neighbor_titles_expected": nextDisplayed.count]
    }
    init(storeURL: URL, input: InputController) {
        self.input = input
        reportDirectory = storeURL.deletingLastPathComponent()
        store = LayoutStore(url: storeURL)
        do { layoutModel = try store.load() } catch { layoutModel = Layout(); loadError = error.localizedDescription }
        window = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        if loadError == nil { lastSavedLayout = layoutModel }
        window.styleMask.remove(.nonactivatingPanel)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.title = "OpenLaunch"
        window.onEscape = { [weak self] in self?.escape() }
        window.onPage = { [weak self] in self?.turnPage($0) }
        for grid in [collection, previousCollection, nextCollection, gestureReceiver] {
            grid.onPage = window.onPage
            grid.onSwipeStart = { [weak self] in self?.beginSwipe() }
            grid.onSwipeOffset = { [weak self] offset in self?.dragPage(offset) }
            grid.onSwipeFinish = { [weak self] delta, offset, events in self?.finishSwipe(delta: delta, offset: offset, events: events) }
        }
        buildView()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.window.isVisible else { return event }
            self.gestureReceiver.scrollWheel(with: event); return nil
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.isVisible else { return event }
            guard self.allowsTileInteraction else { return nil }
            if self.shouldDismissBackground(at: event.locationInWindow) { self.dismiss(); return nil }
            return event
        }
        input.onStatusChanged = { [weak self] in self?.statusLabel.stringValue = self?.input.status ?? "" }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }
    private func button(_ symbol: String, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        b.isBordered = false; b.contentTintColor = .white
        return b
    }
    private func buildView() {
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        wallpaper.frame = root.bounds; wallpaper.autoresizingMask = [.width, .height]; root.addSubview(wallpaper)
        searchSurface.material = .hudWindow; searchSurface.blendingMode = .withinWindow; searchSurface.state = .active
        searchSurface.wantsLayer = true; searchSurface.layer?.cornerRadius = 24; searchSurface.layer?.masksToBounds = true
        searchSurface.layer?.borderWidth = 0.6; searchSurface.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        root.addSubview(searchSurface)
        search.cell = VerticallyCenteredSearchFieldCell(textCell: "")
        search.placeholderString = "搜索应用"; search.font = .systemFont(ofSize: 18)
        search.isBordered = false; search.drawsBackground = false
        if let cell = search.cell as? NSSearchFieldCell { cell.searchButtonCell = nil }
        let magnifier = NSImageView(frame: NSRect(x: 17, y: 15, width: 18, height: 18))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil); magnifier.contentTintColor = .white.withAlphaComponent(0.65)
        searchSurface.addSubview(magnifier)
        search.focusRingType = .none; search.delegate = self
        search.sendsSearchStringImmediately = true
        searchSurface.addSubview(search)
        settingsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "设置"); settingsButton.target = self; settingsButton.action = #selector(showSettings)
        settingsButton.toolTip = "设置"; settingsButton.setAccessibilityLabel("设置")
        settingsButton.isBordered = false; settingsButton.contentTintColor = .white; searchSurface.addSubview(settingsButton)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回"); backButton.target = self; backButton.action = #selector(goBack)
        backButton.isBordered = false; backButton.contentTintColor = .white; root.addSubview(backButton)
        countLabel.isHidden = true; countLabel.font = .systemFont(ofSize: 12); countLabel.textColor = .white.withAlphaComponent(0.5); root.addSubview(countLabel)
        breadcrumb.font = .systemFont(ofSize: 21, weight: .medium); breadcrumb.textColor = .white; breadcrumb.alignment = .center; root.addSubview(breadcrumb)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        flow.minimumInteritemSpacing = 0; flow.minimumLineSpacing = 0; flow.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        for grid in [collection, previousCollection, nextCollection] {
            let layout = grid === collection ? flow : NSCollectionViewFlowLayout()
            layout.minimumInteritemSpacing = 0; layout.minimumLineSpacing = 0
            layout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            grid.collectionViewLayout = layout; grid.dataSource = self; grid.delegate = self
            grid.backgroundColors = [.clear]; grid.isSelectable = false; grid.wantsLayer = true
            grid.register(IconItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("icon"))
            grid.registerForDraggedTypes([.launcherItem]); grid.setDraggingSourceOperationMask(.move, forLocal: true)
        }
        folderBackdrop.material = .popover; folderBackdrop.blendingMode = .withinWindow; folderBackdrop.state = .active
        folderBackdrop.wantsLayer = true; folderBackdrop.layer?.cornerRadius = 28; folderBackdrop.layer?.masksToBounds = true; folderBackdrop.isHidden = true
        root.addSubview(folderBackdrop, positioned: .below, relativeTo: breadcrumb)
        pageViewport.wantsLayer = true; pageViewport.layer?.masksToBounds = true
        pageStrip.wantsLayer = true
        root.addSubview(pageViewport); pageViewport.addSubview(pageStrip)
        for grid in [previousCollection, collection, nextCollection] { pageStrip.addSubview(grid) }
        pages.orientation = .horizontal; pages.spacing = 12; pages.alignment = .centerY; root.addSubview(pages)
        rearrangeFrames()
    }
    func rearrangeFrames() {
        cancelPaging()
        guard let root = window.contentView else { return }
        let size = root.bounds.size
        let searchWidth = min(410, size.width - 120)
        searchSurface.frame = NSRect(x: (size.width - searchWidth) / 2, y: size.height - 108, width: searchWidth, height: 48)
        // Keep AppKit's native search-cell insets and baseline inside the pill.
        search.frame = NSRect(x: 43, y: -13, width: searchWidth - 90, height: 48)
        settingsButton.frame = NSRect(x: searchWidth - 45, y: 8, width: 32, height: 32)
        backButton.frame = NSRect(x: 42, y: size.height - 76, width: 32, height: 32)
        countLabel.frame = NSRect(x: 86, y: size.height - 72, width: 200, height: 20)
        breadcrumb.frame = NSRect(x: size.width / 2 - 200, y: size.height - 126, width: 400, height: 30)
        let margin: CGFloat = max(60, size.width * 0.08)
        scroll.frame = NSRect(x: margin, y: 85, width: size.width - margin * 2, height: size.height - 250)
        let inFolder = folder != nil && query.isEmpty
        folderBackdrop.isHidden = !inFolder
        if inFolder {
            let width = min(680, size.width - 160), height = min(450, size.height - 260)
            scroll.frame = NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2 - 10, width: width, height: height)
            folderBackdrop.frame = scroll.frame.insetBy(dx: -22, dy: -22)
            breadcrumb.frame = NSRect(x: scroll.frame.minX, y: scroll.frame.maxY + 24, width: width, height: 30)
        }
        let cols = inFolder ? 3 : (size.width < 950 ? 6 : 7)
        let rows = inFolder ? 3 : max(3, min(5, Int(scroll.frame.height / 136)))
        pageSize = cols * rows
        flow.itemSize = NSSize(width: floor(scroll.frame.width / CGFloat(cols)), height: floor(scroll.frame.height / CGFloat(rows)))
        pageViewport.frame = scroll.frame
        let width = scroll.frame.width, height = scroll.frame.height
        pageStrip.frame = NSRect(x: -width, y: 0, width: width * 3, height: height)
        for (index, grid) in [previousCollection, collection, nextCollection].enumerated() {
            (grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = flow.itemSize
            grid.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        refresh()
    }
    func scan(completion: (() -> Void)? = nil) {
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async {
            let discovered = ApplicationCatalog.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanDuration = ProcessInfo.processInfo.systemUptime - start
                self.orderedRecords = discovered; self.records = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
                self.layoutModel.merge(discovered: discovered.map(\.id))
                self.save(); self.refresh(); completion?()
            }
        }
    }
    private func cancelPaging() {
        if pendingPagingReport != nil { completePagingReport(status: "interrupted") } else { _ = frameMeter.stop() }
        transitionID += 1; paging = false; settlingTarget = nil
        for grid in [collection, previousCollection, nextCollection, gestureReceiver] { grid.resetPagingState() }
        pageStrip.layer?.removeAllAnimations()
        setPageTranslation(0); clearTileHover()
    }
    private func revealTransform(_ progress: Double) -> CATransform3D {
        let scale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : CGFloat(1.16 - progress * 0.16)
        let center = NSPoint(x: pageViewport.bounds.midX, y: pageViewport.bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }
    private func setRevealProgress(_ value: Double) {
        revealProgress = max(0, min(1, value))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageViewport.layer?.sublayerTransform = revealTransform(revealProgress)
        CATransaction.commit()
        window.alphaValue = revealProgress
    }
    private func preparePresentation() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        cancelPaging()
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false); rearrangeFrames() }
        wallpaper.load(for: screen)
        if priorPresentationOptions == nil { priorPresentationOptions = NSApp.presentationOptions }
        NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        setRevealProgress(0)
        window.makeKeyAndOrderFront(nil)
        for grid in [previousCollection, collection, nextCollection] {
            grid.prepareContent(in: grid.bounds); grid.needsLayout = true; grid.layoutSubtreeIfNeeded()
        }
        window.makeFirstResponder(search)
    }
    private func animateReveal(to target: Double, duration: Double) {
        revealToken += 1; let token = revealToken; revealAnimating = true; revealClosing = target == 0
        let from = pageViewport.layer?.presentation()?.sublayerTransform ?? revealTransform(revealProgress)
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: revealTransform(target))
        animation.duration = duration; animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageViewport.layer?.sublayerTransform = revealTransform(target)
        pageViewport.layer?.add(animation, forKey: "reveal")
        CATransaction.commit()
        revealProgress = target
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            guard let self, token == self.revealToken else { return }
            self.revealAnimating = false
            if target == 0 { self.hide() } else { self.setRevealProgress(1) }
        })
    }
    func show() {
        if window.isVisible && !pinchRevealing { return }
        pinchRevealing = false; revealToken += 1
        pageViewport.layer?.removeAnimation(forKey: "reveal")
        preparePresentation(); animateReveal(to: 1, duration: 0.16)
    }
    func updatePinchReveal(_ progress: Double) {
        guard !pinchSuppressed else { return }
        guard !window.isVisible || pinchRevealing else { return }
        guard progress >= 0.10 || pinchRevealing else { return }
        if !pinchRevealing {
            revealToken += 1; revealAnimating = false; pinchRevealing = true
            pageViewport.layer?.removeAnimation(forKey: "reveal")
            preparePresentation()
        }
        setRevealProgress(progress)
    }
    /// Inward pinches are idempotent: they never close an already open launcher.
    func commitPinchReveal() {
        guard !pinchSuppressed else { return }
        if pinchRevealing || revealClosing { pinchRevealing = false; animateReveal(to: 1, duration: 0.14) }
        else if !window.isVisible { show() }
    }
    func endPinchReveal(committed: Bool) {
        defer { pinchSuppressed = false }
        guard pinchRevealing else { return }
        pinchRevealing = false
        animateReveal(to: committed ? 1 : 0, duration: 0.14)
    }
    func dismiss() {
        guard window.isVisible else { return }
        pinchSuppressed = pinchSuppressed || pinchRevealing; pinchRevealing = false
        cancelPaging(); clearTileHover(); animateReveal(to: 0, duration: 0.14)
    }
    func hide() {
        pinchSuppressed = pinchSuppressed || pinchRevealing; pinchRevealing = false
        revealToken += 1; revealAnimating = false; revealClosing = false
        pageViewport.layer?.removeAnimation(forKey: "reveal")
        cancelPaging()
        window.orderOut(nil); setRevealProgress(1)
        if let priorPresentationOptions { NSApp.presentationOptions = priorPresentationOptions; self.priorPresentationOptions = nil }
        onHide?()
    }
    func toggle() { window.isVisible ? dismiss() : show() }
    func shouldDismissBackground(at point: NSPoint) -> Bool {
        guard let root = window.contentView else { return false }
        let local = root.convert(point, from: nil)
        if searchSurface.frame.contains(local) || (!backButton.isHidden && backButton.frame.contains(local)) { return false }
        let pageControlPoint = pages.convert(point, from: nil)
        if pages.arrangedSubviews.contains(where: { !$0.isHidden && $0.frame.contains(pageControlPoint) }) { return false }
        // A collection cell and its label are larger than the visible icon.
        // Only the icon artwork is an application target, never cell padding.
        for item in collection.visibleItems() {
            guard let tile = item.view as? IconTile else { continue }
            if tile.containsIconArtwork(point) { return false }
        }
        return true
    }
    private func visible(_ node: LayoutNode) -> Bool { node.apps.contains { !layoutModel.hidden.contains($0) } }
    func refresh() {
        cancelPaging()
        if !query.isEmpty {
            items = orderedRecords.filter { !layoutModel.hidden.contains($0.id) && $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map { .application($0.id) }
        } else if let folder {
            items = layoutModel.children(of: folder).filter { !layoutModel.hidden.contains($0) }.map(LayoutNode.application)
        } else { items = layoutModel.nodes.filter(visible) }
        let total = max(1, (items.count + pageSize - 1) / pageSize)
        page = min(page, total - 1)
        displayed = Array(items.dropFirst(page * pageSize).prefix(pageSize))
        breadcrumb.stringValue = folder.flatMap { id in layoutModel.nodes.first { $0.id == id }?.folderName } ?? ""
        backButton.isHidden = folder == nil && query.isEmpty
        countLabel.stringValue = "\(records.count) 个应用"
        previousDisplayed = page > 0 ? Array(items.dropFirst((page - 1) * pageSize).prefix(pageSize)) : []
        nextDisplayed = Array(items.dropFirst((page + 1) * pageSize).prefix(pageSize))
        for grid in [collection, previousCollection, nextCollection] {
            grid.canPrevious = page > 0; grid.canNext = page + 1 < total
            grid.reloadData()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageStrip.frame.origin.x = -pageViewport.bounds.width
        CATransaction.commit()
        currentOffset = 0
        gestureReceiver.frame = NSRect(origin: .zero, size: pageViewport.bounds.size)
        gestureReceiver.canPrevious = page > 0; gestureReceiver.canNext = page + 1 < total
        previousCollection.isHidden = previousDisplayed.isEmpty
        nextCollection.isHidden = nextDisplayed.isEmpty
        let neighboringApps = (previousDisplayed + nextDisplayed).flatMap(\.apps).compactMap { records[$0] }
        for grid in [collection, previousCollection, nextCollection] { grid.layoutSubtreeIfNeeded() }
        catalog.prewarm(neighboringApps, scale: iconScale)
        pages.arrangedSubviews.forEach { pages.removeArrangedSubview($0); $0.removeFromSuperview() }
        if total > 1 {
            let previous = button("chevron.left", action: #selector(previousPage)); previous.isEnabled = page > 0
            previous.widthAnchor.constraint(equalToConstant: 28).isActive = true; previous.heightAnchor.constraint(equalToConstant: 28).isActive = true
            previous.toolTip = "上一页"; pages.addArrangedSubview(previous)
            for i in 0..<total {
                let b = NSButton(title: i == page ? "●" : "○", target: self, action: #selector(pageClicked(_:)))
                b.tag = i; b.isBordered = false; b.font = .systemFont(ofSize: 12); b.contentTintColor = i == page ? .white : .white.withAlphaComponent(0.4)
                b.setAccessibilityLabel("第 \(i + 1) 页"); pages.addArrangedSubview(b)
            }
            let next = button("chevron.right", action: #selector(nextPage)); next.isEnabled = page + 1 < total
            next.widthAnchor.constraint(equalToConstant: 28).isActive = true; next.heightAnchor.constraint(equalToConstant: 28).isActive = true
            next.toolTip = "下一页"; pages.addArrangedSubview(next)
        }
        pages.layoutSubtreeIfNeeded(); let width = CGFloat(total) * 27 + 80
        pages.frame = NSRect(x: (window.frame.width - width) / 2, y: 32, width: width, height: 24)
    }
    private func clearTileHover() {
        for grid in [previousCollection, collection, nextCollection] {
            for item in grid.visibleItems() { (item.view as? IconTile)?.clearHover() }
        }
    }
    private func setPageTranslation(_ offset: Double) {
        currentOffset = offset
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageStrip.layer?.transform = CATransform3DMakeTranslation(CGFloat(offset), 0, 0)
        CATransaction.commit()
    }
    private func beginSwipe() -> Double? {
        var resume = 0.0
        var interruptedPosition: Double?
        var baselineShift = 0.0
        if paging {
            guard let target = settlingTarget else { return nil }
            let presented = Double(pageStrip.layer?.presentation()?.transform.m41 ?? CGFloat(currentOffset))
            let baseline = abs(presented) > Double(pageViewport.bounds.width) * 0.5 ? target : page
            let delta = baseline - page
            transitionID += 1; pageStrip.layer?.removeAllAnimations(); settlingTarget = nil
            commitBufferedPage(baseline)
            baselineShift = Double(delta) * Double(pageViewport.bounds.width)
            interruptedPosition = presented
            resume = presented + baselineShift
            completePagingReport(status: "continued_by_new_gesture")
        }
        paging = true; clearTileHover(); setPageTranslation(resume)
        if let interruptedPosition { nativeContinuityError = abs(Double(pageStrip.layer?.transform.m41 ?? 0) - baselineShift - interruptedPosition) }
        frameMeter.start(view: pageViewport)
        return resume
    }
    private func dragPage(_ offset: Double) { setPageTranslation(offset) }
    /// Keep the incoming page intact; only refill the recycled outer buffer.
    private func commitBufferedPage(_ target: Int) {
        let delta = target - page
        guard delta != 0 else { return }
        let recycled: GridView
        if delta > 0 {
            recycled = previousCollection
            previousCollection = collection; collection = nextCollection; nextCollection = recycled
            previousDisplayed = displayed; displayed = nextDisplayed
            nextDisplayed = Array(items.dropFirst((target + 1) * pageSize).prefix(pageSize))
        } else {
            recycled = nextCollection
            nextCollection = collection; collection = previousCollection; previousCollection = recycled
            nextDisplayed = displayed; displayed = previousDisplayed
            previousDisplayed = target > 0 ? Array(items.dropFirst((target - 1) * pageSize).prefix(pageSize)) : []
        }
        page = target
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, grid) in [previousCollection, collection, nextCollection].enumerated() {
            grid.frame.origin.x = CGFloat(index) * pageViewport.bounds.width
        }
        setPageTranslation(0)
        CATransaction.commit()
        recycled.reloadData(); recycled.layoutSubtreeIfNeeded()
        previousCollection.isHidden = previousDisplayed.isEmpty; nextCollection.isHidden = nextDisplayed.isEmpty
        let total = max(1, (items.count + pageSize - 1) / pageSize)
        gestureReceiver.canPrevious = page > 0; gestureReceiver.canNext = page + 1 < total
        for (i, view) in pages.arrangedSubviews.enumerated() {
            guard let button = view as? NSButton else { continue }
            if i == 0 { button.isEnabled = page > 0 }
            else if i == pages.arrangedSubviews.count - 1 { button.isEnabled = page + 1 < total }
            else { button.title = button.tag == page ? "●" : "○"; button.contentTintColor = button.tag == page ? .white : .white.withAlphaComponent(0.4) }
        }
    }
    private func finishSwipe(delta: Int, offset: Double, events: Int) {
        pendingPagingReport = ["from_page": page + 1, "requested_page": page + delta + 1, "delta": delta, "offset": offset, "events": events, "kind": "AppKit scroll gesture"]
        settlePage(delta: delta, offset: offset)
    }
    private func completePagingReport(status: String) {
        let metrics = frameMeter.stop()
        guard var report = pendingPagingReport else { return }
        pendingPagingReport = nil
        report["completion"] = status; report["committed_page"] = page + 1; report["frame_intervals"] = metrics
        let directory = reportDirectory
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { reportQueue.async { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try? data.write(to: directory.appendingPathComponent("paging-status.json"), options: .atomic) } }
    }
    private func settlePage(delta: Int, offset: Double) {
        clearTileHover()
        let total = max(1, (items.count + pageSize - 1) / pageSize)
        let target = max(0, min(total - 1, page + delta)), actualDelta = target - page
        let width = pageViewport.bounds.width
        let remaining = abs(-Double(actualDelta) * Double(width) - offset)
        if remaining < 0.5 { commitBufferedPage(target); setPageTranslation(0); paging = false; updateDirtyFolders(); completePagingReport(status: "settled"); return }
        transitionID += 1; let token = transitionID
        settlingTarget = target
        let destination = -Double(actualDelta) * Double(width)
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = currentOffset; animation.toValue = destination
        animation.duration = min(0.24, max(0.12, 0.12 + remaining / max(1, Double(width)) * 0.10))
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, token == self.transitionID else { return }
            self.commitBufferedPage(target); self.setPageTranslation(0)
            self.settlingTarget = nil; self.paging = false; self.updateDirtyFolders()
            self.completePagingReport(status: "settled")
        }
        setPageTranslation(destination)
        pageStrip.layer?.add(animation, forKey: "paging")
        CATransaction.commit()
    }

    func turnPage(_ delta: Int) {
        guard !paging else { return }
        let total = max(1, (items.count + pageSize - 1) / pageSize)
        guard page + delta >= 0, page + delta < total else { return }
        paging = true; settlePage(delta: delta, offset: 0)
    }
    @objc private func previousPage() { turnPage(-1) }
    @objc private func nextPage() { turnPage(1) }
    @objc private func pageClicked(_ sender: NSButton) {
        guard !paging else { return }
        let delta = sender.tag - page
        if abs(delta) == 1 { turnPage(delta) } else { page = sender.tag; refresh() }
    }
    private func pageNodes(for view: NSCollectionView) -> [LayoutNode] {
        view === previousCollection ? previousDisplayed : (view === nextCollection ? nextDisplayed : displayed)
    }
    @objc private func goBack() { folder = nil; query = ""; search.stringValue = ""; page = 0; rearrangeFrames() }
    func escape() { if folder != nil || !query.isEmpty { goBack() } else { dismiss() } }
    func controlTextDidChange(_ obj: Notification) { query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); page = 0; rearrangeFrames() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { escape(); return true }
        if command == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(), let first = displayed.first { activate(first); return true }
        if query.isEmpty && command == #selector(NSResponder.moveLeft(_:)) { turnPage(-1); return true }
        if query.isEmpty && command == #selector(NSResponder.moveRight(_:)) { turnPage(1); return true }
        return false
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pageNodes(for: collectionView).count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("icon"), for: indexPath)
        let node = pageNodes(for: collectionView)[indexPath.item], tile = item.view as! IconTile
        tile.node = node; tile.owner = self
        switch node {
        case .application(let id):
            tile.title.stringValue = records[id]?.name ?? (URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent + "（不可用）")
            if let record = records[id] {
                tile.setIcon(catalog.cachedIcon(for: record, scale: iconScale) ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil))
                catalog.requestIcon(for: record, scale: iconScale) { [weak tile] image in
                    guard let tile, tile.node?.id == id else { return }; tile.setIcon(image)
                }
            } else { tile.setIcon(NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "不可用")) }
        case .folder(let id, let name, let apps):
            tile.title.stringValue = name; tile.setIcon(folderImage(apps))
            for record in apps.prefix(9).compactMap({ records[$0] }) where catalog.cachedIcon(for: record, scale: iconScale) == nil {
                catalog.requestIcon(for: record, scale: iconScale) { [weak self, weak tile] _ in
                    guard let self, let tile, tile.node?.id == id else { return }
                    if self.paging { self.dirtyFolderIDs.insert(id); return }
                    tile.setIcon(self.folderImage(tile.node?.apps ?? []))
                }
            }
        }
        tile.updateTitlePixels()
        tile.setAccessibilityElement(true); tile.setAccessibilityRole(.button); tile.setAccessibilityLabel(tile.title.stringValue)
        return item
    }
    private func updateDirtyFolders() {
        guard !dirtyFolderIDs.isEmpty else { return }
        for grid in [previousCollection, collection, nextCollection] {
            for item in grid.visibleItems() {
                guard let tile = item.view as? IconTile, let node = tile.node, dirtyFolderIDs.contains(node.id) else { continue }
                tile.setIcon(folderImage(node.apps))
            }
        }
        dirtyFolderIDs.removeAll()
    }
    private func folderImage(_ apps: [String]) -> NSImage {
        let image = NSImage(size: NSSize(width: 96, height: 96)); image.lockFocus()
        NSColor.white.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 92, height: 92), xRadius: 21, yRadius: 21).fill()
        for (i, id) in apps.filter({ !layoutModel.hidden.contains($0) && records[$0] != nil }).prefix(9).enumerated() {
            (catalog.cachedIcon(for: records[id]!, scale: iconScale) ?? NSImage()).draw(in: NSRect(x: 12 + (i % 3) * 25, y: 59 - (i / 3) * 25, width: 23, height: 23))
        }
        image.unlockFocus(); return image
    }
    func activate(_ node: LayoutNode) {
        switch node {
        case .folder(let id, _, _): folder = id; page = 0; search.stringValue = ""; query = ""; rearrangeFrames()
        case .application(let id):
            guard let app = records[id] else { alert("这个应用暂时不可用。挂载磁盘或重新安装后，可在设置中刷新应用。布局位置已保留。"); return }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async { if let error { self?.alert(error.localizedDescription) } else { self?.hide() } }
            }
        }
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !paging, collectionView === collection, query.isEmpty, draggingInfo.draggingPasteboard.string(forType: .launcherItem) != nil else { return [] }
        let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        if let hovered = collectionView.indexPathForItem(at: point), hovered.item < displayed.count,
           let attributes = collectionView.layoutAttributesForItem(at: hovered) {
            let center = attributes.frame.insetBy(dx: attributes.frame.width * 0.25, dy: attributes.frame.height * 0.15)
            if center.contains(point), folder == nil {
                proposedDropIndexPath.pointee = hovered as NSIndexPath
                proposedDropOperation.pointee = .on
            } else { proposedDropOperation.pointee = .before }
        }
        return .move
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let id = draggingInfo.draggingPasteboard.string(forType: .launcherItem), query.isEmpty else { return false }
        let absoluteIndex = page * pageSize + indexPath.item
        let target = absoluteIndex < items.count ? items[absoluteIndex] : nil
        do {
            if dropOperation == .on, indexPath.item < displayed.count, let target, target.id != id, folder == nil {
                if target.folderName != nil { try layoutModel.move(id, into: target.id, before: nil) }
                else if !id.hasPrefix("folder:") { _ = try layoutModel.group(id, with: target.id, name: "文件夹") }
                else { try layoutModel.move(id, into: folder, before: target.id) }
            } else { try layoutModel.move(id, into: folder, before: target?.id) }
            guard save() else { refresh(); return false }; refresh(); return true
        } catch { alert(error.localizedDescription); return false }
    }
    @discardableResult private func save() -> Bool {
        do { try store.save(layoutModel); lastSavedLayout = layoutModel; return true }
        catch {
            if let lastSavedLayout { layoutModel = lastSavedLayout }
            let message = error.localizedDescription
            statusLabel.stringValue = message
            if loadError != message {
                loadError = message
                DispatchQueue.main.async { [weak self] in self?.alert("布局未保存，已保留上次成功保存的排列。\n" + message) }
            }
            return false
        }
    }
    func contextMenu(_ node: LayoutNode, event: NSEvent, view: NSView) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) { let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; i.representedObject = node.id; menu.addItem(i) }
        if node.folderName != nil { add("重命名文件夹…", #selector(renameFolder(_:))) }
        else {
            add("在 Finder 中显示", #selector(reveal(_:)))
            if folder != nil { add("移出文件夹", #selector(moveOut(_:))) }
            let sub = NSMenu()
            for f in layoutModel.nodes where f.folderName != nil && f.id != folder {
                let i = NSMenuItem(title: f.folderName!, action: #selector(moveInto(_:)), keyEquivalent: ""); i.target = self; i.representedObject = [node.id, f.id]; sub.addItem(i)
            }
            if !sub.items.isEmpty { let i = NSMenuItem(title: "移入文件夹", action: nil, keyEquivalent: ""); i.submenu = sub; menu.addItem(i) }
            add("隐藏应用", #selector(hideApp(_:)))
        }
        if folder == nil { add("移到上一页", #selector(movePrevious(_:))); add("移到下一页", #selector(moveNext(_:))) }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    @objc private func reveal(_ sender: NSMenuItem) { if let id = sender.representedObject as? String, let app = records[id] { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } }
    @objc private func hideApp(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { layoutModel.hidden.insert(id); save(); refresh() } }
    @objc private func moveOut(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { do { try layoutModel.move(id, into: nil, before: nil); save(); refresh() } catch { alert(error.localizedDescription) } } }
    @objc private func moveInto(_ sender: NSMenuItem) { if let pair = sender.representedObject as? [String] { do { try layoutModel.move(pair[0], into: pair[1], before: nil); save(); refresh() } catch { alert(error.localizedDescription) } } }
    @objc private func movePrevious(_ sender: NSMenuItem) { movePage(sender, delta: -1) }
    @objc private func moveNext(_ sender: NSMenuItem) { movePage(sender, delta: 1) }
    private func movePage(_ sender: NSMenuItem, delta: Int) {
        guard let id = sender.representedObject as? String else { return }
        let dest = max(0, (page + delta) * pageSize)
        let remaining = items.filter { $0.id != id }
        let before = dest < remaining.count ? remaining[dest].id : nil
        do { try layoutModel.move(id, into: nil, before: before); save(); if delta > 0 { page += 1 }; refresh() } catch { alert(error.localizedDescription) }
    }
    @objc private func renameFolder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert(); alert.messageText = "文件夹名称"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 26)); text.stringValue = layoutModel.nodes.first { $0.id == id }?.folderName ?? "文件夹"; alert.accessoryView = text
        if alert.runModal() == .alertFirstButtonReturn, !text.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { layoutModel.renameFolder(id, to: text.stringValue); save(); refresh() }
    }
    func alert(_ message: String) { let a = NSAlert(); a.messageText = "OpenLaunch"; a.informativeText = message; a.runModal() }
    @objc func showSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "OpenLaunch 设置"; panel.isReleasedWhenClosed = false; panel.level = .floating; panel.center()
        let root = panel.contentView!
        func label(_ text: String, y: CGFloat) { let l = NSTextField(labelWithString: text); l.frame = NSRect(x: 28, y: y, width: 450, height: 22); root.addSubview(l) }
        label("唤起方式", y: 392)
        let pinch = NSButton(checkboxWithTitle: "触控板捏合", target: self, action: #selector(settingChanged(_:))); pinch.tag = 1; pinch.state = input.pinchEnabled ? .on : .off; pinch.frame = NSRect(x: 28, y: 354, width: 180, height: 24); root.addSubview(pinch)
        let fingers = NSPopUpButton(frame: NSRect(x: 270, y: 351, width: 150, height: 28)); fingers.addItems(withTitles: ["3 指", "4 指", "5 指"]); fingers.selectItem(at: input.fingerCount - 3); fingers.target = self; fingers.action = #selector(fingersChanged(_:)); root.addSubview(fingers)
        label("触发角", y: 307)
        for (i, title) in ["左上", "右上", "左下", "右下"].enumerated() {
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(cornerBoxChanged(_:)))
            b.tag = i; b.state = input.cornerMask & (1 << i) != 0 ? .on : .off; b.frame = NSRect(x: 140 + CGFloat(i) * 82, y: 305, width: 78, height: 24); root.addSubview(b)
        }
        let option = NSButton(checkboxWithTitle: "触发角需要按住 ⌥", target: self, action: #selector(settingChanged(_:))); option.tag = 3; option.state = input.cornerRequiresOption ? .on : .off; option.frame = NSRect(x: 28, y: 269, width: 240, height: 24); root.addSubview(option)
        label("停留时间", y: 232)
        let dwell = NSSlider(value: input.cornerDwell, minValue: 0.1, maxValue: 1.5, target: self, action: #selector(dwellChanged(_:))); dwell.frame = NSRect(x: 140, y: 231, width: 280, height: 24); dwell.isContinuous = false; dwell.numberOfTickMarks = 8; dwell.allowsTickMarkValuesOnly = true; root.addSubview(dwell)
        label("全局快捷键", y: 195)
        let key = NSPopUpButton(frame: NSRect(x: 270, y: 191, width: 150, height: 28)); key.addItems(withTitles: ShortcutController.labels); key.selectItem(at: max(0, min(2, defaults.integer(forKey: "OpenLaunch.shortcut")))); key.target = self; key.action = #selector(shortcutChanged(_:)); root.addSubview(key)
        let restore = NSButton(title: "显示隐藏应用", target: self, action: #selector(restoreHidden)); restore.frame = NSRect(x: 28, y: 145, width: 180, height: 30); root.addSubview(restore)
        let rescan = NSButton(title: "刷新应用", target: self, action: #selector(rescanApps)); rescan.frame = NSRect(x: 270, y: 145, width: 150, height: 30); root.addSubview(rescan)
        if loadError != nil { let recover = NSButton(title: "备份损坏文件并重建布局…", target: self, action: #selector(recoverLayout)); recover.frame = NSRect(x: 28, y: 113, width: 250, height: 30); root.addSubview(recover) }
        statusLabel.stringValue = loadError ?? input.status; statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4; statusLabel.lineBreakMode = .byWordWrapping; statusLabel.frame = NSRect(x: 28, y: 22, width: 474, height: 80); root.addSubview(statusLabel)
        settings = panel; panel.makeKeyAndOrderFront(nil)
    }
    @objc private func cornerBoxChanged(_ sender: NSButton) {
        let bit = 1 << sender.tag
        input.cornerMask = sender.state == .on ? input.cornerMask | bit : input.cornerMask & ~bit
    }
    @objc private func dwellChanged(_ sender: NSSlider) { input.cornerDwell = sender.doubleValue }
    @objc private func shortcutChanged(_ sender: NSPopUpButton) { defaults.set(sender.indexOfSelectedItem, forKey: "OpenLaunch.shortcut"); onShortcutChanged?(sender.indexOfSelectedItem) }
    @objc private func recoverLayout() {
        let a = NSAlert(); a.messageText = "备份原文件并重建布局？"; a.informativeText = "原损坏文件会另存备份。当前排列将成为新布局。"; a.addButton(withTitle: "备份并重建"); a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn {
            do { let backup = try store.recoverByStartingNew(layoutModel); loadError = nil; lastSavedLayout = layoutModel; alert("已保存新布局。原文件备份：\(backup.path)") }
            catch { alert(error.localizedDescription) }
        }
    }
    @objc private func settingChanged(_ sender: NSButton) { switch sender.tag { case 1: input.pinchEnabled = sender.state == .on; case 2: input.f4Enabled = sender.state == .on; case 3: input.cornerRequiresOption = sender.state == .on; default: break } }
    @objc private func fingersChanged(_ sender: NSPopUpButton) { input.fingerCount = sender.indexOfSelectedItem + 3 }
    @objc private func permissions() { input.requestPermissions() }
    @objc private func calibrate() { input.beginF4Calibration() }
    @objc private func restoreHidden() { layoutModel.hidden = []; save(); refresh() }
    @objc private func rescanApps() { catalog.clearIcons(); scan() }
    func exportPreview(to url: URL) throws {
        let previewTile = collection.item(at: IndexPath(item: 0, section: 0))?.view as? IconTile
        if let previewTile {
            previewTile.updateHover(at: previewTile.convert(previewTile.image.frame.center, to: nil))
        }
        defer { previewTile?.clearHover() }
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LayoutError.invalid("无法生成预览。") }
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LayoutError.invalid("无法编码预览。") }
        try data.write(to: url)
    }
    private func awaitRevealSettle(until deadline: TimeInterval, completion: @escaping () -> Void) {
        guard revealAnimating && ProcessInfo.processInfo.systemUptime < deadline else { completion(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.awaitRevealSettle(until: deadline, completion: completion) }
    }
    private func awaitWindowHidden(until deadline: TimeInterval, completion: @escaping () -> Void) {
        guard window.isVisible && ProcessInfo.processInfo.systemUptime < deadline else { completion(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.awaitWindowHidden(until: deadline, completion: completion) }
    }
    func verifyNativeInteractions(completion: @escaping (Bool) -> Void) {
        func failure(_ stage: Int) { fputs("native interaction failure stage=\(stage)\n", stderr); completion(false) }
        hide(); pinchSuppressed = false
        updatePinchReveal(0.2)
        guard window.isVisible, abs(window.alphaValue - 0.2) < 0.01 else { failure(1); return }
        updatePinchReveal(0.6)
        guard abs(window.alphaValue - 0.6) < 0.01 else { failure(2); return }
        endPinchReveal(committed: false)
        awaitRevealSettle(until: ProcessInfo.processInfo.systemUptime + 2) { [weak self] in
            guard let self, !self.window.isVisible else { failure(3); return }
            self.updatePinchReveal(0.3); self.commitPinchReveal()
            self.awaitRevealSettle(until: ProcessInfo.processInfo.systemUptime + 2) { [weak self] in
                guard let self else { failure(4); return }
                self.commitPinchReveal()
                guard self.window.isVisible, self.window.alphaValue > 0.99,
                      !self.shouldDismissBackground(at: self.searchSurface.frame.center),
                      self.shouldDismissBackground(at: NSPoint(x: 20, y: 300)) else { failure(5); return }
                if let tile = self.collection.item(at: IndexPath(item: 0, section: 0))?.view as? IconTile {
                    let iconPoint = tile.convert(tile.image.frame.center, to: nil)
                    let gapPoint = tile.convert(NSPoint(x: tile.bounds.maxX - 1, y: tile.bounds.maxY - 1), to: nil)
                    let labelPoint = tile.convert(tile.title.frame.center, to: nil)
                    let sideGap = tile.convert(NSPoint(x: tile.image.frame.minX - 8, y: tile.image.frame.midY), to: nil)
                    let transparentMargin = tile.convert(NSPoint(x: tile.image.frame.minX + 0.1, y: tile.image.frame.minY + 0.1), to: nil)
                    tile.updateHover(at: gapPoint)
                    guard !tile.hasArtworkHover else { failure(6); return }
                    tile.updateHover(at: iconPoint)
                    guard tile.hasArtworkHover else { failure(7); return }
                    tile.updateHover(at: labelPoint)
                    guard !tile.hasArtworkHover,
                          !self.shouldDismissBackground(at: iconPoint), self.shouldDismissBackground(at: gapPoint),
                          self.shouldDismissBackground(at: labelPoint), self.shouldDismissBackground(at: sideGap),
                          self.shouldDismissBackground(at: transparentMargin) else { failure(8); return }
                } else { failure(7); return }
                guard let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 300), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { failure(8); return }
                NSApp.postEvent(click, atStart: false)
                self.awaitWindowHidden(until: ProcessInfo.processInfo.systemUptime + 2) { [weak self] in
                    guard let self, !self.window.isVisible else { failure(10); return }
                    self.show()
                    self.awaitRevealSettle(until: ProcessInfo.processInfo.systemUptime + 2) { completion(true) }
                }
            }
        }
    }
    private func awaitPagingSettle(until deadline: TimeInterval, completion: @escaping () -> Void) {
        guard paging && ProcessInfo.processInfo.systemUptime < deadline else { completion(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.awaitPagingSettle(until: deadline, completion: completion) }
    }
    /// Controlled native animation check in the temporary smoke session.
    func verifyPagingAnimation(completion: @escaping (Bool) -> Void) {
        let labels = nextDisplayed.indices.compactMap { nextCollection.item(at: IndexPath(item: $0, section: 0))?.view as? IconTile }
        guard labels.count == nextDisplayed.count, labels.allSatisfy({ $0.hasPreparedTitle }) else { completion(false); return }
        guard !nextDisplayed.isEmpty, beginSwipe() != nil else { completion(false); return }
        let originalPage = page
        dragPage(-150); finishSwipe(delta: 1, offset: -150, events: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.pageStrip.layer != nil else { completion(false); return }
            guard let resumed = self.beginSwipe(), self.nativeContinuityError < 0.1 else { fputs("paging check: presentation continuity failed\n", stderr); completion(false); return }
            let delta = self.page == originalPage ? 1 : 0
            self.dragPage(resumed - 10)
            self.finishSwipe(delta: delta, offset: resumed - 10, events: 1)
            self.awaitPagingSettle(until: ProcessInfo.processInfo.systemUptime + 2) { [weak self] in
                guard let self, !self.paging, self.page == originalPage + 1 else { fputs("paging check: first settle failed\n", stderr); completion(false); return }
                self.turnPage(-1)
                self.awaitPagingSettle(until: ProcessInfo.processInfo.systemUptime + 2) { [weak self] in
                    guard let self else { completion(false); return }
                    let ok = !self.paging && self.page == originalPage && abs(self.currentOffset) < 0.1
                    if !ok { fputs("paging check: reverse settle failed paging=\(self.paging) page=\(self.page) offset=\(self.currentOffset)\n", stderr) }
                    completion(ok)
                }
            }
        }
    }
    func exportPagingMidpoint(to url: URL) throws {
        let prior = currentOffset
        dragPage(-Double(pageViewport.bounds.width) * 0.45)
        defer { setPageTranslation(prior) }
        window.contentView?.displayIfNeeded()
        try exportPreview(to: url)
    }
    func smokeCheck() throws -> [String: Any] {
        guard appCount > 0 else { throw LayoutError.invalid("没有扫描到真实应用。") }
        // Exercise actual native buffer identities and hover reuse, not a mock model.
        let incomingLabels = nextDisplayed.indices.compactMap { nextCollection.item(at: IndexPath(item: $0, section: 0))?.view as? IconTile }
        guard incomingLabels.count == nextDisplayed.count, incomingLabels.allSatisfy({ $0.hasPreparedTitle }) else { throw LayoutError.invalid("邻页标题尚未栅格化。") }
        let originalGrid = collection
        let incomingGrid = nextCollection
        if !nextDisplayed.isEmpty {
            commitBufferedPage(page + 1)
            guard collection === incomingGrid else { throw LayoutError.invalid("目标页未复用。") }
            commitBufferedPage(page - 1)
            guard collection === originalGrid else { throw LayoutError.invalid("反向分页缓冲未复用。") }
        }
        let probeSize = flow.itemSize
        let hoverProbe = IconTile(frame: NSRect(origin: .zero, size: probeSize))
        hoverProbe.title.stringValue = "Example App"
        hoverProbe.layout()
        let longTitleProbe = IconTile(frame: NSRect(origin: .zero, size: probeSize))
        longTitleProbe.title.stringValue = "This Is A Much Longer Example Application Name"
        longTitleProbe.layout()
        guard abs(hoverProbe.hoverLayer.frame.width - hoverProbe.hoverLayer.frame.height) < 0.001,
              hoverProbe.hoverLayer.frame.size == longTitleProbe.hoverLayer.frame.size,
              hoverProbe.title.frame.width == longTitleProbe.title.frame.width,
              abs(hoverProbe.hoverLayer.frame.midX - hoverProbe.image.frame.midX) < 0.001,
              abs(hoverProbe.hoverLayer.frame.midY - (hoverProbe.image.frame.midY - 6)) < 0.001,
              hoverProbe.hoverLayer.frame.insetBy(dx: 4, dy: 4).contains(hoverProbe.image.frame),
              hoverProbe.hoverLayer.frame.minX >= 0, hoverProbe.hoverLayer.frame.minY >= 0,
              hoverProbe.hoverLayer.frame.maxX <= hoverProbe.bounds.maxX,
              hoverProbe.hoverLayer.frame.maxY <= hoverProbe.bounds.maxY else {
            throw LayoutError.invalid("图标悬停方框没有围绕图标居中，或越出单元格边界。")
        }
        hoverProbe.hoverLayer.opacity = 1
        hoverProbe.node = .application("hover-reuse-test")
        guard hoverProbe.hoverLayer.opacity == 0 else { throw LayoutError.invalid("图标复用后高亮未清除。") }
        let oldLayout = layoutModel
        let apps = orderedRecords.prefix(2)
        if apps.count == 2 {
            let ids = apps.map(\.id)
            let id = try layoutModel.group(ids[0], with: ids[1], name: "测试文件夹")
            folder = id; refresh()
            guard displayed.count == 2 else { throw LayoutError.invalid("文件夹视图未呈现两个应用。") }
            try layoutModel.move(ids[0], into: nil, before: nil)
            goBack(); save()
            guard try store.load() == layoutModel else { throw LayoutError.invalid("布局重读不一致。") }
            layoutModel = oldLayout; save(); refresh()
        }
        search.stringValue = orderedRecords[0].name; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        guard displayed.contains(.application(orderedRecords[0].id)) else { throw LayoutError.invalid("真实应用搜索未匹配。") }
        goBack()
        let start = ProcessInfo.processInfo.systemUptime
        show(); let elapsed = ProcessInfo.processInfo.systemUptime - start
        var warm: [Double] = []
        for _ in 0..<5 { hide(); let t = ProcessInfo.processInfo.systemUptime; show(); warm.append((ProcessInfo.processInfo.systemUptime - t) * 1000) }
        return ["apps": appCount, "scan_ms": scanDuration * 1000, "show_call_ms": elapsed * 1000, "warm_show_calls_ms": warm, "folder_search_persistence": "passed", "wallpaper": wallpaper.usesWallpaper, "next_page_buffer_ready": nextCollection.item(at: IndexPath(item: 0, section: 0)) != nil, "neighbor_title_pixels_ready": incomingLabels.count, "native_buffer_reuse": "passed", "native_hover_reuse": "passed", "input_live": "not_tested"]
    }
}
