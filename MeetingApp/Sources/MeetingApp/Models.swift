import Foundation

// MARK: - Стадия обработки

enum JobStage: String, Codable, CaseIterable {
    case queued
    case downloading
    case transcribing
    case transcribed
    case summarizing
    case done
    case paused
    case failed

    var title: String {
        switch self {
        case .queued: return "В очереди"
        case .downloading: return "Загрузка с YouTube"
        case .transcribing: return "Транскрибация"
        case .transcribed: return "Транскрипт готов"
        case .summarizing: return "Саммари и сохранение"
        case .done: return "Готово"
        case .paused: return "Пауза"
        case .failed: return "Ошибка"
        }
    }

    var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle"
        case .transcribing: return "waveform"
        case .transcribed: return "doc.text"
        case .summarizing: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    // Стадия, на которой процесс активно работает.
    var isRunning: Bool {
        return self == .downloading || self == .transcribing || self == .summarizing
    }

    // Можно ли продолжить с этого места.
    var isResumable: Bool {
        return self == .queued || self == .transcribed || self == .paused || self == .failed
    }
}

// MARK: - Задача

struct Job: Identifiable, Codable, Equatable {
    var id: UUID
    var sourcePath: String
    var name: String
    var stage: JobStage
    var transcriptPath: String?
    var notionURL: String?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    // Ссылка на YouTube, если задача создана из неё (иначе исходник — локальный файл).
    var youtubeURL: String?

    // Полный вывод упавшего шага (ffmpeg/whisper-cli/yt-dlp/claude) — для разворачиваемых подробностей ошибки.
    var lastErrorDetail: String? = nil

    // Задача пришла из автозаписи встречи (ВКС) — показываем во вкладке «Записи встреч».
    var isMeetingRecording: Bool = false

    init(sourcePath: String) {
        let url = URL(fileURLWithPath: sourcePath)
        self.id = UUID()
        self.sourcePath = sourcePath
        self.name = url.deletingPathExtension().lastPathComponent
        self.stage = .queued
        self.transcriptPath = nil
        self.notionURL = nil
        self.lastError = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.youtubeURL = nil
    }

    // Задача из ссылки YouTube — файл появится только после загрузки.
    init(youtubeURL: String, name: String) {
        self.id = UUID()
        self.sourcePath = ""
        self.name = name
        self.stage = .queued
        self.transcriptPath = nil
        self.notionURL = nil
        self.lastError = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.youtubeURL = youtubeURL
    }

    var fileName: String {
        if sourcePath.isEmpty { return name }
        return URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    // Есть ли готовый транскрипт на диске — значит, этот шаг можно пропустить.
    var hasTranscript: Bool {
        guard let path = transcriptPath else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        return size > 0
    }
}

// MARK: - Внешние зависимости

struct Dependency: Identifiable, Equatable {
    let id: String
    let title: String
    let details: String

    static let ffmpeg = Dependency(
        id: "ffmpeg",
        title: "ffmpeg",
        details: "Извлекает звуковую дорожку из видео и аудиофайлов."
    )

    static let whisper = Dependency(
        id: "whisper",
        title: "whisper-cli (whisper.cpp)",
        details: "Распознаёт речь локально, с ускорением на Apple Silicon."
    )

    static let ytdlp = Dependency(
        id: "ytdlp",
        title: "yt-dlp",
        details: "Скачивает аудио с YouTube по ссылке."
    )

    static let vad = Dependency(
        id: "vad",
        title: "Детектор речи (VAD, ~1 МБ)",
        details: "Вырезает тишину до распознавания: без него на тихих участках появляется мусор, а язык встречи может определиться неверно."
    )

    static func model(_ option: WhisperModelOption) -> Dependency {
        return Dependency(
            id: "model:\(option.id)",
            title: "Модель \(option.fileName) (~\(option.approxSizeText))",
            details: "Языковая модель для распознавания речи (\(option.title))."
        )
    }

    static let claude = Dependency(
        id: "claude",
        title: "Claude Code",
        details: "Делает саммари и сохраняет запись в Notion/Заметки. Установка и вход в аккаунт — автоматически: поставится через npm (Node.js через Homebrew, если его нет), затем откроется браузер для входа в Anthropic."
    )

    var isAutoInstallable: Bool {
        return true
    }
}

// MARK: - Модели Whisper

struct WhisperModelOption: Identifiable, Equatable {
    let id: String
    let title: String
    let fileName: String
    let approxSizeText: String
    let downloadURL: String
    let minRAMGigabytes: Int
    // Очень грубая оценка: доля от длительности аудио, за которую модель
    // успевает распознать речь на Apple Silicon. Нужна только для прикидки
    // оставшегося времени в интерфейсе, не для точного расчёта.
    let realtimeFactor: Double

    static let all: [WhisperModelOption] = [
        WhisperModelOption(
            id: "tiny", title: "tiny — самая быстрая, ниже точность",
            fileName: "ggml-tiny.bin", approxSizeText: "75 МБ",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
            minRAMGigabytes: 0, realtimeFactor: 0.08
        ),
        WhisperModelOption(
            id: "base", title: "base — быстро, базовая точность",
            fileName: "ggml-base.bin", approxSizeText: "140 МБ",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
            minRAMGigabytes: 4, realtimeFactor: 0.12
        ),
        WhisperModelOption(
            id: "small", title: "small — баланс скорости и качества",
            fileName: "ggml-small.bin", approxSizeText: "465 МБ",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            minRAMGigabytes: 8, realtimeFactor: 0.25
        ),
        WhisperModelOption(
            id: "medium", title: "medium — хорошая точность",
            fileName: "ggml-medium.bin", approxSizeText: "1,5 ГБ",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
            minRAMGigabytes: 8, realtimeFactor: 0.45
        ),
        WhisperModelOption(
            id: "large-v3", title: "large-v3 — максимальная точность",
            fileName: "ggml-large-v3.bin", approxSizeText: "3,1 ГБ",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
            minRAMGigabytes: 16, realtimeFactor: 0.9
        )
    ]

