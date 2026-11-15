import Cocoa
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var lastExternalAppID: String?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var retryTimer: Timer?
    private var secureInputOn = false
    private let menuPanel = MenuPanelController()

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.registerDefaults()
        LayoutManager.shared.reload()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuPanel.actions = MenuActions(
            selectLayout: { id in if let l = LayoutManager.shared.layout(withID: id) { LayoutManager.shared.select(l) } },
            openAccessibility: { [weak self] in self?.menuPanel.close(); self?.openPrivacy() },
            openInputMonitoring: { [weak self] in self?.menuPanel.close(); self?.openInputMonitoring() },
            writer: { [weak self] in self?.menuPanel.close(); self?.openWriter() },
            convert: { [weak self] in self?.menuPanel.close(); KeyboardEngine.shared.manualConvert() },
            voice: { [weak self] in self?.menuPanel.close(); VoiceController.shared.toggle() },
            settings: { [weak self] in self?.menuPanel.close(); self?.openSettings() },
            quit: { NSApp.terminate(nil) },
            lockScreen: { [weak self] in self?.menuPanel.close(); SecureInput.lockScreen() })
        updateIndicator()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.rememberLayoutForFrontApp(); self?.updateIndicator() }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { _ in LayoutManager.shared.reload() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            KeyboardEngine.shared.resetAll()
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                AppDelegate.lastExternalAppID = app.bundleIdentifier
                self?.restoreLayout(for: app)
            }
            self?.updateIndicator()
        }
        UserDefaults.standard.addObserver(self, forKeyPath: "indicatorStyle", options: [], context: nil)
        // Secure Input (password fields, or a stuck loginwindow) hides all keystrokes from Keyla.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let on = SecureInput.isOn
            if on != self?.secureInputOn { self?.secureInputOn = on; self?.updateIndicator() }
        }
        startEngine()
        registerLoginItemOnce()
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { OnboardingController.shared.show() }
        }
    }

    // MARK: Per-app layout memory

    private func rememberLayoutForFrontApp() {
        guard Settings.perAppLayout,
              let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              let cur = LayoutManager.shared.current?.id else { return }
        var map = Settings.appLayouts
        if map[id] != cur { map[id] = cur; Settings.appLayouts = map }
    }

    private func restoreLayout(for app: NSRunningApplication) {
        guard Settings.perAppLayout, let id = app.bundleIdentifier,
              let saved = Settings.appLayouts[id], let l = LayoutManager.shared.layout(withID: saved),
              l.id != LayoutManager.shared.current?.id else { return }
        LayoutManager.shared.select(l)
    }

    /// Turn on "open at login" once, on the first run from /Applications. After that the user's choice wins
    /// (including switching it off in System Settings → General → Login Items).
    private func registerLoginItemOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginItemRegistered"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        if Settings.d.bool(forKey: "launchAtLogin") { LoginItem.set(true) }
        d.set(true, forKey: "loginItemRegistered")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        updateIndicator()
    }

    /// Both permissions are needed: Accessibility (to create the tap and rewrite text)
    /// and Input Monitoring (otherwise macOS silently strips key presses from the tap).
    private var hasAccessibility: Bool { AXIsProcessTrusted() }
    private var hasInputMonitoring: Bool { CGPreflightListenEventAccess() }
    private var isReady: Bool { KeyboardEngine.shared.isRunning && hasAccessibility && hasInputMonitoring }

    private func startEngine() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !hasInputMonitoring { CGRequestListenEventAccess() }
        var wasReady = false
        if hasAccessibility && hasInputMonitoring { _ = KeyboardEngine.shared.start(); wasReady = isReady }
        updateIndicator()
        // Keep watching: a tap created before a permission was granted never receives keys, so recreate it.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let permsOK = self.hasAccessibility && self.hasInputMonitoring
            if permsOK && !wasReady {
                KeyboardEngine.shared.stop()
                if KeyboardEngine.shared.start() {
                    HUD.shared.show("Keyla работает", "Печатайте — раскладка переключится сама", force: true)
                }
            } else if !permsOK && wasReady {
                KeyboardEngine.shared.stop()
            }
            if self.isReady != wasReady { wasReady = self.isReady; self.updateIndicator() }
        }
    }

    private func refreshPanel() {
        let m = menuPanel.model
        m.layouts = LayoutManager.shared.layouts.map { .init(id: $0.id, name: $0.name, short: $0.short) }
        m.currentID = LayoutManager.shared.current?.id ?? ""
        m.missingAccessibility = !hasAccessibility
        m.missingInputMonitoring = !hasInputMonitoring
        m.secureInput = secureInputOn
        let owner = secureInputOn ? SecureInput.owner() : nil
        m.secureOwner = owner?.name
        m.secureIsGlitch = owner?.isSystemGlitch ?? false
        m.recording = VoiceController.shared.isRecording
        m.switchesToday = UserDefaults.standard.integer(forKey: Stats.key("switch"))
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        refreshPanel()
        menuPanel.toggle(from: button)
    }

    private func updateIndicator() {
        refreshPanel()
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        guard isReady else { button.title = "⚠️ Keyla"; return }
        guard let l = LayoutManager.shared.current else { button.title = "⌨️"; return }
        switch Settings.indicatorStyle {
        case "flag": button.title = l.flag
        case "both": button.title = "\(l.flag) \(l.short)"
        case "smiley":
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            let img = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Keyla")?.withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.title = " " + l.flag
            button.font = NSFont.systemFont(ofSize: 15)
        case "mark":
            button.image = MenuGlyph.image(height: 15)
            button.imagePosition = .imageLeading
            button.title = " " + l.short
            button.font = NSFont(name: "HelveticaNeue-Bold", size: 13) ?? .boldSystemFont(ofSize: 13)
        default: button.title = l.short
        }
        if secureInputOn { button.title = "🔒 " + button.title }
        button.toolTip = "Keyla — \(l.name)"
    }

    // MARK: Actions

    @objc private func openWriter() {
        // The panel never steals focus, so the user's app still holds the selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WriterController.shared.invoke() }
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        CGRequestListenEventAccess()
    }

    @objc private func openInputMonitoring() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Keyla"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0.855, green: 0.831, blue: 0.796, alpha: 1)
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
