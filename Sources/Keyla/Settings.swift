import Cocoa
import Security

/// UserDefaults-backed settings. SwiftUI views use @AppStorage with the same keys.
enum Settings {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "autoSwitch": true,
            "doubleShift": true,
            "autocorrect": false,
            "spellHints": true,
            "grammarHints": true,
            "showHUD": true,
            "indicatorStyle": "mark",            // mark | smiley | text | flag | both
            "excludedApps": "com.apple.Terminal\ncom.googlecode.iterm2\ndev.warp.Warp-Stable",
            "exceptions": "",
            "pairedLayouts": "",
            "anthropicModel": "claude-opus-5-5",
            "anthropicEffort": "low",
            "openaiBaseURL": "http://localhost:11434/v1",
            "openaiModel": "llama3.1",
            "voiceBackend": "apple",             // apple | http | whispercpp
            "voiceHTTPURL": "https://api.openai.com/v1/audio/transcriptions",
            "voiceHTTPModel": "whisper-1",
            "whisperCLIPath": "/opt/homebrew/bin/whisper-cli",
            "whisperModelPath": "",
            "voiceLanguage": "layout",           // layout | auto | en | ru | ...
            "voiceCleanup": false,
            "pushToTalk": true,
            "launchAtLogin": true,
            "autoUpdateCheck": true,
            "perAppLayout": true,
            "onboarded": false,
            "learnedSwitch": "",
            "instantSwitch": true,
            "askToLearn": true,
            "declinedWords": "",
            "inlineMarks": true,
            "llmProvider": Keychain.get("anthropic")?.isEmpty == false ? "anthropic" : "apple",
        ])
    }

    static var autoSwitch: Bool { d.bool(forKey: "autoSwitch") }
    static var doubleShift: Bool { d.bool(forKey: "doubleShift") }
    static var autocorrect: Bool { d.bool(forKey: "autocorrect") }
    static var spellHints: Bool { d.bool(forKey: "spellHints") }
    static var grammarHints: Bool { d.bool(forKey: "grammarHints") }
    static var showHUD: Bool { d.bool(forKey: "showHUD") }
    static var indicatorStyle: String { d.string(forKey: "indicatorStyle") ?? "mark" }
    static var pushToTalk: Bool { d.bool(forKey: "pushToTalk") }
    static var perAppLayout: Bool { d.bool(forKey: "perAppLayout") }
    static var instantSwitch: Bool { d.bool(forKey: "instantSwitch") }
    static var inlineMarks: Bool { d.bool(forKey: "inlineMarks") }
    static var askToLearn: Bool { d.bool(forKey: "askToLearn") }

    // MARK: My words — the user's own vocabulary (Armenian in Latin/Cyrillic, slang, names…)

    /// Words the user corrected back this session but hasn't confirmed: left alone until Keyla restarts.
    static var sessionIgnored: Set<String> = []

    /// Never switch, never correct, never underline.
    static func isMine(_ word: String) -> Bool {
        let w = word.lowercased()
        return exceptions.contains(w) || sessionIgnored.contains(w)
    }

    static func remember(_ word: String) {
        addException(word)
        NSSpellChecker.shared.learnWord(word.lowercased())    // other apps stop underlining it too
        unknownCounts[word.lowercased()] = nil
    }

    static var declined: Set<String> { Set(lines("declinedWords")) }
    static func decline(_ word: String) {
        let w = word.lowercased()
        guard !declined.contains(w) else { return }
        d.set((lines("declinedWords").suffix(300) + [w]).joined(separator: "\n"), forKey: "declinedWords")
        unknownCounts[w] = nil
    }

    /// How many times each unknown word was typed and left as is.
    static var unknownCounts: [String: Int] {
        get { d.dictionary(forKey: "unknownCounts") as? [String: Int] ?? [:] }
        set {
            var v = newValue
            if v.count > 500 { v = Dictionary(uniqueKeysWithValues: v.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) }) }
            d.set(v, forKey: "unknownCounts")
        }
    }
    /// Count one more use; returns the new total.
    static func noteUnknown(_ word: String) -> Int {
        let w = word.lowercased()
        var c = unknownCounts
        c[w, default: 0] += 1
        unknownCounts = c
        return c[w] ?? 1
    }

    /// Words the user converted by hand (double Shift) — always switch them next time.
    static var learnedSwitch: Set<String> { Set(lines("learnedSwitch").map { $0.lowercased() }) }
    static func learnSwitch(_ word: String) {
        let w = word.lowercased()
        guard w.count >= 2, !learnedSwitch.contains(w) else { return }
        d.set((lines("learnedSwitch") + [w]).joined(separator: "\n"), forKey: "learnedSwitch")
        // A word can't be both "always switch" and "never switch".
        d.set(lines("exceptions").filter { $0.lowercased() != w }.joined(separator: "\n"), forKey: "exceptions")
    }

    /// Remembered layout per app (bundle id → input source id).
    static var appLayouts: [String: String] {
        get { d.dictionary(forKey: "appLayouts") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "appLayouts") }
    }

    static func lines(_ key: String) -> [String] {
        (d.string(forKey: key) ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static var excludedApps: Set<String> { Set(lines("excludedApps")) }
    static var exceptions: Set<String> { Set(lines("exceptions").map { $0.lowercased() }) }
    static var pairedLayouts: [String] { lines("pairedLayouts") }

    static func addException(_ word: String) {
        let w = word.lowercased()
        guard !w.isEmpty, !exceptions.contains(w) else { return }
        d.set((lines("exceptions") + [w]).joined(separator: "\n"), forKey: "exceptions")
        d.set(lines("learnedSwitch").filter { $0.lowercased() != w }.joined(separator: "\n"), forKey: "learnedSwitch")
    }

    static var llmProvider: String { d.string(forKey: "llmProvider") ?? "apple" }   // apple | anthropic | openai
    static var anthropicModel: String { d.string(forKey: "anthropicModel") ?? "claude-opus-5-5" }
    static var anthropicEffort: String { d.string(forKey: "anthropicEffort") ?? "low" }
    static var openaiBaseURL: String { d.string(forKey: "openaiBaseURL") ?? "" }
    static var openaiModel: String { d.string(forKey: "openaiModel") ?? "" }

    static var voiceBackend: String { d.string(forKey: "voiceBackend") ?? "apple" }
    static var voiceHTTPURL: String { d.string(forKey: "voiceHTTPURL") ?? "" }
    static var voiceHTTPModel: String { d.string(forKey: "voiceHTTPModel") ?? "" }
    static var whisperCLIPath: String { d.string(forKey: "whisperCLIPath") ?? "" }
    static var whisperModelPath: String { d.string(forKey: "whisperModelPath") ?? "" }
    static var voiceLanguage: String { d.string(forKey: "voiceLanguage") ?? "layout" }
    static var voiceCleanup: Bool { d.bool(forKey: "voiceCleanup") }
}

/// API keys live in the login Keychain, not in UserDefaults.
enum Keychain {
    private static let service = "Keyla"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
