import Foundation

// Папка встречи — источник правды.
//
// Раньше единственной записью о проделанной работе была общая история
// (history.json). Дважды это заканчивалось плохо: один раз её перезаписали
// пустым списком, другой раз она перестала читаться из-за нового поля — и
// список задач исчезал целиком, хотя все файлы лежали на диске.
//
// Теперь рядом с транскриптом каждой встречи лежит её собственный meta.json.
// Общая история становится указателем, который в любой момент можно собрать
// заново по папкам: файлы на диске переживут и ошибку в коде, и сбой записи.
public enum JobFolder {
    public static let metaFileName = "meta.json"

    public static func metaPath(inFolder folder: String) -> String {
        return folder + "/" + metaFileName
    }

    // Куда класть запись о задаче: рядом с транскриптом, если он уже есть,
    // иначе — рядом с исходным файлом.
    public static func folder(for job: Job) -> String? {
        if let transcript = job.transcriptPath, !transcript.isEmpty {
            return URL(fileURLWithPath: transcript).deletingLastPathComponent().path
        }
        if !job.sourcePath.isEmpty {
            return URL(fileURLWithPath: job.sourcePath).deletingLastPathComponent().path
        }
        return nil
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public static func writeMeta(for job: Job) -> Bool {
        guard let folder = folder(for: job) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else { return false }
        guard let data = try? encoder().encode(job) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: metaPath(inFolder: folder)))
            return true
        } catch {
            return false
        }
    }

    public static func readMeta(inFolder folder: String) -> Job? {
        guard let data = FileManager.default.contents(atPath: metaPath(inFolder: folder)) else { return nil }
        return try? decoder().decode(Job.self, from: data)
    }

    // Собирает задачи по папкам с записями и транскриптами.
    public static func scan(layout: AppLayout) -> [Job] {
        let fm = FileManager.default
        var found: [UUID: Job] = [:]

        for parent in [layout.transcriptsDir, layout.recordingsDir, layout.processedDir] {
            guard let entries = try? fm.contentsOfDirectory(atPath: parent) else { continue }
            for entry in entries.sorted() {
                let folder = parent + "/" + entry
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                guard let job = readMeta(inFolder: folder) else { continue }
                // Если одна и та же задача описана в нескольких папках,
                // побеждает более свежая запись.
                if let existing = found[job.id], existing.updatedAt >= job.updatedAt { continue }
                found[job.id] = job
            }
        }

        return Array(found.values)
    }

    // Дополняет историю задачами, которые нашлись на диске, но пропали из неё.
    // Задачи из истории считаются главными: они свежее и могут содержать то,
    // чего в папке ещё нет.
    public static func merge(history: [Job], foundOnDisk: [Job]) -> (jobs: [Job], added: Int) {
        var byID: [UUID: Job] = [:]
        for job in history { byID[job.id] = job }

        var added = 0
        for job in foundOnDisk where byID[job.id] == nil {
            byID[job.id] = job
            added += 1
        }

        let jobs = byID.values.sorted { $0.createdAt < $1.createdAt }
        return (jobs, added)
    }
}

// MARK: - Переименование встречи

// Название встречи попадает в имена папок, поэтому переименование — это не
// только смена подписи в списке: нужно аккуратно перенести папку с
// транскриптом и поправить пути, а если что-то мешает — оставить файлы на
// месте и сменить только название. Терять файлы из-за переименования нельзя.
public enum JobRename {
    // Убираем из названия то, что не годится для имени папки.
    public static func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(120))
    }

    // Новый путь для файла, лежащего в переименованной папке.
    public static func movedPath(_ path: String, fromFolder oldFolder: String, toFolder newFolder: String) -> String {
        guard path.hasPrefix(oldFolder + "/") else { return path }
        return newFolder + String(path.dropFirst(oldFolder.count))
    }
}

// MARK: - Порядок задач и формат времени

