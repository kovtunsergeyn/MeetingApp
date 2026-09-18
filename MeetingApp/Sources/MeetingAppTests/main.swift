import Foundation
import MeetingCore

// Тесты логики приложения.
//
// XCTest без Xcode недоступен (в Command Line Tools его просто нет), поэтому
// тесты — обычная программа: `swift run MeetingAppTests`. Падение любой
// проверки даёт ненулевой код возврата, так что это годится и для CI.

var failures: [String] = []
var checks = 0

func check(_ condition: Bool, _ what: String) {
    checks += 1
    if !condition { failures.append(what) }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
    checks += 1
    if actual != expected {
        failures.append("\(what): ожидалось «\(expected)», получено «\(actual)»")
    }
}

func group(_ title: String, _ body: () -> Void) {
    print("• \(title)")
    body()
}

// MARK: - Ссылки на встречи

group("Распознавание ссылок на ВКС") {
    equal(MeetingLinkDetector.matchedPlatformName(in: "https://meet.google.com/abc-defg-hij"),
          "Google Meet", "Google Meet по ссылке")
    equal(MeetingLinkDetector.matchedPlatformName(in: "https://us02web.zoom.us/j/123456"),
          "Zoom", "Zoom по ссылке")
    check(MeetingLinkDetector.matchedPlatformName(in: "https://youtube.com/watch?v=1") == nil,
          "обычная ссылка не считается встречей")

    // Свои домены ВКС добавляются в настройках — без них внутренняя платформа
    // компании не распознаётся, и запись никто не предложит.
    MeetingLinkDetector.customPatterns = [("vcs.example.com", "Внутренняя ВКС")]
    equal(MeetingLinkDetector.matchedPlatformName(in: "https://vcs.example.com/room-1"),
          "Внутренняя ВКС", "свой домен ВКС")

    // Ссылка внутри текста события календаря.
    let note = "Еженедельный созвон\nПодключиться: https://vcs.example.com/room-1\nТелефон: 123"
    equal(MeetingLinkDetector.firstMeetingLink(in: note)?.platform, "Внутренняя ВКС",
          "ссылка в тексте события календаря")
    MeetingLinkDetector.customPatterns = []
}

// MARK: - Разбор вывода внешних программ

group("Разбор вывода") {
    equal(OutputParsing.durationSeconds(in: "Готовлю аудио…\nDURATION_SECONDS:2262.8\n"), 2262.8,
          "длительность записи")
    check(OutputParsing.durationSeconds(in: "DURATION_SECONDS:0") == nil,
          "нулевая длительность игнорируется")

    let progress = OutputParsing.downloadProgress(in: "[download]  42.3% of 12.00MiB at 1.00MiB/s ETA 00:21")
    equal(progress?.fraction, 0.423, "доля загрузки yt-dlp")
    equal(progress?.etaText, "00:21", "оставшееся время загрузки")
    check(OutputParsing.downloadProgress(in: "[download] Destination: audio.m4a") == nil,
          "строка без процентов не считается прогрессом")

    equal(OutputParsing.notionURL(in: "Готово.\nСтраница: https://www.notion.so/abc123"),
          "https://www.notion.so/abc123", "ссылка на страницу Notion")
    check(OutputParsing.notionURL(in: "Сохранено в Заметки") == nil,
          "без ссылки возвращается пусто")

    equal(OutputParsing.downloadedTitle(in: "TITLE: Название видео\nostalnoe"), "Название видео",
          "название скачанного видео")

    // Длинный вывод режется, но начало и конец сохраняются: причина ошибки
    // почти всегда в одном из этих мест.
    let long = String(repeating: "строка ошибки\n", count: 2000)
    let detail = OutputParsing.errorDetail(from: long, limit: 100) ?? ""
    check(detail.contains("(пропущено)"), "длинный вывод сокращается")
    check(detail.count < long.count, "сокращённый вывод короче исходного")
    check(OutputParsing.errorDetail(from: "   \n ") == nil, "пустой вывод не даёт подробностей")
}

