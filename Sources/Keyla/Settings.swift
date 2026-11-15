import Foundation
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
            "llmProvider": "anthropic",          // anthropic | openai
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
    }

    static var llmProvider: String { d.string(forKey: "llmProvider") ?? "anthropic" }
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
