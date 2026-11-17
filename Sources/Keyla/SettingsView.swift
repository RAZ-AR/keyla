import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage(Stats.key("switch")) private var switches = 0
    @AppStorage(Stats.key("typo")) private var typos = 0

    private let tabs = [("general", "Основное"), ("spelling", "Правописание"), ("ai", "AI"), ("voice", "Голос")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: K.s4) {
                ForEach(tabs, id: \.0) { id, title in
                    Button { withAnimation(K.quick) { tab = id } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(K.text(14, tab == id ? .bold : .regular)).foregroundStyle(tab == id ? K.ink : K.muted)
                            Rectangle().fill(tab == id ? K.ink : .clear).frame(height: 2)
                        }
                        .fixedSize().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == id ? .isSelected : [])
                }
            }
            .padding(.horizontal, K.s5)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case "spelling": SpellingTab()
                    case "ai": AITab()
                    case "voice": VoiceTab()
                    default: GeneralTab()
                    }
                }
                .padding(.horizontal, K.s5).padding(.vertical, K.s3)
            }
        }
        .frame(width: 600, height: 720)
        .background(K.paper)
        .tint(K.ink)
    }

    /// Reference composition: title top-left, a big circle, a giant numeral bottom-right with a small label.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: K.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyla").font(K.title(34)).foregroundStyle(K.ink)
                    Text("Раскладка · правописание · голос").font(K.text(13)).foregroundStyle(K.muted)
                }
                KeylaMark(size: 132)
            }
            Spacer(minLength: K.s3)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: K.s2) {
                    Text("опечаток").font(K.text(12)).foregroundStyle(K.muted)
                    Text("\(typos)").font(K.numeral(34)).foregroundStyle(K.ink).monospacedDigit()
                }
                Text("\(switches)").font(K.numeral(120)).foregroundStyle(K.ink).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.bottom, -2)
                Text("переключений сегодня").font(K.text(12)).foregroundStyle(K.muted)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, K.s5).padding(.top, 44).padding(.bottom, K.s4)
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(K.text(12)).foregroundStyle(K.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.top, K.s3)
    }
}

private struct GeneralTab: View {
    @AppStorage("autoSwitch") var autoSwitch = true
    @AppStorage("doubleShift") var doubleShift = true
    @AppStorage("showHUD") var showHUD = true
    @AppStorage("indicatorStyle") var indicatorStyle = "mark"
    @AppStorage("excludedApps") var excludedApps = ""
    @AppStorage("pairedLayouts") var paired = ""
    @AppStorage("perAppLayout") var perApp = true
    @AppStorage("instantSwitch") var instant = true
    @AppStorage("launchAtLogin") var launchAtLogin = true
    @AppStorage("autoUpdateCheck") var autoUpdate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Переключать раскладку автоматически", isOn: $autoSwitch).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Сразу при наборе, не дожидаясь пробела", isOn: $instant).toggleStyle(CircleToggleStyle())
                .disabled(!autoSwitch)
            Rule()
            Toggle("Помнить раскладку для каждого приложения", isOn: $perApp).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Запускать при входе", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.set($0); launchAtLogin = $0 })).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Двойной ⇧ — перевести слово или выделение", isOn: $doubleShift).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Подсказка у курсора", isOn: $showHUD).toggleStyle(CircleToggleStyle())
            Rule()
            OptionRow(title: "Значок в строке меню", value: $indicatorStyle,
                      options: [("● RU", "mark"), ("☺︎ 🇷🇺", "smiley"), ("RU", "text"), ("🇷🇺", "flag")])
            Rule()
            OptionRow(title: "Пара раскладок", value: $paired, options: pairOptions)
            Rule()
            LineEditor(title: "Не переключать в приложениях — bundle id, по одному в строке", text: $excludedApps)
            if let id = AppDelegate.lastExternalAppID, !excludedApps.contains(id) {
                Button("+ \(id)") { excludedApps += (excludedApps.isEmpty ? "" : "\n") + id }
                    .buttonStyle(TextLinkStyle())
            }
            Note(text: "⌫ сразу после исправления отменяет его и запоминает слово. Двойной ⇧ на слове, которое Keyla пропустила, — и она выучит его.")
            Button("Показать приветствие") { OnboardingController.shared.show() }
                .buttonStyle(TextLinkStyle()).padding(.top, K.s2)
            Rule().padding(.top, K.s3)
            Toggle("Проверять обновления автоматически", isOn: $autoUpdate).toggleStyle(CircleToggleStyle())
            HStack {
                Text("Версия \(Updater.currentVersion)").font(K.text(13)).foregroundStyle(K.muted)
                Spacer()
                Button("Проверить сейчас") { Updater.shared.check(manual: true) }.buttonStyle(TextLinkStyle())
            }
        }
    }

    private var pairOptions: [(String, String)] {
        let ls = LayoutManager.shared.layouts
        var out: [(String, String)] = [("Авто", "")]
        for i in ls.indices { for j in ls.indices where j > i && ls[i].lang != ls[j].lang {
            out.append(("\(ls[i].name) ⇄ \(ls[j].name)", "\(ls[i].id)\n\(ls[j].id)"))
        } }
        return out
    }
}

