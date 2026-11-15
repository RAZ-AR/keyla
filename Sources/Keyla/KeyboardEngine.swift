import Cocoa
import Carbon

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<KeyboardEngine>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = engine.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker { return Unmanaged.passUnretained(event) }
    return engine.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Watches keystrokes system-wide, rebuilds the current word from key codes and fixes
/// wrong-layout words / typos when a word ends.
final class KeyboardEngine {
    static let shared = KeyboardEngine()
    fileprivate(set) var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let layouts = LayoutManager.shared

    private struct Undo {
        let original: String      // what the user actually typed
        let replaced: String      // what Keyla put instead
        let boundary: String
        let fromLayout: KeyLayout?  // nil = spelling fix, no layout change
        let strokes: [Stroke]
        let time = Date()
    }
    private struct LastWord { let strokes: [Stroke]; let shown: String; let layout: KeyLayout; let boundary: String }

    private var word: [Stroke] = []
    private var lastWord: LastWord?
    private var pendingUndo: Undo?
    private var sentence = ""

    private var shiftDownAt: Date?
    private var otherKeySinceShift = false
    private var lastShiftTap: Date?
    private var roptTimer: Timer?
    private var holdRecording = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        runLoopSource = src
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        runLoopSource = nil
    }

    func resetAll() {
        word = []
        lastWord = nil
        pendingUndo = nil
        sentence = ""
    }

    private var frontAppExcluded: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Settings.excludedApps.contains(id)
    }

    // MARK: Event handling — returns true to swallow the event

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown: return keyDown(event)
        case .flagsChanged: flagsChanged(event); return false
        default: resetAll(); return false   // mouse click: caret moved
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        otherKeySinceShift = true
        lastShiftTap = nil
        if !holdRecording { roptTimer?.invalidate(); roptTimer = nil }

        // Global hotkeys: ⌃⌥G — writing assistant, ⌃⌥V — dictation toggle
        if flags.contains(.maskControl) && flags.contains(.maskAlternate) && !flags.contains(.maskCommand) {
            if kc == 5 { DispatchQueue.main.async { WriterController.shared.invoke() }; return true }
            if kc == 9 { DispatchQueue.main.async { VoiceController.shared.toggle() }; return true }
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { resetAll(); return false }

        if kc == 51 { // Backspace
            if let u = pendingUndo, Date().timeIntervalSince(u.time) < 6 {
                pendingUndo = nil
                undo(u)
                return true
            }
            if !word.isEmpty { word.removeLast() } else { lastWord = nil }
            if !sentence.isEmpty { sentence.removeLast() }
            return false
        }
        pendingUndo = nil

        if flags.contains(.maskAlternate) { word = []; lastWord = nil; return false }

        switch kc {
        case 49: return wordEnded(boundary: " ")
        case 36, 76, 48: // Return / Enter / Tab: never rewrite — the text may already be sent
            word = []; lastWord = nil; sentence = ""
            return false
        case 53, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            resetAll()
            return false
        default:
            guard let cur = layouts.current, cur.hasKey(kc) else { word = []; lastWord = nil; return false }
            let s = Stroke(keyCode: kc, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            if word.isEmpty { lastWord = nil }
            word.append(s)
            sentence += cur.char(s)
            if sentence.count > 600 { sentence = String(sentence.suffix(300)) }
            return false
        }
    }

    private func flagsChanged(_ event: CGEvent) {
        let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Double tap of Shift → convert last word / selection to the other layout
        if kc == 56 || kc == 60 {
            if flags.contains(.maskShift) {
                shiftDownAt = Date()
                otherKeySinceShift = false
            } else if let d = shiftDownAt, !otherKeySinceShift, Date().timeIntervalSince(d) < 0.3 {
                if let last = lastShiftTap, Date().timeIntervalSince(last) < 0.45 {
                    lastShiftTap = nil
                    if Settings.doubleShift { DispatchQueue.main.async { self.manualConvert() } }
                } else {
                    lastShiftTap = Date()
                }
            }
            return
        }
        otherKeySinceShift = true

        // Hold right ⌥ → push-to-talk dictation
        if kc == 61 && Settings.pushToTalk {
            if flags.contains(.maskAlternate) {
                roptTimer?.invalidate()
                roptTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    self?.holdRecording = true
                    VoiceController.shared.start()
                }
            } else {
                roptTimer?.invalidate(); roptTimer = nil
                if holdRecording { holdRecording = false; VoiceController.shared.stop() }
            }
        }
    }

    // MARK: Word end — auto-switch layout, then spelling

    private func wordEnded(boundary: String) -> Bool {
        let strokes = word
        word = []
        guard !strokes.isEmpty, let cur = layouts.current else {
            lastWord = nil
            sentence += boundary
            return false
        }
        let typed = cur.text(strokes)
        let excluded = frontAppExcluded || AX.isSecureField()

        if !excluded && Settings.autoSwitch {
            for alt in layouts.alternates(for: cur) {
            let other = alt.text(strokes)
            if Detector.shouldSwitch(cur: typed, curLang: cur.lang, alt: other, altLang: alt.lang) {
                TextInjector.replace(deleting: typed.count, with: other + boundary)
                layouts.select(alt)
                Stats.bump("switch")
                pendingUndo = Undo(original: typed, replaced: other, boundary: boundary, fromLayout: cur, strokes: strokes)
                lastWord = LastWord(strokes: strokes, shown: other, layout: alt, boundary: boundary)
                sentence = String(sentence.dropLast(typed.count)) + other + boundary
                DispatchQueue.main.async { HUD.shared.show("\(typed) → \(other)", "⌫ — отменить", badge: alt.short) }
                return true
            }
            }
        }
        lastWord = LastWord(strokes: strokes, shown: typed, layout: cur, boundary: boundary)
        sentence += boundary

        guard !excluded else { return false }
        let core = Detector.core(typed)
        let checkable = core.count >= 3 && !typed.contains(where: { $0.isNumber })
            && core != core.uppercased() && !Settings.exceptions.contains(core.lowercased())
        if checkable && !Spell.isValid(core, cur.lang) {
            if Settings.autocorrect, let fix = Spell.correction(core, cur.lang), fix != core {
                let fixed = typed.replacingOccurrences(of: core, with: fix)
                TextInjector.replace(deleting: typed.count, with: fixed + boundary)
                Stats.bump("typo")
                pendingUndo = Undo(original: typed, replaced: fixed, boundary: boundary, fromLayout: nil, strokes: strokes)
                lastWord = nil
                sentence = String(sentence.dropLast(typed.count + boundary.count)) + fixed + boundary
                DispatchQueue.main.async { HUD.shared.show("\(core) → \(fix)", "⌫ — вернуть как было", badge: "Aa") }
                return true
            }
            if Settings.spellHints {
                let g = Spell.guesses(core, cur.lang).prefix(3)
                DispatchQueue.main.async {
                    HUD.shared.show("\(core)?", g.isEmpty ? "Нет в словаре" : g.joined(separator: " · "), badge: "Aa", duration: 2.2)
                }
            }
        }

        // Sentence finished → quick grammar hint
        if Settings.grammarHints, let last = typed.last, ".!?".contains(last) {
            let s = sentence.trimmingCharacters(in: .whitespaces)
            sentence = ""
            if s.split(separator: " ").count >= 3, let hint = Spell.grammarHint(s, cur.lang) {
                DispatchQueue.main.async { HUD.shared.show("Грамматика", hint, badge: "¶", duration: 3.5) }
            }
        }
        return false
    }

    private func undo(_ u: Undo) {
        TextInjector.replace(deleting: u.replaced.count + u.boundary.count, with: u.original)
        if let from = u.fromLayout { layouts.select(from) }
        Settings.addException(u.original)     // don't touch this word again
        word = u.fromLayout != nil ? u.strokes : []
        lastWord = nil
        HUD.shared.show(u.original, "Запомнил — больше не трогаю", badge: "↩")
    }

    // MARK: Manual conversion (double Shift)

    func manualConvert() {
        guard let cur = layouts.current else { return }
        pendingUndo = nil

        if !word.isEmpty, let alt = layouts.alternate(for: cur) {             // word in progress
            let shown = cur.text(word), other = alt.text(word)
            TextInjector.replace(deleting: shown.count, with: other)
            layouts.select(alt)
            HUD.shared.show("\(shown) → \(other)", badge: alt.short)
            return
        }
        if let lw = lastWord, let target = layouts.alternate(for: lw.layout) { // just-finished word
            let other = target.text(lw.strokes)
            TextInjector.replace(deleting: lw.shown.count + lw.boundary.count, with: other + lw.boundary)
            layouts.select(target)
            lastWord = LastWord(strokes: lw.strokes, shown: other, layout: target, boundary: lw.boundary)
            HUD.shared.show("\(lw.shown) → \(other)", badge: target.short)
            return
        }
        TextInjector.selectedText { [self] sel in                               // selection
            guard let sel, !sel.isEmpty, let alt = layouts.alternate(for: cur) else {
                if let alt = layouts.alternate(for: cur) { layouts.select(alt) }
                return
            }
            let (from, to) = cur.coverage(sel) >= alt.coverage(sel) ? (cur, alt) : (alt, cur)
            let converted = KeyLayout.convert(sel, from: from, to: to)
            TextInjector.paste(converted)
            layouts.select(to)
            HUD.shared.show("Выделение → \(to.short)", badge: to.short)
        }
    }
}
