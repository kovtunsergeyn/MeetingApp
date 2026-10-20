import Foundation

// Раскладка папок приложения и разовый переезд со старой.
//
// Вынесено сюда, чтобы переезд можно было прогнать тестом на временной папке:
// на реальных данных ошибка здесь стоит дорого — однажды тестовая сборка
// унесла у рабочей все модели whisper.
public struct AppLayout {
    public let baseDir: String
    public init(homeDirectory: String, folderName: String) {
        self.baseDir = homeDirectory + "/" + folderName
    }

    public var historyPath: String { return baseDir + "/history.json" }
    public var modelsDir: String { return baseDir + "/models" }
    public var recordingsDir: String { return baseDir + "/recordings" }
    public var transcriptsDir: String { return baseDir + "/transcripts" }
    public var processedDir: String { return baseDir + "/processed" }
    public var scriptsDir: String { return baseDir + "/scripts" }
    // Сюда приложение складывает ffmpeg, whisper-cli и yt-dlp. Свои копии, а не
    // системные: тогда человеку, которому приложение передали, не нужны ни
    // Homebrew, ни Node, ни Xcode — поставил .app и работает.
    public var binDir: String { return baseDir + "/bin" }

    public var allDirectories: [String] {
        return [baseDir, processedDir, transcriptsDir, recordingsDir, modelsDir, binDir]
    }

