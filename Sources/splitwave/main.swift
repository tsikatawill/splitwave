import AppKit
import Foundation
import SplitwaveCore

let usage = """
usage: splitwave <command>

  list [--all]                           Apps producing audio and the outputs they can go to
  route <app> <device>... [--volume N]   Send an app to one or more outputs (N = 0-100);
                                         `default` follows the system output
        [--save]                         ...and remember it (always the case when the app is running)
        [--meter]                        ...and print the routed app's level every second
  volume <app> <N>                       Set an app's volume, routed or not
  mute <app> | unmute <app>
  unroute <app> | --all                  Forget a saved route
  routes                                 Show saved routes
  setup list | save <name> | apply <name> | delete <name>
                                         Saved sets of routes ("Desk", "Couch")
  run                                    Apply saved routes until Ctrl-C (headless engine)
  doctor                                 Check permission, the app and every saved route

Without the Splitwave menu-bar app running, `route` holds the route until Ctrl-C; the other
commands change the saved routes, which the app (or `run`) applies.
Names match loosely: `splitwave route spotify airpods soundcore`.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func stamp(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(message)")
}

// MARK: Commands

func list(all: Bool) {
    let apps = AppCatalog.apps().filter { all || $0.isRegularApp || $0.isPlaying }
    let routes = RouteStore.standard.load()
    print("Apps with audio\(all ? "" : " (--all for background processes)")")
    if apps.isEmpty { print("  (none)") }
    for app in apps {
        let mark = app.isPlaying ? "▶" : " "
        let helpers = app.processObjects.count > 1 ? "  (\(app.processObjects.count) processes)" : ""
        let route = routes.first { $0.appID == app.id }.map { "  → \($0.outputsLabel)" } ?? ""
        print("  \(mark) \(pad(app.name, 24)) \(pad(app.id, 32))\(helpers)\(route)")
    }
    print("\nOutputs")
    for device in DeviceCatalog.outputDevices() {
        let mark = device.isDefault ? "*" : " "
        var extra = "\(device.channels)ch"
        if !device.isAlive { extra += ", unavailable" }
        if !device.dataSources.isEmpty { extra += ", receivers: " + device.dataSources.joined(separator: ", ") }
        print("  \(mark) \(pad(device.name, 30)) \(pad(device.transport.rawValue, 12)) \(extra)")
    }
    print("\n▶ playing   * system default")
}

/// Apps the user might mean: ones with audio processes first, then any other running app.
func resolveApp(_ query: String) -> (id: String, name: String) {
    var candidates = AppCatalog.apps().map { (id: $0.id, name: $0.name) }
    let known = Set(candidates.map(\.id))
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let id = app.bundleIdentifier, !known.contains(id) else { continue }
        candidates.append((id: id, name: app.localizedName ?? id))
    }
    do {
        return try Matcher.match(query, in: candidates, kind: "app", name: \.name, key: \.id)
    } catch MatchError.none(_, _, _) where query.contains(".") {
        return (id: query, name: query)  // a bundle ID for an app that isn't running yet
    } catch {
        fail("\(error)")
    }
}

func resolveOutput(_ query: String) -> OutputRef {
    if ["default", "system", "system default"].contains(query.lowercased()) { return .systemDefault }
    let devices = DeviceCatalog.outputDevices()
    do {
        let device = try Matcher.match(query, in: devices, kind: "output", name: \.name, key: \.uid)
        return OutputRef(uid: device.uid, name: device.name)
    } catch {
        fail("\(error)")
    }
}

/// Changes the saved routes or setups (with a manager that never starts audio), then tells a
/// running app to reload them.
func editSaved(_ change: (RouteManager) -> Void) {
    let offline = RouteManager(store: .standard)
    change(offline)
    offline.stop()  // flushes any pending save
    RouteStore.postChanged()
}

func parseVolume(_ text: String) -> Float {
    guard let n = Float(text.replacingOccurrences(of: "%", with: "")), (0...100).contains(n) else {
        fail("Volume is a number from 0 to 100")
    }
    return n / 100
}

func runEngine(_ manager: RouteManager, watchStore: Bool,
               waitingFor app: (id: String, name: String)? = nil, meter: Bool = false) -> Never {
    manager.log = { message in
        stamp(message)
        FileLog.shared.write(message, source: "cli")
    }
    manager.start(watchStore: watchStore)
    var warned: Set<String> = []
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        for id in manager.silentRoutes.subtracting(warned) where manager.permission != .authorized {
            stamp("No sound from \(manager.routes[id]?.appName ?? id). macOS may be blocking audio capture: "
                  + "check System Settings › Privacy & Security › Screen & System Audio Recording, "
                  + "or run `splitwave doctor`.")
        }
        warned = manager.silentRoutes
    }
    if let app, !manager.isActive(app.id), manager.errors[app.id] == nil {
        stamp("Waiting for \(app.name) to open audio…")
    }
    if meter, let app {
        // Sampled several times a second so a quiet passage between callbacks doesn't read as silence.
        var loudest: Float = 0, samples = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            loudest = max(loudest, manager.peak(for: app.id))
            samples += 1
            guard samples == 10 else { return }
            let db = loudest > 0 ? String(format: "%.0f dBFS", 20 * log10(loudest)) : "silent"
            stamp("\(app.name): \(manager.isActive(app.id) ? db : "not routed")")
            loudest = 0
            samples = 0
        }
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            manager.stop()
            print("\nStopped; apps are back on their normal outputs.")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    RunLoop.main.run()  // services the main queue and the meter timer
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
var meterTimer: Timer?
var silenceTimer: Timer?

func route(_ args: [String]) {
    var positional: [String] = []
    var volume: Float?
    var save = false
    var meter = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--volume":
            guard i + 1 < args.count else { fail("--volume takes a number from 0 to 100") }
            volume = parseVolume(args[i + 1])
            i += 1
        case "--save":
            save = true
        case "--meter":
            meter = true
        default:
            positional.append(args[i])
        }
        i += 1
    }
    guard positional.count >= 2 else { fail(usage) }
    let app = resolveApp(positional[0])
    let outputs = positional.dropFirst().map(resolveOutput)
    let label = outputs.map(\.name).joined(separator: " + ")

    if Splitwave.isAppRunning {
        editSaved { $0.route(appID: app.id, appName: app.name, to: Array(outputs), volume: volume) }
        print("Routed \(app.name) → \(label) (via the Splitwave app)")
        exit(0)
    }

    Disclaim.respawnIfNeeded()
    let manager = RouteManager(store: save ? .standard : nil)
    manager.route(appID: app.id, appName: app.name, to: Array(outputs), volume: volume)
    print("Routing \(app.name) → \(label). Ctrl-C to stop.")
    runEngine(manager, watchStore: save, waitingFor: app, meter: meter)
}

func unroute(_ args: [String]) {
    guard args.count == 1 else { fail(usage) }
    if args[0] == "--all" {
        editSaved { $0.unrouteAll() }
        print("Removed all routes.")
        return
    }
    let routes = RouteStore.standard.load()
    let target = (try? Matcher.match(args[0], in: routes, kind: "saved route", name: \.appName, key: \.appID))
        ?? { fail("No saved route for \"\(args[0])\". See `splitwave routes`.") }()
    editSaved { $0.unroute(appID: target.appID) }
    print("Removed the route for \(target.appName).")
}

func volume(_ args: [String]) {
    guard args.count == 2 else { fail(usage) }
    let app = resolveApp(args[0])
    let level = parseVolume(args[1])
    editSaved { $0.setVolume(level, for: app.id, appName: app.name) }
    print("\(app.name): \(Int((level * 100).rounded()))%")
}

func mute(_ args: [String], muted: Bool) {
    guard args.count == 1 else { fail(usage) }
    let app = resolveApp(args[0])
    editSaved { $0.setMuted(muted, for: app.id, appName: app.name) }
    print("\(app.name): \(muted ? "muted" : "unmuted")")
}

func setup(_ args: [String]) {
    let store = RouteStore.standard
    switch (args.first, args.count) {
    case ("list", 1), (nil, 0):
        let setups = store.loadSetups()
        let current = store.load()
        if setups.isEmpty { print("No setups. Save one with `splitwave setup save Desk`.") }
        for s in setups {
            let mark = s.matches(current) ? "*" : " "
            print("  \(mark) \(pad(s.name, 20)) \(s.routes.map { "\($0.appName) → \($0.outputsLabel)" }.joined(separator: ", "))")
        }
    case ("save", 2...):
        let name = args.dropFirst().joined(separator: " ")
        editSaved { $0.saveSetup(named: name) }
        print("Saved the current routes as \(name).")
    case ("apply", 2...):
        let name = args.dropFirst().joined(separator: " ")
        var found = false
        editSaved { found = $0.applySetup(named: name) }
        guard found else { fail("No setup named \"\(name)\". See `splitwave setup list`.") }
        print("Applied \(name).")
    case ("delete", 2...):
        let name = args.dropFirst().joined(separator: " ")
        editSaved { $0.deleteSetup(named: name) }
        print("Deleted \(name).")
    default:
        fail(usage)
    }
}

func showRoutes() {
    let routes = RouteStore.standard.load()
    if routes.isEmpty { print("No saved routes."); return }
    for r in routes {
        let level = r.muted ? "muted" : "\(Int((r.volume * 100).rounded()))%"
        print("  \(pad(r.appName, 24)) → \(pad(r.outputsLabel, 30)) \(level)")
    }
}

func doctor() {
    func row(_ label: String, _ value: String, ok: Bool?) {
        let mark = ok.map { $0 ? "✓" : "✗" } ?? "?"
        print("  \(mark) \(pad(label, 30)) \(value)")
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let osOK = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 2, patchVersion: 0))
    print("Splitwave doctor")
    row("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (needs 14.2+)", ok: osOK)

    let permission = AudioCapturePermission.status
    let permissionText: String
    switch permission {
    case .authorized: permissionText = "allowed"
    case .denied: permissionText = "off: turn on Splitwave in System Settings › Privacy & Security › Screen & System Audio Recording"
    case .unknown: permissionText = "not asked yet (macOS asks on the first route)"
    }
    row("System audio recording", permissionText, ok: permission == .unknown ? nil : permission == .authorized)
    row("Menu-bar app", Splitwave.isAppRunning ? "running" : "not running", ok: Splitwave.isAppRunning ? true : nil)

    let routes = RouteStore.standard.load()
    let apps = AppCatalog.apps()
    let devices = DeviceCatalog.outputDevices()
    print("\nSaved routes (\(routes.count))")
    if routes.isEmpty { print("  (none)") }
    for r in routes {
        let app = apps.first { $0.id == r.appID }
        let missing = r.outputs.filter { o in !o.isSystemDefault && !devices.contains { $0.uid == o.uid && $0.isAlive } }
        let state: String
        if app == nil {
            state = "\(r.appName) isn't running; applies when it opens"
        } else if missing.count == r.outputs.count {
            state = "not connected; \(r.appName) is on the system default"
        } else if !missing.isEmpty {
            state = "playing without \(missing.map(\.name).joined(separator: ", ")) (not connected)"
        } else {
            state = app!.isPlaying ? "active, playing" : "active, idle"
        }
        row("\(r.appName) → \(r.outputsLabel)", state, ok: app != nil && missing.isEmpty ? true : nil)
    }
    print("\nLog: \(FileLog.shared.url.path)")
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: Entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "list": list(all: args.contains("--all"))
case "route": route(Array(args.dropFirst()))
case "unroute": unroute(Array(args.dropFirst()))
case "volume": volume(Array(args.dropFirst()))
case "mute": mute(Array(args.dropFirst()), muted: true)
case "unmute": mute(Array(args.dropFirst()), muted: false)
case "setup", "setups": setup(Array(args.dropFirst()))
case "routes": showRoutes()
case "doctor":
    Disclaim.respawnIfNeeded()  // so the permission shown is the one routing would get
    doctor()
case "run":
    if Splitwave.isAppRunning { fail("The Splitwave app is running and already applies saved routes.") }
    Disclaim.respawnIfNeeded()
    runEngine(RouteManager(store: .standard), watchStore: true)
case nil, "help", "-h", "--help": print(usage)
default: fail(usage)
}
