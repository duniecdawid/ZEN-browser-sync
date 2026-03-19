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

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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
                statusItem.button?.title = "\u{1F9D8} Ready"
                restoreMenuItem.isEnabled = true
                restoreMenuItem.toolTip = nil
            case .pulling:
                statusItem.button?.title = "\u{2B07}\u{FE0E} Syncing\u{2026}"
                restoreMenuItem.isEnabled = false
            case .zenRunning:
                statusItem.button?.title = "\u{1F9D8} Zen"
                restoreMenuItem.isEnabled = false
                restoreMenuItem.toolTip = "Close Zen first"
            case .pushing:
                statusItem.button?.title = "\u{2B06}\u{FE0E} Syncing\u{2026}"
                restoreMenuItem.isEnabled = false
            case .error:
                statusItem.button?.title = "\u{26A0}\u{FE0F} ZenSync"
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
