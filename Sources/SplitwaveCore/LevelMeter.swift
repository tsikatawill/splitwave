import Foundation

/// Turns the IOProc's raw peaks into the bar the popover draws inside the volume slider.
public enum LevelScale {
    /// The bottom of the meter. Music lives roughly between -30 and 0 dBFS, so a -40 floor
    /// keeps the bar moving instead of parking it half full (as a -60 floor did).
    public static let floorDB: Double = -40

    /// Pre-volume level as 0...1. The peak arrives after the gain was applied; dividing it back out
    /// gives the app's own level, which the slider then scales by the volume, so the bright fill
    /// never passes the knob.
    public static func fraction(peak: Float, gain: Float) -> Double {
        guard peak > 0, gain > 0 else { return 0 }
        let db = 20 * log10(Double(min(1, peak / gain)))
        return max(0, min(1, 1 - db / floorDB))
    }
}

/// Meter ballistics: jump straight up to a new peak, fall back smoothly.
public struct LevelBallistics: Sendable {
    /// Seconds for the bar to fall to ~37% after the sound stops.
    public var release: Double
    public private(set) var value: Double = 0
    private var last: Date?

    public init(release: Double = 0.25) { self.release = release }

    public mutating func update(_ target: Double, now: Date = Date()) -> Double {
        let dt = last.map { max(0, now.timeIntervalSince($0)) } ?? 0
        last = now
        value = target >= value ? target : max(target, value * exp(-dt / release))
        return value
    }
}