    static func byID(_ id: String) -> WhisperModelOption {
        return all.first { $0.id == id } ?? all.first { $0.id == "medium" }!
    }

    // Подбор рекомендованной модели по железу пользователя.
    static func recommended() -> WhisperModelOption {
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        let isAppleSilicon = MacHardware.isAppleSilicon

        if ramGB >= 32 && isAppleSilicon {
            return byID("large-v3")
        } else if ramGB >= 16 {
            return byID("medium")
        } else if ramGB >= 8 {
            return byID("small")
        } else if ramGB >= 4 {
            return byID("base")
        } else {
            return byID("tiny")
        }
    }
}

enum MacHardware {
    static var isAppleSilicon: Bool {
        var size: Int = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }

    static var ramGigabytes: Int {
        return Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    static var summaryText: String {
        let chip = isAppleSilicon ? "Apple Silicon" : "Intel"
        return "\(chip), \(ramGigabytes) ГБ ОЗУ"
    }
}

// MARK: - Язык транскрибации

struct TranscriptionLanguage: Identifiable, Equatable {
    let id: String
    let title: String

    static let auto = TranscriptionLanguage(id: "auto", title: "Определять автоматически")

    static let all: [TranscriptionLanguage] = [
        .auto,
        TranscriptionLanguage(id: "ru", title: "Русский"),
        TranscriptionLanguage(id: "en", title: "English"),
        TranscriptionLanguage(id: "uk", title: "Українська"),
        TranscriptionLanguage(id: "es", title: "Español"),
        TranscriptionLanguage(id: "de", title: "Deutsch"),
        TranscriptionLanguage(id: "fr", title: "Français"),
        TranscriptionLanguage(id: "zh", title: "中文")
    ]

    static func byID(_ id: String) -> TranscriptionLanguage {
        return all.first { $0.id == id } ?? .auto
    }
}

// MARK: - Куда сохранять итог

struct SaveDestinations: Equatable {
    var notes: Bool
    var notion: Bool

    var isEmpty: Bool { return !notes && !notion }

    static let `default` = SaveDestinations(notes: false, notion: true)
}

// MARK: - Поддерживаемые файлы

enum MediaKind {
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "webm", "wmv", "flv", "mpg", "mpeg"
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "wma", "aiff", "aif", "caf"
    ]

    static var allExtensions: Set<String> {
        return videoExtensions.union(audioExtensions)
    }

    static func isSupported(_ url: URL) -> Bool {
        return allExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Распознавание ссылок YouTube

enum YouTubeLink {
    static func isYouTubeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: trimmed), let host = url.host else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
    }
}

// MARK: - Распознавание ссылок на видеоконференции (ВКС)

enum MeetingLinkDetector {
    private static let builtInPatterns: [(needle: String, platform: String)] = [
        ("meet.google.com/", "Google Meet"),
        ("teams.microsoft.com/", "Microsoft Teams"),
        ("teams.live.com/meet", "Microsoft Teams"),
        ("zoom.us/j/", "Zoom"),
        ("zoom.us/wc/", "Zoom")
    ]

    // Свои домены ВКС (внутрикорпоративные системы и т.п.), которые пользователь
    // добавляет вручную в Настройках — их не может быть в списке из коробки.
    static var customPatterns: [(needle: String, platform: String)] = []

    // Возвращает название платформы, если ссылка похожа на активную встречу.
    static func matchedPlatformName(in url: String) -> String? {
        let lower = url.lowercased()
        for pattern in builtInPatterns + customPatterns where lower.contains(pattern.needle.lowercased()) {
            return pattern.platform
        }
        return nil
    }

    // Ищет ссылку на встречу внутри произвольного текста (например, в описании
    // или месте события календаря, где ссылка — лишь часть текста).
    static func firstMeetingLink(in text: String) -> (url: String, platform: String)? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for token in tokens {
            let candidate = String(token)
            if let platform = matchedPlatformName(in: candidate) {
                return (candidate, platform)
            }
        }
        return nil
    }
}

// MARK: - Свой домен ВКС, добавленный пользователем вручную

struct CustomMeetingDomain: Codable, Identifiable, Equatable {
    var id = UUID()
    var domain: String    // фрагмент URL, например "vcs.example.com"
    var label: String     // как называть в уведомлении, например "Корпоративная ВКС"
}

// MARK: - Браузеры, в которых ищем открытую встречу

struct MonitoredBrowser {
    enum Dialect { case safari, chromium }

    let processName: String
    let appleScriptName: String
    let dialect: Dialect

    static let all: [MonitoredBrowser] = [
        MonitoredBrowser(processName: "Safari", appleScriptName: "Safari", dialect: .safari),
        MonitoredBrowser(processName: "Google Chrome", appleScriptName: "Google Chrome", dialect: .chromium),
        MonitoredBrowser(processName: "Brave Browser", appleScriptName: "Brave Browser", dialect: .chromium),
        MonitoredBrowser(processName: "Yandex", appleScriptName: "Yandex", dialect: .chromium)
    ]
}
