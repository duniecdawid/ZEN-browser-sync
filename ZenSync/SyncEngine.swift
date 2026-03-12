import AppKit

struct SyncConfig: Codable {
    var firstRunDone: Bool
}

final class SyncEngine {
    static let zenBundleID = "app.zen-browser.zen"

    static let iCloudFolder: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ZenSync")
    }()

    static let configFile: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".zensync/config.json")
    }()

    // MARK: - Path Resolution

    static func zenProfilePath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profilesDir = home.appendingPathComponent("Library/Application Support/zen/Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: nil
        ) else {
            Logger.shared.log("Zen Profiles directory not found", level: .error)
            return nil
        }
        return contents.first { $0.lastPathComponent.hasSuffix(".Default (release)") }
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
            "--exclude=crashes/",
            "--exclude=*.lock",
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

    static func push() -> Bool {
        guard let profile = zenProfilePath() else {
            Logger.shared.log("Cannot push: Zen profile not found", level: .error)
            return false
        }
        Logger.shared.log("Pushing profile to iCloud")
        return runRsync(source: profile, destination: iCloudFolder)
    }

    static func pull() -> Bool {
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

    // MARK: - Freshness Check

    static func iCloudIsNewer() -> Bool {
        guard let profile = zenProfilePath() else { return false }
        let sentinel = "prefs.js"
        let iCloudFile = iCloudFolder.appendingPathComponent(sentinel)
        let localFile = profile.appendingPathComponent(sentinel)

        guard let iCloudDate = modDate(of: iCloudFile),
              let localDate = modDate(of: localFile) else { return false }

        return iCloudDate > localDate
    }

    private static func modDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
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
