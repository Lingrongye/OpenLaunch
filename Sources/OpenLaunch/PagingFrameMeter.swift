import AppKit
import QuartzCore

/// Samples main-run-loop callback intervals only during a swipe/settle.
/// This detects UI-thread stalls; it is not a GPU-rendered FPS measurement.
final class PagingFrameMeter: NSObject {
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var intervals: [Double] = []
    func start(view: NSView) {
        _ = stop(); intervals.reserveCapacity(120)
        let link = view.displayLink(target: self, selector: #selector(sample(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func sample(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous, intervals.count < 360 { intervals.append((now - previous) * 1000) }
        previous = now
        if intervals.count >= 360 { sender.invalidate(); link = nil }
    }
    func stop() -> [String: Any] {
        link?.invalidate(); link = nil; previous = nil
        defer { intervals.removeAll(keepingCapacity: true) }
        guard !intervals.isEmpty else { return ["samples": 0, "kind": "main_runloop_callbacks"] }
        let ordered = intervals.sorted(), p95 = ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * 0.95))]
        return ["samples": intervals.count, "mean_ms": intervals.reduce(0, +) / Double(intervals.count), "p95_ms": p95, "max_ms": ordered.last!, "kind": "main_runloop_callbacks"]
    }
    deinit { link?.invalidate() }
}