// Обе мелочи живут в ядре, потому что на них уже наступали: сортировка по
// времени изменения поднимала наверх старую встречу после переименования, а
// нечисловая длительность записи роняла ползунок проигрывателя.
public enum JobOrder {
    // По времени самой встречи, свежее — выше. Статус и последующие правки
    // на порядок не влияют.
    public static func sortedForDisplay(_ jobs: [Job]) -> [Job] {
        return jobs.sorted { $0.createdAt > $1.createdAt }
    }
}

public enum TimeFormat {
    // Минуты и секунды. Некорректная длительность (ноль, отрицательная,
    // нечисловая) превращается в нули, а не в мусор на экране.
    public static func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Прерванные записи

// Приложение может умереть посреди встречи, и тогда дорожки остаются на диске
// без задачи. Такие папки нужно возвращать в обработку — но только их.
//
// Однажды эта проверка была слишком широкой: после обработки запись уезжает в
// processed, а папка записи остаётся, и вчерашние обработанные встречи были
// приняты за прерванные и отправлены распознаваться заново, на большой модели.
public enum InterruptedRecording {
    public static func shouldAdopt(folderName: String, layout: AppLayout, knownNames: [String]) -> Bool {
        // Задача с таким названием уже есть в истории — в том числе если к
        // автоматическому имени потом дописали тему: однажды переименование
        // встречи отправило её старую запись распознаваться заново.
        if knownNames.contains(where: { JobNaming.extends($0, base: folderName) }) { return false }
        // Для этой встречи уже есть готовый транскрипт — работа сделана.
        if FileManager.default.fileExists(
            atPath: layout.transcriptsDir + "/" + folderName + "/transcript.txt"
        ) { return false }
        return true
    }
}

// MARK: - Название встречи по сути разговора

// Автоматическое имя вида «Встреча 05.10.2026 18-11» годится как метка времени,
// но в списке из десятка таких строк найти нужную невозможно. После сбора
// саммари название дополняется контекстом: как событие называлось в календаре
// и о чём говорили — при условии, что человек не переименовал встречу сам:
// его название всегда главнее.
public enum JobNaming {
    // Разделитель частей — дефис с пробелами, как в названиях, которые
    // человек даёт сам и которые лежат в Notion.
    public static let separator = " - "

    // Имя считается автоматическим, если это «Встреча <дата> <время>» или
    // «Запись <дата> <время>» без добавленной человеком темы.
    public static func isAutomaticName(_ name: String) -> Bool {
        let pattern = #"^(Встреча|Запись) \d{2}\.\d{2}\.\d{4} \d{2}[-:]\d{2}$"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    // Имя совпадает с base или продолжает его темой.
    public static func extends(_ name: String, base: String) -> Bool {
        return name == base || name.hasPrefix(base + separator) || name.hasPrefix(base + " — ")
    }

    // «Встреча <дата> <время> - <событие календаря> - <тема>». Дата остаётся
    // впереди: по ней встречи выстраиваются по порядку и ищутся «по дню».
    // Событие календаря говорит, что это за встреча вообще (регулярная
    // планёрка, разбор с подрядчиком), тема — о чём шла речь именно сегодня.
    // Тема, которая просто повторяет название события, второй раз не пишется.
    public static func compose(automaticName: String, calendarTitle: String? = nil, title: String?) -> String {
        let clean = { (s: String?) -> String in
            (s ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".«»\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let event = clean(calendarTitle)
        var topic = clean(title)
        if !event.isEmpty, topic.lowercased() == event.lowercased() { topic = "" }
        return ([automaticName, event, topic].filter { !$0.isEmpty }).joined(separator: separator)
    }
}

// MARK: - Папка записи встречи

public enum MeetingFolderName {
    // Рядом с дорожками лежит название события из календаря: если запись
    // оборвётся, при подхвате контекст встречи не потеряется.
    public static let calendarFileName = "calendar-event.txt"

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH-mm"
        return formatter
    }()

    // «Встреча 05.10.2026 18-11» — то же автоматическое имя, что и у задачи.
    public static func forRecording(startedAt date: Date) -> String {
        return "Встреча " + formatter.string(from: date)
    }
}