private struct SpellingTab: View {
    @AppStorage("spellHints") var spellHints = true
    @AppStorage("autocorrect") var autocorrect = false
    @AppStorage("inlineMarks") var inline = true
    @AppStorage("grammarHints") var grammarHints = true
    @AppStorage("exceptions") var exceptions = ""
    @AppStorage("learnedSwitch") var learned = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Показывать слова с ошибками", isOn: $spellHints).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Подчёркивать ошибки прямо в тексте", isOn: $inline).toggleStyle(CircleToggleStyle())
                .disabled(!spellHints)
            Rule()
            Toggle("Исправлять опечатки автоматически", isOn: $autocorrect).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Проверять грамматику предложений", isOn: $grammarHints).toggleStyle(CircleToggleStyle())
            Rule()
            LineEditor(title: "Исключения — не переключать и не исправлять", text: $exceptions)
            LineEditor(title: "Выученные слова — переключать всегда", text: $learned)
            Note(text: "Словари — системные macOS, работают офлайн. Нажмите на подчёркнутое слово — появятся варианты. ⌃⌥G на выделенном тексте открывает помощника письма.")
        }
    }
}

private struct AITab: View {
    @AppStorage("llmProvider") var provider = "apple"
    @AppStorage("anthropicModel") var model = "claude-opus-5-5"
    @AppStorage("anthropicEffort") var effort = "low"
    @AppStorage("openaiBaseURL") var baseURL = "http://localhost:11434/v1"
    @AppStorage("openaiModel") var oaModel = "llama3.1"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionRow(title: "Модель для письма", value: $provider,
                      options: [("Apple, на устройстве", "apple"), ("Claude", "anthropic"), ("Своя: Ollama, LM Studio", "openai")])
            Rule()
            if provider == "apple" {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple Intelligence").font(K.text(15, .bold)).foregroundStyle(K.ink)
                    Text(AppleModel.status).font(K.text(13)).foregroundStyle(K.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, K.s3)
            } else if provider == "anthropic" {
                LineField(title: "API-ключ Anthropic", text: keychainBinding("anthropic"), secure: true, placeholder: "sk-ant-…")
                OptionRow(title: "Модель", value: $model,
                          options: [("Opus 5.5 — качество", "claude-opus-5-5"), ("Sonnet 5.5 — баланс", "claude-sonnet-5-5"),
                                    ("Haiku 5.5 — скорость", "claude-haiku-5-5")])
                Rule()
                OptionRow(title: "Усилие", value: $effort, options: [("Низкое", "low"), ("Среднее", "medium"), ("Высокое", "high")])
            } else {
                LineField(title: "Адрес сервера", text: $baseURL)
                LineField(title: "Модель", text: $oaModel)
                LineField(title: "API-ключ, если нужен", text: keychainBinding("openai"), secure: true)
            }
            Note(text: provider == "apple"
                 ? "Текст не покидает Mac. Для длинных и сложных текстов лучше подходит Claude."
                 : "Ключи хранятся в Связке ключей. Если ключ не задан, Keyla использует модель Apple на устройстве.")
        }
    }
}

private struct VoiceTab: View {
    @AppStorage("voiceBackend") var backend = "apple"
    @AppStorage("voiceHTTPURL") var httpURL = ""
    @AppStorage("voiceHTTPModel") var httpModel = "whisper-1"
    @AppStorage("whisperCLIPath") var cliPath = "/opt/homebrew/bin/whisper-cli"
    @AppStorage("whisperModelPath") var modelPath = ""
    @AppStorage("voiceLanguage") var language = "layout"
    @AppStorage("voiceCleanup") var cleanup = false
    @AppStorage("pushToTalk") var pushToTalk = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionRow(title: "Распознавание", value: $backend,
                      options: [("Apple, на устройстве", "apple"), ("Whisper API", "http"), ("whisper.cpp, локально", "whispercpp")])
            Rule()
            switch backend {
            case "http":
                LineField(title: "Endpoint", text: $httpURL)
                LineField(title: "Модель", text: $httpModel)
                LineField(title: "API-ключ", text: keychainBinding("voice"), secure: true)
            case "whispercpp":
                LineField(title: "Путь к whisper-cli", text: $cliPath)
                LineField(title: "Файл модели .bin", text: $modelPath)
                Button("Выбрать файл…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = false
                    if p.runModal() == .OK, let u = p.url { modelPath = u.path }
                }
                .buttonStyle(TextLinkStyle())
            default: EmptyView()
            }
            OptionRow(title: "Язык", value: $language,
                      options: [("Как раскладка", "layout"), ("Авто", "auto"), ("Русский", "ru"), ("English", "en")])
            Rule()
            Toggle("Удерживать правый ⌥ для диктовки", isOn: $pushToTalk).toggleStyle(CircleToggleStyle())
            Rule()
            Toggle("Чистить текст AI-моделью", isOn: $cleanup).toggleStyle(CircleToggleStyle())
            Note(text: "⌃⌥V — начать или остановить диктовку. Текст вставляется туда, где стоит курсор.")
        }
    }
}

private func keychainBinding(_ account: String) -> Binding<String> {
    Binding(get: { Keychain.get(account) ?? "" }, set: { Keychain.set(account, $0) })
}
