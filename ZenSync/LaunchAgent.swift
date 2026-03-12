import Foundation
import ServiceManagement

enum LaunchAgent {
    static func registerLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                Logger.shared.log("Login item registered")
            } catch {
                Logger.shared.log("Failed to register login item: \(error.localizedDescription)", level: .error)
            }
        }
    }
}
