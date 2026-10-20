import AppKit
import SplitwaveCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let manager = RouteManager(store: .standard)
    private var onboardingWindow: NSWindow?
    private static let onboardedKey = "didOnboard"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.runIfRequested(manager: manager) { exit(0) }
        manager.log = { message in
            NSLog("Splitwave: %@", message)
            FileLog.shared.write(message, source: "app")
        }
        FileLog.shared.write("Splitwave started; permission: \(manager.permission)", source: "app")
        // Started here, not when the popover opens, so saved routes apply at login (F5).
        manager.start(watchStore: true)
        if !UserDefaults.standard.bool(forKey: Self.onboardedKey) { showOnboarding() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI hands URLs to its scenes, not to application(_:open:); take the Apple Event ourselves.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        open(url)
    }

    /// splitwave://setup/<name> applies a setup; splitwave://reset puts every app back.
    /// For Shortcuts ("Open URL"), Raycast or any hotkey tool.
    private func open(_ url: URL) {
        guard url.scheme == "splitwave" else { return }
        switch url.host() {
        case "setup":
            let name = url.path().dropFirst().removingPercentEncoding ?? ""
            if !manager.applySetup(named: name) { manager.log("No setup named \(name) (from \(url))") }
        case "reset":
            manager.unrouteAll()
            manager.log("Reset every app (from \(url))")
        default:
            manager.log("Unknown link \(url)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stop()
        FileLog.shared.write("Splitwave quit", source: "app")
    }

    private func showOnboarding() {
        let view = OnboardingView(manager: manager) { [weak self] in self?.onboardingWindow?.close() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Splitwave"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        // A menu-bar app isn't active at launch; bring the window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Skipped or done, it doesn't come back; the popover keeps nagging until permission is granted.
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        onboardingWindow = nil
    }
}

@main
struct SplitwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(manager: delegate.manager)
        } label: {
            MenuBarIcon(manager: delegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var manager: RouteManager

    var body: some View {
        if manager.permission == .denied || !manager.silentRoutes.isEmpty {
            Image(systemName: "waveform.badge.exclamationmark")
        } else {
            Image(systemName: manager.apps.contains { manager.isActive($0.id) } ? "waveform.circle.fill" : "waveform")
        }
    }
}
