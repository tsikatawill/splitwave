import AppKit
import Foundation

/// The "system audio recording" permission that process taps need.
///
/// There is no public API to read it: without it a tap is created fine and simply delivers silence.
/// The TCC framework's preflight/request functions are looked up at runtime; if they ever go away
/// the status reads as `.unknown` and the silence check (see `SilenceDetector`) still catches it.
public enum AudioCapturePermission {
    public enum Status: Equatable, Sendable {
        case authorized, denied, unknown
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static var status: Status {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the person hasn't answered yet; calls back on the main queue.
    public static func request(_ completion: @escaping (Bool) -> Void) {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// System Settings › Privacy & Security › Screen & System Audio Recording.
    public static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Spots a route that is up but carries no sound while its app is playing, which almost always
/// means the permission is missing. Pure so it can be tested; fed once per second.
public struct SilenceDetector: Sendable {
    /// How long a playing app may be silent before the route is flagged.
    public var threshold: TimeInterval
    private var silentSince: [String: Date] = [:]
    private var heard: Set<String> = []

    public init(threshold: TimeInterval = 4) { self.threshold = threshold }

    /// - Returns: the app IDs whose route has stayed silent past the threshold.
    public mutating func update(active: [(appID: String, isPlaying: Bool, peak: Float)], now: Date = Date()) -> Set<String> {
        let ids = Set(active.map(\.appID))
        silentSince = silentSince.filter { ids.contains($0.key) }
        heard.formIntersection(ids)

        var flagged: Set<String> = []
        for entry in active {
            if entry.peak > 0 {
                heard.insert(entry.appID)
                silentSince[entry.appID] = nil
            } else if entry.isPlaying, !heard.contains(entry.appID) {
                // Only routes that have never carried sound: a quiet passage in a song isn't a fault.
                let since = silentSince[entry.appID] ?? now
                silentSince[entry.appID] = since
                if now.timeIntervalSince(since) >= threshold { flagged.insert(entry.appID) }
            } else {
                silentSince[entry.appID] = nil
            }
        }
        return flagged
    }
}
