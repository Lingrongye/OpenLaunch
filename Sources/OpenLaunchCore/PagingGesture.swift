/// Allocation-free drag state. Positive deltas reveal the previous page.
/// Call `begin` for the physical gesture, `end` at release; ignore momentum.
public struct PagingGesture {
    public private(set) var offset: Double = 0
    public private(set) var isTracking = false
    private enum Axis { case pending, horizontal, vertical }
    private var axis = Axis.pending
    private var width: Double = 0
    private var canPrevious = false
    private var canNext = false
    private var visualStart: Double = 0
    private var horizontal: Double = 0
    private var vertical: Double = 0
    private var lastTimestamp: Double?
    private var velocity: Double = 0
    public init() {}

    public mutating func begin(width: Double, canPrevious: Bool, canNext: Bool, initialOffset: Double = 0) {
        reset()
        guard width.isFinite, width > 0, initialOffset.isFinite else { return }
        self.width = width; self.canPrevious = canPrevious; self.canNext = canNext
        visualStart = max(-width, min(width, initialOffset)); offset = visualStart
        isTracking = true
    }
    @discardableResult
    public mutating func update(dx: Double, dy: Double, timestamp: Double) -> Double {
        guard isTracking else { return 0 }
        guard dx.isFinite, dy.isFinite, timestamp.isFinite,
              lastTimestamp == nil || timestamp >= lastTimestamp! else {
            reset(); return 0
        }
        let boundedDX = max(-width, min(width, dx))
        horizontal = max(-width, min(width, horizontal + boundedDX))
        vertical = max(-width, min(width, vertical + max(-width, min(width, dy))))
        if let lastTimestamp, timestamp > lastTimestamp {
            velocity = max(-4_000, min(4_000, boundedDX / (timestamp - lastTimestamp)))
        }
        lastTimestamp = timestamp
        if axis == .pending {
            let x = abs(horizontal), y = abs(vertical)
            if max(x, y) >= 6 {
                if x >= y * 1.25 { axis = .horizontal }
                else if y >= x * 1.25 { axis = .vertical }
            }
        }
        guard axis == .horizontal else { offset = visualStart; return offset }
        let visual = max(-width, min(width, visualStart + horizontal))
        let blocked = visual > 0 ? !canPrevious : !canNext
        if blocked {
            let resistance = width * 0.12
            let distance = abs(visual)
            offset = (visual > 0 ? 1 : -1) * resistance * distance / (resistance + distance)
        } else { offset = visual }
        return offset
    }
    /// Returns at most one page step: -1 previous, +1 next, 0 settle back.
    public mutating func end(cancelled: Bool = false) -> Int {
        defer { reset() }
        guard isTracking, !cancelled, axis == .horizontal else { return 0 }
        let distance = abs(horizontal)
        // Independent tuning: ordinary 120pt swipes must commit on a 1235pt page.
        let longDrag = distance >= width * 0.085
        let fastFlick = distance >= 35 && abs(velocity) >= 450 && horizontal * velocity > 0
        guard longDrag || fastFlick else { return 0 }
        if horizontal > 0 && canPrevious { return -1 }
        if horizontal < 0 && canNext { return 1 }
        return 0
    }
    public mutating func reset() {
        offset = 0; isTracking = false; axis = .pending
        width = 0; visualStart = 0; horizontal = 0; vertical = 0; velocity = 0
        canPrevious = false; canNext = false; lastTimestamp = nil
    }
}