// MARK: - Выбор дорожек записи встречи

group("Дорожки записи встречи") {
    let dir = "/tmp/meeting"
    let both: (String) -> Bool = {
        $0.hasSuffix(MeetingTracks.systemTrackName) || $0.hasSuffix(MeetingTracks.micTrackName)
    }

    let separate = MeetingTracks.select(sourcePath: dir + "/meeting.m4a",
                                        isMeetingRecording: true,
                                        fileExists: both)
    equal(separate.mainPath, dir + "/" + MeetingTracks.systemTrackName, "собеседники — это системный звук")
    equal(separate.micPath, dir + "/" + MeetingTracks.micTrackName, "свой голос — это микрофон")

    // Одна дорожка без второй превратила бы разговор в монолог: распознаём
    // тогда сведённый файл целиком.
    let onlySystem = MeetingTracks.select(sourcePath: dir + "/meeting.m4a",
                                          isMeetingRecording: true,
                                          fileExists: { $0.hasSuffix(MeetingTracks.systemTrackName) })
    equal(onlySystem.mainPath, dir + "/meeting.m4a", "без микрофона берём сведённый файл")
    check(onlySystem.micPath == nil, "без микрофона вторая дорожка не передаётся")

    // Загруженный файл или видео с YouTube — всегда одна дорожка.
    let imported = MeetingTracks.select(sourcePath: "/tmp/video.mp4",
                                        isMeetingRecording: false,
                                        fileExists: { _ in true })
    equal(imported.mainPath, "/tmp/video.mp4", "обычный файл распознаётся как есть")
    check(imported.micPath == nil, "у обычного файла нет дорожки микрофона")
}

// MARK: - Модели whisper

group("Модели whisper") {
    equal(WhisperModelOption.byID("large-v3").fileName, "ggml-large-v3.bin", "модель по идентификатору")
    equal(WhisperModelOption.byID("несуществующая").id, "medium", "неизвестная модель — medium")
    check(WhisperModelOption.all.allSatisfy { $0.realtimeFactor > 0 },
          "у каждой модели есть оценка скорости")
    check(WhisperModelOption.all.allSatisfy { $0.downloadURL.hasPrefix("https://") },
          "модели скачиваются по https")
}

// MARK: - Стадии обработки

group("Стадии обработки") {
    check(JobStage.transcribing.isRunning, "транскрибация — активная стадия")
    check(!JobStage.paused.isRunning, "пауза — не активная стадия")
    // С этих стадий работу можно продолжить, не начиная заново: транскрипт уже
    // есть, а падал шаг саммари.
    check(JobStage.transcribed.isResumable, "с готового транскрипта можно продолжить")
    check(JobStage.failed.isResumable, "после ошибки можно продолжить")
    check(!JobStage.done.isResumable, "завершённую задачу продолжать незачем")
}

// MARK: - Переезд на единую папку

