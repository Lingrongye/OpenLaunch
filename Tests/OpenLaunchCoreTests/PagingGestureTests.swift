import Testing
@testable import OpenLaunchCore

@Test func pagingAccumulationAndCommit() {
    var gesture = PagingGesture()
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    for i in 0..<60 { _ = gesture.update(dx: -2, dy: 0, timestamp: Double(i) * 0.02) }
    #expect(gesture.offset == -120)
    let page = gesture.end()
    #expect(page == 1)
    #expect(!gesture.isTracking)
    #expect(gesture.offset == 0)
    let momentum = gesture.update(dx: -300, dy: 0, timestamp: 2)
    #expect(momentum == 0)
    let secondEnd = gesture.end()
    #expect(secondEnd == 0)
}
@Test func pagingVerticalAndJitterDoNotCommit() {
    var gesture = PagingGesture()
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: -1, dy: 7, timestamp: 0)
    let vertical = gesture.update(dx: -200, dy: 2, timestamp: 0.05)
    #expect(vertical == 0)
    let verticalEnd = gesture.end()
    #expect(verticalEnd == 0)
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    for i in 0..<10 { _ = gesture.update(dx: i % 2 == 0 ? -4 : 3, dy: 0, timestamp: Double(i) * 0.01) }
    let jitterEnd = gesture.end()
    #expect(jitterEnd == 0)
}
@Test func pagingFastFlickAndSlowShortDrag() {
    var gesture = PagingGesture()
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: -20, dy: 0, timestamp: 0)
    _ = gesture.update(dx: -20, dy: 0, timestamp: 0.04)
    let flickEnd = gesture.end()
    #expect(flickEnd == 1)
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: 20, dy: 0, timestamp: 0)
    _ = gesture.update(dx: 20, dy: 0, timestamp: 0.4)
    let slowEnd = gesture.end()
    #expect(slowEnd == 0)
}
@Test func pagingBoundariesAndCancellation() {
    var gesture = PagingGesture()
    gesture.begin(width: 600, canPrevious: false, canNext: true)
    let resistance = gesture.update(dx: 400, dy: 0, timestamp: 0)
    #expect(resistance > 0 && resistance < 100)
    let blockedPrevious = gesture.end()
    #expect(blockedPrevious == 0)
    gesture.begin(width: 600, canPrevious: true, canNext: false)
    let negativeResistance = gesture.update(dx: -400, dy: 0, timestamp: 1)
    #expect(negativeResistance < 0 && negativeResistance > -100)
    let blockedNext = gesture.end()
    #expect(blockedNext == 0)
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: 200, dy: 0, timestamp: 2)
    let cancelled = gesture.end(cancelled: true)
    #expect(cancelled == 0)
    #expect(gesture.offset == 0)
}
@Test func pagingPreviousAndMalformedEvents() {
    var gesture = PagingGesture()
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: 120, dy: 0, timestamp: 0)
    let previous = gesture.end()
    #expect(previous == -1)
    gesture.begin(width: 600, canPrevious: true, canNext: true)
    _ = gesture.update(dx: -20, dy: 0, timestamp: 1)
    _ = gesture.update(dx: -20, dy: 0, timestamp: 1.04)
    let invalid = gesture.update(dx: .nan, dy: 0, timestamp: 1.05)
    #expect(invalid == 0)
    #expect(!gesture.isTracking)
    let invalidEnd = gesture.end()
    #expect(invalidEnd == 0)
    gesture.begin(width: 0, canPrevious: true, canNext: true)
    #expect(!gesture.isTracking)
}
@Test func pagingOrdinarySlowSwipeOnWideViewport() {
    var gesture = PagingGesture()
    gesture.begin(width: 1235, canPrevious: true, canNext: true)
    for i in 0..<40 { _ = gesture.update(dx: -3, dy: 0, timestamp: Double(i) / 60) }
    let ordinarySwipe = gesture.end()
    #expect(ordinarySwipe == 1)
    gesture.begin(width: 1235, canPrevious: true, canNext: true)
    for i in 0..<20 { _ = gesture.update(dx: -2, dy: 0, timestamp: 1 + Double(i) / 60) }
    let shortDrag = gesture.end()
    #expect(shortDrag == 0)
}

@Test func pagingResumesFromInterruptedPresentation() {
    var gesture = PagingGesture()
    gesture.begin(width: 1000, canPrevious: true, canNext: true, initialOffset: 160)
    #expect(gesture.offset == 160)
    let resumed = gesture.update(dx: -20, dy: 0, timestamp: 1)
    #expect(resumed == 140)
    #expect(gesture.end() == 0)
    gesture.begin(width: 1000, canPrevious: true, canNext: true, initialOffset: .nan)
    #expect(!gesture.isTracking)
}

@Test func interruptedAnimationCannotReverseNewSwipeDirection() {
    var gesture = PagingGesture()
    gesture.begin(width: 1200, canPrevious: true, canNext: true, initialOffset: 900)
    for i in 0..<20 { _ = gesture.update(dx: -6, dy: 0, timestamp: Double(i) / 60) }
    #expect(gesture.offset == 780)
    #expect(gesture.end() == 1)
    gesture.begin(width: 1200, canPrevious: true, canNext: true, initialOffset: -900)
    for i in 0..<20 { _ = gesture.update(dx: 6, dy: 0, timestamp: Double(i) / 60) }
    #expect(gesture.offset == -780)
    #expect(gesture.end() == -1)
}
