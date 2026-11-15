import ServiceManagement

/// "Open at login" via the system login-items API (shows up in System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !on, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Keyla login item: \(error.localizedDescription)")
            return false
        }
    }
}
