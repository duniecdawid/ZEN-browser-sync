import AppKit

final class FirstRunWindow: NSWindow {
    var onComplete: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Welcome to ZenSync"
        isReleasedWhenClosed = false
        center()

        let contentView = NSView(frame: self.contentRect(forFrameRect: frame))
        self.contentView = contentView

        let label = NSTextField(labelWithString: "Which machine are you setting up from?")
        label.font = NSFont.systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        let primaryButton = NSButton(title: "Primary \u{2014} push local to iCloud", target: self, action: #selector(primaryClicked))
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.bezelStyle = .rounded
        contentView.addSubview(primaryButton)

        let secondaryButton = NSButton(title: "Secondary \u{2014} pull iCloud to local", target: self, action: #selector(secondaryClicked))
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.bezelStyle = .rounded
        contentView.addSubview(secondaryButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),

            primaryButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            primaryButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 30),
            primaryButton.widthAnchor.constraint(equalToConstant: 280),

            secondaryButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            secondaryButton.topAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: 12),
            secondaryButton.widthAnchor.constraint(equalToConstant: 280),
        ])
    }

    @objc private func primaryClicked() {
        Logger.shared.log("First run: user chose Primary (push local to iCloud)")
        DispatchQueue.global(qos: .userInitiated).async {
            let success = SyncEngine.push()
            DispatchQueue.main.async { [self] in
                if !success {
                    Logger.shared.log("First run push failed", level: .error)
                }
                finishSetup()
            }
        }
    }

    @objc private func secondaryClicked() {
        Logger.shared.log("First run: user chose Secondary (pull iCloud to local)")
        DispatchQueue.global(qos: .userInitiated).async {
            let success = SyncEngine.pull()
            DispatchQueue.main.async { [self] in
                if !success {
                    Logger.shared.log("First run pull failed", level: .error)
                }
                finishSetup()
            }
        }
    }

    private func finishSetup() {
        var config = SyncEngine.readConfig()
        config.firstRunDone = true
        SyncEngine.writeConfig(config)
        close()
        onComplete?()
    }
}
