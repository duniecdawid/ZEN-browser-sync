import Foundation

final class BackupManager {
    static let shared = BackupManager()

    private let backupsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zensync/backups")
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {}

    func backup() -> Bool {
        guard let profile = SyncEngine.zenProfilePath() else {
            Logger.shared.log("Cannot backup: Zen profile not found", level: .error)
            return false
        }
        let today = dateFormatter.string(from: Date())
        let dest = backupsDir.appendingPathComponent(today)
        Logger.shared.log("Backing up profile to \(dest.path)")
        return SyncEngine.runRsync(source: profile, destination: dest)
    }

    func pruneOldBackups() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: backupsDir.path) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        for entry in entries {
            guard let date = dateFormatter.date(from: entry) else { continue }
            if date < cutoff {
                let path = backupsDir.appendingPathComponent(entry)
                try? fm.removeItem(at: path)
                Logger.shared.log("Pruned old backup: \(entry)")
            }
        }
    }

    func availableBackups() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: backupsDir.path) else {
            return []
        }
        return entries
            .filter { dateFormatter.date(from: $0) != nil }
            .sorted(by: >)
    }

    func restore(from dateString: String) -> Bool {
        guard let profile = SyncEngine.zenProfilePath() else {
            Logger.shared.log("Cannot restore: Zen profile not found", level: .error)
            return false
        }
        let source = backupsDir.appendingPathComponent(dateString)
        guard FileManager.default.fileExists(atPath: source.path) else {
            Logger.shared.log("Backup not found: \(dateString)", level: .error)
            return false
        }

        Logger.shared.log("Restoring from backup: \(dateString)")

        // Restore backup to profile
        guard SyncEngine.runRsync(source: source, destination: profile) else { return false }

        // Push restored profile to iCloud
        guard SyncEngine.pushVersioned() else {
            Logger.shared.log("Restore succeeded but push to iCloud failed", level: .warning)
            return true
        }

        return true
    }
}
