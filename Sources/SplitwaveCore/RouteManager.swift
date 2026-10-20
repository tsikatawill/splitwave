import Combine
import CoreAudio
import Foundation

/// Owns every route and its chain. The UI and the CLI only talk to this.
///
/// Main-thread only. Listens for Core Audio device and process changes and rebuilds the
/// chains those changes affect (F5, F6).
public final class RouteManager: ObservableObject {
    @Published public private(set) var apps: [AudioApp] = []
    @Published public private(set) var devices: [OutputDevice] = []
    @Published public private(set) var routes: [String: RouteConfig] = [:]
    /// Last chain-build error per app, cleared when the chain comes up.
    @Published public private(set) var errors: [String: String] = [:]
    /// Routes that are up while their app plays, yet carry no sound (usually: no permission).
    @Published public private(set) var silentRoutes: Set<String> = []
    @Published public private(set) var permission: AudioCapturePermission.Status = AudioCapturePermission.status
    /// Saved route sets, by name (F: setups).
    @Published public private(set) var setups: [Setup] = []

    /// Called with one-line status messages (chain built, torn down, failed).
    public var log: (String) -> Void = { _ in }

    private let store: RouteStore?
    private var chains: [String: RouteChain] = [:]
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var storeObserver: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var failures: [String: Int] = [:]
    private var silence = SilenceDetector()
    private var pollTimer: Timer?
    /// Chains whose output changed format; rebuilt on the next reconcile.
    private var stale: Set<String> = []

