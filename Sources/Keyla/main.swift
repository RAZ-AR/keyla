import Cocoa

/// `Keyla --selftest` checks layout detection and spelling without needing any permissions.
enum SelfTest {
    static func run() -> Int32 {
        Settings.registerDefaults()
        let lm = LayoutManager.shared
        lm.reload()
        print("Включённые раскладки:", lm.layouts.map { "\($0.name) [\($0.lang)]" })
        guard let en = lm.installed(id: "com.apple.keylayout.US") ?? lm.installed(id: "com.apple.keylayout.ABC"),
              let ru = lm.installed(id: "com.apple.keylayout.Russian") ?? lm.installed(id: "com.apple.keylayout.RussianWin") else {
            print("Нет раскладок US/Russian"); return 1
        }
        print("Словари проверки:", ["en", "ru"].map { "\($0)→\(Spell.lang($0) ?? "нет")" })
        // (typed text, which layout it was typed in, expected: should switch?)
        let cases: [(String, KeyLayout, KeyLayout, Bool)] = [
            ("ghbdtn", en, ru, true), ("rfr", en, ru, true), ("ltkf", en, ru, true), ("yt", en, ru, true),
            ("hello", en, ru, false), ("world", en, ru, false), ("recieve", en, ru, false), ("is", en, ru, false),
            ("руддщ", ru, en, true), ("цщкдв", ru, en, true), ("ерфтлы", ru, en, true),
            ("привет", ru, en, false), ("как", ru, en, false), ("превет", ru, en, false), ("мама", ru, en, false),
        ]
        var fails = 0
        for (typed, from, to, expect) in cases {
            let other = KeyLayout.convert(typed, from: from, to: to)
            let got = Detector.shouldSwitch(cur: typed, curLang: from.lang, alt: other, altLang: to.lang)
            let ok = got == expect
            if !ok { fails += 1 }
            print(ok ? "✅" : "❌", typed, "→", got ? other : "(оставить)")
        }
        // Context: inside a Russian sentence, a borderline unknown word leans Russian.
        let ctx = [("ghbdtnbr", en, ru)]   // "приветик" — not in the dictionary
        for (typed, from, to) in ctx {
            let other = KeyLayout.convert(typed, from: from, to: to)
            let without = Detector.shouldSwitch(cur: typed, curLang: from.lang, alt: other, altLang: to.lang)
            let with = Detector.shouldSwitch(cur: typed, curLang: from.lang, alt: other, altLang: to.lang, context: to.lang)
            print(with ? "✅" : "❌", "контекст:", typed, "→", other, "| без контекста:", without, "с контекстом:", with)
            if !with { fails += 1 }
        }
        print("Опечатка 'recieve' →", Spell.correction("recieve", "en") ?? "-", "| 'превет' →", Spell.guesses("превет", "ru").prefix(3))
        let (fixed, notes) = Spell.localFix("I has a apple and i recieve it yesterday.")
        print("Офлайн-исправление:", fixed, notes)
        print(fails == 0 ? "Все проверки пройдены" : "Ошибок: \(fails)")
        return fails == 0 ? 0 : 2
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
    Snapshots.run(CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
