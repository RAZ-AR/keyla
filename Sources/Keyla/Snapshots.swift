import Cocoa
import SwiftUI

/// `Keyla --snapshots <dir>` renders every screen offscreen to PNG for design review.
enum Snapshots {
    static func render<V: View>(_ view: V, _ name: String, to dir: URL, size: NSSize? = nil, appearance: NSAppearance.Name = .aqua) {
        let host = NSHostingView(rootView: view)
        let fit = size ?? host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: fit),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: appearance)
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        w.orderOut(nil)
        print("✓", name, Int(fit.width), "×", Int(fit.height))
    }

    static func run(_ path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Settings.registerDefaults()
        LayoutManager.shared.reload()
        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let savedTab = d.string(forKey: "settingsTab")
        d.set(14, forKey: Stats.key("switch")); d.set(3, forKey: Stats.key("typo"))

        for tab in ["general", "spelling", "ai", "voice"] {
            d.set(tab, forKey: "settingsTab")
            render(SettingsView(), "settings-\(tab)", to: dir)
        }
        d.set(savedTab ?? "general", forKey: "settingsTab")

        let m = WriterModel()
        m.original = "привет, я хотел уточнить на счёт встречи завтра, получится ли перенести её на после обеда"
        m.result = "Привет! Хотел уточнить насчёт завтрашней встречи: получится ли перенести её на вторую половину дня?"
        m.mode = .improve
        render(WriterView(model: m, onRun: {}, onApply: {}, onCopy: {}), "writer", to: dir, size: NSSize(width: 600, height: 560))
        let e = WriterModel(); e.original = "I has a apple"; e.result = "I have an apple"; e.offline = true
        e.mode = .formal; e.error = "Режим «Деловой» требует AI-модель — подключите её в Настройках → AI."
        e.notes = ["Consider ‘an’ instead", "«has» → «have»"]
        render(WriterView(model: e, onRun: {}, onApply: {}, onCopy: {}), "writer-offline", to: dir, size: NSSize(width: 600, height: 600))

        let hud = HUDModel()
        let samples: [(String, String?, String?, Double?)] = [
            ("ghbdtn → привет", "⌫ — отменить", "RU", nil),
            ("recieve → receive", "⌫ — вернуть как было", "Aa", nil),
            ("Говорите", "Отпустите правый ⌥ или нажмите ⌃⌥V", nil, 0.6),
            ("Очень-очень длинное слово-исключение → вариант", "Подсказка, которая занимает две строки, чтобы проверить перенос и ширину карточки", "EN", nil),
        ]
        for (i, s) in samples.enumerated() {
            hud.title = s.0; hud.subtitle = s.1; hud.badge = s.2; hud.level = s.3
            render(HUDView(model: hud).padding(12).background(Color.white), "hud-\(i)", to: dir)
        }
        let om = OnboardingModel()
        let lm = LearnPrompt.Model()
        lm.word = "барев"
        lm.reason = "Пишете его уже 3 раза — больше не подчёркивать"
        render(LearnView(model: lm, remember: {}, dismiss: {}).padding(12).background(Color.white), "learn-prompt", to: dir)
        render(OnboardingView(model: om, openAccessibility: {}, openInputMonitoring: {}, setLogin: { _ in }, done: {}), "onboarding-start", to: dir)
        om.accessibility = true; om.inputMonitoring = true; om.loginItem = true; om.tryText = "привет "
        render(OnboardingView(model: om, openAccessibility: {}, openInputMonitoring: {}, setLogin: { _ in }, done: {}), "onboarding-done", to: dir)
        let mm = MenuModel()
        mm.layouts = LayoutManager.shared.layouts.map { .init(id: $0.id, name: $0.name, short: $0.short) }
        mm.currentID = mm.layouts.first(where: { $0.short == "RU" })?.id ?? mm.layouts.first?.id ?? ""
        render(MenuPanelView(model: mm, actions: MenuActions()), "menu-panel", to: dir)
        mm.missingInputMonitoring = true; mm.secureInput = true; mm.secureIsGlitch = true; mm.recording = true
        render(MenuPanelView(model: mm, actions: MenuActions()), "menu-panel-warnings", to: dir)
        for (name, app) in [("menubar-light", NSAppearance.Name.aqua), ("menubar-dark", .darkAqua)] {
            let img = MenuGlyph.image(height: 15)
            render(HStack(spacing: 4) {
                Image(nsImage: img).renderingMode(.template)
                Text("RU").font(.custom("Helvetica Neue", size: 13).weight(.bold))
            }
            .foregroundStyle(app == .darkAqua ? Color.white : Color.black)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(app == .darkAqua ? Color(white: 0.16) : Color(white: 0.93)), name, to: dir, appearance: app)
        }
    }
}
