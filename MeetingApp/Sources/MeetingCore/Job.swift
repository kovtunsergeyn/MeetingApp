import Foundation

// MARK: - Задача

public struct Job: Identifiable, Codable, Equatable {
    public var id: UUID
    public var sourcePath: String
    public var name: String
    public var stage: JobStage
    public var transcriptPath: String?
    public var notionURL: String?
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    // Ссылка на YouTube, если задача создана из неё (иначе исходник — локальный файл).
    public var youtubeURL: String?

    // Полный вывод упавшего шага (ffmpeg/whisper-cli/yt-dlp/claude) — для разворачиваемых подробностей ошибки.
    public var lastErrorDetail: String? = nil

    // Задача пришла из автозаписи встречи (ВКС) — в истории её можно отфильтровать.
    public var isMeetingRecording: Bool = false

    // Саммари уже выгружено в Заметки — чтобы не отправлять дважды.
    public var savedToNotes: Bool = false


    // Разбор истории терпим к отсутствующим полям. Историю пишет само
    // приложение, и когда в задачу добавляется новое свойство, в старых файлах
    // его нет. Синтезированный разбор на таком файле падает целиком — и вся
    // история выглядит пустой. Однажды это уже стоило потери списка задач.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Без названия"
        stage = try container.decodeIfPresent(JobStage.self, forKey: .stage) ?? .queued
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        notionURL = try container.decodeIfPresent(String.self, forKey: .notionURL)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        youtubeURL = try container.decodeIfPresent(String.self, forKey: .youtubeURL)
        lastErrorDetail = try container.decodeIfPresent(String.self, forKey: .lastErrorDetail)
        isMeetingRecording = try container.decodeIfPresent(Bool.self, forKey: .isMeetingRecording) ?? false
        savedToNotes = try container.decodeIfPresent(Bool.self, forKey: .savedToNotes) ?? false
    }

    public init(sourcePath: String) {
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
    public init(youtubeURL: String, name: String) {
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

    public var fileName: String {
        if sourcePath.isEmpty { return name }
        return URL(fileURLWithPath: sourcePath).lastPathComponent
    }

    // Есть ли готовый транскрипт на диске — значит, этот шаг можно пропустить.
    public var hasTranscript: Bool {
        guard let path = transcriptPath else { return false }
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        return size > 0
    }
}

