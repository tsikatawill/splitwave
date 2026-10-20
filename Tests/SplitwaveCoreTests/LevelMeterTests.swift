import XCTest
@testable import SplitwaveCore

final class LevelMeterTests: XCTestCase {
    func testScaleUndoesTheGainAndUsesAFortyDecibelRange() {
        XCTAssertEqual(LevelScale.fraction(peak: 1, gain: 1), 1)
        XCTAssertEqual(LevelScale.fraction(peak: 0.1, gain: 1), 0.5, accuracy: 1e-6)   // -20 dBFS
        XCTAssertEqual(LevelScale.fraction(peak: 0.01, gain: 1), 0, accuracy: 1e-9)    // -40 dBFS floor
        // Same app level at 25% gain reads the same; the slider scales it by the volume.
        XCTAssertEqual(LevelScale.fraction(peak: 0.025, gain: 0.25), 0.5, accuracy: 1e-6)
        XCTAssertEqual(LevelScale.fraction(peak: 0, gain: 1), 0)
        XCTAssertEqual(LevelScale.fraction(peak: 0.5, gain: 0), 0)  // muted
    }

    func testRisesInstantlyAndFallsSmoothly() {
        var b = LevelBallistics(release: 0.25)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(b.update(0.8, now: t0), 0.8)
        let after = b.update(0, now: t0 + 0.25)
        XCTAssertEqual(after, 0.8 * exp(-1), accuracy: 1e-9)
        XCTAssertEqual(b.update(0.9, now: t0 + 0.26), 0.9)
    }
}
