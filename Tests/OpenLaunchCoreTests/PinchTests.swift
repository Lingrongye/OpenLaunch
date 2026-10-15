import Testing
@testable import OpenLaunchCore

private func ring(_ radius: Double, count: Int = 4, dx: Double = 0) -> [TouchPoint] {
    (0..<count).map { i in
        let a = Double(i) * 2 * .pi / Double(count)
        return TouchPoint(id: i, x: 0.5 + dx + cos(a) * radius, y: 0.5 + sin(a) * radius)
    }
}
import Foundation
@Test func pinchContracts() {
    for n in 3...5 {
        var r = PinchRecognizer(fingerCount: n)
        let frameResult1 = r.update(ring(0.3, count: n), timestamp: 0)
        #expect(!frameResult1)
        let frameResult2 = r.update(ring(0.28, count: n), timestamp: 0.05)
        #expect(!frameResult2)
        let frameResult3 = r.update(ring(0.15, count: n), timestamp: 0.15)
        #expect(frameResult3)
        let frameResult4 = r.update(ring(0.1, count: n), timestamp: 0.2)
        #expect(!frameResult4)
        let frameResult5 = r.update([], timestamp: 0.3)
        #expect(!frameResult5)
        let frameResult6 = r.update(ring(0.3, count: n), timestamp: 0.4)
        #expect(!frameResult6)
        let frameResult7 = r.update(ring(0.15, count: n), timestamp: 0.55)
        #expect(frameResult7)
    }
}
@Test func fastFiveFingerPinchCommitsBeforeRelease() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    let activated = r.update(ring(0.18, count: 5), timestamp: 0.02)
    #expect(activated)
    #expect(r.progress == 1)
    #expect(!r.isTracking)
}
@Test func shortTravelFastPinchCommits() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.12, count: 5), timestamp: 0)
    let activated = r.update(ring(0.09, count: 5), timestamp: 0.016)
    #expect(activated)
    #expect(r.progress == 1)
}
@Test func rejectsScrollWrongCountAndMalformedFrames() {
    var r = PinchRecognizer()
    let frameResult8 = r.update(ring(0.3, count: 2), timestamp: 0)
    #expect(!frameResult8)
    let frameResult9 = r.update(ring(0.1, count: 2), timestamp: 0.2)
    #expect(!frameResult9)
    let frameResult10 = r.update(ring(0.2), timestamp: 1)
    #expect(!frameResult10)
    let frameResult11 = r.update(ring(0.2, dx: 0.2), timestamp: 1.2)
    #expect(!frameResult11)
    let frameResult12 = r.update(ring(0.05, dx: 0.2), timestamp: 1.4)
    #expect(!frameResult12)
    r.reset()
    let frameResult13 = r.update(ring(0.3), timestamp: 2)
    #expect(!frameResult13)
    let frameResult14 = r.update([TouchPoint(id: 0, x: .nan, y: 0)], timestamp: 2.1)
    #expect(!frameResult14)
    let frameResult15 = r.update(ring(0.1), timestamp: 2.2)
    #expect(!frameResult15)
}
@Test func rejectsIdentityChangesAndTimeout() {
    var r = PinchRecognizer()
    let frameResult16 = r.update(ring(0.3), timestamp: 0)
    #expect(!frameResult16)
    let frameResult17 = r.update(ring(0.1), timestamp: 4)
    #expect(!frameResult17)
    r.reset()
    let frameResult18 = r.update(ring(0.3), timestamp: 5)
    #expect(!frameResult18)
    var points = ring(0.1)
    points[0] = TouchPoint(id: 99, x: points[0].x, y: points[0].y)
    let frameResult19 = r.update(points, timestamp: 5.2)
    #expect(!frameResult19)
}

@Test func rejectsDuplicateIDsInvalidBoundsAndBackwardTime() {
    var r = PinchRecognizer()
    _ = r.update(ring(0.3), timestamp: 0)
    var duplicate = ring(0.1)
    duplicate[1] = TouchPoint(id: duplicate[0].id, x: duplicate[1].x, y: duplicate[1].y)
    let duplicateResult = r.update(duplicate, timestamp: 0.2)
    #expect(!duplicateResult)
    r.reset()
    _ = r.update(ring(0.3), timestamp: 1)
    var outside = ring(0.1)
    outside[0] = TouchPoint(id: 0, x: 1.1, y: 0.5)
    let boundsResult = r.update(outside, timestamp: 1.2)
    #expect(!boundsResult)
    r.reset()
    _ = r.update(ring(0.3), timestamp: 2)
    let backwardResult = r.update(ring(0.1), timestamp: 1.9)
    #expect(!backwardResult)
}

