import Foundation

public struct TouchPoint: Equatable {
    public let id: Int
    public let x: Double
    public let y: Double
    public init(id: Int, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

/// Pure recognizer. A matched, brief 5-to-4 contact dropout freezes tracking; other
/// count changes restart tracking. Discontinuity and malformed
/// frames disarm it until fingers leave. Positions are normalized to the touch surface.
public struct PinchRecognizer {
    public private(set) var decision = "idle"
    /// Continuous contraction toward both activation thresholds, including reversals.
    public private(set) var progress: Double = 0
    public var isTracking: Bool { !locked && !ids.isEmpty }
    public var fingerCount: Int = 4 { didSet { reset() } }
    private var ids: Set<Int> = []
    private var lastTouches: [TouchPoint] = []
    private var lastTrackingTime: Double = 0
    private var missingContactGrace = false
    private var centroid = (x: 0.0, y: 0.0)
    private var spread = 0.0
    private var started = 0.0
    private var previous = -Double.infinity
    private var locked = false
    public init(fingerCount: Int = 4) { self.fingerCount = fingerCount }
    public mutating func reset() {
        ids = []; lastTouches = []; missingContactGrace = false; spread = 0; previous = -.infinity; locked = false; decision = "idle"; progress = 0
    }
    public mutating func update(_ touches: [TouchPoint], timestamp: Double) -> Bool {
        guard timestamp.isFinite, timestamp >= previous,
              touches.count <= 16,
              touches.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              Set(touches.map(\.id)).count == touches.count else {
            decision = "invalid_frame"; progress = 0; locked = true; ids = []; return false
        }
        previous = timestamp
        if touches.isEmpty { reset(); return false }
        guard (3...5).contains(fingerCount), touches.count == fingerCount else {
            // Only an already established five-contact gesture may bridge one
            // briefly missing contact. Never update its baseline or progress here.
            if fingerCount == 5, touches.count == 4, isTracking, timestamp - started > 2.5 {
                decision = "timeout"; progress = 0; locked = true; return false
            }
            if fingerCount == 5, touches.count == 4, isTracking,
               timestamp - lastTrackingTime <= 0.16,
               spatiallyContinuous(touches, maximumDistance: 0.1, allowSubset: true) {
                missingContactGrace = true; decision = "waiting_contact_recovery"
                return false
            }
            decision = "waiting_finger_count"; progress = 0; ids = []; lastTouches = []; missingContactGrace = false; spread = 0; return false
        }
        guard !locked else { return false }
        let currentIDs = Set(touches.map(\.id))
        let cx = touches.reduce(0) { $0 + $1.x } / Double(touches.count)
        let cy = touches.reduce(0) { $0 + $1.y } / Double(touches.count)
        let radius = touches.reduce(0) { $0 + hypot($1.x - cx, $1.y - cy) } / Double(touches.count)
        if ids.isEmpty {
            guard radius >= 0.08 else { decision = "initial_spread_too_small"; progress = 0; locked = true; return false }
            decision = "tracking"; ids = currentIDs; centroid = (cx, cy); spread = radius; started = timestamp; lastTouches = touches; lastTrackingTime = timestamp
            return false
        }
        if missingContactGrace {
            // Recheck all five locations, including unchanged IDs. The timeout is
            // measured from the last full frame, not extended by four-contact frames.
            guard timestamp - lastTrackingTime <= 0.2,
                  spatiallyContinuous(touches, maximumDistance: 0.12) else {
                decision = "contact_recovery_failed"; progress = 0; locked = true; return false
            }
            missingContactGrace = false; ids = currentIDs; decision = "contact_recovered"
        } else if ids != currentIDs {
            guard timestamp - lastTrackingTime <= 0.08, spatiallyContinuous(touches) else {
                decision = "finger_identity_changed"; progress = 0; locked = true; return false
            }
            ids = currentIDs; decision = "contact_reidentified"
        }
        guard timestamp - started <= 2.5,
              hypot(cx - centroid.x, cy - centroid.y) <= 0.12 else {
            decision = timestamp - started > 2.5 ? "timeout" : "hand_translated"
            progress = 0; locked = true; return false
        }
        lastTouches = touches; lastTrackingTime = timestamp
        progress = max(0, min(1, min((1 - radius / spread) / 0.22, (spread - radius) / 0.025)))
        // A faster, shorter pinch should still commit. Keep both a proportional
        // contraction and a small absolute movement to reject sensor jitter.
        if radius <= spread * 0.78 && spread - radius >= 0.025 {
            decision = "activated"; progress = 1; locked = true; return true
        }
        return false
    }
    private func spatiallyContinuous(_ current: [TouchPoint], maximumDistance: Double = 0.08, allowSubset: Bool = false) -> Bool {
        guard allowSubset ? lastTouches.count >= current.count : lastTouches.count == current.count else { return false }
        // At most five contacts; exact bipartite matching also matches a four-point
        // subset without assigning multiple new contacts to the same old location.
        func match(_ index: Int, _ used: Int) -> Bool {
            if index == current.count { return true }
            let new = current[index]
            for candidate in lastTouches.indices where used & (1 << candidate) == 0 {
                let old = lastTouches[candidate]
                if hypot(old.x - new.x, old.y - new.y) <= maximumDistance,
                   match(index + 1, used | (1 << candidate)) { return true }
            }
            return false
        }
        return match(0, 0)
    }
}
