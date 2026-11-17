import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence on-device model (macOS 26+): free, offline, no API key.
enum AppleModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Human-readable status for Settings.
    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Готова — работает на этом Mac, без интернета и ключей"
            case .unavailable(.deviceNotEligible): return "Этот Mac не поддерживает Apple Intelligence"
            case .unavailable(.appleIntelligenceNotEnabled): return "Включите Apple Intelligence в Системных настройках"
            case .unavailable(.modelNotReady): return "Модель ещё загружается — попробуйте позже"
            case .unavailable: return "Недоступна"
            }
        }
        #endif
        return "Нужна macOS 26 или новее"
    }

    static func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Rewriting the user's own text: the permissive guardrails avoid false refusals on ordinary messages.
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: model, instructions: system)
            do {
                let text = try await session.respond(to: user).content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw LLMError.empty }
                return text
            } catch let e as LLMError {
                throw e
            } catch {
                throw LLMError.http("Apple Intelligence: \(error.localizedDescription)")
            }
        }
        #endif
        throw LLMError.http("Apple Intelligence недоступна на этой версии macOS")
    }
}
