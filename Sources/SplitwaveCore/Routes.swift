import CoreAudio
import Foundation

/// One output a route plays to, remembered by UID with the name it had (for when it's unplugged).
public struct OutputRef: Codable, Equatable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    /// Whatever the system output is at the moment; a route to it gives an app its own volume
    /// without moving it anywhere (and follows the default when it changes).
    public static let systemDefault = OutputRef(uid: "app.splitwave.system-default", name: "System default")

    public var isSystemDefault: Bool { uid == Self.systemDefault.uid }
}

/// A saved route: where an app plays, and how loud (F3–F5, F12).
public struct RouteConfig: Codable, Equatable, Sendable {
    public var appID: String
    public var appName: String
    /// Every output the app plays to at once. The first one sets the clock.
    public var outputs: [OutputRef]
    /// 0...1, as the slider shows it.
    public var volume: Float
    public var muted: Bool

    public init(appID: String, appName: String, outputs: [OutputRef], volume: Float = 1, muted: Bool = false) {
        self.appID = appID
        self.appName = appName
        self.outputs = outputs
        self.volume = volume
        self.muted = muted
    }

    public init(appID: String, appName: String, deviceUID: String, deviceName: String,
                volume: Float = 1, muted: Bool = false) {
        self.init(appID: appID, appName: appName, outputs: [OutputRef(uid: deviceUID, name: deviceName)],
                  volume: volume, muted: muted)
    }

    /// Amplitude for the IOProc. Squared so the slider feels even to the ear.
    public var gain: Float { muted ? 0 : max(0, min(1, volume)) * max(0, min(1, volume)) }

    /// "AirPods + soundcore Select"
    public var outputsLabel: String { outputs.map(\.name).joined(separator: " + ") }

    /// "AirPods +1": fits a menu button, where a long joined label would hide the "+".
    public var shortOutputsLabel: String {
        guard let first = outputs.first else { return OutputRef.systemDefault.name }
        guard outputs.count > 1 else { return first.name }
        // Menu buttons cut titles from the end, which would take the "+1" with it.
        let name = first.name.count > 14 ? first.name.prefix(13).trimmingCharacters(in: .whitespaces) + "…" : first.name
        return "\(name) +\(outputs.count - 1)"
    }

    /// A route that only follows the default at full volume does nothing; it can be dropped.
    public var isNoOp: Bool { outputs == [.systemDefault] && volume >= 1 && !muted }

    private enum CodingKeys: String, CodingKey { case appID, appName, outputs, volume, muted, deviceUID, deviceName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(String.self, forKey: .appID)
        appName = try c.decode(String.self, forKey: .appName)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        if let outputs = try c.decodeIfPresent([OutputRef].self, forKey: .outputs) {
            self.outputs = outputs
        } else {
            // Routes saved before multi-output: one device.
            outputs = [OutputRef(uid: try c.decode(String.self, forKey: .deviceUID),
                                 name: try c.decode(String.self, forKey: .deviceName))]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appID, forKey: .appID)
        try c.encode(appName, forKey: .appName)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(volume, forKey: .volume)
        try c.encode(muted, forKey: .muted)
    }
}

/// A named set of routes to switch to in one go ("Desk", "Couch").
public struct Setup: Codable, Equatable, Sendable {
    public var name: String
    public var routes: [RouteConfig]

    public init(name: String, routes: [RouteConfig]) {
        self.name = name
        self.routes = routes.sorted { $0.appID < $1.appID }
    }

