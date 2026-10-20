import AppKit
import CoreAudio
import Darwin
import Foundation

/// One Core Audio process object: a process that has opened an audio client.
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool
}

/// An app as the user thinks of it, with its helper processes folded in (F1).
public struct AudioApp: Identifiable, Hashable, Sendable {
    /// The owning app's bundle ID, or "pid:<n>" for a process without one.
    public let id: String
    public let name: String
    public let pid: pid_t
    /// Every process object to tap for this app (the app itself plus helpers).
    public let processObjects: [AudioObjectID]
    public let isPlaying: Bool
    /// True for apps with a Dock presence; false for daemons and agents.
    public let isRegularApp: Bool

    public init(id: String, name: String, pid: pid_t, processObjects: [AudioObjectID],
                isPlaying: Bool, isRegularApp: Bool) {
        self.id = id
        self.name = name
        self.pid = pid
        self.processObjects = processObjects
        self.isPlaying = isPlaying
        self.isRegularApp = isRegularApp
    }
}

public enum AppCatalog {
    public static func processes() -> [AudioProcess] {
        let ids = (try? AudioObject.array(AudioObject.system, kAudioHardwarePropertyProcessObjectList,
                                          of: AudioObjectID.self)) ?? []
        return ids.compactMap { id in
            guard let pid = try? AudioObject.value(id, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else {
                return nil
            }
            let bundleID = (try? AudioObject.string(id, kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let running = ((try? AudioObject.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running)
        }
    }

    /// Audio processes grouped under the app responsible for them, Splitwave itself excluded.
    public static func apps() -> [AudioApp] {
        rawApps().filter { !$0.id.hasPrefix("app.splitwave.") }  // other Splitwave processes (app, CLI)
    }

    private static func rawApps() -> [AudioApp] {
        let me = getpid()
        var groups: [pid_t: [AudioProcess]] = [:]
        for process in processes() where process.pid != me {
            let owner = owningPID(of: process.pid)
            guard owner != me else { continue }
            groups[owner, default: []].append(process)
        }
        return groups.map { owner, members in
            let app = NSRunningApplication(processIdentifier: owner)
            let bundleID = app?.bundleIdentifier ?? members.first(where: { $0.pid == owner })?.bundleID
            let name = (app?.localizedName ?? bundleID.map(shortName) ?? processName(owner) ?? "pid \(owner)")
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))  // e.g. a leading U+200E
            return AudioApp(
                id: bundleID ?? "pid:\(owner)",
                name: name,
                pid: owner,
                processObjects: members.map(\.objectID).sorted(),
                isPlaying: members.contains(where: \.isRunningOutput),
                isRegularApp: app?.activationPolicy == .regular
            )
        }
        .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// The app a process belongs to: Chrome for Chrome Helper, Safari for WebKit's GPU process.
    static func owningPID(of pid: pid_t) -> pid_t {
        if let responsible = responsiblePID(pid), responsible > 1 {
            return responsible
        }
        // Fallback: walk up the parent chain to the nearest regular app.
        var current = pid
        for _ in 0..<8 {
            if NSRunningApplication(processIdentifier: current)?.activationPolicy == .regular { return current }
            guard let parent = parentPID(current), parent > 1 else { break }
            current = parent
        }
        return pid
    }

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFn: ResponsibilityFn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibilityFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// "com.apple.Music" → "Music"
    private static func shortName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
