import AppKit
import CTouch
import Foundation

/// Guided, explicit opt-in collector for raw built-in trackpad frames.
/// It runs instead of the launcher so there is exactly one multitouch reader.
final class PinchCapture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct Point: Codable {
        let pathID: Int32
        let fingerID: Int32
        let handID: Int32
        let state: UInt32
        let x: Double
        let y: Double
    }
    private struct Frame: Codable {
        let timestamp: Double
        let frameNumber: UInt64
        let originalCount: Int
        let points: [Point]
    }
    private struct PhaseFile: Codable {
        let schemaVersion: Int
        let phase: String
        let label: String
        let startedAt: String
        let endedAt: String
        let captureSource: String
        let deviceIndex: Int
        let deviceIsBuiltIn: Int
        let sensorWidth: Int
        let sensorHeight: Int
        let droppedFrames: UInt64
        let frames: [Frame]
    }
    private struct Phase {
        let id: String
        let title: String
        let instruction: String
    }

    private let phases = [
        Phase(id: "normal", title: "正常速度", instruction: "手掌自然放在触控板上，五指张开后以平常速度向内捏合，再张开。连续做 3 次；每次之间稍停一下。"),
        Phase(id: "slow", title: "缓慢捏合", instruction: "五指张开后，尽量匀速、缓慢地向内捏合，每次约 3–5 秒；捏到底停一下再张开。连续做 3 次。"),
        Phase(id: "reverse", title: "半途回张", instruction: "五指张开后开始向内捏，走到一半停住并重新张开；再完成一次捏合。如此交替，做 3 轮。"),
        Phase(id: "varied", title: "不同节奏与幅度", instruction: "各做几次：很轻的小幅捏合、先慢后快、快捏后停住。请用你平时真实会做的动作，不必刻意配合程序。")
    ]
    private let outputURL: URL
    private var window: NSWindow!
    private var titleField: NSTextField!
    private var instructionField: NSTextField!
    private var statusField: NSTextField!
    private var mainButton: NSButton!
    private var nextButton: NSButton!
    private var phaseIndex = 0
    private var phaseStarted: Date?
    private var collecting = false
    // Accessed only on drainQueue; the callback source and the UI thread both
    // synchronize with this queue when starting or ending a phase.
    private var collectionActive = false
    private var source: DispatchSourceUserDataAdd!
    private let drainQueue = DispatchQueue(label: "com.openlaunch.pinch-capture.drain")
    private var activeFrames: [Frame] = []
    private let frameLimit = 15_000
    private var outputFiles: [String] = []

    init(outputURL: URL) { self.outputURL = outputURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        buildWindow()
        do { try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true) }
        catch { statusField.stringValue = "无法创建采集目录：\(error.localizedDescription)"; return }

        source = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        source.setEventHandler { [weak self] in self?.drainFrames() }
        source.resume()
        guard OLTouchStart() != 0 else {
            statusField.stringValue = "触控板监听未启动：\(String(cString: OLTouchStatus()))"
            mainButton.isEnabled = false
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        OLTouchSetFrameHandler({ rawContext in
            guard let rawContext else { return }
            let collector = Unmanaged<PinchCapture>.fromOpaque(rawContext).takeUnretainedValue()
            collector.source.add(data: 1)
        }, context)
        let builtIn = OLTouchSelectedIsBuiltIn() == 1 ? "内建触控板" : "设备索引 \(OLTouchSelectedDeviceIndex())（内建状态未确认）"
        statusField.stringValue = "已连接：\(builtIn)。点击开始后再做动作；每组结束时保存原始触点。"
        showPhase()
        writeManifest(completed: false)
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 620, height: 390)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "OpenLaunch · 五指动作采集"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSView(frame: rect)
        window.contentView = root

        titleField = label("", size: 25, weight: .semibold)
        titleField.frame = NSRect(x: 36, y: 320, width: 548, height: 34)
        root.addSubview(titleField)
        instructionField = label("", size: 15, weight: .regular)
        instructionField.frame = NSRect(x: 36, y: 205, width: 548, height: 95)
        instructionField.maximumNumberOfLines = 4
        instructionField.lineBreakMode = .byWordWrapping
        root.addSubview(instructionField)
        statusField = label("准备中…", size: 12, weight: .regular)
        statusField.textColor = .secondaryLabelColor
        statusField.frame = NSRect(x: 36, y: 140, width: 548, height: 44)
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byWordWrapping
        root.addSubview(statusField)

        mainButton = NSButton(title: "开始本组采集", target: self, action: #selector(mainAction))
        mainButton.bezelStyle = .rounded
        mainButton.keyEquivalent = "\r"
        mainButton.frame = NSRect(x: 36, y: 52, width: 180, height: 38)
        root.addSubview(mainButton)
        nextButton = NSButton(title: "下一组 →", target: self, action: #selector(nextPhase))
        nextButton.bezelStyle = .rounded
        nextButton.frame = NSRect(x: 226, y: 52, width: 120, height: 38)
        nextButton.isHidden = true
        root.addSubview(nextButton)
        let quit = NSButton(title: "结束采集", target: self, action: #selector(finish))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: 464, y: 52, width: 120, height: 38)
        root.addSubview(quit)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = .labelColor
        return field
    }

    private func showPhase() {
        guard phases.indices.contains(phaseIndex) else { return }
        let phase = phases[phaseIndex]
        titleField.stringValue = "\(phaseIndex + 1) / \(phases.count)　\(phase.title)"
        instructionField.stringValue = phase.instruction
        statusField.stringValue = "准备好后点击“开始本组采集”。采集期间可以自然停顿；做完再点击结束。"
        mainButton.title = "开始本组采集"
        mainButton.isEnabled = true
        nextButton.isHidden = true
    }

    @objc private func mainAction() {
        if collecting { stopPhaseAndSave(); return }
        guard phases.indices.contains(phaseIndex) else { finish(); return }
        phaseStarted = Date()
        collecting = true
        OLCaptureStart()
        drainQueue.sync {
            activeFrames.removeAll(keepingCapacity: true)
            collectionActive = true
            drainFrames()
        }
        mainButton.title = "结束本组并保存"
        statusField.stringValue = "正在采集原始触点… 已记录 0 帧。动作由你控制，完成后点击结束。"
        mainButton.keyEquivalent = ""
        startStatusRefresh()
    }

    private var refreshTimer: Timer?
    private func startStatusRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.collecting else { return }
            let frameCount = self.drainQueue.sync { self.activeFrames.count }
            self.statusField.stringValue = "正在采集原始触点… 已记录 \(frameCount) 帧，丢帧 \(OLCaptureDropped())。"
        }
    }

    private func drainFrames() {
        guard collectionActive else { return }
        var points = Array(repeating: OLCapturePoint(pathID: 0, fingerID: 0, handID: 0, state: 0, x: 0, y: 0), count: 16)
        while activeFrames.count < frameLimit {
            var count = 0, original = 0, timestamp = 0.0
            var number: UInt64 = 0
            let result = OLCaptureRead(&points, points.count, &count, &timestamp, &number, &original)
            if result == 0 { break }
            if result < 0 { continue }
            let copied = points.prefix(count).map { Point(pathID: $0.pathID, fingerID: $0.fingerID, handID: $0.handID, state: $0.state, x: $0.x, y: $0.y) }
            activeFrames.append(Frame(timestamp: timestamp, frameNumber: number, originalCount: original, points: copied))
        }
    }

    private func stopPhaseAndSave() {
        guard collecting else { return }
        collecting = false
        refreshTimer?.invalidate(); refreshTimer = nil
        OLCaptureStop()
        source.add(data: 1)
        let capturedFrames = drainQueue.sync { () -> [Frame] in
            drainFrames()
            collectionActive = false
            return activeFrames
        }
        let phase = phases[phaseIndex]
        let now = Date()
        var width: Int32 = 0, height: Int32 = 0
        _ = OLTouchSelectedDimensions(&width, &height)
        let record = PhaseFile(schemaVersion: 1, phase: phase.id, label: phase.title,
            startedAt: ISO8601DateFormatter().string(from: phaseStarted ?? now), endedAt: ISO8601DateFormatter().string(from: now),
            captureSource: "hardware_multitouch_callback_raw", deviceIndex: Int(OLTouchSelectedDeviceIndex()),
            deviceIsBuiltIn: Int(OLTouchSelectedIsBuiltIn()), sensorWidth: Int(width), sensorHeight: Int(height),
            droppedFrames: OLCaptureDropped(), frames: capturedFrames)
        do {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let data = try encoder.encode(record)
            let url = outputURL.appendingPathComponent("\(String(format: "%02d", phaseIndex + 1))-\(phase.id).json")
            try data.write(to: url, options: .atomic)
            outputFiles.append(url.lastPathComponent)
            statusField.stringValue = "已保存 \(capturedFrames.count) 帧，丢帧 \(record.droppedFrames)。"
            mainButton.isEnabled = false
            if phaseIndex + 1 < phases.count { nextButton.isHidden = false }
            else { mainButton.title = "全部完成"; nextButton.isHidden = true }
        } catch {
            statusField.stringValue = "保存失败：\(error.localizedDescription)"
            mainButton.title = "重试保存"
            mainButton.isEnabled = true
        }
        writeManifest(completed: true)
    }

    @objc private func nextPhase() {
        phaseIndex += 1
        showPhase()
        writeManifest(completed: false)
    }

    @objc private func finish() {
        if collecting { stopPhaseAndSave() }
        OLCaptureStop()
        OLTouchStop()
        source?.cancel()
        writeManifest(completed: true)
        NSApp.terminate(nil)
    }

    private func writeManifest(completed: Bool) {
        let manifest: [String: Any] = [
            "schemaVersion": 1, "createdAt": ISO8601DateFormatter().string(from: Date()),
            "host": "macOS", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": "arm64", "captureSource": "hardware_multitouch_callback_raw",
            "deviceIndex": OLTouchSelectedDeviceIndex(), "deviceIsBuiltIn": OLTouchSelectedIsBuiltIn(),
            "phaseFiles": outputFiles, "currentPhase": phases.indices.contains(phaseIndex) ? phases[phaseIndex].id : "complete",
            "completed": completed && phaseIndex >= phases.count - 1
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: outputURL.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }
    func applicationWillTerminate(_ notification: Notification) { OLCaptureStop(); OLTouchStop() }
}
