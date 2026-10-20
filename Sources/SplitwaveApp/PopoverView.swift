import AppKit
import ServiceManagement
import SplitwaveCore
import SwiftUI

/// The menu-bar popover: one row per app with its outputs and volume (F7, F8), plus setups.
struct PopoverView: View {
    @ObservedObject var manager: RouteManager
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if manager.permission != .authorized {
                PermissionCard(manager: manager)
                    .padding(14)
                    .background(.quaternary.opacity(0.5))
                Divider()
            }
            if rows.isEmpty {
                Text("No apps are using audio right now.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            AppRow(row: row, manager: manager)
                            if row.id != rows.last?.id { Divider().padding(.leading, 48) }
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { manager.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Splitwave").font(.headline)
            Spacer()
            if let setup = manager.activeSetup {
                Label(setup, systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
            } else {
                let moved = manager.routes.values.filter { $0.outputs != [.systemDefault] }.count
                if moved > 0 { Text("\(moved) routed").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                setupsMenu
                Button("Reset all") { manager.unrouteAll() }
                    .disabled(manager.routes.isEmpty)
                    .help("Every app back to the system default at full volume")
                Spacer()
                moreMenu
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Saved route sets: pick one to switch every route at once.
    private var setupsMenu: some View {
        Menu("Setups") {
            ForEach(manager.setups, id: \.name) { setup in
                Toggle(setup.name, isOn: Binding(
                    get: { manager.activeSetup == setup.name },
                    set: { _ in manager.applySetup(named: setup.name) }
                ))
            }
            if !manager.setups.isEmpty { Divider() }
            Button("Save current as…") { promptForSetupName() }
            if !manager.setups.isEmpty {
                Menu("Delete") {
                    ForEach(manager.setups, id: \.name) { setup in
                        Button(setup.name) { manager.deleteSetup(named: setup.name) }
                    }
                }
            }
        }
        .fixedSize()
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            Button("Show log") { NSWorkspace.shared.open(FileLog.shared.url) }
            Divider()
            Button("Quit Splitwave") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    /// Apps worth showing: real apps with audio, anything playing, and saved routes whose app is closed.
    private var rows: [Row] {
        var result = manager.apps
            .filter { $0.isRegularApp || $0.isPlaying || manager.routes[$0.id] != nil }
            .map { Row(id: $0.id, name: $0.name, pid: $0.pid, isPlaying: $0.isPlaying, isRunning: true) }
        let shown = Set(result.map(\.id))
        for route in manager.routes.values.sorted(by: { $0.appName < $1.appName }) where !shown.contains(route.appID) {
            result.append(Row(id: route.appID, name: route.appName, pid: nil, isPlaying: false, isRunning: false))
        }
        return result
    }

    private func promptForSetupName() {
        let alert = NSAlert()
        alert.messageText = "Save setup"
        alert.informativeText = "Saves every app's outputs and volume. Saving with an existing name replaces it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Desk"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            manager.saveSetup(named: field.stringValue)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct Row: Identifiable, Equatable {
    let id: String
    let name: String
    let pid: pid_t?
    let isPlaying: Bool
    let isRunning: Bool
}

private struct AppRow: View {
    let row: Row
    @ObservedObject var manager: RouteManager

    var body: some View {
        let route = manager.routes[row.id]
        let level = manager.level(for: row.id)
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1).layoutPriority(1)
                    if row.isPlaying {
                        Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    outputMenu(route: route)
                }
                if let status = status(route: route) {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                // Every app gets a volume; touching it gives the app a route that follows the default.
                HStack(spacing: 8) {
                    Button {
                        manager.setMuted(!level.muted, for: row.id, appName: row.name)
                    } label: {
                        Image(systemName: level.muted ? "speaker.slash.fill" : "speaker.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(level.muted ? "Unmute" : "Mute")
                    VolumeSlider(
                        volume: Binding(get: { level.volume },
                                        set: { manager.setVolume($0, for: row.id, appName: row.name) }),
                        peak: { manager.isActive(row.id) ? manager.peak(for: row.id) : nil },
                        gain: route?.gain ?? 1,
                        isEnabled: !level.muted
                    )
                    Text("\(Int((level.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(row.isRunning ? 1 : 0.6)
    }

    @ViewBuilder private var icon: some View {
        if let pid = row.pid, let image = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: image).resizable()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.id) {
            // Closed apps with a saved route (and previews) still get their real icon.
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    /// Pick one output, or add more under "Also play on" (F12).
    private func outputMenu(route: RouteConfig?) -> some View {
        let devices = manager.devices.filter(\.isAlive)
        let outputs = route?.outputs ?? [.systemDefault]
        let missing = outputs.filter { o in !o.isSystemDefault && !devices.contains { $0.uid == o.uid } }
        let only = { (ref: OutputRef) in
            Binding(get: { outputs == [ref] },
                    set: { _ in manager.route(appID: row.id, appName: row.name, to: [ref]) })
        }
        return Menu {
            Toggle("System default", isOn: only(.systemDefault))
            Divider()
            ForEach(devices) { device in
                Toggle(device.name, isOn: only(OutputRef(uid: device.uid, name: device.name)))
            }
            Divider()
            Menu("Also play on") {
                ForEach(devices) { device in
                    let ref = OutputRef(uid: device.uid, name: device.name)
                    Toggle(device.name, isOn: Binding(
                        get: { outputs.contains(ref) },
                        set: { _ in manager.toggleOutput(ref, appID: row.id, appName: row.name) }
                    ))
                }
            }
            ForEach(missing, id: \.uid) { ref in
                Button("Remove \(ref.name) (not connected)") {
                    manager.toggleOutput(ref, appID: row.id, appName: row.name)
                }
            }
        } label: {
            Text(route?.shortOutputsLabel ?? OutputRef.systemDefault.name)
        }
        .frame(maxWidth: 160, alignment: .trailing)
        .help(route?.outputsLabel ?? OutputRef.systemDefault.name)
    }

    private func status(route: RouteConfig?) -> String? {
        guard let route else { return nil }
        if let error = manager.errors[row.id] { return error }
        if manager.silentRoutes.contains(row.id), manager.permission != .authorized {
            return "No sound is coming through. Allow system audio recording above."
        }
        let moved = route.outputs != [.systemDefault]
        if !row.isRunning { return moved ? "Will play on \(route.outputsLabel) when it opens" : nil }
        let missing = route.outputs.filter { o in
            !o.isSystemDefault && !manager.devices.contains { $0.uid == o.uid && $0.isAlive }
        }
        if missing.isEmpty { return nil }
        let names = missing.map(\.name).joined(separator: ", ")
        return missing.count == route.outputs.count
            ? "\(names) isn't connected; using the system default"
            : "\(names) isn't connected; playing on the rest"
    }
}