@Test func continuousFiveFingerPinchSurvivesContactReidentification() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    var activations = 0
    for i in 1...14 {
        var points = ring(0.3 - Double(i) * 0.012, count: 5)
        if i >= 3 { points[0] = TouchPoint(id: 99, x: points[0].x, y: points[0].y) }
        if r.update(points, timestamp: Double(i) * 0.01) { activations += 1 }
    }
    #expect(activations == 1)
}
@Test func reidentificationDoesNotJoinSeparatedOrDistantContacts() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    var points = ring(0.29, count: 5)
    points[0] = TouchPoint(id: 99, x: points[0].x, y: points[0].y)
    let delayed = r.update(points, timestamp: 0.2)
    #expect(!delayed)
    let afterDelay = r.update(ring(0.1, count: 5), timestamp: 0.3)
    #expect(!afterDelay)
    r.reset()
    _ = r.update(ring(0.3, count: 5), timestamp: 1)
    var distant = ring(0.1, count: 5)
    distant[0] = TouchPoint(id: 99, x: distant[0].x, y: distant[0].y)
    let distantResult = r.update(distant, timestamp: 1.01)
    #expect(!distantResult)
}

@Test func reidentifiedContactsMatchOneToOneRegardlessOfArrayOrder() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    var activations = 0
    for i in 1...14 {
        let points = Array(ring(0.3 - Double(i) * 0.012, count: 5).reversed()).map {
            TouchPoint(id: $0.id + 100, x: $0.x, y: $0.y)
        }
        if r.update(points, timestamp: Double(i) * 0.01) { activations += 1 }
    }
    #expect(activations == 1)
    r.reset()
    _ = r.update(ring(0.3, count: 5), timestamp: 1)
    let crowded = (0..<5).map { TouchPoint(id: 100 + $0, x: 0.5, y: 0.5) }
    let crowdedResult = r.update(crowded, timestamp: 1.01)
    #expect(!crowdedResult)
}
@Test func contactCountGapStartsANewPinchBaseline() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    _ = r.update(ring(0.2, count: 4), timestamp: 0.01)
    _ = r.update(ring(0.14, count: 5), timestamp: 0.02)
    let result = r.update(ring(0.1, count: 5), timestamp: 0.13)
    #expect(result)
}

@Test func slowPinchPublishesProgressAndCanExpandBack() {
    var r = PinchRecognizer(fingerCount: 5)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    #expect(r.isTracking)
    let first = r.update(ring(0.27, count: 5), timestamp: 0.2)
    #expect(!first)
    #expect(abs(r.progress - (0.03 / 0.3 / 0.22)) < 0.000001)
    _ = r.update(ring(0.24, count: 5), timestamp: 0.4)
    let contractedProgress = r.progress
    #expect(contractedProgress > 0.9 && contractedProgress < 1)
    _ = r.update(ring(0.285, count: 5), timestamp: 0.6)
    #expect(r.progress < contractedProgress)
    #expect(r.progress > 0.2 && r.progress < 0.3)
    _ = r.update(ring(0.32, count: 5), timestamp: 0.8)
    #expect(r.progress == 0)
    #expect(r.isTracking)
    r.reset()
    #expect(r.progress == 0)
    #expect(!r.isTracking)
    _ = r.update(ring(0.09, count: 5), timestamp: 1)
    _ = r.update(ring(0.07, count: 5), timestamp: 1.2)
    #expect(abs(r.progress - 0.8) < 0.000001)
}
@Test func pinchProgressClearsOnCancellationAndDiscontinuity() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    _ = r.update(ring(0.27, count: 5), timestamp: 0.2)
    _ = r.update(ring(0.27, count: 4), timestamp: 0.3)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
    _ = r.update(ring(0.3, count: 5), timestamp: 0.4)
    _ = r.update(ring(0.27, count: 5), timestamp: 0.6)
    _ = r.update([], timestamp: 0.7)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
    _ = r.update(ring(0.3, count: 5), timestamp: 1)
    _ = r.update(ring(0.27, count: 5), timestamp: 1.2)
    _ = r.update([TouchPoint(id: 0, x: .nan, y: 0.5)], timestamp: 1.3)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
    r.reset()
    _ = r.update(ring(0.3, count: 5), timestamp: 2)
    _ = r.update(ring(0.27, count: 5), timestamp: 2.2)
    let changed = ring(0.26, count: 5).map { TouchPoint(id: $0.id + 100, x: $0.x, y: $0.y) }
    _ = r.update(changed, timestamp: 2.4)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
}
@Test func pinchProgressLatchesAtOneAfterSingleActivation() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    let activated = r.update(ring(0.18, count: 5), timestamp: 0.2)
    #expect(activated)
    #expect(r.progress == 1)
    #expect(!r.isTracking)
    let repeated = r.update(ring(0.3, count: 5), timestamp: 0.4)
    #expect(!repeated)
    #expect(r.progress == 1)
    _ = r.update([], timestamp: 0.5)
    #expect(r.progress == 0)
    #expect(!r.isTracking)
}

