import Cocoa
import SwiftUI

/// State shown in the menu bar panel.
final class MenuModel: ObservableObject {
    struct Layout: Identifiable { let id: String; let name: String; let short: String }
    @Published var layouts: [Layout] = []
    @Published var currentID = ""
    @Published var missingAccessibility = false
    @Published var missingInputMonitoring = false
    @Published var secureInput = false
    @Published var secureOwner: String?
    @Published var secureIsGlitch = false
    @Published var secureStillStuck = false   // lock + unlock didn't help
    @Published var updateVersion: String?
    @Published var updateBusy = false
    @Published var recording = false
    @Published var switchesToday = 0

    var current: Layout? { layouts.first { $0.id == currentID } }
}

struct MenuActions {
    var selectLayout: (String) -> Void = { _ in }
    var openAccessibility: () -> Void = {}
    var openInputMonitoring: () -> Void = {}
    var writer: () -> Void = {}
    var convert: () -> Void = {}
    var voice: () -> Void = {}
    var settings: () -> Void = {}
    var quit: () -> Void = {}
    var lockScreen: () -> Void = {}
    var installUpdate: () -> Void = {}
}

/// Row button: full-width hit area, subtle ink wash when pressed.
private struct RowStyle: ButtonStyle {
    var vertical: CGFloat = 11
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, K.s4).padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(K.ink.opacity(configuration.isPressed ? 0.08 : 0))
            .contentShape(Rectangle())
    }
}

struct MenuPanelView: View {
    @ObservedObject var model: MenuModel
    var actions: MenuActions
    @AppStorage("autoSwitch") private var autoSwitch = true
    @AppStorage("autocorrect") private var autocorrect = false
    @AppStorage("spellHints") private var spellHints = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            warnings

