import AppKit
import UserNotifications

final class RestoreWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    private var backups: [String] = []
    private let tableView = NSTableView()
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Restore Backup"
        isReleasedWhenClosed = false
        center()

        backups = BackupManager.shared.availableBackups()

        let contentView = NSView(frame: self.contentRect(forFrameRect: frame))
        self.contentView = contentView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        column.title = "Backup Date"
        column.width = 300
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked)
        restoreButton.bezelStyle = .rounded
        restoreButton.isEnabled = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: restoreButton.topAnchor, constant: -12),

            restoreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            restoreButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            restoreButton.widthAnchor.constraint(equalToConstant: 100),
        ])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        backups.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        backups[row]
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        restoreButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Actions

    @objc private func restoreClicked() {
        guard tableView.selectedRow >= 0 else { return }
        let dateString = backups[tableView.selectedRow]

        let alert = NSAlert()
        alert.messageText = "Restore from \(dateString)?"
        alert.informativeText = "This will overwrite your current profile. Continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let success = BackupManager.shared.restore(from: dateString)
            DispatchQueue.main.async { [self] in
                close()
                if success {
                    sendNotification(title: "ZenSync", body: "Restored from \(dateString). You can now open Zen.")
                }
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
