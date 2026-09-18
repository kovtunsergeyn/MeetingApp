import Foundation
import MeetingCore

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

    // Задача пришла из автозаписи встречи (ВКС) — в истории её можно отфильтровать.
    var isMeetingRecording: Bool = false

    // Саммари уже выгружено в Заметки — чтобы не отправлять дважды.
    var savedToNotes: Bool = false

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
