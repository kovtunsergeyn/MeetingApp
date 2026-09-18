import Foundation

// Разбор вывода внешних программ (whisper-cli, yt-dlp, claude) и выбор дорожек
// для записи встречи. Чистые функции без состояния — их и проверяют тесты:
// именно здесь ошибка тихо ломает прогресс, имя задачи или подписи говорящих.
public enum OutputParsing {

    // Строка «DURATION_SECONDS:123.4», которую печатает transcribe.sh.
    public static func durationSeconds(in chunk: String) -> Double? {
        for line in chunk.components(separatedBy: .newlines) {
            guard line.hasPrefix("DURATION_SECONDS:") else { continue }
            let value = line.replacingOccurrences(of: "DURATION_SECONDS:", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let duration = Double(value), duration > 0 { return duration }
        }
        return nil
    }

    // Прогресс загрузки yt-dlp: «[download]  42.3% of 12.00MiB at ... ETA 00:21».
    public struct DownloadProgress: Equatable {
        public let fraction: Double
        public let etaText: String?
        public init(fraction: Double, etaText: String?) {
            self.fraction = fraction
            self.etaText = etaText
        }
    }

    public static func downloadProgress(in line: String) -> DownloadProgress? {
        guard line.contains("%") else { return nil }
        guard let percentRange = line.range(of: #"[0-9]+\.[0-9]%"#, options: .regularExpression) else { return nil }
        guard let percent = Double(line[percentRange].dropLast()) else { return nil }
        var eta: String? = nil
        if let etaRange = line.range(of: #"ETA [0-9:]+"#, options: .regularExpression) {
            eta = line[etaRange].replacingOccurrences(of: "ETA ", with: "")
        }
        return DownloadProgress(fraction: percent / 100, etaText: eta)
    }

    // Ссылка на созданную страницу Notion в выводе claude.
    public static func notionURL(in output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) {
            for token in rawLine.components(separatedBy: .whitespaces) {
                let clean = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'(),"))
                if clean.hasPrefix("http") && clean.contains("notion") {
                    return clean
                }
            }
        }
        return nil
    }

    // Название видео, которое печатает download_youtube.sh строкой «TITLE: …».
    public static func downloadedTitle(in output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) where rawLine.hasPrefix("TITLE:") {
            let title = rawLine.replacingOccurrences(of: "TITLE:", with: "")
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    // Подробности упавшего шага: длинный вывод режем, оставляя начало и конец —
    // причина обычно либо в первых строках, либо в последних.
    public static func errorDetail(from output: String, limit: Int = 4000) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        let head = String(trimmed.prefix(limit / 2))
        let tail = String(trimmed.suffix(limit / 2))
        return head + "\n\n… (пропущено) …\n\n" + tail
    }
}

// MARK: - Выбор дорожек записи встречи

public enum MeetingTracks {
    public struct Selection: Equatable {
        // Что распознавать как речь собеседников: системный звук или, если
        // отдельных дорожек нет, сведённый файл.
        public let mainPath: String
        // Дорожка микрофона (свой голос). nil — распознаём одной дорожкой.
        public let micPath: String?

        public init(mainPath: String, micPath: String?) {
            self.mainPath = mainPath
            self.micPath = micPath
        }
    }

    // Дорожки лежат несжатыми: так обрыв записи не уносит встречу целиком.
    public static let systemTrackName = "system.caf"
    public static let micTrackName = "mic.wav"

    // Раздельные дорожки берём только у записей встреч и только если на месте
    // обе: одна дорожка без второй превратила бы разговор в монолог.
    public static func select(
        sourcePath: String,
        isMeetingRecording: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Selection {
        guard isMeetingRecording else { return Selection(mainPath: sourcePath, micPath: nil) }
        let dir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().path
        let systemPath = dir + "/" + systemTrackName
        let micPath = dir + "/" + micTrackName
        guard fileExists(systemPath), fileExists(micPath) else {
            return Selection(mainPath: sourcePath, micPath: nil)
        }
        return Selection(mainPath: systemPath, micPath: micPath)
    }
}
