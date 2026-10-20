import XCTest
@testable import SplitwaveCore

final class SilenceDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testFlagsAPlayingRouteThatNeverCarriedSound() {
        var detector = SilenceDetector(threshold: 4)
        XCTAssertEqual(detector.update(active: [("spotify", true, 0)], now: t0), [])
        XCTAssertEqual(detector.update(active: [("spotify", true, 0)], now: t0 + 3), [])
        XCTAssertEqual(detector.update(active: [("spotify", true, 0)], now: t0 + 4), ["spotify"])
    }

    func testQuietPassageAfterSoundIsNotAFault() {
        var detector = SilenceDetector(threshold: 4)
        _ = detector.update(active: [("spotify", true, 0.3)], now: t0)
        XCTAssertEqual(detector.update(active: [("spotify", true, 0)], now: t0 + 10), [])
    }

    func testIdleAppsAndRemovedRoutesAreForgotten() {
        var detector = SilenceDetector(threshold: 4)
        _ = detector.update(active: [("chrome", true, 0)], now: t0)
        // Paused: the clock resets.
        XCTAssertEqual(detector.update(active: [("chrome", false, 0)], now: t0 + 5), [])
        XCTAssertEqual(detector.update(active: [("chrome", true, 0)], now: t0 + 6), [])
        // Unrouted, then routed again: starts over.
        _ = detector.update(active: [], now: t0 + 7)
        XCTAssertEqual(detector.update(active: [("chrome", true, 0)], now: t0 + 9), [])
        XCTAssertEqual(detector.update(active: [("chrome", true, 0)], now: t0 + 13), ["chrome"])
    }
}
