import XCTest
@testable import SplitwaveCore

final class RoutePlannerTests: XCTestCase {
    let spotify = AudioApp(id: "com.spotify.client", name: "Spotify", pid: 100, processObjects: [41],
                           isPlaying: true, isRegularApp: true)
    let chrome = AudioApp(id: "com.google.Chrome", name: "Google Chrome", pid: 200, processObjects: [52, 53],
                          isPlaying: false, isRegularApp: true)

    func route(_ app: AudioApp, _ uids: String...) -> RouteConfig {
        RouteConfig(appID: app.id, appName: app.name,
                    outputs: uids.map { $0 == "default" ? .systemDefault : OutputRef(uid: $0, name: $0) })
    }

    func plan(_ routes: [RouteConfig], apps: [AudioApp]? = nil, available: Set<String>,
              defaultUID: String? = "speakers") -> [String: ChainSpec] {
        RoutePlanner.desiredChains(routes: routes, apps: apps ?? [spotify, chrome],
                                   availableDeviceUIDs: available, defaultDeviceUID: defaultUID)
    }

    func testChainsOnlyForPresentAppsAndDevices() {
        let desired = plan([route(spotify, "airpods"), route(chrome, "speakers"),
                            RouteConfig(appID: "org.videolan.vlc", appName: "VLC", deviceUID: "tv", deviceName: "TV")],
                           available: ["speakers"])
        // Spotify's AirPods are gone → no chain, so it falls back to the default output (F6).
        XCTAssertNil(desired[spotify.id])
        XCTAssertEqual(desired[chrome.id], ChainSpec(appID: chrome.id, deviceUIDs: ["speakers"], processObjects: [52, 53]))
        XCTAssertNil(desired["org.videolan.vlc"])
    }

    func testSystemDefaultFollowsTheCurrentDefault() {
        let routes = [route(chrome, "default")]
        XCTAssertEqual(plan(routes, available: ["speakers", "airpods"])[chrome.id]?.deviceUIDs, ["speakers"])
        let moved = plan(routes, available: ["speakers", "airpods"], defaultUID: "airpods")
        XCTAssertEqual(moved[chrome.id]?.deviceUIDs, ["airpods"])
        // The default changing is a device change, so the chain is rebuilt on the new one.
        let diff = RoutePlanner.diff(current: plan(routes, available: ["speakers", "airpods"]), desired: moved)
        XCTAssertEqual(diff.remove, [chrome.id])
        XCTAssertEqual(diff.build.map(\.deviceUIDs), [["airpods"]])
    }

    func testMultipleOutputsPlayOnWhicheverAreConnected() {
        let routes = [route(spotify, "airpods", "soundcore", "default")]
        XCTAssertEqual(plan(routes, available: ["speakers", "airpods", "soundcore"])[spotify.id]?.deviceUIDs,
                       ["airpods", "soundcore", "speakers"])
        XCTAssertEqual(plan(routes, available: ["speakers", "soundcore"])[spotify.id]?.deviceUIDs,
                       ["soundcore", "speakers"])
        // "default" that resolves to a device already listed isn't added twice.
        XCTAssertEqual(plan(routes, available: ["airpods"], defaultUID: "airpods")[spotify.id]?.deviceUIDs,
                       ["airpods"])
    }

    func testDeviceReconnectRebuildsSavedRoute() {
        let routes = [route(spotify, "airpods")]
        let diff = RoutePlanner.diff(current: plan(routes, available: ["speakers"]),
                                     desired: plan(routes, available: ["speakers", "airpods"]))
        XCTAssertEqual(diff.remove, [])
        XCTAssertEqual(diff.build.map(\.appID), [spotify.id])
    }

    func testChangedHelperProcessesRetapInPlace() {
        let current = ["c": ChainSpec(appID: "c", deviceUIDs: ["speakers"], processObjects: [52])]
        let desired = ["c": ChainSpec(appID: "c", deviceUIDs: ["speakers"], processObjects: [52, 60])]
        XCTAssertEqual(RoutePlanner.diff(current: current, desired: desired), .init(retap: [desired["c"]!]))
    }

    func testChangedDeviceRebuildsTheChain() {
        let current = ["s": ChainSpec(appID: "s", deviceUIDs: ["speakers"], processObjects: [41])]
        let desired = ["s": ChainSpec(appID: "s", deviceUIDs: ["airpods"], processObjects: [41])]
        XCTAssertEqual(RoutePlanner.diff(current: current, desired: desired),
                       .init(remove: ["s"], build: [desired["s"]!]))
    }

