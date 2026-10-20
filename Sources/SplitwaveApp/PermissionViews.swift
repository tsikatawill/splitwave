import AppKit
import SplitwaveCore
import SwiftUI

/// Explains and asks for the system-audio-recording permission. Shown in the first-run window
/// and, until the permission is granted, at the top of the popover.
struct PermissionCard: View {
    @ObservedObject var manager: RouteManager
    /// Inline: no icon or title, for when the surrounding view already says what this is.
    var inline = false
    @State private var asking = false

    var body: some View {
        switch manager.permission {
        case .authorized:
            Label("Splitwave can hear your apps.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unknown:
            card(
                icon: "waveform.badge.exclamationmark",
                title: "Allow system audio recording",
                body: "macOS has to let Splitwave capture an app's sound before it can play it somewhere else. "
                    + "Splitwave only touches the apps you route and never records or saves audio.",
                tint: .accentColor
            ) {
                Button(asking ? "Waiting for macOS…" : "Allow…") {
                    asking = true
                    AudioCapturePermission.request { _ in
                        asking = false
                        manager.refresh()
                    }
                }
                .disabled(asking)
                .keyboardShortcut(.defaultAction)
            }
        case .denied:
            card(
                icon: "speaker.slash.fill",
                title: "Splitwave can't hear your apps",
                body: "System audio recording is off for Splitwave, so routed apps would play silence. "
                    + "Turn Splitwave on in System Settings, then reopen it.",
                tint: .orange
            ) {
                HStack {
                    Button("Open System Settings") { AudioCapturePermission.openSettings() }
                    Button("Reopen Splitwave") { relaunch() }
                }
            }
        }
    }

    private func card(icon: String, title: String, body: String, tint: Color,
                      @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !inline {
                Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !inline { Text(title).font(.headline) }
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
    }

    /// macOS applies a permission turned on in System Settings only after the app restarts.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// First-run window: get the permission, then show where the controls live.
struct OnboardingView: View {
    @ObservedObject var manager: RouteManager
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Splitwave").font(.title2.bold())
                    Text("Send each app's sound to the output you choose.").foregroundStyle(.secondary)
                }
            }
            step(1, "Allow system audio recording") {
                PermissionCard(manager: manager, inline: true)
            }
            step(2, "Click \(Image(systemName: "waveform")) in the menu bar") {
                Text("Every app that's using audio gets a row.").foregroundStyle(.secondary)
            }
            step(3, "Pick an output next to an app") {
                Text("Spotify to AirPods, Chrome to the speakers. Apps you leave alone stay on the system default, "
                     + "and routes come back when the app or device does.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(manager.permission == .authorized ? "Done" : "Skip for now", action: done)
                    .keyboardShortcut(manager.permission == .authorized ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.callout.bold().monospacedDigit())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
