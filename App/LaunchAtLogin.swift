import Foundation
import ServiceManagement

/// Launch-at-login, via `SMAppService`.
///
/// Off by default and never enabled implicitly: registering a login item is a
/// persistent, user-visible system change, so it happens only when asked.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS needs the user to approve the item in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("nits: launch at login \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
