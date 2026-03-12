import Foundation

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class Logger {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "app.zensync.logger")
    private let baseDir: URL
    private let logFile: URL
    private let rotatedFile: URL
    private let maxSize: UInt64 = 1_048_576 // 1 MB

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".zensync")
        logFile = baseDir.appendingPathComponent("zensync.log")
        rotatedFile = baseDir.appendingPathComponent("zensync.log.1")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    func log(_ message: String, level: LogLevel = .info) {
        queue.async { [self] in
            rotateIfNeeded()

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"

            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8)!)
                    handle.closeFile()
                }
            } else {
                try? line.data(using: .utf8)?.write(to: logFile)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64,
              size >= maxSize else { return }

        try? FileManager.default.removeItem(at: rotatedFile)
        try? FileManager.default.moveItem(at: logFile, to: rotatedFile)
    }
}
