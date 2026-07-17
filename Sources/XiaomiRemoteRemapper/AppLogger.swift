import Foundation

final class AppLogger {
    static let shared = AppLogger()

    let logURL: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    private init() {
        logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/XiaomiRemoteRemapper/app.log")
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        fputs(line, stderr)

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try Data().write(to: logURL)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            fputs("log_write_failed=\(error)\n", stderr)
        }
    }
}
