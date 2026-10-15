import AppKit
import CTouch
import OpenLaunchCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: LauncherController!
    let input = InputController()
    let shortcut = ShortcutController()
    var menuItem: NSStatusItem?
    var launchStart = ProcessInfo.processInfo.systemUptime
    private var lastActivation: TimeInterval = 0
    private var activationCounts: [String: Int] = [:]
    private let args = CommandLine.arguments
    private var smoke: Bool { args.contains("--smoke") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenLaunch")
        let storeURL = smoke ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenLaunch-smoke-" + UUID().uuidString).appendingPathComponent("layout.json") : base.appendingPathComponent("layout.json")
        if !smoke { input.f4Enabled = false }
        controller = LauncherController(storeURL: storeURL, input: input)
        input.onActivate = { [weak self] source in self?.activate(source) }
        input.onPinchProgress = { [weak self] progress in self?.controller.updatePinchReveal(progress) }
        input.onPinchEnd = { [weak self] committed in self?.controller.endPinchReveal(committed: committed) }
        controller.onShortcutChanged = { [weak self] _ in self?.shortcut.start() }
        shortcut.onActivate = { [weak self] in self?.activate("shortcut") }
        if !smoke { setupMenu(); input.start(); shortcut.start() }
        controller.scan { [weak self] in
            guard let self else { return }
            if self.smoke {
                do {
                    var result = try self.controller.smokeCheck()
                    result["process_to_scan_ms"] = (ProcessInfo.processInfo.systemUptime - self.launchStart) * 1000
                    let dir = self.args.firstIndex(of: "--output").flatMap { i in i + 1 < self.args.count ? self.args[i + 1] : nil } ?? FileManager.default.temporaryDirectory.path
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    self.controller.verifyNativeInteractions { interactionPassed in
                        guard interactionPassed else { fputs("Smoke failed: native reveal/background interaction\n", stderr); exit(1) }
                        self.controller.verifyPagingAnimation { animationPassed in
                        do {
                            guard animationPassed else { throw LayoutError.invalid("原生分页动画中断/复位验证失败。") }
                            result["native_animation_interrupt"] = "passed"
                            result["native_reveal_progress_cancel_idempotence"] = "passed"
                            result["native_background_click"] = "passed"
                            result.merge(self.controller.smokeImageStatus) { _, new in new }
                            try self.controller.exportPagingMidpoint(to: URL(fileURLWithPath: dir).appendingPathComponent("paging-midpoint.png"))
                            try self.controller.exportPreview(to: URL(fileURLWithPath: dir).appendingPathComponent("preview.png"))
                            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("smoke.json"))
                            print(String(data: data, encoding: .utf8)!)
                            try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
                            NSApp.terminate(nil)
                        } catch { fputs("Smoke failed: \(error)\n", stderr); exit(1) }
                        }
                    }
                } catch { fputs("Smoke failed: \(error)\n", stderr); exit(1) }
            } else if !self.args.contains("--background") {
                self.controller.show()
                self.controller.catalog.pruneDiskCache()
                if let error = self.controller.loadError { self.controller.alert(error) }
            }
        }
    }
    private func activate(_ source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard source == "pinch" || now - lastActivation > 0.25 else { return }
        lastActivation = now
        activationCounts[source, default: 0] += 1
        let began = ProcessInfo.processInfo.systemUptime
        if source == "pinch" { controller.commitPinchReveal() } else { controller.toggle() }
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
        // Only trigger category and count are retained, never key text or touch positions.
        let report: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "action": source == "pinch" ? "show" : "toggle", "counts": activationCounts, "latest": source, "input": input.diagnostics, "shortcut": shortcut.status, "visible": controller.window.isVisible, "toggle_call_ms": elapsed]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenLaunch")
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? data.write(to: base.appendingPathComponent("input-status.json"), options: .atomic)
        }
    }
    private func setupMenu() {
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem?.button?.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "OpenLaunch")
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开启动台  ⌃⌥Space", action: #selector(toggle), keyEquivalent: ""); show.target = self; menu.addItem(show)
        let settings = NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let probe = NSMenuItem(title: "查看输入状态", action: #selector(inputStatus), keyEquivalent: ""); probe.target = self; menu.addItem(probe)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 OpenLaunch", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        menuItem?.menu = menu
    }
    @objc func toggle() { activate("menu") }
    @objc func settingsAction() { NSApp.activate(ignoringOtherApps: true); controller.showSettings() }
    @objc func inputStatus() { NSApp.activate(ignoringOtherApps: true); controller.alert(input.diagnostics + "\n" + shortcut.status) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationDidResignActive(_ notification: Notification) { if !smoke { controller?.hide() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { controller.show(); return true }
    func applicationWillTerminate(_ notification: Notification) { input.stop(); shortcut.stop() }
}
if CommandLine.arguments.contains("--verify-input-lifecycle") {
    let input = InputController(); input.start()
    let before = input.adapterStarts
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    let after = input.adapterStarts
    input.stop()
    print("screen change: adapter starts before=\(before) after=\(after)")
    exit(before > 0 && before == after ? 0 : 1)
}
if CommandLine.arguments.contains("--trace-input") {
    let input = InputController()
    input.onActivate = { source in print("recognized=\(source)") }
    input.start()
    print(input.diagnostics)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 45))
    input.stop(); exit(0)
}
if CommandLine.arguments.contains("--probe-input") {
    let input = InputController(); input.start()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    print(input.diagnostics); input.stop(); exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--verify-launch"), index + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let config = NSWorkspace.OpenConfiguration(); config.activates = false
    var finished = false
    NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
        if let error { fputs("Launch failed: \(error)\n", stderr); exit(1) }
        print("actual_target_pid=\(app?.processIdentifier ?? 0) bundle=\(app?.bundleIdentifier ?? "unknown") terminated=\(app?.isTerminated ?? true)")
        finished = true
    }
    let deadline = Date(timeIntervalSinceNow: 10)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    exit(finished ? 0 : 1)
}
let application = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--capture-pinches") {
    let outputPath = index + 1 < CommandLine.arguments.count
        ? CommandLine.arguments[index + 1]
        : FileManager.default.currentDirectoryPath + "/verification/pinch-capture"
    let captureDelegate = PinchCapture(outputURL: URL(fileURLWithPath: outputPath, isDirectory: true))
    application.delegate = captureDelegate
    application.run()
    exit(0)
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