    public func createDirectories() {
        let fm = FileManager.default
        for path in allDirectories {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}

public enum LayoutMigration {
    // Старые кириллические имена подпапок и их латинские замены.
    public static let renames = [
        "транскрипты": "transcripts",
        "обработано": "processed",
        "tmp": "recordings"
    ]

    public struct Report {
        public var movedItems: [String] = []
        public var movedModels: [String] = []
        public var historyRewritten = false
        public var skipped: String? = nil

        public var didSomething: Bool {
            return !movedItems.isEmpty || !movedModels.isEmpty || historyRewritten
        }
    }

    // Переносит содержимое старой папки данных в новую раскладку.
    //
    // legacyModelsFolder пустая — модели не трогаем: у тестовой сборки модели
    // общие с рабочей, и забирать их она не должна.
    @discardableResult
    public static func run(
        homeDirectory: String,
        layout: AppLayout,
        legacyFolderName: String,
        legacyModelsFolderName: String
    ) -> Report {
        var report = Report()
        let fm = FileManager.default
        let legacyBase = homeDirectory + "/" + legacyFolderName
        let legacyModels = legacyModelsFolderName.isEmpty ? "" : homeDirectory + "/" + legacyModelsFolderName

        let hasLegacyBase = fm.fileExists(atPath: legacyBase)
        let hasLegacyModels = !legacyModels.isEmpty && fm.fileExists(atPath: legacyModels)
        guard hasLegacyBase || hasLegacyModels else {
            report.skipped = "старой раскладки нет"
            return report
        }
        // История уже на новом месте — значит, переезд состоялся.
        guard !fm.fileExists(atPath: layout.historyPath) else {
            report.skipped = "переезд уже был"
            return report
        }

        try? fm.createDirectory(atPath: layout.baseDir, withIntermediateDirectories: true)

        // Переносим по одному, а не папку целиком: новая папка к этому моменту
        // уже существует — сборка кладёт в неё свежие скрипты.
        if hasLegacyBase, let items = try? fm.contentsOfDirectory(atPath: legacyBase) {
            for item in items.sorted() {
                let destination = layout.baseDir + "/" + (renames[item] ?? item)
                // Скрипты в новой папке свежее — старые не тащим.
                guard !fm.fileExists(atPath: destination) else { continue }
                if (try? fm.moveItem(atPath: legacyBase + "/" + item, toPath: destination)) != nil {
                    report.movedItems.append(item)
                }
            }
            if let left = try? fm.contentsOfDirectory(atPath: legacyBase), left.isEmpty {
                try? fm.removeItem(atPath: legacyBase)
            }
        }

        if hasLegacyModels {
            try? fm.createDirectory(atPath: layout.modelsDir, withIntermediateDirectories: true)
            if let models = try? fm.contentsOfDirectory(atPath: legacyModels) {
                for model in models.sorted() where !fm.fileExists(atPath: layout.modelsDir + "/" + model) {
                    if (try? fm.moveItem(atPath: legacyModels + "/" + model,
                                         toPath: layout.modelsDir + "/" + model)) != nil {
                        report.movedModels.append(model)
                    }
                }
            }
            if let left = try? fm.contentsOfDirectory(atPath: legacyModels), left.isEmpty {
                try? fm.removeItem(atPath: legacyModels)
            }
        }

        report.historyRewritten = rewriteHistoryPaths(
            layout: layout,
            legacyBase: legacyBase,
            legacyModels: legacyModels
        )
        return report
    }

    // Чинит пути, оставшиеся от старой раскладки, даже если сам переезд был
    // раньше и уже не повторится: история — единственная запись о работе,
    // и терять привязку к файлам из-за давней ошибки нельзя.
    @discardableResult
    public static func repairLingeringLegacyPaths(
        homeDirectory: String,
        layout: AppLayout,
        legacyFolderName: String,
        legacyModelsFolderName: String
    ) -> Bool {
        let legacyBase = homeDirectory + "/" + legacyFolderName
        guard let data = FileManager.default.contents(atPath: layout.historyPath),
              let text = String(data: data, encoding: .utf8) else { return false }
        let escaped = legacyBase.replacingOccurrences(of: "/", with: "\\/")
        guard text.contains(legacyBase) || text.contains(escaped) else { return false }
        return rewriteHistoryPaths(
            layout: layout,
            legacyBase: legacyBase,
            legacyModels: legacyModelsFolderName.isEmpty ? "" : homeDirectory + "/" + legacyModelsFolderName
        )
    }

    // В истории лежат абсолютные пути к исходникам и транскриптам: после
    // переезда их нужно переписать, иначе задачи «потеряют» свои файлы.
    @discardableResult
    public static func rewriteHistoryPaths(
        layout: AppLayout,
        legacyBase: String,
        legacyModels: String
    ) -> Bool {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: layout.historyPath),
              var text = String(data: data, encoding: .utf8) else { return false }

        // Копия на случай, если что-то пойдёт не так: история — единственная
        // запись о проделанной работе.
        try? data.write(to: URL(fileURLWithPath: layout.historyPath + ".before-migration"))

        var replacements: [(String, String)] = [
            (legacyBase + "/транскрипты", layout.transcriptsDir),
            (legacyBase + "/обработано", layout.processedDir),
            (legacyBase + "/tmp", layout.recordingsDir),
            (legacyBase, layout.baseDir)
        ]
        if !legacyModels.isEmpty {
            replacements.append((legacyModels, layout.modelsDir))
        }

        let before = text
        for (old, new) in replacements {
            text = text.replacingOccurrences(of: old, with: new)
            // JSON, который пишет JSONEncoder, экранирует косые черты:
            // "\/Users\/sk\/…". Без этой замены пути в истории оставались
            // старыми, и задачи «теряли» свои файлы после переезда.
            text = text.replacingOccurrences(
                of: old.replacingOccurrences(of: "/", with: "\\/"),
                with: new.replacingOccurrences(of: "/", with: "\\/")
            )
        }
        guard text != before else { return false }
        try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: layout.historyPath))
        return true
    }
}

// MARK: - Защита истории обработки

// История — единственная запись о проделанной работе: файлы на диске есть, но
// какие задачи были, чем закончились и куда выгружены, знает только она.
// Однажды она уже обнулилась, поэтому пустую историю поверх непустой не пишем:
// это всегда ошибка, а не осмысленное действие. Настоящую очистку человек
// делает по одной задаче, и тогда список пустеет постепенно.
public enum HistorySafety {
    public static func allowsWrite(newJobCount: Int, existingFileSize: Int) -> Bool {
        if newJobCount > 0 { return true }
        // Пустой или отсутствующий файл перезаписать можно — терять нечего.
        return existingFileSize <= emptyFileThreshold
    }

    // «[]» с переводом строки — это и есть пустая история.
    public static let emptyFileThreshold = 8
}
