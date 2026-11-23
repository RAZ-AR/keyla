import Cocoa
import SwiftUI

/// "Запомнить «барев»?" — a small clickable card near the caret.
/// Shown when the user corrects Keyla (⌫ after a fix, double ⇧ on Keyla's conversion)
/// or keeps typing the same word the dictionaries don't know (Armenian in Latin/Cyrillic, slang, names).
/// "Запомнить" puts the word into "My words": never switched, never corrected, not underlined,
/// and taught to the macOS spell checker so other apps stop flagging it too.
final class LearnPrompt {
    static let shared = LearnPrompt()

    final class Model: ObservableObject {
        @Published var word = ""
        @Published var reason = ""
    }

    let model = Model()
    private let panel: NSPanel
    private let host: FirstMouseHostingView<LearnView>
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host = FirstMouseHostingView(rootView: LearnView(model: model, remember: {}, dismiss: {}))
        panel.contentView = host
        host.rootView = LearnView(model: model,
                                  remember: { [weak self] in self?.remember() },
                                  dismiss: { [weak self] in self?.decline() })
    }

    var isVisible: Bool { panel.isVisible }

    /// Ask about `word` unless it's already known, declined before, or asking is off.
    func ask(_ word: String, reason: String) {
        let w = word.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard Settings.askToLearn, w.count >= 2, !Settings.exceptions.contains(w.lowercased()), !Settings.declined.contains(w.lowercased()) else { return }
        HUD.shared.hide()
        model.word = w
        model.reason = reason
        let size = host.fittingSize
        var origin: NSPoint
        if let a = AX.caretRect() {
            origin = NSPoint(x: a.minX - 8, y: a.minY - size.height - 6)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 14, y: m.y - size.height - 14)
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = max(origin.y, f.minY + 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let w2 = DispatchWorkItem { [weak self] in self?.hide() }   // no answer = not now (ask again later)
        hideWork = w2
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w2)
    }

    private func remember() {
        let w = model.word
        Settings.remember(w)
        hide()
        HUD.shared.show("Запомнил «\(w)»", "Слово в «Моих словах» — Настройки → Правописание", badge: "✓", duration: 1.8, force: true)
    }

    private func decline() {
        Settings.decline(model.word)
        hide()
    }

    func hide() {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }
}

struct LearnView: View {
    @ObservedObject var model: LearnPrompt.Model
    var remember: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Запомнить «\(model.word)»?").font(K.text(14, .bold)).foregroundStyle(.white).lineLimit(1)
                Text(model.reason).font(K.text(12)).foregroundStyle(.white.opacity(0.66)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 210, alignment: .leading)
            }
            Button("Нет", action: dismiss)
                .buttonStyle(.plain).font(K.text(13)).foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 6)
                .accessibilityLabel("Не запоминать")
            Button(action: remember) {
                Text("Запомнить").font(K.text(13, .bold)).foregroundStyle(K.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(K.signal))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(K.ink))
        .fixedSize()
    }
}

/// Lets the first click on a non-key panel press the button instead of just focusing the window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
