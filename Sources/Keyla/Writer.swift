import Cocoa
import SwiftUI

final class WriterModel: ObservableObject {
    @Published var original = ""
    @Published var result = ""
    @Published var mode: WriteMode = .fix
    @Published var loading = false
    @Published var error: String?
    @Published var notes: [String] = []
    @Published var offline = false
}

struct WriterView: View {
    @ObservedObject var model: WriterModel
    var onRun: () -> Void
    var onApply: () -> Void
    var onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mode as the headline, like "Sold Services"
            HStack(alignment: .firstTextBaseline) {
                Text(model.mode.title).font(K.title(30)).foregroundStyle(K.ink)
                Spacer()
                if model.loading { ProgressView().controlSize(.small).tint(K.ink) }
                Text(model.offline ? "офлайн" : "AI").font(K.text(12, .medium)).foregroundStyle(K.muted)
            }
            .padding(.horizontal, K.s5).padding(.top, 40)

            FlowRow(spacing: K.s3) {
                ForEach(WriteMode.allCases) { m in
                    Button { model.mode = m; onRun() } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(m.title).font(K.text(13, model.mode == m ? .bold : .regular))
                                .foregroundStyle(model.mode == m ? K.ink : K.muted)
                            Rectangle().fill(model.mode == m ? K.ink : .clear).frame(height: 2)
                        }
                        .fixedSize().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.mode == m ? .isSelected : [])
                }
            }
            .padding(.horizontal, K.s5).padding(.top, K.s3)
            Rule()

            ScrollView {
                Text(model.original).font(K.text(13)).foregroundStyle(K.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 72)
            .padding(.horizontal, K.s5).padding(.vertical, K.s3)
            Rule()

            TextEditor(text: $model.result)
                .font(K.text(18)).foregroundStyle(K.ink).lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 170)
                .padding(.horizontal, K.s5 - 5).padding(.vertical, K.s2)
                .accessibilityLabel("Результат")

            if let e = model.error {
                Text(e).font(K.text(12, .medium)).foregroundStyle(K.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(K.signal))
                    .padding(.horizontal, K.s5).padding(.bottom, K.s2)
            }
            if !model.notes.isEmpty {
                Text(model.notes.prefix(4).joined(separator: "   ·   ")).font(K.text(12)).foregroundStyle(K.muted)
                    .lineLimit(2).padding(.horizontal, K.s5).padding(.bottom, K.s2)
            }
            Rule()

            // Bottom grid from the reference: round action | secondary actions
            HStack(spacing: 0) {
                Button("Заменить", action: onApply)
                    .buttonStyle(CircleButtonStyle(size: 96))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.result.isEmpty || model.loading)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(K.rule).frame(width: 1)
                HStack(spacing: K.s4) {
                    Button("Копировать", action: onCopy).buttonStyle(TextLinkStyle()).disabled(model.result.isEmpty)
                    Button("Ещё раз", action: onRun).buttonStyle(TextLinkStyle()).disabled(model.loading)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 132)
        }
        .frame(width: 600)
        .background(K.paper)
        .tint(K.ink)
    }
}

/// ⌃⌥G: take the selected text from any app, rewrite it, put it back.
final class WriterController {
    static let shared = WriterController()
    private let model = WriterModel()
    private var window: NSPanel?
    private var targetApp: NSRunningApplication?
    private var task: Task<Void, Never>?

    func invoke() {
        targetApp = NSWorkspace.shared.frontmostApplication
        TextInjector.selectedText { [self] text in
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                HUD.shared.show("Выделите текст", "и нажмите ⌃⌥G ещё раз", force: true)
                return
            }
            model.original = text
            model.result = ""
            model.notes = []
            model.error = nil
            showWindow()
            run()
        }
    }

    private func showWindow() {
        if window == nil {
            let view = WriterView(model: model, onRun: { [weak self] in self?.run() },
                                  onApply: { [weak self] in self?.apply() },
                                  onCopy: { [weak self] in self?.copy() })
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(red: 0.855, green: 0.831, blue: 0.796, alpha: 1)
            w.contentViewController = NSHostingController(rootView: view)
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func run() {
        task?.cancel()
        let text = model.original, mode = model.mode
        model.error = nil
        model.notes = []
        if !LLM.isConfigured {
            // No model connected: offline fix with the macOS dictionaries.
            let (fixed, notes) = Spell.localFix(text)
            model.offline = true
            model.result = fixed
            model.notes = notes.isEmpty ? ["Ошибок не найдено"] : notes
            if mode != .fix { model.error = "Режим «\(mode.title)» требует AI-модель — подключите её в Настройках → AI." }
            return
        }
        model.offline = false
        model.loading = true
        task = Task { @MainActor in
            do {
                let out = try await Writer.run(text, mode: mode)
                if !Task.isCancelled { model.result = out }
            } catch {
                if !Task.isCancelled { model.error = error.localizedDescription }
            }
            model.loading = false
        }
    }

    private func apply() {
        let text = model.result
        window?.orderOut(nil)
        targetApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { TextInjector.paste(text) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.result, forType: .string)
    }
}
