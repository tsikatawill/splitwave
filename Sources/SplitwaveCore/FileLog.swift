import Foundation

/// Appends timestamped lines to ~/Library/Logs/Splitwave/splitwave.log, so a week of daily use
/// leaves a record of every route change, fallback and failure. Main thread only.
public final class FileLog {
    public static let shared = FileLog()

    public let url: URL
    private let maxBytes: UInt64 = 1_000_000
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Splitwave/splitwave.log")) {
        self.url = url
    }

    /// - Parameter source: who is writing ("app", "cli"), since both share the file.
    public func write(_ message: String, source: String) {
        let line = "\(formatter.string(from: Date())) [\(source)] \(message)\n"
        guard let handle = openHandle() else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        if handle.offsetInFile > maxBytes { rotate() }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        return handle
    }

    /// Keeps one previous file (splitwave.log.1) so the log never grows past ~2 MB.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
