import Cocoa

/// Spelling and "wrong layout" decisions, built on the system spell checker (offline, ~20 languages).
enum Spell {
    private static var langCache: [String: String?] = [:]

    static func lang(_ l: String) -> String? {
        if let c = langCache[l] { return c }
        let avail = NSSpellChecker.shared.availableLanguages
        let r = avail.contains(l) ? l : avail.first { $0.hasPrefix(l) }
        langCache[l] = r
        return r
    }

    static func isValid(_ w: String, _ l: String) -> Bool {
        guard let sl = lang(l) else { return false }
        let r = NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: sl, wrap: false,
                                                    inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }

    static func guesses(_ w: String, _ l: String) -> [String] {
        guard let sl = lang(l) else { return [] }
        return NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length),
                                             in: w, language: sl, inSpellDocumentWithTag: 0) ?? []
    }

    static func correction(_ w: String, _ l: String) -> String? {
        guard let sl = lang(l) else { return nil }
        return NSSpellChecker.shared.correction(forWordRange: NSRange(location: 0, length: (w as NSString).length),
                                                in: w, language: sl, inSpellDocumentWithTag: 0)
    }

    /// First grammar problem in a sentence, as a human-readable hint.
    static func grammarHint(_ sentence: String, _ l: String) -> String? {
        guard let sl = lang(l) else { return nil }
        var details: NSArray?
        let r = NSSpellChecker.shared.checkGrammar(of: sentence, startingAt: 0, language: sl, wrap: false,
                                                   inSpellDocumentWithTag: 0, details: &details)
        guard r.location != NSNotFound, let d = (details as? [[String: Any]])?.first else { return nil }
        var hint = (d["NSGrammarUserDescription"] as? String) ?? "Проверьте фразу"
        if let fixes = d["NSGrammarCorrections"] as? [String], !fixes.isEmpty {
            hint += " → " + fixes.prefix(2).joined(separator: ", ")
        }
        return hint
    }

    /// Offline "fix my text": spelling + grammar corrections from the system checker.
    static func localFix(_ text: String) -> (String, [String]) {
        let ns = text as NSString
        let types = NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue
        let results = NSSpellChecker.shared.check(text, range: NSRange(location: 0, length: ns.length), types: types,
                                                  options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        let language = NSSpellChecker.shared.language()
        var edits: [(NSRange, String)] = []
        var notes: [String] = []
        for r in results {
            if r.resultType == .spelling {
                let word = ns.substring(with: r.range)
                if let fix = NSSpellChecker.shared.correction(forWordRange: r.range, in: text, language: language, inSpellDocumentWithTag: 0)
                    ?? NSSpellChecker.shared.guesses(forWordRange: r.range, in: text, language: nil, inSpellDocumentWithTag: 0)?.first {
                    edits.append((r.range, fix))
                    notes.append("«\(word)» → «\(fix)»")
                } else {
                    notes.append("«\(word)» — неизвестное слово")
                }
            } else if r.resultType == .grammar {
                for d in r.grammarDetails ?? [] {
                    let desc = (d["NSGrammarUserDescription"] as? String) ?? "Грамматика"
                    if let rv = d["NSGrammarRange"] as? NSValue, let fix = (d["NSGrammarCorrections"] as? [String])?.first {
                        let rr = rv.rangeValue
                        edits.append((NSRange(location: r.range.location + rr.location, length: rr.length), fix))
                    }
                    notes.append(desc)
                }
            }
        }
        let out = NSMutableString(string: text)
        var lastStart = Int.max
        for (range, fix) in edits.sorted(by: { $0.0.location > $1.0.location }) where NSMaxRange(range) <= lastStart {
            out.replaceCharacters(in: range, with: fix)
            lastStart = range.location
        }
        return (out as String, notes)
    }
}

enum Detector {
    static func core(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet.letters.inverted) }

    /// Decide whether `cur` (what appeared on screen) was really meant as `alt` (same keys, other layout).
    /// `context` is the language of the previous word in this sentence, if known.
    static func shouldSwitch(cur: String, curLang: String, alt: String, altLang: String, context: String? = nil) -> Bool {
        let c = core(cur), a = core(alt)
        guard a.count >= 2, c.count >= 1 else { return false }
        if Settings.exceptions.contains(cur.lowercased()) || Settings.exceptions.contains(c.lowercased()) { return false }
        if Settings.learnedSwitch.contains(c.lowercased()) { return true }
        if cur.contains(where: { $0.isNumber }) { return false }
        if cur.contains("@") || cur.contains("://") { return false }
        // Inner punctuation (e.g. "ghbdtn,rfr") — not a single word in the other layout either; keep it simple.
        if a.contains(where: { !$0.isLetter && $0 != "-" && $0 != "'" && $0 != "’" }) { return false }

        if Spell.isValid(c, curLang) { return false }
        if Spell.isValid(a, altLang) { return true }
        guard a.count >= (context == altLang ? 3 : 4) else { return false }
        // Both unknown: if the current word is one typo away from a real word, it's a typo, not a layout mistake.
        if Spell.guesses(c, curLang).contains(where: { levenshtein($0.lowercased(), c.lowercased()) <= 1 }) { return false }
        // The sentence is already in the other language: a smaller lead is enough.
        let margin = context == altLang ? 0.15 : 0.6
        return plausibility(a, altLang) - plausibility(c, curLang) > margin
    }

    private static let vowels: [String: Set<Character>] = [
        "en": Set("aeiouy"), "ru": Set("аеёиоуыэюя"), "uk": Set("аеєиіїоуюя"), "be": Set("аеёіоуыэюя"),
        "de": Set("aeiouyäöü"), "fr": Set("aeiouyéèêàâîïôûù"), "es": Set("aeiouáéíóú"),
    ]

    /// Rough "does this look like a word in this language" score.
    static func plausibility(_ w: String, _ lang: String) -> Double {
        let s = w.lowercased()
        let v = vowels[lang] ?? (s.unicodeScalars.first.map { $0.value >= 0x400 && $0.value < 0x500 } == true ? vowels["ru"]! : vowels["en"]!)
        var run = 0, maxRun = 0, vc = 0
        for ch in s {
            if v.contains(ch) { vc += 1; run = 0 } else { run += 1; maxRun = max(maxRun, run) }
        }
        let ratio = Double(vc) / Double(max(s.count, 1))
        var score = 1.0 - abs(ratio - 0.42) * 2.5 - Double(max(0, maxRun - 3)) * 0.6
        if lang == "ru" || lang == "uk" || lang == "be", let f = s.first, "ьъы".contains(f) { score -= 1 }
        return score
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
