import Foundation

// Ядро без интерфейса: типы и чистые функции, которые не зависят от AppKit и
// SwiftUI. Вынесено в отдельный модуль ради тестов — исполняемую цель
// приложения импортировать нельзя, а библиотеку можно.

// MARK: - Стадия обработки

public enum JobStage: String, Codable, CaseIterable {
    case queued
    case downloading
    case transcribing
    case transcribed
    case summarizing
    case done
    case paused
    case failed

    public var title: String {
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

    public var symbolName: String {
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
    public var isRunning: Bool {
        return self == .downloading || self == .transcribing || self == .summarizing
    }

    // Можно ли продолжить с этого места.
    public var isResumable: Bool {
        return self == .queued || self == .transcribed || self == .paused || self == .failed
    }
}

// MARK: - Модели Whisper

public struct WhisperModelOption: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let fileName: String
    public let approxSizeText: String
    public let downloadURL: String
    public let minRAMGigabytes: Int
    // Очень грубая оценка: доля от длительности аудио, за которую модель
    // успевает распознать речь на Apple Silicon. Нужна только для прикидки
    // оставшегося времени в интерфейсе, не для точного расчёта.
    public let realtimeFactor: Double

    public static let all: [WhisperModelOption] = [
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

    public static func byID(_ id: String) -> WhisperModelOption {
        return all.first { $0.id == id } ?? all.first { $0.id == "medium" }!
    }

    // Подбор рекомендованной модели по железу пользователя.
    public static func recommended() -> WhisperModelOption {
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

public enum MacHardware {
    public static var isAppleSilicon: Bool {
        var size: Int = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }

    public static var ramGigabytes: Int {
        return Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    public static var summaryText: String {
        let chip = isAppleSilicon ? "Apple Silicon" : "Intel"
        return "\(chip), \(ramGigabytes) ГБ ОЗУ"
    }
}

// MARK: - Язык транскрибации

public struct TranscriptionLanguage: Identifiable, Equatable {
    public let id: String
    public let title: String

    public static let auto = TranscriptionLanguage(id: "auto", title: "Определять автоматически")

    public static let all: [TranscriptionLanguage] = [
        .auto,
        TranscriptionLanguage(id: "ru", title: "Русский"),
        TranscriptionLanguage(id: "en", title: "English"),
        TranscriptionLanguage(id: "uk", title: "Українська"),
        TranscriptionLanguage(id: "es", title: "Español"),
        TranscriptionLanguage(id: "de", title: "Deutsch"),
        TranscriptionLanguage(id: "fr", title: "Français"),
        TranscriptionLanguage(id: "zh", title: "中文")
    ]

    public static func byID(_ id: String) -> TranscriptionLanguage {
        return all.first { $0.id == id } ?? .auto
    }
}

// MARK: - Поддерживаемые файлы

public enum MediaKind {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "webm", "wmv", "flv", "mpg", "mpeg"
    ]

    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "wma", "aiff", "aif", "caf"
    ]

    public static var allExtensions: Set<String> {
        return videoExtensions.union(audioExtensions)
    }

    public static func isSupported(_ url: URL) -> Bool {
        return allExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Распознавание ссылок YouTube

public enum YouTubeLink {
    public static func isYouTubeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: trimmed), let host = url.host else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
    }
}

// MARK: - Распознавание ссылок на видеоконференции (ВКС)

public enum MeetingLinkDetector {
    private static let builtInPatterns: [(needle: String, platform: String)] = [
        ("meet.google.com/", "Google Meet"),
        ("teams.microsoft.com/", "Microsoft Teams"),
        ("teams.live.com/meet", "Microsoft Teams"),
        ("zoom.us/j/", "Zoom"),
        ("zoom.us/wc/", "Zoom")
    ]

    // Свои домены ВКС (внутрикорпоративные системы и т.п.), которые пользователь
    // добавляет вручную в Настройках — их не может быть в списке из коробки.
    public static var customPatterns: [(needle: String, platform: String)] = []

    // Возвращает название платформы, если ссылка похожа на активную встречу.
    public static func matchedPlatformName(in url: String) -> String? {
        let lower = url.lowercased()
        for pattern in builtInPatterns + customPatterns where lower.contains(pattern.needle.lowercased()) {
            return pattern.platform
        }
        return nil
    }

    // Ищет ссылку на встречу внутри произвольного текста (например, в описании
    // или месте события календаря, где ссылка — лишь часть текста).
    public static func firstMeetingLink(in text: String) -> (url: String, platform: String)? {
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

public struct CustomMeetingDomain: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var domain: String    // фрагмент URL, например "vcs.example.com"
    public var label: String     // как называть в уведомлении, например "Корпоративная ВКС"

    // Структуры из библиотеки получают публичный инициализатор только явно.
    public init(id: UUID = UUID(), domain: String, label: String) {
        self.id = id
        self.domain = domain
        self.label = label
    }
}