    func testStaleChainIsRebuiltEvenWhenUnchanged() {
        // AirPods switched to call mode: same device, new format.
        let chains = ["s": ChainSpec(appID: "s", deviceUIDs: ["airpods"], processObjects: [41])]
        XCTAssertEqual(RoutePlanner.diff(current: chains, desired: chains, stale: ["s"]),
                       .init(remove: ["s"], build: [chains["s"]!]))
    }

    func testUnchangedChainsAreLeftAlone() {
        let chains = ["s": ChainSpec(appID: "s", deviceUIDs: ["airpods"], processObjects: [41])]
        XCTAssertEqual(RoutePlanner.diff(current: chains, desired: chains), .init())
    }

    func testGainCurveMuteAndNoOp() {
        var r = route(spotify, "x")
        r.volume = 0.5
        XCTAssertEqual(r.gain, 0.25, accuracy: 1e-6)
        r.muted = true
        XCTAssertEqual(r.gain, 0)
        XCTAssertTrue(route(spotify, "default").isNoOp)
        var quiet = route(spotify, "default")
        quiet.volume = 0.3
        XCTAssertFalse(quiet.isNoOp)
        XCTAssertFalse(route(spotify, "airpods").isNoOp)
    }
}

final class SetupTests: XCTestCase {
    func testMatchesTheSameRoutesInAnyOrder() {
        let a = RouteConfig(appID: "a", appName: "A", deviceUID: "x", deviceName: "X", volume: 0.3)
        let b = RouteConfig(appID: "b", appName: "B", outputs: [.systemDefault], volume: 0.5)
        let setup = Setup(name: "Desk", routes: [a, b])
        XCTAssertTrue(setup.matches([b, a]))
        var louder = a
        louder.volume = 0.8
        XCTAssertFalse(setup.matches([louder, b]))
        XCTAssertFalse(setup.matches([a]))
    }
}

final class MatcherTests: XCTestCase {
    struct Item { let name: String; let key: String }
    let devices = [Item(name: "MacBook Pro Speakers", key: "BuiltInSpeakerDevice"),
                   Item(name: "Sam’s AirPods Pro", key: "AA-BB-CC:output"),
                   Item(name: "Sam’s TV", key: "airplay-tv")]

    func find(_ q: String) throws -> String {
        try Matcher.match(q, in: devices, kind: "output", name: \.name, key: \.key).name
    }

    func testLooseMatching() throws {
        XCTAssertEqual(try find("airpods"), "Sam’s AirPods Pro")
        XCTAssertEqual(try find("Sam's TV"), "Sam’s TV")  // straight vs curly apostrophe
        XCTAssertEqual(try find("macbook"), "MacBook Pro Speakers")
        XCTAssertEqual(try find("BuiltInSpeakerDevice"), "MacBook Pro Speakers")
    }

    func testAmbiguousAndMissing() {
        XCTAssertThrowsError(try find("sam")) { error in
            guard case MatchError.ambiguous = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try find("  ")) { error in
            guard case MatchError.none = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try find("hdmi")) { error in
            guard case MatchError.none = error else { return XCTFail("\(error)") }
        }
    }

    func testExactNameBeatsSubstring() throws {
        let apps = [Item(name: "Music", key: "com.apple.Music"), Item(name: "Music Recorder", key: "x.rec")]
        XCTAssertEqual(try Matcher.match("music", in: apps, kind: "app", name: \.name, key: \.key).name, "Music")
    }
}

final class RouteStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RouteStore(url: dir.appendingPathComponent("routes.json"))
        XCTAssertEqual(store.load(), [])
        let routes = [RouteConfig(appID: "com.spotify.client", appName: "Spotify", deviceUID: "airpods",
                                  deviceName: "AirPods", volume: 0.3, muted: true)]
        try store.save(routes)
        XCTAssertEqual(store.load(), routes)

        let setups = [Setup(name: "Desk", routes: routes)]
        try store.saveSetups(setups)
        XCTAssertEqual(store.loadSetups(), setups)
    }

    func testReadsRoutesSavedBeforeMultiOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RouteStore(url: dir.appendingPathComponent("routes.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"routes":[{"appID":"com.google.Chrome","appName":"Google Chrome","deviceName":"soundcore","deviceUID":"sc-1","muted":false,"volume":0.24}]}"#
        try Data(old.utf8).write(to: store.url)
        XCTAssertEqual(store.load(), [RouteConfig(appID: "com.google.Chrome", appName: "Google Chrome",
                                                  deviceUID: "sc-1", deviceName: "soundcore", volume: 0.24)])
    }
}
