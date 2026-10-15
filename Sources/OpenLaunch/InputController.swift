import AppKit
import ApplicationServices
import OpenLaunchCore
import CTouch

private final class TouchWakeup {
    let source = DispatchSource.makeUserDataAddSource(queue: .main)
}

/// Global adapters are optional. MultitouchSupport uses a private ABI, isolated in CTouch.
final class InputController {
    var onActivate: ((String) -> Void)?
    var onPinchProgress: ((Double) -> Void)?
    var onPinchEnd: ((Bool) -> Void)?
    private var pinchProgressStarted = false
    private var pinchProgressCommitted = false
    var onStatusChanged: (() -> Void)?
    var pinchEnabled: Bool { didSet { save("pinchEnabled", pinchEnabled); rebuild() } }
    var fingerCount: Int { didSet { save("fingerCount", fingerCount); recognizer.fingerCount = fingerCount; refreshStatus() } }
    var f4Enabled: Bool { didSet { save("f4Enabled", f4Enabled); rebuild() } }
    /// bit 0 top-left, bit 1 top-right, bit 2 bottom-left, bit 3 bottom-right.
    var cornerMask: Int { didSet { save("cornerMask", cornerMask & 15); resetCorner(); rebuild() } }
    /// Compatibility for callers that select a single corner (0 disables all).
    var corner: Int {
        get { (1...4).first { cornerMask & (1 << ($0 - 1)) != 0 } ?? 0 }
        set { cornerMask = (1...4).contains(newValue) ? 1 << (newValue - 1) : 0 }
    }
    var cornerRequiresOption: Bool { didSet { save("cornerRequiresOption", cornerRequiresOption); resetCorner(); refreshStatus() } }
    var cornerDwell: TimeInterval { didSet { save("cornerDwell", cornerDwell); resetCorner(); refreshStatus() } }
    private(set) var lastSystemKeyCode: Int?
    private(set) var status = "输入尚未启动"
    var diagnostics: String {
        var width: Int32 = 0, height: Int32 = 0
        let hasDimensions = OLTouchSelectedDimensions(&width, &height) == 1
        let dimensions = hasDimensions ? "\(width)x\(height)" : "unknown"
        return "\(status)\nTouch adapter starts=\(adapterStarts), dropped frames=\(OLTouchDroppedFrames())\nSystem pinch runtime four=\(OLSystemPinchGet(4)), five=\(OLSystemPinchGet(5))\nMultitouchSupport symbols=\(OLTouchIsSupported()), devices=\(OLTouchDeviceCount()), selectedIndex=\(OLTouchSelectedDeviceIndex()), builtIn=\(OLTouchSelectedIsBuiltIn()), sensorDimensions=\(dimensions), adapter=\(String(cString: OLTouchStatus()))\nAX=\(AXIsProcessTrusted()), CGListen=\(CGPreflightListenEventAccess()), CGPost=\(CGPreflightPostEventAccess()); ordinary F4=118; system F4 key code=\(learnedSystemCode.map(String.init) ?? "unverified")\n\(gestureConflictDescription())\nlastSystemKeyCode=\(lastSystemKeyCode.map(String.init) ?? "none")"
    }
    private var diagnosticProgressFrames = 0
    private var diagnosticPartialProgressFrames = 0
    private var diagnosticDecisions: [String: Int] = [:]
    private var diagnosticCounts: [Int: Int] = [:]
    private var diagnosticStart: Double?
    private var diagnosticLast: Double = 0
    private var diagnosticActivated = false
    private var diagnosticStartRadius: Double?
    private var diagnosticMinRatio: Double = 1
    private let diagnosticQueue = DispatchQueue(label: "local.openlaunch.pinch-diagnostics", qos: .utility)
    private func finishTouchDiagnostic() {
        if pinchProgressStarted { onPinchEnd?(pinchProgressCommitted); pinchProgressStarted = false }
        pinchProgressCommitted = false
        defer { diagnosticProgressFrames = 0; diagnosticPartialProgressFrames = 0; diagnosticDecisions.removeAll(keepingCapacity: true); diagnosticCounts.removeAll(keepingCapacity: true); diagnosticStart = nil; diagnosticActivated = false; diagnosticStartRadius = nil; diagnosticMinRatio = 1 }
        guard (diagnosticCounts.keys.max() ?? 0) >= 3 else { return }
        let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier, "configured_fingers": fingerCount, "frames_by_contact_count": Dictionary(uniqueKeysWithValues: diagnosticCounts.map { (String($0.key), $0.value) }), "duration_ms": max(0, diagnosticLast - (diagnosticStart ?? diagnosticLast)) * 1000, "progress_frames": diagnosticProgressFrames, "partial_progress_frames": diagnosticPartialProgressFrames, "decisions": diagnosticDecisions, "minimum_spread_ratio": diagnosticMinRatio, "activated": diagnosticActivated]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenLaunch")
        diagnosticQueue.async { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try? data.write(to: dir.appendingPathComponent("pinch-diagnostics.json"), options: .atomic) }
        print("pinch_diagnostic " + (String(data: data, encoding: .utf8) ?? ""))
    }
    private func recordTouchDiagnostic(_ points: [TouchPoint], timestamp: Double) {
        guard !points.isEmpty else { return }
        diagnosticCounts[points.count, default: 0] += 1
        diagnosticStart = diagnosticStart ?? timestamp; diagnosticLast = timestamp
        guard points.count == fingerCount else { return }
        let cx = points.reduce(0) { $0 + $1.x } / Double(points.count), cy = points.reduce(0) { $0 + $1.y } / Double(points.count)
        let radius = points.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / Double(points.count)
        if diagnosticStartRadius == nil { diagnosticStartRadius = radius }
        if let initial = diagnosticStartRadius, initial > 0 { diagnosticMinRatio = min(diagnosticMinRatio, radius / initial) }
    }
    private(set) var adapterStarts = 0
    private var running = false
    private var recognizer: PinchRecognizer
    private var touchWakeup: TouchWakeup?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMouse: Any?
    private var localMouse: Any?
    private var observers: [NSObjectProtocol] = []
    private var cornerTimer: Timer?
    private var cornerArmed = true
    private struct CornerTarget: Equatable {
        let screen: NSScreen
        let index: Int
    }
    private var cornerTarget: CornerTarget?
    private var lastAccessibility = false
    private var lastListenPermission = false
    private var f4Held = false
    private var systemF4Held = false
    private var calibrationTimer: Timer?
    private var calibrating = false
    private var learnedSystemCode: Int? {
        UserDefaults.standard.object(forKey: "OpenLaunch.input.confirmedF4SystemKeyCode") as? Int
    }
    private var pinchState = "关闭"
    private var f4State = "关闭"
    private var cornerConflict = false
    init() {
        let d = UserDefaults.standard
        pinchEnabled = d.object(forKey: "OpenLaunch.input.pinchEnabled") as? Bool ?? true
        fingerCount = d.object(forKey: "OpenLaunch.input.fingerCount") as? Int ?? 5
        f4Enabled = d.object(forKey: "OpenLaunch.input.f4Enabled") as? Bool ?? false
        if let savedMask = d.object(forKey: "OpenLaunch.input.cornerMask") as? Int {
            cornerMask = savedMask & 15
        } else {
            let legacyCorner = d.object(forKey: "OpenLaunch.input.corner") as? Int ?? 0
            cornerMask = (1...4).contains(legacyCorner) ? 1 << (legacyCorner - 1) : 0
        }
        cornerRequiresOption = d.object(forKey: "OpenLaunch.input.cornerRequiresOption") as? Bool ?? false
        cornerDwell = d.object(forKey: "OpenLaunch.input.cornerDwell") as? Double ?? 0.4
        recognizer = PinchRecognizer(fingerCount: fingerCount)
    }
    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: "OpenLaunch.input." + key) }
    func start() {
        guard !running else { return }
        running = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.rebuild() })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.suspend() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.resetCorner(); self?.refreshStatus() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let accessibility = AXIsProcessTrusted(), listen = CGPreflightListenEventAccess()
            // Showing the launcher must preserve a corner's one-shot latch.
            // Rebuild only when returning from a real permission change.
            if accessibility != self.lastAccessibility || listen != self.lastListenPermission { self.rebuild() }
            else { self.refreshStatus() }
        })
        rebuild()
    }
    func stop() {
        running = false; stopAdapters(); pinchState = "关闭"; f4State = "关闭"
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []; refreshStatus()
    }
    func beginF4Calibration() {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            f4State = "录制 F4 需要辅助功能/输入监控权限"; refreshStatus(); return
        }
        calibrationTimer?.invalidate()
        calibrating = true
        if tap == nil { installTap() }
        guard tap != nil else { calibrating = false; refreshStatus(); return }
        f4State = "请在 10 秒内按一次 F4 键帽（将记录系统事件编号）"; refreshStatus()
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.calibrating = false; self.calibrationTimer = nil; self.rebuild()
        }
    }
    func requestPermissions() {
        // Explicit user action only; grid and touch adapter do not force a TCC prompt.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        rebuild()
    }
    private func suspend() {
        stopAdapters(); pinchState = "系统暂停"; f4State = "系统暂停"; refreshStatus()
    }
    private func stopAdapters() {
        // Clearing the C handler takes its callback lock, completing every in-flight
        // add(data:) before the source/context can be cancelled and released.
        OLTouchSetFrameHandler(nil, nil)
        touchWakeup?.source.cancel(); touchWakeup = nil
        OLTouchStop(); recognizer.reset()
        if pinchProgressStarted { onPinchEnd?(false); pinchProgressStarted = false }
        pinchProgressCommitted = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; tapSource = nil; f4Held = false; systemF4Held = false
        calibrationTimer?.invalidate(); calibrationTimer = nil; calibrating = false
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        globalMouse = nil; localMouse = nil; resetCorner()
    }
    private func rebuild() {
        guard running else { return }
        // The user already chose to disable this conflict; apply the saved choice
        // to the live input driver as well as preferences, including after wake.
        let backup = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenLaunch/system-pinch-backup.json")
        if pinchEnabled, FileManager.default.fileExists(atPath: backup.path),
           let saved = try? Data(contentsOf: backup), let document = try? JSONSerialization.jsonObject(with: saved) as? [String: Any],
           document["domain"] as? String == "com.apple.AppleMultitouchTrackpad", document["disabled_active"] as? Bool == true {
            for fingers in [4, 5] {
                let key = "Trackpad\(fingers)FingerPinchGesture"
                if let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.AppleMultitouchTrackpad" as CFString) as? NSNumber,
                   value.intValue == 0, OLSystemPinchGet(Int32(fingers)) != 0 { _ = OLSystemPinchSet(Int32(fingers), 0) }
            }
        }
        stopAdapters()
        lastAccessibility = AXIsProcessTrusted(); lastListenPermission = CGPreflightListenEventAccess()
        pinchState = "关闭"; f4State = "关闭"
        if pinchEnabled {
            if OLTouchStart() == 1 {
                adapterStarts += 1
                pinchState = "\(fingerCount) 指捏合已启用"
                let wakeup = TouchWakeup()
                touchWakeup = wakeup
                wakeup.source.setEventHandler { [weak self, weak wakeup] in
                    guard let self, let wakeup, self.touchWakeup === wakeup else { return }
                    self.readTouches()
                }
                wakeup.source.resume()
                OLTouchSetFrameHandler({ context in
                    guard let context else { return }
                    let wakeup = Unmanaged<TouchWakeup>.fromOpaque(context).takeUnretainedValue()
                    wakeup.source.add(data: 1)
                }, Unmanaged.passUnretained(wakeup).toOpaque())
            } else { pinchState = String(cString: OLTouchStatus()) }
        }
        if f4Enabled { installTap() }
        if cornerMask & 15 != 0 {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]
            globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.checkCorner() }
            localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.checkCorner(); return event }
            cornerConflict = systemCornerConflict()
        } else { cornerConflict = false }
        refreshStatus()
    }
    private func refreshStatus() {
        let names = ["左上", "右上", "左下", "右下"].enumerated().filter { cornerMask & (1 << $0.offset) != 0 }.map(\.element).joined(separator: "/")
        let cornerDescription = names.isEmpty ? "关闭" : names + (cornerRequiresOption ? "（Option）" : "") + "，停留 \(String(format: "%.1f", cornerDwell)) 秒"
        status = "捏合：\(pinchState)；F4：\(f4State)；触发角：\(cornerDescription)" + (cornerConflict ? "（与系统触发角冲突）" : "")
        let conflict = gestureConflictDescription()
        if pinchEnabled && !conflict.isEmpty { status += "；" + conflict }
        onStatusChanged?()
    }
    private func readTouches() {
        var buffer = [OLTouch](repeating: OLTouch(), count: 16)
        var count = 0
        var timestamp = 0.0
        let result = buffer.withUnsafeMutableBufferPointer { OLTouchRead($0.baseAddress, $0.count, &count, &timestamp) }
        if result < 0 {
            OLTouchSetFrameHandler(nil, nil)
            touchWakeup?.source.cancel(); touchWakeup = nil
            OLTouchStop(); recognizer.reset()
            if pinchProgressStarted { onPinchEnd?(false); pinchProgressStarted = false }
            pinchState = "触点解析错误，已停用"; refreshStatus(); return
        }
        guard result > 0, count <= buffer.count else { return }
        // The C adapter drains its bounded FIFO oldest-first. Release markers
        // reset one gesture before any queued frames from the next one.
        if result & 2 != 0 { finishTouchDiagnostic(); recognizer.reset() }
        if result & 1 != 0 {
            let points = buffer.prefix(count).map { TouchPoint(id: Int($0.id), x: $0.x, y: $0.y) }
            recordTouchDiagnostic(points, timestamp: timestamp)
            let activated = recognizer.update(points, timestamp: timestamp)
            if recognizer.isTracking || activated {
                if recognizer.progress > 0.01 || pinchProgressStarted {
                    pinchProgressStarted = true
                    diagnosticProgressFrames += 1
                    if recognizer.progress > 0 && recognizer.progress < 1 { diagnosticPartialProgressFrames += 1 }
                    onPinchProgress?(recognizer.progress)
                }
            }
            if pinchProgressStarted && !recognizer.isTracking && !activated && !pinchProgressCommitted {
                onPinchEnd?(false); pinchProgressStarted = false
            }
            if activated { pinchProgressCommitted = true; diagnosticActivated = true; pinchState = "已收到 \(fingerCount) 指捏合"; refreshStatus(); activate("pinch") }
            diagnosticDecisions[recognizer.decision, default: 0] += 1
        }
        // Process one sample per main-loop turn so reveal animation gets each
        // progress update while the queue prevents a fast gesture being skipped.
        if result & 4 != 0 { touchWakeup?.source.add(data: 1) }
    }
    private func activate(_ source: String) { onActivate?(source) } // All adapters deliver on main run loop.
    private func installTap() {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            f4State = "需要辅助功能/输入监控权限"; return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << 14)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handleKey(type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            f4State = "无法建立事件监听"; return
        }
        tapSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        f4State = learnedSystemCode == nil ? "普通 F4 已启用；系统键帽请到设置录制 F4" : "普通 F4 / 已录制系统键帽已启用（真实按键待验证）"
    }
    private func handleKey(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            f4Held = false; recognizer.reset()
            if AXIsProcessTrusted(), CGPreflightListenEventAccess(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            else { f4State = "权限撤销，已停止接管"; refreshStatus() }
            return Unmanaged.passUnretained(event)
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            f4Held = false; systemF4Held = false; return Unmanaged.passUnretained(event)
        }
        if type.rawValue == 14 {
            if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                let code = (ns.data1 >> 16) & 0xffff
                let state = (ns.data1 >> 8) & 0xff
                let repeated = (ns.data1 & 1) != 0
                if lastSystemKeyCode != code { lastSystemKeyCode = code; onStatusChanged?() }
                if calibrating && state == 0x0a && !repeated && code > 25 {
                    // Explicit user calibration. Never learn the documented volume,
                    // brightness, transport or illumination codes (0...25).
                    UserDefaults.standard.set(code, forKey: "OpenLaunch.input.confirmedF4SystemKeyCode")
                    calibrating = false; calibrationTimer?.invalidate(); calibrationTimer = nil
                    f4State = "已录制系统 F4 编号 \(code)；再次按键验证"; refreshStatus()
                    DispatchQueue.main.async { [weak self] in self?.rebuild() }
                    return Unmanaged.passUnretained(event)
                }
                if f4Enabled && code == learnedSystemCode {
                    if state == 0x0b && systemF4Held { systemF4Held = false; return nil }
                    guard ns.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return Unmanaged.passUnretained(event) }
                    if state == 0x0b { systemF4Held = false; return nil }
                    if state == 0x0a {
                        if !systemF4Held && !repeated { systemF4Held = true; DispatchQueue.main.async { [weak self] in self?.activate("F4-system") } }
                        return nil
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if calibrating && type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 118 {
            calibrating = false; calibrationTimer?.invalidate(); calibrationTimer = nil
            f4State = "此模式发送普通 F4（118）；无需录制系统编号"; refreshStatus()
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
            return Unmanaged.passUnretained(event)
        }
        guard f4Enabled else { return Unmanaged.passUnretained(event) }
        guard event.getIntegerValueField(.keyboardEventKeycode) == 118 else { return Unmanaged.passUnretained(event) }
        if type == .keyUp && f4Held { f4Held = false; return nil }
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard modifiers.isEmpty else { return Unmanaged.passUnretained(event) }
        if type == .keyUp { f4Held = false; return nil }
        if type == .keyDown {
            if !f4Held && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { f4Held = true; DispatchQueue.main.async { [weak self] in self?.activate("F4") } }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
    private func resetCorner() { cornerTimer?.invalidate(); cornerTimer = nil; cornerArmed = true; cornerTarget = nil }
    private func matchingCorner() -> CornerTarget? {
        guard cornerMask & 15 != 0 else { return nil }
        let point = NSEvent.mouseLocation
        // Cocoa coordinates, including screens left/below the primary display.
        for screen in NSScreen.screens {
            let frame = screen.frame
            guard point.x >= frame.minX - 1, point.x <= frame.maxX + 1, point.y >= frame.minY - 1, point.y <= frame.maxY + 1 else { continue }
            let left = abs(point.x - frame.minX) <= 3, right = abs(point.x - frame.maxX) <= 3
            let top = abs(point.y - frame.maxY) <= 3, bottom = abs(point.y - frame.minY) <= 3
            let matches = [left && top, right && top, left && bottom, right && bottom]
            for index in 0..<4 where cornerMask & (1 << index) != 0 && matches[index] {
                return CornerTarget(screen: screen, index: index)
            }
        }
        return nil
    }
    private func checkCorner() {
        guard let target = matchingCorner() else { resetCorner(); return }
        if let old = cornerTarget, old != target { resetCorner() }
        cornerTarget = target
        guard !cornerRequiresOption || NSEvent.modifierFlags.contains(.option) else {
            cornerTimer?.invalidate(); cornerTimer = nil; return
        }
        guard cornerArmed, cornerTimer == nil else { return }
        cornerTimer = Timer.scheduledTimer(withTimeInterval: cornerDwell.isFinite ? min(5, max(0.1, cornerDwell)) : 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.cornerTimer = nil
            guard self.matchingCorner() == self.cornerTarget else { self.resetCorner(); return }
            guard !self.cornerRequiresOption || NSEvent.modifierFlags.contains(.option) else { return }
            self.cornerArmed = false; self.activate("corner")
        }
        if let timer = cornerTimer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func gestureConflictDescription() -> String {
        let key: String, label: String
        switch fingerCount {
        case 3: key = "TrackpadThreeFingerDrag"; label = "系统三指拖移"
        case 4: key = "TrackpadFourFingerPinchGesture"; label = "系统四指捏合"
        case 5: key = "TrackpadFiveFingerPinchGesture"; label = "系统五指捏合"
        default: return ""
        }
        let domains = [("内置", "com.apple.AppleMultitouchTrackpad"), ("蓝牙", "com.apple.driver.AppleBluetoothMultitouch.trackpad")]
        let states = domains.map { name, domain -> String in
            guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString), let number = value as? NSNumber else {
                return name + "未知"
            }
            return name + (number.intValue > 0 ? "已开启（可能冲突）" : "已关闭")
        }
        return label + "：" + states.joined(separator: "/")
    }
    private func systemCornerConflict() -> Bool {
        guard let dock = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") else { return false }
        let keys = ["wvous-tl-corner", "wvous-tr-corner", "wvous-bl-corner", "wvous-br-corner"]
        return keys.enumerated().contains { index, key in
            cornerMask & (1 << index) != 0 && (dock[key] as? Int ?? 0) > 1
        }
    }
}
