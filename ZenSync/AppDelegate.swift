import AppKit
import UserNotifications

enum SyncState {
    case ready
    case pulling
    case zenRunning
    case pushing
    case error
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var restoreMenuItem: NSMenuItem!
    private var pollTimer: Timer?
    private var state: SyncState = .ready {
        didSet { updateStatusDisplay() }
    }
    private var firstRunWindow: FirstRunWindow?
    private var restoreWindow: RestoreWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        setupStatusBar()
        setupWorkspaceObservers()
        LaunchAgent.registerLoginItem()

        // Check if Zen is already running
        if SyncEngine.isZenRunning() {
            state = .zenRunning
        } else {
            checkFirstRun()
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Force Sync", action: #selector(forceSyncClicked), keyEquivalent: ""))

        restoreMenuItem = NSMenuItem(title: "Restore Backup\u{2026}", action: #selector(restoreClicked), keyEquivalent: "")
        menu.addItem(restoreMenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem.menu = menu
        updateStatusDisplay()
    }

    private func updateStatusDisplay() {
        DispatchQueue.main.async { [self] in
            switch state {
            case .ready:
                statusItem.button?.title = "\u{1F9D8} Ready"
                statusMenuItem.title = "Ready"
                restoreMenuItem.isEnabled = true
                restoreMenuItem.toolTip = nil
            case .pulling:
                statusItem.button?.title = "\u{2B07}\u{FE0E} Syncing\u{2026}"
                statusMenuItem.title = "Pulling from iCloud\u{2026}"
                restoreMenuItem.isEnabled = false
            case .zenRunning:
                statusItem.button?.title = "\u{1F9D8} Zen"
                statusMenuItem.title = "Zen is running"
                restoreMenuItem.isEnabled = false
                restoreMenuItem.toolTip = "Close Zen first"
            case .pushing:
                statusItem.button?.title = "\u{2B06}\u{FE0E} Syncing\u{2026}"
                statusMenuItem.title = "Pushing to iCloud\u{2026}"
                restoreMenuItem.isEnabled = false
            case .error:
                statusItem.button?.title = "\u{26A0}\u{FE0F} ZenSync"
                statusMenuItem.title = "Error \u{2014} check log"
                restoreMenuItem.isEnabled = !SyncEngine.isZenRunning()
            }
        }
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == SyncEngine.zenBundleID else { return }

        Logger.shared.log("Zen launched")
        stopPolling()
        state = .zenRunning
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == SyncEngine.zenBundleID else { return }

        Logger.shared.log("Zen quit")
        state = .pushing

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let pushOk = SyncEngine.push()
            if !pushOk {
                sendNotification(title: "ZenSync", body: "Push failed after Zen quit")
                DispatchQueue.main.async { self.state = .error }
            }

            let _ = BackupManager.shared.backup()
            BackupManager.shared.pruneOldBackups()

            DispatchQueue.main.async { [self] in
                if pushOk { state = .ready }
                startPolling()
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        Logger.shared.log("Starting poll timer")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.pollCheck()
        }
        // Run immediately on start
        pollCheck()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollCheck() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard !SyncEngine.hasICloudStubs() else {
                Logger.shared.log("iCloud stubs detected, skipping poll", level: .warning)
                return
            }
            guard SyncEngine.iCloudIsNewer() else { return }

            DispatchQueue.main.async { self.state = .pulling }
            let ok = SyncEngine.pull()
            DispatchQueue.main.async { [self] in
                if ok {
                    state = .ready
                    Logger.shared.log("Background pull completed")
                } else {
                    state = .error
                    sendNotification(title: "ZenSync", body: "Pull failed")
                }
            }
        }
    }

    // MARK: - First Run

    private func checkFirstRun() {
        let config = SyncEngine.readConfig()
        if !config.firstRunDone && SyncEngine.iCloudFolderIsEmpty() {
            showFirstRun()
        } else {
            startPolling()
        }
    }

    private func showFirstRun() {
        firstRunWindow = FirstRunWindow()
        firstRunWindow?.onComplete = { [weak self] in
            self?.firstRunWindow = nil
            self?.startPolling()
        }
        firstRunWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Actions

    @objc private func forceSyncClicked() {
        let alert = NSAlert()
        alert.messageText = "Force Sync"
        alert.informativeText = "Which version should win?"
        alert.addButton(withTitle: "\u{2191} This Mac \u{2192} iCloud")
        alert.addButton(withTitle: "\u{2193} iCloud \u{2192} This Mac")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let pushDirection = response == .alertFirstButtonReturn
        let wasRunning = SyncEngine.isZenRunning()

        let doSync = { [self] in
            stopPolling()
            state = pushDirection ? .pushing : .pulling

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let ok: Bool
                if pushDirection {
                    ok = SyncEngine.push()
                } else {
                    ok = SyncEngine.pull()
                }

                DispatchQueue.main.async { [self] in
                    if ok {
                        state = .ready
                        Logger.shared.log("Force sync completed")
                        if wasRunning { SyncEngine.launchZen() }
                    } else {
                        state = .error
                        sendNotification(title: "ZenSync", body: "Force sync failed")
                    }
                    startPolling()
                }
            }
        }

        if wasRunning {
            SyncEngine.quitZen { [self] graceful in
                DispatchQueue.main.async {
                    if graceful {
                        doSync()
                    } else {
                        self.showForceQuitAlert(then: doSync)
                    }
                }
            }
        } else {
            doSync()
        }
    }

    private func showForceQuitAlert(then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Zen is not responding"
        alert.informativeText = "Force quit and sync anyway?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            if let zenApp = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == SyncEngine.zenBundleID
            }) {
                zenApp.forceTerminate()
            }
            // Small delay to let the process exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                action()
            }
        }
    }

    @objc private func restoreClicked() {
        guard !SyncEngine.isZenRunning() else { return }
        restoreWindow = RestoreWindow()
        restoreWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