group("Переезд на единую папку") {
    let fm = FileManager.default
    let home = NSTemporaryDirectory() + "migration-test-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: home) }

    // Старая раскладка: кириллические папки и модели отдельно от данных.
    let legacy = home + "/Встречи"
    for sub in ["транскрипты/Встреча 1", "обработано", "tmp/Встреча 2"] {
        try? fm.createDirectory(atPath: legacy + "/" + sub, withIntermediateDirectories: true)
    }
    try? fm.createDirectory(atPath: home + "/whisper-models", withIntermediateDirectories: true)
    fm.createFile(atPath: home + "/whisper-models/ggml-medium.bin", contents: Data("модель".utf8))
    fm.createFile(atPath: legacy + "/транскрипты/Встреча 1/transcript.txt", contents: Data("текст".utf8))
    // Пути пишутся так же, как их пишет JSONEncoder приложения — с
    // экранированными косыми чертами. На «красивой» фикстуре с обычными
    // слешами тест проходил, а на настоящей истории замена не срабатывала.
    let escapedLegacy = legacy.replacingOccurrences(of: "/", with: "\\/")
    let history = """
    [{"sourcePath":"\(escapedLegacy)\\/tmp\\/Встреча 2\\/meeting.m4a","transcriptPath":"\(escapedLegacy)\\/транскрипты\\/Встреча 1\\/transcript.txt"}]
    """
    fm.createFile(atPath: legacy + "/history.json", contents: Data(history.utf8))

    // Новая папка уже существует со свежими скриптами — так делает сборка.
    let layout = AppLayout(homeDirectory: home, folderName: "MeetingApp")
    try? fm.createDirectory(atPath: layout.scriptsDir, withIntermediateDirectories: true)
    fm.createFile(atPath: layout.scriptsDir + "/transcribe.sh", contents: Data("новый скрипт".utf8))

    let report = LayoutMigration.run(homeDirectory: home, layout: layout,
                                     legacyFolderName: "Встречи",
                                     legacyModelsFolderName: "whisper-models")

    check(report.didSomething, "переезд что-то сделал")
    check(fm.fileExists(atPath: layout.transcriptsDir + "/Встреча 1/transcript.txt"),
          "транскрипты переехали в transcripts")
    check(fm.fileExists(atPath: layout.recordingsDir + "/Встреча 2"),
          "записи переехали в recordings")
    check(fm.fileExists(atPath: layout.modelsDir + "/ggml-medium.bin"),
          "модели переехали в models")
    check(!fm.fileExists(atPath: legacy), "старая папка удалена")
    check(fm.fileExists(atPath: layout.historyPath + ".before-migration"),
          "копия истории до переезда сохранена")

    let rewritten = String(data: fm.contents(atPath: layout.historyPath) ?? Data(), encoding: .utf8) ?? ""
    let escapedRecordings = layout.recordingsDir.replacingOccurrences(of: "/", with: "\\/")
    check(rewritten.contains(escapedRecordings + "\\/Встреча 2\\/meeting.m4a"),
          "путь к записи переписан")
    check(!rewritten.contains("Встречи"), "старых путей в истории не осталось")

    // Повторный запуск не должен ничего трогать: история уже на новом месте.
    let again = LayoutMigration.run(homeDirectory: home, layout: layout,
                                    legacyFolderName: "Встречи",
                                    legacyModelsFolderName: "whisper-models")
    check(!again.didSomething, "повторный переезд ничего не делает")
}

group("Переезд тестовой сборки не забирает общие модели") {
    let fm = FileManager.default
    let home = NSTemporaryDirectory() + "migration-models-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: home) }

    try? fm.createDirectory(atPath: home + "/Встречи-тест", withIntermediateDirectories: true)
    fm.createFile(atPath: home + "/Встречи-тест/history.json", contents: Data("[]".utf8))
    try? fm.createDirectory(atPath: home + "/whisper-models", withIntermediateDirectories: true)
    fm.createFile(atPath: home + "/whisper-models/ggml-large-v3.bin", contents: Data("модель".utf8))

    let layout = AppLayout(homeDirectory: home, folderName: "MeetingApp-Test")
    // Пустое имя папки моделей = модели не трогать. Однажды тестовая сборка
    // унесла у рабочей все модели — этот тест сторожит именно тот случай.
    LayoutMigration.run(homeDirectory: home, layout: layout,
                        legacyFolderName: "Встречи-тест",
                        legacyModelsFolderName: "")

    check(fm.fileExists(atPath: home + "/whisper-models/ggml-large-v3.bin"),
          "общие модели остались на месте")
    check(!fm.fileExists(atPath: layout.modelsDir + "/ggml-large-v3.bin"),
          "тестовая сборка не забрала модели себе")
}

