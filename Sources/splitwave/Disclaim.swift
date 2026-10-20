import Darwin
import Foundation

/// macOS grants audio capture to the *responsible* app: for a CLI that is the terminal, and
/// Terminal.app has no NSAudioCaptureUsageDescription, so the request is refused outright.
/// Re-launching ourselves with responsibility disclaimed makes this binary its own responsible
/// process, so macOS asks using the Info.plist embedded in it.
enum Disclaim {
    private static let marker = "SPLITWAVE_DISCLAIMED"

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static var child: pid_t = 0

    /// Returns in the disclaimed child (or when disclaiming isn't possible); otherwise runs the
    /// child to completion and exits with its status.
    static func respawnIfNeeded() {
        guard ProcessInfo.processInfo.environment[marker] == nil,
              let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_spawnattrs_setdisclaim"),
              let path = executablePath() else { return }
        let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { return }

        var env = ProcessInfo.processInfo.environment
        env[marker] = "1"
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, path, nil, &attr, argv, envp) == 0 else { return }
        child = pid

        // Ctrl-C reaches the child directly (same process group); just pass on a SIGTERM.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM) { _ in kill(Disclaim.child, SIGTERM) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let exited = status & 0x7f == 0
        exit(exited ? (status >> 8) & 0xff : 1)
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}
