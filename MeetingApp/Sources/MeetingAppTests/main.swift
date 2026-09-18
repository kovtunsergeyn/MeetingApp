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
    let both: (String) -> Bool = { $0.hasSuffix("system.m4a") || $0.hasSuffix("mic.m4a") }

    let separate = MeetingTracks.select(sourcePath: dir + "/meeting.m4a",
                                        isMeetingRecording: true,
                                        fileExists: both)
    equal(separate.mainPath, dir + "/system.m4a", "собеседники — это системный звук")
    equal(separate.micPath, dir + "/mic.m4a", "свой голос — это микрофон")

    // Одна дорожка без второй превратила бы разговор в монолог: распознаём
    // тогда сведённый файл целиком.
    let onlySystem = MeetingTracks.select(sourcePath: dir + "/meeting.m4a",
                                          isMeetingRecording: true,
                                          fileExists: { $0.hasSuffix("system.m4a") })
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
    let history = """
    [{"sourcePath":"\(legacy)/tmp/Встреча 2/meeting.m4a","transcriptPath":"\(legacy)/транскрипты/Встреча 1/transcript.txt"}]
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
    check(rewritten.contains(layout.recordingsDir + "/Встреча 2/meeting.m4a"),
          "путь к записи переписан")
    check(!rewritten.contains("/Встречи/"), "старых путей в истории не осталось")

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