    /// With a store, routes load from and save to disk; without one they live only as long as this object.
    public init(store: RouteStore?) {
        self.store = store
        if let store {
            routes = Self.index(store.load())
            setups = store.loadSetups()
        }
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// - Parameters:
    ///   - watchStore: reload when another process (the CLI) changes the saved routes.
    ///   - pollInterval: how often to re-read which apps are playing and check routes for silence.
    public func start(watchStore: Bool = false, pollInterval: TimeInterval? = 1) {
        let selectors = [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyProcessObjectList]
        for selector in selectors {
            var addr = AudioObject.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh(after: 0.15) }
            if AudioObjectAddPropertyListenerBlock(AudioObject.system, &addr, .main, block) == noErr {
                listeners.append((addr, block))
            }
        }
        if watchStore, store != nil {
            storeObserver = DistributedNotificationCenter.default().addObserver(
                forName: RouteStore.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reloadStore() }
        }
        if let pollInterval {
            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    /// Unroutes everything and stops listening; apps go back to normal system behaviour.
    public func stop() {
        for (addr, block) in listeners {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(AudioObject.system, &addr, .main, block)
        }
        listeners.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        if let storeObserver { DistributedNotificationCenter.default().removeObserver(storeObserver) }
        storeObserver = nil
        pendingRefresh?.cancel()
        flushSave()
        tearDown(Array(chains.keys), stopping: true)
    }

    /// Re-reads apps and devices and brings chains in line with the routes.
    public func refresh() {
        pendingRefresh = nil
        guard !isPreview else { return }  // previews keep their made-up state
        // Assigned only on change: this runs every second and each assignment redraws the UI.
        let newDevices = DeviceCatalog.outputDevices()
        if newDevices != devices { devices = newDevices }
        let newApps = AppCatalog.apps()
        if newApps != apps { apps = newApps }
        reconcile()
        checkHealth()
    }

    // MARK: Routes

    /// Sends the app to exactly these outputs (one, several, or `.systemDefault`).
    public func route(appID: String, appName: String, to outputs: [OutputRef], volume: Float? = nil) {
        guard !outputs.isEmpty else { return unroute(appID: appID) }
        var config = routes[appID] ?? RouteConfig(appID: appID, appName: appName, outputs: outputs)
        config.appName = appName
        config.outputs = outputs
        if let volume { config.volume = max(0, min(1, volume)) }
        store(config)
    }

    public func route(appID: String, appName: String, to device: OutputDevice, volume: Float? = nil) {
        route(appID: appID, appName: appName, to: [OutputRef(uid: device.uid, name: device.name)], volume: volume)
    }

    /// Adds or removes one extra output, keeping the others (F12).
    public func toggleOutput(_ output: OutputRef, appID: String, appName: String) {
        var outputs = routes[appID]?.outputs ?? [.systemDefault]
        if let i = outputs.firstIndex(of: output) {
            outputs.remove(at: i)
        } else {
            outputs.append(output)
        }
        if outputs.isEmpty { outputs = [.systemDefault] }
        route(appID: appID, appName: appName, to: outputs)
    }

    public func unroute(appID: String) {
        routes[appID] = nil
        errors[appID] = nil
        save()
        reconcile()
    }

    public func unrouteAll() {
        routes.removeAll()
        errors.removeAll()
        save()
        reconcile()
    }

    /// Works for any app: an app without a route gets one that follows the system default, so
    /// every app has its own volume. Back at 100% and unmuted, that route is dropped again.
    public func setVolume(_ volume: Float, for appID: String, appName: String) {
        var config = routes[appID] ?? RouteConfig(appID: appID, appName: appName, outputs: [.systemDefault])
        config.volume = max(0, min(1, volume))
        if let chain = chains[appID] {
            routes[appID] = config
            chain.gain = config.gain
            save(debounced: true)
            if config.isNoOp { pendingNoOpCheck(appID) }
        } else {
            store(config)
        }
    }

    public func setMuted(_ muted: Bool, for appID: String, appName: String) {
        var config = routes[appID] ?? RouteConfig(appID: appID, appName: appName, outputs: [.systemDefault])
        config.muted = muted
        store(config)
    }

    /// Volume and mute as the row should show them, routed or not.
    public func level(for appID: String) -> (volume: Float, muted: Bool) {
        routes[appID].map { ($0.volume, $0.muted) } ?? (1, false)
    }

    /// True while the app's audio is actually going through Splitwave.
    public func isActive(_ appID: String) -> Bool { chains[appID] != nil || previewPeaks[appID] != nil }

    /// The outputs the app is playing on right now (connected ones; "system default" resolved).
    public func playingDeviceUIDs(for appID: String) -> [String] { chains[appID]?.deviceUIDs ?? [] }

    public func peak(for appID: String) -> Float { chains[appID]?.peak ?? previewPeaks[appID] ?? 0 }

    // MARK: Previews

    private var previewPeaks: [String: Float] = [:]
    private var isPreview = false

    /// A manager with made-up apps, devices and routes, for screenshots. It never touches audio:
    /// don't call `start()` or `refresh()` on it.
    public static func preview(apps: [AudioApp], devices: [OutputDevice], routes: [RouteConfig],
                               setups: [Setup] = [], peaks: [String: Float] = [:]) -> RouteManager {
        let manager = RouteManager(store: nil)
        manager.apps = apps
        manager.devices = devices
        manager.routes = index(routes)
        manager.setups = setups
        manager.previewPeaks = peaks
        manager.permission = .authorized
        manager.isPreview = true
        return manager
    }

    // MARK: Setups

    /// The setup the current routes are exactly, if any.
    public var activeSetup: String? { setups.first { $0.matches(Array(routes.values)) }?.name }

    /// Saves the current routes under `name`, replacing a setup with the same name.
    public func saveSetup(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        setups.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        setups.append(Setup(name: name, routes: Array(routes.values)))
        saveSetups()
        log("Saved setup \(name) (\(routes.count) route(s))")
    }

    /// Replaces every route with the setup's.
    @discardableResult
    public func applySetup(named name: String) -> Bool {
        guard let setup = setups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        routes = Self.index(setup.routes)
        errors.removeAll()
        failures.removeAll()
        save()
        reconcile()
        log("Applied setup \(setup.name)")
        return true
    }

    public func deleteSetup(named name: String) {
        setups.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        saveSetups()
    }

    // MARK: Internals

    private func store(_ config: RouteConfig) {
        if config.isNoOp {
            routes[config.appID] = nil
        } else {
            routes[config.appID] = config
        }
        failures[config.appID] = nil
        save()
        reconcile()
    }

    /// Dropping a no-op route mid-drag would rebuild audio under the slider; wait for the drag to settle.
    private func pendingNoOpCheck(_ appID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let config = self.routes[appID], config.isNoOp else { return }
            self.store(config)
        }
    }

    private var defaultDeviceUID: String? { devices.first(where: \.isDefault)?.uid }

    private func reconcile() {
        let available = Set(devices.filter(\.isAlive).map(\.uid))
        let desired = RoutePlanner.desiredChains(routes: Array(routes.values), apps: apps,
                                                 availableDeviceUIDs: available, defaultDeviceUID: defaultDeviceUID)
        let current = chains.mapValues {
            ChainSpec(appID: $0.appID, deviceUIDs: $0.deviceUIDs, processObjects: $0.processObjects)
        }
        let diff = RoutePlanner.diff(current: current, desired: desired, stale: stale)
        stale.removeAll()
        tearDown(diff.remove)

        var rebuild = diff.build
        for spec in diff.retap {
            guard let chain = chains[spec.appID] else { continue }
            do {
                try chain.updateProcesses(spec.processObjects)
                log("Updated \(routes[spec.appID]?.appName ?? spec.appID) to \(spec.processObjects.count) audio process(es)")
            } catch {
                log("\(error); rebuilding instead")
                tearDown([spec.appID])
                rebuild.append(spec)
            }
        }

        var retry = false
        for spec in rebuild {
            guard let config = routes[spec.appID] else { continue }
            do {
                let chain = try RouteChain(appID: spec.appID, processObjects: spec.processObjects,
                                           deviceUIDs: spec.deviceUIDs, gain: config.gain)
                chain.onFormatChange = { [weak self] in
                    guard let self else { return }
                    self.log("An output for \(config.appName) changed format; rebuilding its route")
                    self.stale.insert(spec.appID)
                    self.scheduleRefresh(after: 0.3)
                }
                chains[spec.appID] = chain
                errors[spec.appID] = nil
                failures[spec.appID] = nil
                log("Routed \(config.appName) → \(names(of: spec.deviceUIDs))\(config.muted ? " (muted)" : "")")
            } catch {
                errors[spec.appID] = "\(error)"
                failures[spec.appID, default: 0] += 1
                retry = retry || failures[spec.appID, default: 0] < 5
                log("Could not route \(config.appName): \(error)")
            }
        }
        for (id, chain) in chains { chain.gain = routes[id]?.gain ?? 0 }
        if retry { scheduleRefresh(after: 1.0) }
    }

    private func checkHealth() {
        let status = AudioCapturePermission.status
        if status != permission {
            log("System audio recording permission: \(status)")
            permission = status
        }
        let playing = Set(apps.filter(\.isPlaying).map(\.id))
        let flagged = silence.update(active: chains.map { (appID: $0.key, isPlaying: playing.contains($0.key), peak: $0.value.peak) })
        for id in flagged.subtracting(silentRoutes) {
            log("No sound is reaching Splitwave from \(routes[id]?.appName ?? id) (permission: \(status))")
        }
        if flagged != silentRoutes { silentRoutes = flagged }
    }

    /// Fades the chains out together (one ~35 ms wait), then destroys them.
    private func tearDown(_ ids: [String], stopping: Bool = false) {
        let leaving = ids.compactMap { id in chains.removeValue(forKey: id).map { (id, $0) } }
        guard !leaving.isEmpty else { return }
        for (_, chain) in leaving { chain.gain = 0 }
        Thread.sleep(forTimeInterval: 0.035)
        for (id, _) in leaving {
            let name = routes[id]?.appName ?? apps.first { $0.id == id }?.name ?? id
            if stopping || routes[id] == nil {
                log("Unrouted \(name)")
            } else if let route = routes[id], !route.outputs.contains(where: { o in
                o.isSystemDefault || devices.contains { $0.uid == o.uid && $0.isAlive }
            }) {
                log("\(route.outputsLabel) gone; \(name) is back on the system default")
            } else if !apps.contains(where: { $0.id == id }) {
                log("\(name) closed; its route applies again when it reopens")
            } else {
                log("Rebuilding the route for \(name)")
            }
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func names(of uids: [String]) -> String {
        uids.map { uid in devices.first { $0.uid == uid }?.name ?? uid }.joined(separator: " + ")
    }

    private func saveSetups() {
        guard let store else { return }
        do { try store.saveSetups(setups) } catch { log("Could not save setups: \(error)") }
    }

    private func reloadStore() {
        guard let store else { return }
        routes = Self.index(store.load())
        setups = store.loadSetups()
        failures.removeAll()
        refresh()
    }

    private func save(debounced: Bool = false) {
        guard store != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSave = work
        if debounced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            work.perform()
        }
    }

    private func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store else { return }
        do { try store.save(Array(routes.values)) } catch { log("Could not save routes: \(error)") }
    }

    private static func index(_ list: [RouteConfig]) -> [String: RouteConfig] {
        Dictionary(list.map { ($0.appID, $0) }, uniquingKeysWith: { _, last in last })
    }
}
