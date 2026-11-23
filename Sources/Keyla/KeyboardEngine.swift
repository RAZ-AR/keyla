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
    /// `byKeyla`: the shown text is Keyla's conversion, so converting it back means "that was wrong".
    private struct LastWord { let strokes: [Stroke]; let shown: String; let layout: KeyLayout; let boundary: String; var byKeyla = false }

    private var word: [Stroke] = [] { didSet { if word.isEmpty { midSwitch = nil; vetoWord = false; askWhenWordEnds = false } } }
    /// The user undid a switch inside this word — leave it alone until it ends.
    private var vetoWord = false
    /// Ask "remember?" about the whole word once it's finished (the user undid a switch mid-word).
    private var askWhenWordEnds = false
    /// Set when the current word was switched while typing: (original layout, what was on screen).
    private var midSwitch: (from: KeyLayout, typed: String)?
    /// A one-letter word right before the current one ("z" before "ghbdtn") — fixed together with it.
    private struct Single { let strokes: [Stroke]; let shown: String; let layout: KeyLayout; let boundary: String }
    private var prevSingle: Single?
    private var langStreak = 0
    private var lastWord: LastWord?
    private var pendingUndo: Undo?
    private var sentence = ""
    private var lastLang: String?     // language of the previous word in this sentence

    private var shiftDownAt: Date?
    private var otherKeySinceShift = false
    private var lastShiftTap: Date?
    private var roptTimer: Timer?
    private var holdRecording = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel]
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
        lastLang = nil
        langStreak = 0
        prevSingle = nil
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
        case .scrollWheel:
            DispatchQueue.main.async { InlineMarks.shared.clear() }
            return false
        default:                            // mouse click: caret moved
            let p = event.location
            DispatchQueue.main.async { InlineMarks.shared.mouseDown(at: p) }
            resetAll()
            return false
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
            if !word.isEmpty { word.removeLast() } else { lastWord = nil; prevSingle = nil }
            if !sentence.isEmpty { sentence.removeLast() }
            DispatchQueue.main.async { InlineMarks.shared.caretMovedBack() }
            return false
        }
        pendingUndo = nil

        if flags.contains(.maskAlternate) { word = []; lastWord = nil; return false }

        switch kc {
        case 49: return wordEnded(boundary: " ")
        case 36, 76, 48: // Return / Enter / Tab: never rewrite — the text may already be sent
            word = []; lastWord = nil; sentence = ""; prevSingle = nil
            DispatchQueue.main.async { InlineMarks.shared.clear() }
            return false
        case 53, 115, 116, 117, 119, 121, 123, 124, 125, 126:
            resetAll()
            DispatchQueue.main.async { InlineMarks.shared.clear() }
            return false
        default:
            guard let cur = layouts.current, cur.hasKey(kc) else { word = []; lastWord = nil; return false }
            let s = Stroke(keyCode: kc, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
            if word.isEmpty { lastWord = nil }
            word.append(s)
            sentence += cur.char(s)
            if sentence.count > 600 { sentence = String(sentence.suffix(300)) }
            if Settings.autoSwitch && Settings.instantSwitch && midSwitch == nil && (3...6).contains(word.count) {
                let n = word.count
                DispatchQueue.main.async { self.tryInstant(expect: n) }
            }
            return false
        }
    }

    // MARK: Instant switch while typing

    private func tryInstant(expect n: Int) {
        guard word.count == n, midSwitch == nil, !vetoWord, let cur = layouts.current, !frontAppExcluded, !AX.isSecureField() else { return }
        let typed = cur.text(word)
        for alt in layouts.alternates(for: cur) {
            let other = alt.text(word)
            guard Detector.shouldSwitchPrefix(cur: typed, curLang: cur.lang, alt: other, altLang: alt.lang) else { continue }
            let (extra, lead) = retroSingle(cur: cur, alt: alt)
            TextInjector.replace(deleting: typed.count + extra, with: lead + other)
            layouts.select(alt)
            midSwitch = (cur, typed)
            Stats.bump("switch")
            pendingUndo = Undo(original: typed, replaced: other, boundary: "", fromLayout: cur, strokes: word)
            sentence = String(sentence.dropLast(typed.count)) + other
            HUD.shared.show("\(typed) → \(other)…", "⌫ — отменить", badge: alt.short)
            return
        }
    }

    /// If the word before was a lone letter typed in the same wrong layout ("z" → «я»), fix it too.
    /// Returns how many extra characters to delete and the text to put before the current word.
    private func retroSingle(cur: KeyLayout, alt: KeyLayout) -> (Int, String) {
        defer { prevSingle = nil }
        guard let p = prevSingle, p.layout.id == cur.id else { return (0, "") }
        let a = alt.text(p.strokes)
        guard Detector.common[alt.lang]?.contains(a.lowercased()) == true,
              Detector.common[cur.lang]?.contains(p.shown.lowercased()) != true,
              !Settings.isMine(p.shown) else { return (0, "") }
        return (p.shown.count + p.boundary.count, a + p.boundary)
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
        let vetoed = vetoWord, mid = midSwitch, askNow = askWhenWordEnds
        word = []
        if askNow, let cur = layouts.current {
            let w = Detector.core(cur.text(strokes))
            Settings.sessionIgnored.insert(w.lowercased())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                LearnPrompt.shared.ask(w, reason: "Больше не переключать раскладку на нём")
            }
        }
        guard !strokes.isEmpty, let cur = layouts.current else {
            lastWord = nil
            sentence += boundary
            return false
        }
        let typed = cur.text(strokes)
        let excluded = frontAppExcluded || AX.isSecureField()

        if let mid {                    // already switched while typing — ⌫ right after the space still undoes it
            bumpLang(cur.lang)
            pendingUndo = Undo(original: mid.from.text(strokes), replaced: typed, boundary: boundary, fromLayout: mid.from, strokes: strokes)
            prevSingle = nil
            lastWord = LastWord(strokes: strokes, shown: typed, layout: cur, boundary: boundary, byKeyla: true)
            sentence += boundary
            return false
        }

        if !excluded && Settings.autoSwitch && !vetoed {
            for alt in layouts.alternates(for: cur) {
            let other = alt.text(strokes)
            if Detector.shouldSwitch(cur: typed, curLang: cur.lang, alt: other, altLang: alt.lang,
                                     context: lastLang, streak: langStreak) {
                bumpLang(alt.lang)
                let (extra, lead) = retroSingle(cur: cur, alt: alt)
                TextInjector.replace(deleting: typed.count + extra, with: lead + other + boundary)
                layouts.select(alt)
                Stats.bump("switch")
                pendingUndo = Undo(original: typed, replaced: other, boundary: boundary, fromLayout: cur, strokes: strokes)
                lastWord = LastWord(strokes: strokes, shown: other, layout: alt, boundary: boundary, byKeyla: true)
                sentence = String(sentence.dropLast(typed.count)) + other + boundary
                DispatchQueue.main.async { HUD.shared.show("\(typed) → \(other)", "⌫ — отменить", badge: alt.short) }
                return true
            }
            }
        }
        lastWord = LastWord(strokes: strokes, shown: typed, layout: cur, boundary: boundary)
        sentence += boundary
        let coreLen = Detector.core(typed).count
        prevSingle = coreLen == 1 && typed.count == 1 ? Single(strokes: strokes, shown: typed, layout: cur, boundary: boundary) : nil
        if coreLen >= 2 { bumpLang(cur.lang) }

        guard !excluded else { return false }
        let core = Detector.core(typed)
        let checkable = core.count >= 3 && !typed.contains(where: { $0.isNumber })
            && core != core.uppercased() && !Settings.isMine(core)
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
            // The same unknown word again and again → probably the user's own word: offer to remember it.
            let uses = Settings.noteUnknown(core)
            if uses >= 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    LearnPrompt.shared.ask(core, reason: "Пишете его уже \(uses) \(uses < 5 ? "раза" : "раз") — больше не подчёркивать")
                }
                return false
            }
            if Settings.spellHints {
                let g = Spell.guesses(core, cur.lang).prefix(3)
                let hud = { HUD.shared.show("\(core)?", g.isEmpty ? "Нет в словаре" : g.joined(separator: " · "), badge: "Aa", duration: 2.2) }
                if Settings.inlineMarks {
                    InlineMarks.shared.mark(core: core, typed: typed, boundary: boundary, lang: cur.lang, fallback: hud)
                } else {
                    DispatchQueue.main.async(execute: hud)
                }
            }
        }

        // Sentence finished → quick grammar hint
        if Settings.grammarHints, let last = typed.last, ".!?".contains(last) {
            let s = sentence.trimmingCharacters(in: .whitespaces)
            sentence = ""
            lastLang = nil
            langStreak = 0
            if s.split(separator: " ").count >= 3, let hint = Spell.grammarHint(s, cur.lang) {
                DispatchQueue.main.async { HUD.shared.show("Грамматика", hint, badge: "¶", duration: 3.5) }
            }
        }
        return false
    }

    private func bumpLang(_ l: String) {
        langStreak = lastLang == l ? langStreak + 1 : 1
        lastLang = l
    }

    private func undo(_ u: Undo) {
        TextInjector.replace(deleting: u.replaced.count + u.boundary.count, with: u.original)
        if let from = u.fromLayout { layouts.select(from) }
        // Leave it alone for now and ask whether it's one of the user's words.
        let w = Detector.core(u.original)
        let midWord = u.boundary.isEmpty && u.fromLayout != nil
        word = u.fromLayout != nil ? u.strokes : []
        midSwitch = nil
        vetoWord = midWord
        askWhenWordEnds = midWord
        lastWord = nil
        if midWord {
            HUD.shared.show(u.original, "Вернул как было", badge: "↩")
        } else {
            Settings.sessionIgnored.insert(w.lowercased())
            LearnPrompt.shared.ask(w, reason: u.fromLayout != nil ? "Больше не переключать раскладку на нём" : "Больше не исправлять его")
        }
    }

    // MARK: Manual conversion (double Shift)

    func manualConvert() {
        guard let cur = layouts.current else { return }
        pendingUndo = nil

        if !word.isEmpty, let alt = layouts.alternate(for: cur) {             // word in progress
            let shown = cur.text(word), other = alt.text(word)
            if let m = midSwitch {                                           // undoing Keyla's instant switch
                Settings.sessionIgnored.insert(m.typed.lowercased())
                vetoWord = true
                askWhenWordEnds = true
            }
            else { Settings.learnSwitch(Detector.core(shown)) }
            midSwitch = nil
            TextInjector.replace(deleting: shown.count, with: other)
            layouts.select(alt)
            HUD.shared.show("\(shown) → \(other)", badge: alt.short)
            return
        }
        if let lw = lastWord, let target = layouts.alternate(for: lw.layout) { // just-finished word
            let other = target.text(lw.strokes)
            if lw.byKeyla {                                                   // undoing Keyla's switch
                let w = Detector.core(other)
                Settings.sessionIgnored.insert(w.lowercased())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    LearnPrompt.shared.ask(w, reason: "Больше не переключать раскладку на нём")
                }
            }
            else { Settings.learnSwitch(Detector.core(lw.shown)) }          // user's own fix → remember it
            TextInjector.replace(deleting: lw.shown.count + lw.boundary.count, with: other + lw.boundary)
            layouts.select(target)
            lastWord = LastWord(strokes: lw.strokes, shown: other, layout: target, boundary: lw.boundary, byKeyla: true)
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