    /// True when `routes` is exactly this setup (same outputs, volume and mute for the same apps).
    public func matches(_ routes: [RouteConfig]) -> Bool {
        let mine = Dictionary(self.routes.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(routes.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        guard mine.count == theirs.count else { return false }
        return mine.allSatisfy { id, r in
            guard let o = theirs[id] else { return false }
            return o.outputs == r.outputs && o.muted == r.muted && abs(o.volume - r.volume) < 0.005
        }
    }
}

/// JSON files in Application Support, shared by the menu-bar app and the CLI.
public struct RouteStore: Sendable {
    public let url: URL

    /// Posted (distributed) when one process changes a file so others reload it.
    public static let changedNotification = Notification.Name("app.splitwave.routes-changed")

    public init(url: URL) { self.url = url }

    public static var standard: RouteStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RouteStore(url: base.appendingPathComponent("Splitwave/routes.json"))
    }

    /// Setups live next to the routes.
    public var setupsURL: URL { url.deletingLastPathComponent().appendingPathComponent("setups.json") }

    private struct File: Codable { var routes: [RouteConfig] }
    private struct SetupsFile: Codable { var setups: [Setup] }

    public func load() -> [RouteConfig] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.routes
    }

    public func save(_ routes: [RouteConfig]) throws {
        try write(File(routes: routes.sorted { $0.appID < $1.appID }), to: url)
    }

    public func loadSetups() -> [Setup] {
        guard let data = try? Data(contentsOf: setupsURL),
              let file = try? JSONDecoder().decode(SetupsFile.self, from: data) else { return [] }
        return file.setups
    }

    public func saveSetups(_ setups: [Setup]) throws {
        try write(SetupsFile(setups: setups.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }),
                  to: setupsURL)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    public static func postChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// What a chain is built from; when any part changes the chain is rebuilt.
public struct ChainSpec: Equatable, Sendable {
    public var appID: String
    /// Real device UIDs, in route order, already resolved from "system default" and filtered to
    /// the ones connected. The first is the clock.
    public var deviceUIDs: [String]
    public var processObjects: [AudioObjectID]
}

/// Pure decisions about which chains should exist. Kept apart from Core Audio so it can be tested.
public enum RoutePlanner {
    /// A route gets a chain while its app has audio processes and at least one of its outputs is
    /// connected; it plays on the connected ones. With none connected there's no chain, so the
    /// app falls back to the system default (F6).
    public static func desiredChains(routes: [RouteConfig], apps: [AudioApp],
                                     availableDeviceUIDs: Set<String>,
                                     defaultDeviceUID: String?) -> [String: ChainSpec] {
        var result: [String: ChainSpec] = [:]
        for route in routes {
            guard let app = apps.first(where: { $0.id == route.appID }), !app.processObjects.isEmpty else { continue }
            var uids: [String] = []
            for output in route.outputs {
                let uid = output.isSystemDefault ? defaultDeviceUID : output.uid
                if let uid, availableDeviceUIDs.contains(uid), !uids.contains(uid) { uids.append(uid) }
            }
            guard !uids.isEmpty else { continue }
            result[route.appID] = ChainSpec(appID: route.appID, deviceUIDs: uids, processObjects: app.processObjects)
        }
        return result
    }

    public struct Diff: Equatable {
        public var remove: [String]
        public var build: [ChainSpec]
        /// Chains whose devices are unchanged but whose app gained or lost helper processes:
        /// their tap is updated in place, so the audio doesn't drop out.
        public var retap: [ChainSpec]

        public init(remove: [String] = [], build: [ChainSpec] = [], retap: [ChainSpec] = []) {
            self.remove = remove
            self.build = build
            self.retap = retap
        }
    }

    /// Chains to tear down, (re)build, or retap. A chain whose devices changed, or that is
    /// `stale` (its device switched format), is removed and rebuilt.
    public static func diff(current: [String: ChainSpec], desired: [String: ChainSpec],
                            stale: Set<String> = []) -> Diff {
        var result = Diff()
        for (id, spec) in current {
            guard let want = desired[id] else { result.remove.append(id); continue }
            if want == spec && !stale.contains(id) { continue }
            if want.deviceUIDs == spec.deviceUIDs && !stale.contains(id) {
                result.retap.append(want)
            } else {
                result.remove.append(id)
                result.build.append(want)
            }
        }
        for (id, spec) in desired where current[id] == nil {
            result.build.append(spec)
        }
        result.remove.sort()
        result.build.sort { $0.appID < $1.appID }
        result.retap.sort { $0.appID < $1.appID }
        return result
    }
}
