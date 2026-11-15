import Cocoa
import SwiftUI

final class OnboardingModel: ObservableObject {
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var loginItem = false
    @Published var tryText = ""
    var allGranted: Bool { accessibility && inputMonitoring }
    var triedOK: Bool { tryText.lowercased().contains("привет") || tryText.lowercased().contains("hello") }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var openAccessibility: () -> Void
    var openInputMonitoring: () -> Void
    var setLogin: (Bool) -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keyla").font(K.title(34)).foregroundStyle(K.ink)
                    Text("Три шага — и раскладка\nбудет переключаться сама.").font(K.text(15)).foregroundStyle(K.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                KeylaMark(size: 112)
            }
            .padding(.horizontal, K.s5).padding(.top, 44).padding(.bottom, K.s4)
            Rule()

            step(1, "Универсальный доступ", "Чтобы исправлять слова прямо в тексте.",
                 done: model.accessibility, action: ("Открыть", openAccessibility))
            Rule()
            step(2, "Мониторинг ввода", "Без него macOS не показывает Keyla нажатия клавиш.",
                 done: model.inputMonitoring, action: ("Открыть", openInputMonitoring))
            Rule()
            HStack(alignment: .center, spacing: K.s3) {
                Text("3").font(K.numeral(44)).foregroundStyle(K.ink).frame(width: 36, alignment: .leading)
                Toggle(isOn: Binding(get: { model.loginItem }, set: { setLogin($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Запускать при входе").font(K.text(15, .bold))
                        Text("Keyla всегда под рукой после перезагрузки.").font(K.text(12)).foregroundStyle(K.muted)
                    }
                }
                .toggleStyle(CircleToggleStyle())
            }
            .padding(.horizontal, K.s5).padding(.vertical, 6)
            Rule()

            // Try it right here
            VStack(alignment: .leading, spacing: 8) {
                Text("Попробуйте: в английской раскладке наберите  ghbdtn  и пробел")
                    .font(K.text(12, .medium)).foregroundStyle(K.muted)
                HStack {
                    TextField("", text: $model.tryText)
                        .textFieldStyle(.plain).font(K.text(22)).foregroundStyle(K.ink)
                        .accessibilityLabel("Поле для пробы")
                        .disabled(!model.allGranted)
                    if model.triedOK {
                        Text("Работает").font(K.text(13, .bold)).foregroundStyle(K.ink)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(K.signal))
                    }
                }
                Rectangle().fill(K.ink).frame(height: 1)
                if !model.allGranted {
                    Text("Станет доступно после шагов 1 и 2.").font(K.text(12)).foregroundStyle(K.muted)
                }
            }
            .padding(.horizontal, K.s5).padding(.vertical, K.s4)
            Rule()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.allGranted ? "Всё готово" : "Можно закончить позже")
                        .font(K.text(14, .bold)).foregroundStyle(K.ink)
                    Text("Keyla живёт в строке меню — значок ● рядом с часами.")
                        .font(K.text(12)).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, K.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(K.rule).frame(width: 1)
                Button(model.allGranted ? "Готово" : "Позже", action: done)
                    .buttonStyle(CircleButtonStyle(size: 88, fill: model.allGranted ? K.signal : K.ink,
                                                   label: model.allGranted ? K.ink : K.paper))
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 200)
            }
            .frame(height: 124)
        }
        .frame(width: 560)
        .background(K.paper)
        .tint(K.ink)
    }

    private func step(_ n: Int, _ title: String, _ hint: String, done: Bool, action: (String, () -> Void)) -> some View {
        HStack(alignment: .center, spacing: K.s3) {
            Text("\(n)").font(K.numeral(44)).foregroundStyle(K.ink).frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(K.text(15, .bold)).foregroundStyle(K.ink)
                Text(hint).font(K.text(12)).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if done {
                ZStack {
                    Circle().fill(K.ink)
                    Circle().fill(K.signal).frame(width: 8, height: 8).offset(x: -4, y: 4)
                }
                .frame(width: 24, height: 24)
                .accessibilityLabel("готово")
            } else {
                Button(action.0 + " →", action: action.1)
                    .buttonStyle(TextLinkStyle())
                    .padding(.horizontal, 14).padding(.vertical, 2)
                    .background(Capsule().fill(K.signal))
            }
        }
        .padding(.horizontal, K.s5).padding(.vertical, 14)
        .animation(K.quick, value: done)
    }
}

/// First-run window. Polls permissions every second so the checkmarks appear as soon as the user flips them.
final class OnboardingController {
    static let shared = OnboardingController()
    let model = OnboardingModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show() {
        refresh()
        if window == nil {
            let view = OnboardingView(
                model: model,
                openAccessibility: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                },
                openInputMonitoring: {
                    CGRequestListenEventAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                },
                setLogin: { [weak self] on in
                    LoginItem.set(on)
                    UserDefaults.standard.set(on, forKey: "launchAtLogin")
                    self?.refresh()
                },
                done: { [weak self] in self?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Keyla"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0.855, green: 0.831, blue: 0.796, alpha: 1)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let a = AXIsProcessTrusted(), i = CGPreflightListenEventAccess(), l = LoginItem.isEnabled
        if model.accessibility != a { model.accessibility = a }
        if model.inputMonitoring != i { model.inputMonitoring = i }
        if model.loginItem != l { model.loginItem = l }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.set(true, forKey: "onboarded")
        window?.close()
    }
}
