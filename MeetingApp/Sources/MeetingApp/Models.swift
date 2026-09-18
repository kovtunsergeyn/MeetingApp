import Foundation
import MeetingCore

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
