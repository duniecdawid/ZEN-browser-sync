import AppKit

struct SyncConfig: Codable {
    var firstRunDone: Bool
    var currentVersionId: String?
}

struct VersionEntry: Codable {
    let id: String          // "2026-03-19-001"
    let timestamp: String   // ISO 8601
    let machineId: String
}

struct VersionManifest: Codable {
    var schemaVersion: Int = 1
    var latest: VersionEntry?
}

final class SyncEngine {
    static let zenBundleID = "app.zen-browser.zen"

    static let iCloudFolder: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ZenSync")
    }()

    static let manifestFile: URL = {
        iCloudFolder.appendingPathComponent("manifest.json")
    }()

    static let configFile: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zensync/config.json")
    }()

    // MARK: - Path Resolution

    static func zenProfilePath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let zenDir = home.appendingPathComponent("Library/Application Support/zen")
        let profilesDir = zenDir.appendingPathComponent("Profiles")

        // Scan for all profiles matching Default (release) pattern
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            Logger.shared.log("Zen Profiles directory not found", level: .error)
            return nil
        }
        let matches = contents.filter {
            $0.lastPathComponent.contains(".Default (release)")
        }

        if matches.isEmpty {
            Logger.shared.log("No Default (release) profile found", level: .error)
            return nil
        }

        // If only one match, use it
        if matches.count == 1 {
            Logger.shared.log("Resolved profile: \(matches[0].lastPathComponent)")
            return matches[0]
        }

        // Multiple matches: pick the most recently modified (the one Zen is actually using)
        let best = matches.max { a, b in
            let aDate = (try? a.appendingPathComponent("prefs.js")
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.appendingPathComponent("prefs.js")
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate < bDate
        }
        if let best = best {
            Logger.shared.log("Resolved profile (most recent): \(best.lastPathComponent)")
            return best
        }
        return matches.first
    }

    // MARK: - rsync

    @discardableResult
    static func runRsync(source: URL, destination: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let destPath = destination.path.hasSuffix("/") ? destination.path : destination.path + "/"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a", "--delete",
            "--exclude=cache/",
            "--exclude=storage/",
            "--exclude=sessionstore-backups/",
            "--exclude=sessionstore-logs/",
            "--exclude=crashes/",
            "--exclude=datareporting/",
            "--exclude=gmp-*/",
            "--exclude=security_state/",
            "--exclude=*.lock",
            "--exclude=.parentlock",
            "--exclude=*.sqlite-wal",
            "--exclude=*.sqlite-journal",
            "--exclude=places.sqlite",
            "--exclude=favicons.sqlite",
            "--exclude=cookies.sqlite",
            "--exclude=formhistory.sqlite",
            "--exclude=sessionstore.jsonlz4",
            "--exclude=sessionCheckpoints.json",
            "--exclude=extensions.json",
            "--exclude=weave/",
            "--exclude=key4.db",
            "--exclude=cert9.db",
            "--exclude=manifest.json",
            sourcePath,
            destPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.shared.log("rsync failed to launch: \(error.localizedDescription)", level: .error)
            return false
        }

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Logger.shared.log("rsync exited with status \(process.terminationStatus): \(output)", level: .error)
            return false
        }
        return true
    }

    static func cleanICloudStorageLegacy() {
        let fm = FileManager.default
        let storageDir = iCloudFolder.appendingPathComponent("storage")
        let junk = [
            storageDir.appendingPathComponent("permanent"),
            storageDir.appendingPathComponent("temporary"),
            storageDir.appendingPathComponent("ls-archive.sqlite"),
        ]
        for url in junk {
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                Logger.shared.log("Cleaned legacy iCloud file: \(url.lastPathComponent)")
            }
        }
    }

    private static func push() -> Bool {
        guard let profile = zenProfilePath() else {
            Logger.shared.log("Cannot push: Zen profile not found", level: .error)
            return false
        }
        cleanICloudStorageLegacy()
        Logger.shared.log("Pushing profile to iCloud")
        return runRsync(source: profile, destination: iCloudFolder)
    }

    private static func pull() -> Bool {
        guard let profile = zenProfilePath() else {
            Logger.shared.log("Cannot pull: Zen profile not found", level: .error)
            return false
        }
        if hasICloudStubs() {
            Logger.shared.log("iCloud stubs detected, skipping pull", level: .warning)
            return false
        }
        Logger.shared.log("Pulling iCloud to profile")
        return runRsync(source: iCloudFolder, destination: profile)
    }

    // MARK: - Versioned Sync

    static func pushVersioned() -> Bool {
        guard push() else { return false }

        var manifest = readManifest()
        let versionId = nextVersionId(manifest: manifest)
        let entry = VersionEntry(
            id: versionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            machineId: Host.current().localizedName ?? "Unknown"
        )
        manifest.latest = entry
        writeManifest(manifest)

        var config = readConfig()
        config.currentVersionId = versionId
        writeConfig(config)

        Logger.shared.log("Pushed version \(versionId)")
        return true
    }

    static func pullVersioned() -> Bool {
        guard pull() else { return false }

        let manifest = readManifest()
        var config = readConfig()
        config.currentVersionId = manifest.latest?.id
        writeConfig(config)

        Logger.shared.log("Pulled version \(manifest.latest?.id ?? "unknown")")
        return true
    }

    // MARK: - Manifest

    static func readManifest() -> VersionManifest {
        guard let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(VersionManifest.self, from: data) else {
            return VersionManifest()
        }
        return manifest
    }

    static func writeManifest(_ manifest: VersionManifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? FileManager.default.createDirectory(
            at: iCloudFolder,
            withIntermediateDirectories: true
        )
        try? data.write(to: manifestFile)
    }

    static func nextVersionId(manifest: VersionManifest) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())

        if let latestId = manifest.latest?.id,
           latestId.hasPrefix(today),
           let lastPart = latestId.split(separator: "-").last,
           let num = Int(lastPart) {
            return String(format: "%@-%03d", today, num + 1)
        }
        return "\(today)-001"
    }

    static func latestICloudVersion() -> VersionEntry? {
        readManifest().latest
    }

    static func hasNewerVersion() -> Bool {
        let config = readConfig()
        guard let remoteId = readManifest().latest?.id else { return false }
        return config.currentVersionId != remoteId
    }

    // MARK: - Migration

    static func migrateIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: iCloudFolder.path),
              !iCloudFolderIsEmpty(),
              !fm.fileExists(atPath: manifestFile.path) else { return }

        Logger.shared.log("Migrating existing iCloud data to versioned format")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let versionId = "\(df.string(from: Date()))-001"

        let entry = VersionEntry(
            id: versionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            machineId: Host.current().localizedName ?? "Unknown"
        )
        var manifest = VersionManifest()
        manifest.latest = entry
        writeManifest(manifest)

        var config = readConfig()
        config.currentVersionId = versionId
        writeConfig(config)

        Logger.shared.log("Migration complete: assigned version \(versionId)")
    }

    // MARK: - iCloud Stubs

    static func hasICloudStubs() -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: iCloudFolder,
            includingPropertiesForKeys: nil
        ) else { return false }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasPrefix(".") && fileURL.lastPathComponent.hasSuffix(".icloud") {
                return true
            }
        }
        return false
    }


    // MARK: - Zen Process

    static func isZenRunning() -> Bool {
        !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == zenBundleID }.isEmpty
    }

    static func quitZen(completion: @escaping (Bool) -> Void) {
        guard let zenApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == zenBundleID
        }) else {
            completion(true)
            return
        }

        zenApp.terminate()

        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 0.5
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            elapsed += interval
            if zenApp.isTerminated {
                timer.invalidate()
                completion(true)
            } else if elapsed >= 10 {
                timer.invalidate()
                completion(false)
            }
        }
    }

    static func launchZen() {
        let config = NSWorkspace.OpenConfiguration()
        let zenURL = URL(fileURLWithPath: "/Applications/Zen.app")
        NSWorkspace.shared.openApplication(at: zenURL, configuration: config) { _, error in
            if let error = error {
                Logger.shared.log("Failed to launch Zen: \(error.localizedDescription)", level: .error)
            }
        }
    }

    // MARK: - Config

    static func readConfig() -> SyncConfig {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(SyncConfig.self, from: data) else {
            return SyncConfig(firstRunDone: false)
        }
        return config
    }

    static func writeConfig(_ config: SyncConfig) {
        try? FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFile)
        }
    }

    // MARK: - iCloud Folder State

    static func iCloudFolderIsEmpty() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: iCloudFolder.path) else { return true }
        guard let contents = try? fm.contentsOfDirectory(atPath: iCloudFolder.path) else { return true }
        return contents.isEmpty
    }
}
