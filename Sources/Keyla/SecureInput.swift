import Cocoa
import Carbon
import IOKit

/// Who holds macOS "Secure Keyboard Entry". While it is on, no app (Keyla included) can see key presses.
enum SecureInput {
    struct Owner { let pid: pid_t; let name: String; let isSystemGlitch: Bool }

    static var isOn: Bool { IsSecureEventInputEnabled() }

    static func owner() -> Owner? {
        guard isOn else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]] else { return nil }
        for u in users {
            guard let pid = (u["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value, pid > 0 else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid)
            // loginwindow keeps it after lock/unlock or a password prompt — a known macOS glitch.
            return Owner(pid: pid, name: name, isSystemGlitch: name.lowercased() == "loginwindow")
        }
        return nil
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    /// When the user last asked Keyla to lock the screen to clear the glitch.
    static var lockRequestedAt: Date?

    /// Locks the screen. After unlocking, loginwindow normally releases Secure Input.
    static func lockScreen() {
        lockRequestedAt = Date()
        // System lock call (what the Control Center lock uses); falls back to the ⌃⌘Q shortcut.
        typealias LockFn = @convention(c) () -> Int32
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
        } else {
            TextInjector.key(12, flags: [.maskCommand, .maskControl])
        }
    }
}
