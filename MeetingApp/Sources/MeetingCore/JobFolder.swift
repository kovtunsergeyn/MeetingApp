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
