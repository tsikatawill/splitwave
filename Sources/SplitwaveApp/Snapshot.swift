import AppKit
import SplitwaveCore
import SwiftUI

/// `SplitwaveApp --snapshot <dir>` renders the popover and the first-run window to PNGs and quits.
/// For checking layout without clicking through the menu bar.
enum Snapshot {
    static func runIfRequested(manager: RouteManager) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        if args.contains("--demo") {
            renderDemo(to: dir)
            return true
        }
        manager.refresh()
        render(PopoverView(manager: manager), to: dir.appendingPathComponent("popover.png"))

        // The same popover with one app routed, to see the slider, mute and meter.
        let routed = RouteManager(store: nil)
        routed.refresh()
        if let app = routed.apps.first(where: \.isRegularApp),
           let device = routed.devices.first(where: \.isDefault) {
            routed.route(appID: app.id, appName: app.name, to: device, volume: 0.6)
            // A second app on two outputs, and a third with only a volume change.
            let others = routed.apps.filter { $0.isRegularApp && $0.id != app.id }
            if let second = others.first, let extra = routed.devices.first(where: { !$0.isDefault && $0.isAlive }) {
                routed.route(appID: second.id, appName: second.name,
                             to: [OutputRef(uid: device.uid, name: device.name), OutputRef(uid: extra.uid, name: extra.name)])
            }
            if others.count > 1 { routed.setVolume(0.3, for: others[1].id, appName: others[1].name) }
        }
        render(PopoverView(manager: routed), to: dir.appendingPathComponent("popover-routed.png"))
        routed.stop()

        // The slider with a fixed -12 dB signal at 60% volume, to check the level fill draws.
        let gain = RouteConfig(appID: "", appName: "", deviceUID: "", deviceName: "", volume: 0.6).gain
        render(VolumeSlider(volume: .constant(0.6), peak: { 0.25 * gain }, gain: gain)
            .frame(width: 280).padding(12), to: dir.appendingPathComponent("slider-level.png"))
        render(OnboardingView(manager: manager) {}, to: dir.appendingPathComponent("onboarding.png"))
        return true
    }

    /// The website screenshot: made-up apps and devices, in light and dark.
    private static func renderDemo(to dir: URL) {
        func app(_ id: String, _ name: String, _ playing: Bool) -> AudioApp {
            AudioApp(id: id, name: name, pid: 0, processObjects: [1], isPlaying: playing, isRegularApp: true)
        }
        func device(_ uid: String, _ name: String, _ transport: Transport, isDefault: Bool = false) -> OutputDevice {
            OutputDevice(objectID: 0, uid: uid, name: name, transport: transport, isAlive: true, isDefault: isDefault, channels: 2)
        }
        let speakers = OutputRef(uid: "speakers", name: "MacBook Pro Speakers")
        let airpods = OutputRef(uid: "airpods", name: "AirPods Pro")
        let tv = OutputRef(uid: "tv", name: "Living Room TV")
        let speaker = OutputRef(uid: "bt", name: "Bluetooth Speaker")
        _ = speakers
        let routes = [
            RouteConfig(appID: "com.apple.Music", appName: "Music", outputs: [airpods], volume: 0.8),
            RouteConfig(appID: "org.videolan.vlc", appName: "VLC", outputs: [tv, speaker]),
            RouteConfig(appID: "com.google.Chrome", appName: "Google Chrome", outputs: [.systemDefault], volume: 0.3),
        ]
        let manager = RouteManager.preview(
            apps: [app("com.apple.Music", "Music", true), app("org.videolan.vlc", "VLC", true),
                   app("com.google.Chrome", "Google Chrome", true), app("us.zoom.xos", "zoom.us", false)],
            devices: [device("speakers", "MacBook Pro Speakers", .builtIn, isDefault: true),
                      device("airpods", "AirPods Pro", .bluetooth), device("tv", "Living Room TV", .airPlay),
                      device("bt", "Bluetooth Speaker", .bluetooth)],
            routes: routes,
            setups: [Setup(name: "Movie night", routes: routes)],
            peaks: ["com.apple.Music": 0.32, "org.videolan.vlc": 0.5, "com.google.Chrome": 0.04])
        for (name, appearance) in [("popover-light.png", NSAppearance.Name.aqua), ("popover-dark.png", .darkAqua)] {
            render(PopoverView(manager: manager), to: dir.appendingPathComponent(name), appearance: appearance)
        }
    }

    private static func render(_ view: some View, to url: URL, appearance: NSAppearance.Name = .aqua) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.orderFrontRegardless()
        // Let SwiftUI lay out and draw its text and AppKit controls before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