            // Hero: current layout as a giant code, like the reference's numerals
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    KeylaMark(size: 30)
                    Spacer(minLength: K.s3)
                    Text("Сейчас").font(K.text(12)).foregroundStyle(K.muted)
                    Text(model.current?.name ?? "—").font(K.text(15, .bold)).foregroundStyle(K.ink)
                }
                Spacer()
                Text(model.current?.short ?? "··").font(K.numeral(84)).foregroundStyle(K.ink)
                    .padding(.bottom, -10)
            }
            .frame(height: 112)
            .padding(.horizontal, K.s4).padding(.top, K.s4).padding(.bottom, K.s3)
            .accessibilityElement(children: .combine)

            VStack(spacing: 0) {
                ForEach(model.layouts) { l in
                    let on = l.id == model.currentID
                    Button { actions.selectLayout(l.id) } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().strokeBorder(K.ink, lineWidth: 1.5)
                                Circle().fill(K.ink).scaleEffect(on ? 1 : 0.001)
                            }
                            .frame(width: 14, height: 14)
                            Text(l.name).font(K.text(14, on ? .bold : .regular)).foregroundStyle(K.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(l.short).font(K.text(12, .medium)).foregroundStyle(K.muted)
                        }
                    }
                    .buttonStyle(RowStyle(vertical: 7))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.bottom, K.s2)
            Rule()

            VStack(spacing: 0) {
                Toggle("Автопереключение", isOn: $autoSwitch).toggleStyle(CircleToggleStyle())
                Toggle("Автоисправление опечаток", isOn: $autocorrect).toggleStyle(CircleToggleStyle())
                Toggle("Подсказки по орфографии", isOn: $spellHints).toggleStyle(CircleToggleStyle())
            }
            .padding(.horizontal, K.s4).padding(.vertical, 2)
            Rule()

            Button(action: actions.writer) { row("Помощник письма", "⌃⌥G") }.buttonStyle(RowStyle())
            Button(action: actions.convert) { row("Перевести последнее слово", "⇧⇧") }.buttonStyle(RowStyle())
            Rule()

            // Bottom grid from the reference: round action | text actions
            HStack(spacing: 0) {
                Button(model.recording ? "Стоп" : "Голос", action: actions.voice)
                    .buttonStyle(CircleButtonStyle(size: 76, fill: model.recording ? K.ink : K.signal,
                                                   label: model.recording ? K.paper : K.ink))
                    .help("Диктовка — ⌃⌥V или удерживайте правый ⌥")
                    .frame(maxWidth: .infinity)
                Rectangle().fill(K.rule).frame(width: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: actions.settings) { linkRow("Настройки", "⌘,") }.buttonStyle(.plain)
                    Button(action: actions.quit) { linkRow("Выйти", "⌘Q") }.buttonStyle(.plain)
                }
                .padding(.horizontal, K.s4)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 108)
        }
        .frame(width: 340)
        .background(K.paper)
        .tint(K.ink)
    }

    @ViewBuilder private var warnings: some View {
        if let v = model.updateVersion {
            banner(model.updateBusy ? "Обновляю Keyla до \(v)…" : "Доступна Keyla \(v) — обновить",
                   action: model.updateBusy ? nil : actions.installUpdate)
        }
        if model.missingAccessibility {
            banner("Включите Keyla в «Универсальном доступе»", action: actions.openAccessibility)
        }
        if model.missingInputMonitoring {
            banner("Включите Keyla в «Мониторинге ввода»", action: actions.openInputMonitoring)
        }
        if model.secureInput {
            if model.secureStillStuck {
                banner("Блокировка экрана не помогла: macOS держит «Защищённый ввод». Выйдите из учётной записи и войдите снова или перезагрузите Mac.",
                       action: nil)
            } else if model.secureIsGlitch || model.secureOwner == nil {
                // macOS glitch: loginwindow kept Secure Input. Lock + unlock releases it.
                banner("macOS завис в «Защищённом вводе» — Keyla не видит клавиши. Нажмите: экран заблокируется, после разблокировки всё заработает.",
                       action: actions.lockScreen)
            } else {
                banner("«\(model.secureOwner!)» включил защищённый ввод (поле пароля). Закройте его — и Keyla снова заработает.",
                       action: nil)
            }
        }
    }

    @ViewBuilder private func banner(_ text: String, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { bannerBody(text, arrow: true, fill: K.signal, ink: K.ink) }.buttonStyle(.plain)
        } else {
            bannerBody(text, arrow: false, fill: K.ink, ink: .white)   // informational: ink card, no button
        }
    }

    private func bannerBody(_ text: String, arrow: Bool, fill: Color, ink: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(arrow ? K.ink : K.signal).frame(width: 8, height: 8).padding(.top, 5)
            Text(text).font(K.text(13, .medium)).foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if arrow { Text("→").font(K.text(14, .bold)).foregroundStyle(ink) }
        }
        .padding(.horizontal, K.s4).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1) }
        .contentShape(Rectangle())
    }

    private func row(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title).font(K.text(14)).foregroundStyle(K.ink)
            Spacer()
            Text(key).font(K.text(13)).foregroundStyle(K.muted)
        }
    }

    private func linkRow(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title).font(K.text(14, .medium)).foregroundStyle(K.ink)
            Spacer()
            Text(key).font(K.text(12)).foregroundStyle(K.muted)
        }
        .padding(.vertical, 7).contentShape(Rectangle())
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Borderless panel that drops down from the status item — replaces the system NSMenu.
final class MenuPanelController {
    let model = MenuModel()
    private var panel: KeyPanel?
    private var monitors: [Any] = []
    var actions = MenuActions()
    var isOpen: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton) { isOpen ? close() : open(from: button) }

    func open(from button: NSStatusBarButton) {
        let host = NSHostingView(rootView: MenuPanelView(model: model, actions: actions)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.black.opacity(0.12))))
        let size = host.fittingSize
        let p = panel ?? KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        panel = p

        guard let bw = button.window else { return }
        let b = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        var x = b.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrame(NSRect(x: x, y: b.minY - size.height - 6, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }   // Esc
            return e
        } as Any)
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 },
                                            completionHandler: { p.orderOut(nil) })
    }
}