group("Чтение истории старых версий") {
    // Историю пишет само приложение, и с каждым новым свойством задачи старые
    // файлы становятся «неполными». Разбор обязан это переживать: иначе одна
    // недостающая строчка обнуляет весь список — так уже терялась история.
    let legacy = """
    [{"id":"CCF6B47F-36C0-4497-8B08-DB54B0A733AF","sourcePath":"/tmp/a.m4a","name":"Встреча из старой версии",
      "stage":"done","createdAt":"2026-09-17T09:52:27Z","updatedAt":"2026-09-17T09:53:50Z"}]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        let jobs = try decoder.decode([Job].self, from: Data(legacy.utf8))
        equal(jobs.count, 1, "старая история читается")
        equal(jobs.first?.name, "Встреча из старой версии", "название сохранилось")
        equal(jobs.first?.stage, JobStage.done, "стадия сохранилась")
        check(jobs.first?.savedToNotes == false, "новое поле получает значение по умолчанию")
        check(jobs.first?.isMeetingRecording == false, "новое поле не ломает разбор")
    } catch {
        check(false, "старая история не прочиталась: \(error)")
    }

    // И то, что пишет сегодняшняя версия, тоже должно читаться обратно.
    do {
        var job = Job(sourcePath: "/tmp/b.m4a")
        job.savedToNotes = true
        job.isMeetingRecording = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([job])
        let back = try decoder.decode([Job].self, from: data)
        equal(back.first?.savedToNotes, true, "запись и чтение согласованы")
    } catch {
        check(false, "свежая история не прочиталась: \(error)")
    }
}

group("Удаление не воскресает из папки") {
    let fm = FileManager.default
    let home = NSTemporaryDirectory() + "delete-test-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: home) }

    let layout = AppLayout(homeDirectory: home, folderName: "MeetingApp")
    layout.createDirectories()

    let folder = layout.transcriptsDir + "/Встреча"
    try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var job = Job(sourcePath: layout.processedDir + "/x.m4a")
    job.name = "Встреча"
    job.transcriptPath = folder + "/transcript.txt"
    JobFolder.writeMeta(for: job)
    check(!JobFolder.scan(layout: layout).isEmpty, "задача видна на диске")

    // Удаление обязано убрать запись задачи из папки: иначе восстановление по
    // папкам вернёт её при следующем запуске, и удаление выглядит сломанным.
    try? fm.removeItem(atPath: JobFolder.metaPath(inFolder: folder))
    check(JobFolder.scan(layout: layout).isEmpty, "после удаления записи задача не находится")
}

group("Защита истории обработки") {
    // История — единственная запись о проделанной работе, и однажды она уже
    // обнулилась: приложение записало пустой список поверх четырёх задач.
    check(!HistorySafety.allowsWrite(newJobCount: 0, existingFileSize: 2071),
          "пустая история не пишется поверх непустой")
    check(HistorySafety.allowsWrite(newJobCount: 4, existingFileSize: 2071),
          "непустая история пишется поверх непустой")
    check(HistorySafety.allowsWrite(newJobCount: 0, existingFileSize: 0),
          "пустую историю можно записать, если файла ещё нет")
    check(HistorySafety.allowsWrite(newJobCount: 0, existingFileSize: 4),
          "пустую историю можно переписать поверх пустой")
}

group("Папка встречи как источник правды") {
    let fm = FileManager.default
    let home = NSTemporaryDirectory() + "folder-truth-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: home) }

    let layout = AppLayout(homeDirectory: home, folderName: "MeetingApp")
    layout.createDirectories()

    // Две задачи: одна с транскриптом, другая только с исходником.
    let folderA = layout.transcriptsDir + "/Встреча А"
    try? fm.createDirectory(atPath: folderA, withIntermediateDirectories: true)
    fm.createFile(atPath: folderA + "/transcript.txt", contents: Data("текст".utf8))
    var jobA = Job(sourcePath: layout.processedDir + "/a.m4a")
    jobA.name = "Встреча А"
    jobA.transcriptPath = folderA + "/transcript.txt"
    jobA.stage = .done
    check(JobFolder.writeMeta(for: jobA), "запись о задаче сохранена рядом с транскриптом")

    let folderB = layout.recordingsDir + "/Встреча Б"
    try? fm.createDirectory(atPath: folderB, withIntermediateDirectories: true)
    var jobB = Job(sourcePath: folderB + "/meeting.m4a")
    jobB.name = "Встреча Б"
    jobB.isMeetingRecording = true
    check(JobFolder.writeMeta(for: jobB), "запись о задаче сохранена рядом с записью встречи")

    let onDisk = JobFolder.scan(layout: layout)
    equal(onDisk.count, 2, "обе задачи нашлись на диске")

    // Главное свойство: история потеряна целиком, но собирается заново.
    let restored = JobFolder.merge(history: [], foundOnDisk: onDisk)
    equal(restored.added, 2, "потерянная история восстанавливается по папкам")
    check(restored.jobs.contains { $0.name == "Встреча А" && $0.stage == .done },
          "стадия задачи восстановилась вместе с ней")

    // Задача из истории главнее: она свежее той, что записана в папку.
    var newer = jobA
    newer.stage = .failed
    newer.updatedAt = Date().addingTimeInterval(60)
    let merged = JobFolder.merge(history: [newer], foundOnDisk: onDisk)
    equal(merged.added, 1, "из папок добавляется только то, чего нет в истории")
    check(merged.jobs.first { $0.id == jobA.id }?.stage == .failed,
          "запись из истории не затирается старой записью из папки")
}

group("Переименование встречи") {
    equal(JobRename.sanitized("  Встреча с коллегой  "), "Встреча с коллегой",
          "лишние пробелы убираются")
    // В имя папки нельзя косую черту и двоеточие: иначе переименование
    // разложило бы встречу по вложенным папкам или сломало путь.
    equal(JobRename.sanitized("Отчёт 12:30 / черновик"), "Отчёт 12-30 - черновик",
          "запрещённые символы заменяются")
    check(JobRename.sanitized(String(repeating: "я", count: 300)).count <= 120,
          "слишком длинное название обрезается")
    check(JobRename.sanitized("   ").isEmpty, "пустое название остаётся пустым")

    equal(JobRename.movedPath("/data/Старая/transcript.txt",
                              fromFolder: "/data/Старая", toFolder: "/data/Новая"),
          "/data/Новая/transcript.txt", "путь внутри переименованной папки обновляется")
    equal(JobRename.movedPath("/other/file.txt",
                              fromFolder: "/data/Старая", toFolder: "/data/Новая"),
          "/other/file.txt", "чужой путь не трогается")
}

group("Порядок задач в списке") {
    var older = Job(sourcePath: "/tmp/a.m4a")
    older.name = "Ранняя"
    older.createdAt = Date().addingTimeInterval(-3600)
    older.updatedAt = Date()   // недавно переименовали

    var newer = Job(sourcePath: "/tmp/b.m4a")
    newer.name = "Поздняя"
    newer.createdAt = Date().addingTimeInterval(-60)
    newer.updatedAt = Date().addingTimeInterval(-60)

    // Порядок держится по времени встречи: раньше сортировка шла по последнему
    // изменению, и переименование старой записи выбрасывало её наверх.
    let sorted = JobOrder.sortedForDisplay([older, newer])
    equal(sorted.first?.name, "Поздняя", "свежая встреча выше")
    equal(sorted.last?.name, "Ранняя", "переименование не поднимает старую встречу")
}

group("Время в проигрывателе") {
    equal(TimeFormat.mmss(0), "00:00", "ноль")
    equal(TimeFormat.mmss(65), "01:05", "минуты и секунды")
    equal(TimeFormat.mmss(3599), "59:59", "почти час")
    // Повреждённый файл может отдать бессмысленную длительность — на ней
    // ползунок раньше ронял приложение.
    equal(TimeFormat.mmss(.nan), "00:00", "нечисловая длительность")
    equal(TimeFormat.mmss(-5), "00:00", "отрицательная длительность")
}

// MARK: - Итог

print("")
if failures.isEmpty {
    print("Проверок пройдено: \(checks). Всё в порядке.")
    exit(0)
} else {
    print("Провалено \(failures.count) из \(checks):")
    for failure in failures { print("  ✗ \(failure)") }
    exit(1)
}
