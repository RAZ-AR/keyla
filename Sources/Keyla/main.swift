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
        // Short words: with no context, and inside a Russian sentence.
        for (typed, ctx, expect) in [("yt", nil, true), ("nj", nil, true), ("xnj", nil, true), ("e;t", nil, true),
                                     ("ns", nil, true), ("z", nil, false), ("z", "ru", true), ("b", "ru", true),
                                     ("vs", nil, false), ("vs", "ru", true), ("is", "ru", false), ("ok", "ru", false),
                                     ("a", "ru", false), ("the", "ru", false)] as [(String, String?, Bool)] {
            let other = KeyLayout.convert(typed, from: en, to: ru)
            let got = Detector.shouldSwitch(cur: typed, curLang: "en", alt: other, altLang: "ru", context: ctx)
            if got != expect { fails += 1 }
            print(got == expect ? "✅" : "❌", "короткое:", typed, ctx.map { "[\($0)]" } ?? "", "→", got ? other : "(оставить)")
        }
        // Instant switch while typing: decided on the prefix.
        for (typed, from, to, expect) in [("ghb", en, ru, true), ("ntc", en, ru, true), ("rfr", en, ru, true),
                                          ("the", en, ru, false), ("hel", en, ru, false), ("str", en, ru, false),
                                          ("iOS", en, ru, false), ("рудд", ru, en, true), ("цщк", ru, en, true),
                                          ("при", ru, en, false), ("мам", ru, en, false)] {
            let other = KeyLayout.convert(typed, from: from, to: to)
            let got = Detector.shouldSwitchPrefix(cur: typed, curLang: from.lang, alt: other, altLang: to.lang)
            if got != expect { fails += 1 }
            print(got == expect ? "✅" : "❌", "на лету:", typed, "→", got ? other + "…" : "(ждать)")
        }
        print("Apple Intelligence:", AppleModel.status)
        for (a, b, exp) in [("0.2.2", "0.2.1", true), ("0.10.0", "0.9.9", true), ("0.2.1", "0.2.1", false), ("0.2", "0.2.1", false), ("1.0", "0.9.9", true)] {
            let got = Updater.isNewer(a, than: b)
            if got != exp { fails += 1 }
            print(got == exp ? "✅" : "❌", "версия \(a) новее \(b)?", got)
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

if CommandLine.arguments.contains("--update-dry-run") {
    var code: Int32 = 1
    Task { code = await Updater.dryRun(); exit(code) }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--apple-write"), i + 1 < CommandLine.arguments.count {
    let text = CommandLine.arguments[i + 1]
    Task {
        for mode in [WriteMode.fix, .formal, .translate] {
            let t0 = Date()
            do {
                let user = Writer.prompt(text, mode: mode)
                let out = try await AppleModel.complete(system: Writer.system, user: user)
                print("[\(mode.title)] \(String(format: "%.1f", Date().timeIntervalSince(t0)))с:", out)
            } catch { print("[\(mode.title)] ошибка:", error.localizedDescription) }
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
