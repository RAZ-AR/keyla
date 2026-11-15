import Foundation

enum LLMError: LocalizedError {
    case noKey, http(String), refusal, empty
    var errorDescription: String? {
        switch self {
        case .noKey: return "Не задан API-ключ. Откройте Настройки → AI."
        case .http(let m): return m
        case .refusal: return "Модель отказалась обрабатывать этот текст."
        case .empty: return "Модель вернула пустой ответ."
        }
    }
}

/// Text model client: Claude (Anthropic API) or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter, ...).
enum LLM {
    static var isConfigured: Bool {
        Settings.llmProvider == "openai" ? !Settings.openaiBaseURL.isEmpty : !(Keychain.get("anthropic") ?? "").isEmpty
    }

    static func complete(system: String, user: String) async throws -> String {
        Settings.llmProvider == "openai" ? try await openAI(system: system, user: user)
                                         : try await anthropic(system: system, user: user)
    }

    private static func anthropic(system: String, user: String) async throws -> String {
        guard let key = Keychain.get("anthropic"), !key.isEmpty else { throw LLMError.noKey }
        let model = Settings.anthropicModel
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": Settings.anthropicEffort],
        ]
        // Server-side refusal fallback for models that support it.
        if ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1"].contains(model) {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "HTTP error"
            throw LLMError.http("Claude API: \(msg)")
        }
        if json["stop_reason"] as? String == "refusal" { throw LLMError.refusal }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }

    private static func openAI(system: String, user: String) async throws -> String {
        let base = Settings.openaiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.http("Неверный адрес сервера") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let k = Keychain.get("openai"), !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Settings.openaiModel,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.http("Сервер модели: " + (String(data: data, encoding: .utf8) ?? "ошибка"))
        }
        let text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }
}

enum WriteMode: String, CaseIterable, Identifiable {
    case fix, improve, formal, friendly, shorter, translate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fix: return "Исправить"
        case .improve: return "Улучшить"
        case .formal: return "Деловой"
        case .friendly: return "Дружелюбный"
        case .shorter: return "Короче"
        case .translate: return "Перевести"
        }
    }
    var instruction: String {
        switch self {
        case .fix: return "Исправь орфографию, пунктуацию и грамматику. Не меняй стиль, лексику и смысл без необходимости."
        case .improve: return "Сделай текст яснее и естественнее: исправь ошибки, убери канцелярит и повторы, сохрани смысл, тон и язык."
        case .formal: return "Перепиши текст в вежливом деловом стиле, исправив ошибки. Сохрани язык и смысл."
        case .friendly: return "Перепиши текст в тёплом дружелюбном тоне, исправив ошибки. Сохрани язык и смысл."
        case .shorter: return "Сократи текст примерно вдвое без потери важного смысла, исправив ошибки. Сохрани язык."
        case .translate: return "Если текст на русском — переведи на английский, иначе — на русский. Перевод должен звучать естественно для носителя."
        }
    }
}

enum Writer {
    static let system = """
    Ты — редактор текста, встроенный в macOS. Пользователь выделил фрагмент в любом приложении и хочет заменить его.
    Отвечай ТОЛЬКО готовым текстом для вставки: без кавычек, пояснений, вступлений и markdown-обёрток.
    Сохраняй переносы строк, списки, эмодзи, ссылки и имена собственные.
    """

    static func run(_ text: String, mode: WriteMode) async throws -> String {
        let user = "\(mode.instruction)\n\n<text>\n\(text)\n</text>"
        return try await LLM.complete(system: system, user: user).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
