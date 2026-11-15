import AVFoundation
import Cocoa
import Speech

protocol Transcriber {
    func transcribe(wav: URL, language: String?) async throws -> String
}

/// Apple speech recognition (on-device when available). No setup needed.
struct AppleTranscriber: Transcriber {
    func transcribe(wav: URL, language: String?) async throws -> String {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let ok = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            guard ok else { throw LLMError.http("Нет доступа к распознаванию речи (Системные настройки → Конфиденциальность)") }
        }
        let locale = Locale(identifier: ["ru": "ru-RU", "en": "en-US", "uk": "uk-UA", "de": "de-DE",
                                         "fr": "fr-FR", "es": "es-ES"][language ?? "en"] ?? (language ?? "en-US"))
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw LLMError.http("Распознавание для \(locale.identifier) недоступно")
        }
        let req = SFSpeechURLRecognitionRequest(url: wav)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.formattedString) }
            }
        }
    }
}

/// Any OpenAI-compatible /audio/transcriptions endpoint: OpenAI Whisper, Groq, local faster-whisper / speaches, etc.
struct HTTPTranscriber: Transcriber {
    func transcribe(wav: URL, language: String?) async throws -> String {
        guard let url = URL(string: Settings.voiceHTTPURL) else { throw LLMError.http("Неверный адрес сервера распознавания") }
        let boundary = "keyla-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        if let k = Keychain.get("voice"), !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "authorization") }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", Settings.voiceHTTPModel)
        field("response_format", "json")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw LLMError.http("Сервер распознавания: " + (String(data: data, encoding: .utf8) ?? "ошибка"))
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["text"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
    }
}

/// Fully local whisper.cpp (`brew install whisper-cpp`) with any ggml model file.
struct WhisperCppTranscriber: Transcriber {
    func transcribe(wav: URL, language: String?) async throws -> String {
        let exe = Settings.whisperCLIPath, model = Settings.whisperModelPath
        guard FileManager.default.isExecutableFile(atPath: exe) else { throw LLMError.http("whisper-cli не найден: \(exe)") }
        guard FileManager.default.fileExists(atPath: model) else { throw LLMError.http("Файл модели whisper не найден") }
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["-m", model, "-f", wav.path, "-l", language ?? "auto", "-nt", "-np"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ") ?? ""
        }.value
    }
}

/// Records 16 kHz mono WAV, transcribes it with the chosen model and types the result where the cursor is.
final class VoiceController {
    static let shared = VoiceController()
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var startedAt = Date()
    private(set) var isRecording = false
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("keyla-dictation.wav")

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            HUD.shared.show("Нет доступа к микрофону", "Системные настройки → Конфиденциальность → Микрофон", duration: 3, force: true)
            return
        }
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            file = f
            input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { buf, _ in
                let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFmt.sampleRate + 64)
                guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                try? f.write(from: out)
                if let ch = out.floatChannelData?[0], out.frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<Int(out.frameLength) { sum += ch[i] * ch[i] }
                    let rms = sqrt(sum / Float(out.frameLength))
                    let level = min(1, Double(rms) * 12)
                    DispatchQueue.main.async { HUD.shared.updateLevel(level) }
                }
            }
            try engine.start()
            isRecording = true
            startedAt = Date()
            HUD.shared.show("Говорите", "Отпустите правый ⌥ или нажмите ⌃⌥V", level: 0, duration: nil, force: true)
        } catch {
            HUD.shared.show("Ошибка записи", error.localizedDescription, duration: 3, force: true)
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil  // closes the WAV
        if Date().timeIntervalSince(startedAt) < 0.5 { HUD.shared.hide(); return }

        HUD.shared.show("Распознаю…", backendName, duration: nil, force: true)
        let lang = language
        let wav = url
        Task { @MainActor in
            do {
                var text = try await transcriber.transcribe(wav: wav, language: lang)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if Settings.voiceCleanup, LLM.isConfigured, !text.isEmpty {
                    text = try await LLM.complete(
                        system: "Ты чистишь надиктованный текст. Верни только готовый текст.",
                        user: "Расставь пунктуацию и заглавные буквы, убери слова-паразиты и повторы, ничего не добавляй.\n\n<text>\n\(text)\n</text>"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !text.isEmpty else { HUD.shared.show("Ничего не распознано", force: true); return }
                HUD.shared.hide()
                TextInjector.paste(text + " ")
            } catch {
                HUD.shared.show("Ошибка распознавания", error.localizedDescription, duration: 4, force: true)
            }
        }
    }

    private var language: String? {
        switch Settings.voiceLanguage {
        case "layout": return LayoutManager.shared.current?.lang
        case "auto": return nil
        case let l: return l
        }
    }

    private var transcriber: Transcriber {
        switch Settings.voiceBackend {
        case "http": return HTTPTranscriber()
        case "whispercpp": return WhisperCppTranscriber()
        default: return AppleTranscriber()
        }
    }

    private var backendName: String {
        switch Settings.voiceBackend {
        case "http": return "Whisper API · \(Settings.voiceHTTPModel)"
        case "whispercpp": return "whisper.cpp · локально"
        default: return "Apple · на устройстве"
        }
    }
}
