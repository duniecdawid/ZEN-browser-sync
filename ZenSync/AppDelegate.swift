import AppKit
import UserNotifications

enum SyncState {
    case ready
    case pulling
    case zenRunning
    case pushing
    case error
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var localVersionItem: NSMenuItem!
    private var iCloudVersionItem: NSMenuItem!
    private var pushMenuItem: NSMenuItem!
    private var pullMenuItem: NSMenuItem!
    private var restoreMenuItem: NSMenuItem!
    private var state: SyncState = .ready {
        didSet { updateStatusDisplay() }
    }
    private var firstRunWindow: FirstRunWindow?
    private var restoreWindow: RestoreWindow?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        SyncEngine.migrateIfNeeded()
        setupStatusBar()
        setupWorkspaceObservers()
        LaunchAgent.registerLoginItem()

        if SyncEngine.isZenRunning() {
            state = .zenRunning
        } else {
            checkFirstRun()
        }
    }

    // MARK: - Status Bar

    private static let zenIconBase64 = "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"

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let iconData = Data(base64Encoded: Self.zenIconBase64),
           let icon = NSImage(data: iconData) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = false
            statusItem.button?.image = icon
        }

        let menu = NSMenu()
        menu.delegate = self

        localVersionItem = NSMenuItem(title: "Local: –", action: nil, keyEquivalent: "")
        localVersionItem.isEnabled = false
        menu.addItem(localVersionItem)

        iCloudVersionItem = NSMenuItem(title: "iCloud: –", action: nil, keyEquivalent: "")
        iCloudVersionItem.isEnabled = false
        menu.addItem(iCloudVersionItem)

        menu.addItem(NSMenuItem.separator())

        pushMenuItem = NSMenuItem(title: "Push to iCloud", action: #selector(pushClicked), keyEquivalent: "")
        menu.addItem(pushMenuItem)

        pullMenuItem = NSMenuItem(title: "Pull from iCloud", action: #selector(pullClicked), keyEquivalent: "")
        menu.addItem(pullMenuItem)

        menu.addItem(NSMenuItem.separator())

        restoreMenuItem = NSMenuItem(title: "Restore Backup\u{2026}", action: #selector(restoreClicked), keyEquivalent: "")
        menu.addItem(restoreMenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q"))

        statusItem.menu = menu
        updateStatusDisplay()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshVersionDisplay()
    }

    private func refreshVersionDisplay() {
        let config = SyncEngine.readConfig()
        let localId = config.currentVersionId

        if let localId = localId {
            localVersionItem.title = "Local: v\(localId)"
        } else {
            localVersionItem.title = "Local: not synced"
        }

        if let remote = SyncEngine.latestICloudVersion() {
            if remote.id != localId {
                iCloudVersionItem.title = "iCloud: v\(remote.id) \u{2191} newer"
            } else {
                iCloudVersionItem.title = "iCloud: up to date"
            }
        } else {
            iCloudVersionItem.title = "iCloud: no data"
        }
    }

    private func updateStatusDisplay() {
        DispatchQueue.main.async { [self] in
            let syncing = state == .pushing || state == .pulling
            let zenRunning = state == .zenRunning

            switch state {
            case .ready:
                restoreMenuItem.isEnabled = true
                restoreMenuItem.toolTip = nil
            case .pulling, .pushing:
                restoreMenuItem.isEnabled = false
            case .zenRunning:
                restoreMenuItem.isEnabled = false
                restoreMenuItem.toolTip = "Close Zen first"
            case .error:
                restoreMenuItem.isEnabled = !SyncEngine.isZenRunning()
            }

            pushMenuItem.isEnabled = !syncing && !zenRunning
            pullMenuItem.isEnabled = !syncing && !zenRunning
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
        state = .zenRunning
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == SyncEngine.zenBundleID else { return }

        Logger.shared.log("Zen quit")
        state = .ready
    }

    // MARK: - First Run

    private func checkFirstRun() {
        let config = SyncEngine.readConfig()
        if !config.firstRunDone && SyncEngine.iCloudFolderIsEmpty() {
            showFirstRun()
        }
    }

    private func showFirstRun() {
        firstRunWindow = FirstRunWindow()
        firstRunWindow?.onComplete = { [weak self] in
            self?.firstRunWindow = nil
        }
        firstRunWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Actions

    @objc private func pushClicked() {
        let wasRunning = SyncEngine.isZenRunning()

        let doSync = { [self] in
            state = .pushing

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let ok = SyncEngine.pushVersioned()

                DispatchQueue.main.async { [self] in
                    if ok {
                        state = .ready
                        Logger.shared.log("Push completed")
                        if wasRunning { SyncEngine.launchZen() }
                    } else {
                        state = .error
                        sendNotification(title: "ZenSync", body: "Push failed")
                    }
                }
            }
        }

        if wasRunning {
            SyncEngine.quitZen { [self] graceful in
                DispatchQueue.main.async {
                    if graceful {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            doSync()
                        }
                    } else {
                        self.showForceQuitAlert(then: doSync)
                    }
                }
            }
        } else {
            doSync()
        }
    }

    @objc private func pullClicked() {
        let wasRunning = SyncEngine.isZenRunning()

        let doSync = { [self] in
            self.state = .pulling

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let ok = SyncEngine.pullVersioned()

                DispatchQueue.main.async { [self] in
                    if ok {
                        state = .ready
                        Logger.shared.log("Pull completed")
                        if wasRunning {
                            // Delay relaunch so Zen reads the freshly pulled session data
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                SyncEngine.launchZen()
                            }
                        }
                    } else {
                        state = .error
                        sendNotification(title: "ZenSync", body: "Pull failed")
                    }
                }
            }
        }

        if wasRunning {
            SyncEngine.quitZen { [self] graceful in
                DispatchQueue.main.async {
                    if graceful {
                        // Wait for Zen to fully release file locks before pulling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            doSync()
                        }
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