@Test func fiveFingerPinchSurvivesBriefMatchedContactLoss() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    _ = r.update(ring(0.27, count: 5), timestamp: 0.05)
    let frozen = r.progress
    var activations = 0
    for (radius, timestamp) in [(0.24, 0.08), (0.22, 0.12), (0.18, 0.15)] {
        if r.update(Array(ring(radius, count: 5).dropLast()), timestamp: timestamp) { activations += 1 }
        #expect(r.isTracking)
        #expect(r.progress == frozen)
    }
    if r.update(ring(0.19, count: 5), timestamp: 0.20) { activations += 1 }
    if r.update(ring(0.17, count: 5), timestamp: 0.22) { activations += 1 }
    #expect(activations == 1)
    #expect(r.progress == 1)
}
@Test func missingContactGraceExpiresAndCannotStartFromFour() {
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    _ = r.update(ring(0.27, count: 5), timestamp: 0.05)
    _ = r.update(Array(ring(0.26, count: 5).dropLast()), timestamp: 0.1)
    _ = r.update(Array(ring(0.25, count: 5).dropLast()), timestamp: 0.27)
    #expect(!r.isTracking)
    #expect(r.progress == 0)
    r.reset()
    for (radius, timestamp) in [(0.3, 1.0), (0.2, 1.1), (0.1, 1.2)] {
        let activated = r.update(Array(ring(radius, count: 5).dropLast()), timestamp: timestamp)
        #expect(!activated)
        #expect(!r.isTracking)
        #expect(r.progress == 0)
    }
}
@Test func returningFifthContactMustMatchOriginalSurfaceAndTime() {
    for timestamp in [0.12, 0.30] {
        var r = PinchRecognizer(fingerCount: 5)
        _ = r.update(ring(0.3, count: 5), timestamp: 0)
        _ = r.update(ring(0.27, count: 5), timestamp: 0.05)
        _ = r.update(Array(ring(0.26, count: 5).dropLast()), timestamp: 0.08)
        let radius = timestamp < 0.2 ? 0.08 : 0.19
        let returned = r.update(ring(radius, count: 5), timestamp: timestamp)
        #expect(!returned)
        #expect(!r.isTracking)
        #expect(r.progress == 0)
    }
}
@Test func missingContactGracePreservesTimeoutAndRejectsTwoOrThree() {
    for count in [2, 3] {
        var r = PinchRecognizer(fingerCount: 5)
        _ = r.update(ring(0.3, count: 5), timestamp: 0)
        _ = r.update(ring(0.27, count: 5), timestamp: 0.05)
        _ = r.update(Array(ring(0.26, count: 5).dropLast()), timestamp: 0.08)
        _ = r.update(Array(ring(0.25, count: 5).prefix(count)), timestamp: 0.1)
        #expect(!r.isTracking)
        #expect(r.progress == 0)
    }
    var r = PinchRecognizer(fingerCount: 5)
    _ = r.update(ring(0.3, count: 5), timestamp: 0)
    _ = r.update(ring(0.27, count: 5), timestamp: 2.45)
    _ = r.update(Array(ring(0.26, count: 5).dropLast()), timestamp: 2.52)
    _ = r.update(ring(0.18, count: 5), timestamp: 2.55)
    #expect(!r.isTracking)
    #expect(r.progress == 0)
}
