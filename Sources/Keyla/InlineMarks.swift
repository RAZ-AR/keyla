import Cocoa

/// Grammarly-style underlines: a misspelled word gets a thin signal-coloured line right in the text field.
/// Click it → suggestions menu → the word is replaced in place (via Accessibility selection + typing).
/// Works where the app exposes text geometry (most Cocoa apps, Safari, Notes, Mail, Pages…); elsewhere
/// Keyla falls back to the cursor HUD.
final class InlineMarks {
    static let shared = InlineMarks()

    final class Mark {
        let word: String
        let lang: String
        let range: CFRange          // UTF-16 range in the element's text
        let element: AXUIElement
        let pid: pid_t
        let cgRect: CGRect          // global, top-left origin (as AX and CGEvent use)
        let panel: NSPanel
        let created = Date()
        init(word: String, lang: String, range: CFRange, element: AXUIElement, pid: pid_t, cgRect: CGRect, panel: NSPanel) {
            self.word = word; self.lang = lang; self.range = range; self.element = element
            self.pid = pid; self.cgRect = cgRect; self.panel = panel
        }
    }

    private var marks: [Mark] = []
    private var expiry: Timer?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.clear() }
        }
    }

    /// Try to underline `core` (inside `typed`, followed by `boundary`) that was just typed.
    /// Calls `fallback` if the app doesn't expose text geometry.
    func mark(core: String, typed: String, boundary: String, lang: String, fallback: @escaping () -> Void) {
        // Let the app process the keystrokes first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            guard let el = AX.focused(), let caret = AX.selectedRange(el), caret.length == 0 else { fallback(); return }
            let coreOffset = (typed as NSString).range(of: core).location
            guard coreOffset != NSNotFound else { fallback(); return }
            let start = caret.location - (boundary as NSString).length - (typed as NSString).length + coreOffset
            let range = CFRange(location: start, length: (core as NSString).length)
            guard start >= 0, AX.string(el, range) == core,
                  let r = AX.bounds(el, range), r.width > 2, r.height > 4 else { fallback(); return }
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            show(Mark(word: core, lang: lang, range: range, element: el, pid: pid, cgRect: r, panel: makePanel(for: r)))
        }
    }

    private func show(_ m: Mark) {
        marks.append(m)
        if marks.count > 6 { remove(marks[0]) }
        m.panel.orderFrontRegardless()
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            for old in self.marks where Date().timeIntervalSince(old.created) > 90 { self.remove(old) }
        }
    }

    private func makePanel(for r: CGRect) -> NSPanel {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: r.minX, y: h - r.maxY - 3, width: r.width, height: r.height + 3)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        let v = MarkView(frame: NSRect(origin: .zero, size: frame.size))
        v.onClick = { [weak self, weak p] in
            guard let self, let p, let m = self.marks.first(where: { $0.panel === p }) else { return }
            self.menu(for: m)
        }
        p.contentView = v
        return p
    }

    // MARK: Suggestions

    private func menu(for m: Mark) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let guesses = Array(Spell.guesses(m.word, m.lang).prefix(5))
        if guesses.isEmpty {
            let none = NSMenuItem(title: "Нет вариантов", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for g in guesses {
            let item = ClosureItem(title: g) { [weak self] in self?.replace(m, with: g) }
            item.attributedTitle = NSAttributedString(string: g, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureItem(title: "Запомнить «\(m.word)» — моё слово") { [weak self] in
            Settings.remember(m.word)
            self?.remove(m)
        })
        menu.addItem(ClosureItem(title: "Пропустить") { [weak self] in self?.remove(m) })
        let v = m.panel.contentView!
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: v)
    }

    private func replace(_ m: Mark, with fix: String) {
        let caret = AX.selectedRange(m.element)
        guard AX.string(m.element, m.range) == m.word else {
            HUD.shared.show("Текст изменился", "Не удалось заменить «\(m.word)»", badge: "Aa", force: true)
            clear(); return
        }
        NSRunningApplication(processIdentifier: m.pid)?.activate()
        AX.select(m.element, m.range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard AX.selectedText() == m.word else {
                HUD.shared.show("Не удалось выделить слово", "Исправьте вручную: \(fix)", badge: "Aa", force: true)
                clear(); return
            }
            TextInjector.type(fix)
            Stats.bump("typo")
            let delta = (fix as NSString).length - m.range.length
            if let caret, caret.location >= m.range.location + m.range.length {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    AX.select(m.element, CFRange(location: caret.location + delta, length: 0))
                }
            }
            clear()
        }
    }

    // MARK: Lifecycle

    /// A click outside every mark means the caret moved — drop them.
    func mouseDown(at p: CGPoint) {
        if marks.contains(where: { $0.cgRect.insetBy(dx: -2, dy: -4).contains(p) }) { return }
        clear()
    }

    /// After Backspace: drop marks the caret has moved into.
    func caretMovedBack() {
        guard !marks.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard let el = AX.focused(), let c = AX.selectedRange(el) else { clear(); return }
            for m in marks where c.location < m.range.location + m.range.length { remove(m) }
        }
    }

    func clear() {
        for m in marks { m.panel.orderOut(nil) }
        marks.removeAll()
        expiry?.invalidate()
        expiry = nil
    }

    private func remove(_ m: Mark) {
        m.panel.orderOut(nil)
        marks.removeAll { $0 === m }
    }
}

private final class MarkView: NSView {
    var onClick: (() -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        // A faint wash over the word. Also needed for clicks: fully transparent pixels let the mouse fall through.
        NSColor(red: 0.937, green: 0.290, blue: 0.180, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 2, yRadius: 2).fill()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.setLineDash([0.1, 4], count: 2, phase: 0)   // round dots
        path.move(to: NSPoint(x: 2, y: 1.5))
        path.line(to: NSPoint(x: bounds.width - 1, y: 1.5))
        NSColor(red: 0.937, green: 0.290, blue: 0.180, alpha: 1).setStroke()   // K.signal
        path.stroke()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class ClosureItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
