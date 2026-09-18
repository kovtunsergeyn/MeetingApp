import Foundation
import AppKit
import CoreAudio
import CoreGraphics
import ServiceManagement
import UniformTypeIdentifiers
import MeetingCore

@MainActor
final class JobStore: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published var jobs: [Job] = []
    @Published var logText: String = ""
    @Published var currentJobID: UUID?

    // Интерфейсное состояние (вместо @State — property wrapper-макросы не работают без Xcode).
    @Published var selectedSection: AppSection = .queue
    @Published var selectedJobID: UUID? = nil
    @Published var searchText: String = ""
    @Published var stageFilter: String = "all"
    @Published var showSettings: Bool = false
    @Published var showGlossarySheet: Bool = false
    @Published var pendingDependencies: [Dependency] = []
    @Published var showDependencySheet: Bool = false
    @Published var isInstallingDependency: Bool = false
    @Published var youtubeURLText: String = ""
    @Published var expandedErrorJobIDs: Set<UUID> = []

    // Лог свёрнут по умолчанию — вместо него показываем прогресс текущего шага.
    @Published var isLogExpanded: Bool = false
    @Published var stageProgressFraction: Double? = nil
    @Published var stageStatusText: String = ""

    private var progressTimer: Timer?
    private var stageStartDate: Date?
    private var stageEstimatedSeconds: Double?
    private var stageDirectFraction: Double?
    private var stageDirectStatusText: String?

    func toggleErrorDetail(jobID: UUID) {
        if expandedErrorJobIDs.contains(jobID) {
            expandedErrorJobIDs.remove(jobID)
        } else {
            expandedErrorJobIDs.insert(jobID)
        }
    }


    let audioRecorder = AudioRecorder()
    let systemAudioRecorder = SystemAudioRecorder()
    private let meetingDetector = BrowserMeetingDetector()
    private let calendarDetector = CalendarMeetingDetector()

    // MARK: - Автоопределение и запись встреч (ВКС)

    @Published var meetingDetectionEnabled: Bool = UserDefaults.standard.object(forKey: "meetingDetectionEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "meetingDetectionEnabled") {
        didSet {
            UserDefaults.standard.set(meetingDetectionEnabled, forKey: "meetingDetectionEnabled")
            if meetingDetectionEnabled {
                meetingDetector.start()
                calendarDetector.start()
            } else {
                meetingDetector.stop()
                calendarDetector.stop()
            }
        }
    }
    // Свои домены ВКС (внутрикорпоративные системы), которых нет и не может
    // быть в списке из коробки (Zoom/Meet/Teams).
    @Published var customMeetingDomains: [CustomMeetingDomain] = JobStore.loadCustomMeetingDomains() {
        didSet {
            JobStore.saveCustomMeetingDomains(customMeetingDomains)
            MeetingLinkDetector.customPatterns = customMeetingDomains.map { ($0.domain, $0.label) }
        }
    }

    @Published var newMeetingDomainText: String = ""
    @Published var newMeetingLabelText: String = ""

    func addCustomMeetingDomain(domain: String, label: String) {
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDomain.isEmpty else { return }
        customMeetingDomains.append(CustomMeetingDomain(domain: cleanDomain, label: cleanLabel.isEmpty ? cleanDomain : cleanLabel))
        appendLog("Добавлена платформа ВКС: \(cleanDomain). Всего своих платформ: \(customMeetingDomains.count).")
    }

    func removeCustomMeetingDomain(_ id: UUID) {
        customMeetingDomains.removeAll { $0.id == id }
        appendLog("Удалена платформа ВКС. Осталось своих платформ: \(customMeetingDomains.count).")
    }

    private static func loadCustomMeetingDomains() -> [CustomMeetingDomain] {
        guard let data = UserDefaults.standard.data(forKey: "customMeetingDomains"),
              let decoded = try? JSONDecoder().decode([CustomMeetingDomain].self, from: data) else { return [] }
        return decoded
    }

    private static func saveCustomMeetingDomains(_ domains: [CustomMeetingDomain]) {
        guard let data = try? JSONEncoder().encode(domains) else { return }
        UserDefaults.standard.set(data, forKey: "customMeetingDomains")
    }

    @Published var detectedMeetingURL: String? = nil
    @Published var detectedMeetingPlatform: String? = nil
    @Published var isMeetingRecordingActive: Bool = false
    @Published var meetingRecordingElapsedSeconds: Int = 0
    @Published var meetingRecordingPermissionIssue: Bool = false

    private var ignoredMeetingURLs: Set<String> = []
    private var meetingRecordingStartDate: Date?
    private var pendingSystemAudioURL: URL?
    private var meetingElapsedTimer: Timer?
    private var originalDefaultInputDeviceID: AudioDeviceID?

    // MARK: - Выбор микрофона для записи встречи

    @Published var availableMicrophones: [AudioDevices.Device] = []
    @Published var selectedMicrophoneDeviceID: AudioDeviceID? = {
        let stored = UserDefaults.standard.integer(forKey: "selectedMicrophoneDeviceID")
        return stored == 0 ? nil : AudioDeviceID(stored)
    }() {
        didSet {
            UserDefaults.standard.set(Int(selectedMicrophoneDeviceID ?? 0), forKey: "selectedMicrophoneDeviceID")
        }
    }

    func refreshMicrophoneList() {
        availableMicrophones = AudioDevices.listInputDevices()
        // Если ранее выбранного устройства больше нет (отключили гарнитуру
        // и т.п.) — возвращаемся к системному микрофону по умолчанию.
        if let selected = selectedMicrophoneDeviceID, !availableMicrophones.contains(where: { $0.id == selected }) {
            selectedMicrophoneDeviceID = nil
        }
    }

    func startMeetingDetection() {
        meetingDetector.onMeetingDetected = { [weak self] url, platform in
            self?.handleMeetingDetected(url: url, platform: platform)
        }
        calendarDetector.onMeetingDetected = { [weak self] url, platform in
            self?.handleMeetingDetected(url: url, platform: platform)
        }
        calendarDetector.onAccessStatus = { [weak self] status in
            self?.appendLog("Календарь (детектор встреч): \(status)")
        }
        meetingDetector.onDiagnostic = { [weak self] message in
            self?.appendLog("Браузер (детектор встреч): \(message)")
        }
        guard meetingDetectionEnabled else { return }
        meetingDetector.start()
        calendarDetector.start()
    }

    private func handleMeetingDetected(url: String, platform: String) {
        guard !isMeetingRecordingActive else { return }
        guard detectedMeetingURL == nil else { return }
        guard !ignoredMeetingURLs.contains(url) else { return }
        detectedMeetingURL = url
        detectedMeetingPlatform = platform
        refreshMicrophoneList()

        // Системное уведомление — путь, который macOS предлагает для таких
        // предложений. Своё плавающее окно остаётся запасным вариантом, если
        // уведомления запрещены: иначе предложить запись было бы нечем.
        if !MeetingNotifier.shared.notifyMeetingDetected(platform: platform) {
            MeetingAlertPanelController.shared.show(
                store: self,
                platform: platform,
                onStart: { [weak self] in self?.startMeetingRecording() },
                onDismiss: { [weak self] in self?.dismissDetectedMeeting() }
            )
        }
    }

    func dismissDetectedMeeting() {
        if let url = detectedMeetingURL { ignoredMeetingURLs.insert(url) }
        detectedMeetingURL = nil
        detectedMeetingPlatform = nil
        MeetingAlertPanelController.shared.hide()
    }

    func startMeetingRecording() {
        detectedMeetingURL = nil
        detectedMeetingPlatform = nil
        meetingRecordingPermissionIssue = false
        MeetingAlertPanelController.shared.hide()

        // Если выбран не системный микрофон по умолчанию — переключаем на
        // время записи и запоминаем, что было, чтобы вернуть после.
        if let chosen = selectedMicrophoneDeviceID, chosen != AudioDevices.defaultInputDeviceID() {
            originalDefaultInputDeviceID = AudioDevices.defaultInputDeviceID()
            if !AudioDevices.setDefaultInputDevice(chosen) {
                appendLog("Не удалось переключиться на выбранный микрофон — записываю с текущего по умолчанию.")
                originalDefaultInputDeviceID = nil
            }
        }

        audioRecorder.start()

        if !CGPreflightScreenCaptureAccess() {
            appendLog("Запускаю запись встречи… жду подтверждения разрешения «Запись экрана» в системном диалоге.")
        } else {
            appendLog("Запускаю запись встречи…")
        }

        Task {
            guard let systemURL = await systemAudioRecorder.start() else {
                let detail = systemAudioRecorder.lastErrorMessage ?? "причина неизвестна"
                appendLog("Не удалось начать запись системного звука: \(detail)")
                meetingRecordingPermissionIssue = true
                audioRecorder.cancel()
                return
            }
            pendingSystemAudioURL = systemURL
            meetingRecordingStartDate = Date()
            isMeetingRecordingActive = true
            startMeetingElapsedTimer()
            appendLog("Начата запись встречи.")
        }
    }

    func stopMeetingRecording() {
        guard isMeetingRecordingActive else { return }
        isMeetingRecordingActive = false
        stopMeetingElapsedTimer()

        if let original = originalDefaultInputDeviceID {
            AudioDevices.setDefaultInputDevice(original)
            originalDefaultInputDeviceID = nil
        }

        Task {
            let micURL = audioRecorder.stop()
            let systemURL = await systemAudioRecorder.stop() ?? pendingSystemAudioURL
            pendingSystemAudioURL = nil
            guard let systemURL else {
                appendLog("Запись встречи не удалась — нет файла системного звука.")
                return
            }
            await finalizeMeetingRecording(systemURL: systemURL, micURL: micURL)
        }
    }

    private func finalizeMeetingRecording(systemURL: URL, micURL: URL?) async {
        appendLog("Свожу дорожки записи встречи…")
        let startDate = meetingRecordingStartDate ?? Date()
        let safeName = "Встреча " + DateFormatter.rowDate.string(from: startDate).replacingOccurrences(of: ":", with: "-")
        let destDir = recordingsDir + "/" + safeName
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let mixedPath = destDir + "/meeting.m4a"

        let result = await runScript(
            name: "mix_meeting_audio.sh",
            arguments: [systemURL.path, micURL?.path ?? "/dev/null", mixedPath],
            jobID: nil
        )

        // Исходные дорожки не удаляем: сведённый файл нужен, чтобы переслушать
        // встречу, а распознаём мы дорожки по отдельности — так речь не
        // накладывается друг на друга и видно, кто говорит. Удалим их сразу
        // после успешной транскрибации.
        let fm = FileManager.default
        try? fm.removeItem(atPath: destDir + "/" + MeetingTracks.systemTrackName)
        try? fm.moveItem(at: systemURL, to: URL(fileURLWithPath: destDir + "/" + MeetingTracks.systemTrackName))
        if let micURL {
            try? fm.removeItem(atPath: destDir + "/" + MeetingTracks.micTrackName)
            try? fm.moveItem(at: micURL, to: URL(fileURLWithPath: destDir + "/" + MeetingTracks.micTrackName))
        } else {
            // Без дорожки микрофона встреча запишется «в одну сторону»: будут
            // слышны собеседники, но не свой голос. Обычно это неразрешённый
            // доступ к микрофону.
            appendLog("Микрофон не записался — проверь разрешение на микрофон в системных настройках.")
        }

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: mixedPath) else {
            appendLog("Не удалось свести аудио встречи (код \(result.exitCode)).")
            return
        }

        var job = Job(sourcePath: mixedPath)
        job.name = safeName
        job.isMeetingRecording = true
        jobs.append(job)
        appendLog("Запись встречи добавлена в очередь: \(safeName)")
        saveHistory()
        startNextIfIdle()
    }

    private func startMeetingElapsedTimer() {
        meetingRecordingElapsedSeconds = 0
        meetingElapsedTimer?.invalidate()
        meetingElapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meetingRecordingElapsedSeconds += 1 }
        }
    }

    private func stopMeetingElapsedTimer() {
        meetingElapsedTimer?.invalidate()
        meetingElapsedTimer = nil
    }

    // MARK: - Настройки

    @Published var scriptsDir: String = UserDefaults.standard.string(forKey: "scriptsDir")
        ?? (NSHomeDirectory() + "/" + JobStore.dataFolderName + "/scripts") {
        didSet { UserDefaults.standard.set(scriptsDir, forKey: "scriptsDir") }
    }

    @Published var languageID: String = UserDefaults.standard.string(forKey: "languageID") ?? "auto" {
        didSet { UserDefaults.standard.set(languageID, forKey: "languageID") }
    }

    // Термины, аббревиатуры и имена, которые часто звучат на встречах. Передаются
    // whisper как подсказка при распознавании и Claude — как справочник при саммари.
    @Published var glossary: String = UserDefaults.standard.string(forKey: "glossary") ?? "" {
        didSet { UserDefaults.standard.set(glossary, forKey: "glossary") }
    }

    // Куда складывать саммари в Notion. У каждого своя база, поэтому имя —
    // настройка, а не зашитая в код строка. Если базы с таким именем нет,
    // Claude создаст её при первом сохранении.
    @Published var notionDatabaseName: String =
        UserDefaults.standard.string(forKey: "notionDatabaseName") ?? "Саммари встреч" {
        didSet { UserDefaults.standard.set(notionDatabaseName, forKey: "notionDatabaseName") }
    }

    @Published var modelID: String = UserDefaults.standard.string(forKey: "modelID")
        ?? WhisperModelOption.recommended().id {
        didSet { UserDefaults.standard.set(modelID, forKey: "modelID") }
    }

    private var selectedModel: WhisperModelOption { return WhisperModelOption.byID(modelID) }




    // MARK: - Пути

    // Папка с данными задаётся в Info.plist (ключ MADataFolder) при сборке:
    // у промышленной сборки это ~/Встречи, у тестовой — ~/Встречи-тест,
    // чтобы проверки правок не трогали рабочую историю обработки.
    static let dataFolderName: String =
        (Bundle.main.object(forInfoDictionaryKey: "MADataFolder") as? String) ?? "MeetingApp"

    // Имя старой папки данных — нужно только для разового переезда.
    static let legacyDataFolderName: String =
        (Bundle.main.object(forInfoDictionaryKey: "MALegacyDataFolder") as? String) ?? "Встречи"

    // Старая папка моделей. У тестовой сборки пустая: модели общие и
    // принадлежат рабочей сборке, забирать их проверка правок не должна.
    static let legacyModelsFolderName: String =
        (Bundle.main.object(forInfoDictionaryKey: "MALegacyModelsFolder") as? String) ?? "whisper-models"

    // Всё, что создаёт приложение, лежит в одной папке с латинским именем:
    // раньше данные были разбросаны (~/Встречи и ~/whisper-models), а кириллица
    // в путях ломала часть консольных инструментов.
    // Раскладка папок и переезд со старой живут в ядре — там их проверяют тесты.
    private let layout = AppLayout(homeDirectory: NSHomeDirectory(), folderName: JobStore.dataFolderName)

    private var baseDir: String { return layout.baseDir }
    private var historyURL: URL { return URL(fileURLWithPath: layout.historyPath) }
    private var modelsDir: String { return layout.modelsDir }
    private var recordingsDir: String { return layout.recordingsDir }
    private var transcriptsDir: String { return layout.transcriptsDir }
    private var processedDir: String { return layout.processedDir }
    private var modelPath: String { return modelsDir + "/" + selectedModel.fileName }

    // MARK: - Управление моделями whisper (скачать / удалить)

    @Published var modelDownloadInProgress: String? = nil

    func isModelDownloaded(_ option: WhisperModelOption) -> Bool {
        return FileManager.default.fileExists(atPath: modelsDir + "/" + option.fileName)
    }

    func modelFileSizeText(_ option: WhisperModelOption) -> String? {
        let path = modelsDir + "/" + option.fileName
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func downloadModel(_ option: WhisperModelOption) {
        guard modelDownloadInProgress == nil else { return }
        modelDownloadInProgress = option.id
        Task {
            appendLog("Скачиваю модель \(option.fileName)…")
            let result = await runScript(
                name: "install_dep.sh",
                arguments: ["model", option.id, option.fileName, option.downloadURL, modelsDir],
                jobID: nil
            )
            if result.exitCode == 0 {
                appendLog("Модель \(option.fileName) готова.")
            } else {
                appendLog("Не удалось скачать модель \(option.fileName) (код \(result.exitCode)).")
            }
            modelDownloadInProgress = nil
        }
    }

    // Не даём удалить модель, которая сейчас выбрана как активная — иначе
    // следующая задача просто не найдёт файл посреди обработки.
    func deleteModel(_ option: WhisperModelOption) {
        guard option.id != modelID else {
            appendLog("Нельзя удалить активную модель — сначала выбери другую.")
            return
        }
        let path = modelsDir + "/" + option.fileName
        do {
            try FileManager.default.removeItem(atPath: path)
            appendLog("Модель \(option.fileName) удалена.")
        } catch {
            appendLog("Не удалось удалить модель \(option.fileName): \(error.localizedDescription)")
        }
    }

    // Процесс текущей стадии — нужен, чтобы уметь ставить на паузу.
    private var currentProcess: Process?
    private var pauseRequested: Bool = false
    private var cancelRequested: Bool = false

    // MARK: - Инициализация

    init() {
        JobStore.migrateLegacySettingsIfNeeded()
        migrateLegacyLayoutIfNeeded()
        createDirectories()
        loadHistory()
        normalizeStagesOnLaunch()
        MeetingLinkDetector.customPatterns = customMeetingDomains.map { ($0.domain, $0.label) }
        startMeetingDetection()
        refreshNotionAvailability()
        MeetingNotifier.shared.prepare(store: self)
    }

    private func createDirectories() {
        layout.createDirectories()
    }

    // MARK: - Переезд настроек со старого идентификатора

    // macOS хранит настройки приложения по идентификатору пакета. Когда мы
    // сменили идентификатор на нейтральный, все настройки — словарь, язык,
    // выбранная модель, свои платформы ВКС — остались в прежнем хранилище и
    // приложение запустилось пустым. Переносим их один раз при первом запуске.
    static func migrateLegacySettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "settingsMigratedFromLegacyBundle") else { return }
        guard let legacyID = Bundle.main.object(forInfoDictionaryKey: "MALegacyBundleID") as? String,
              !legacyID.isEmpty,
              legacyID != Bundle.main.bundleIdentifier,
              let legacy = UserDefaults(suiteName: legacyID) else { return }

        let keys = [
            "languageID", "modelID", "glossary", "notionDatabaseName",
            "customMeetingDomains", "meetingDetectionEnabled", "selectedMicrophoneDeviceID"
        ]
        var moved: [String] = []
        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            moved.append(key)
        }
        defaults.set(true, forKey: "settingsMigratedFromLegacyBundle")
        if !moved.isEmpty {
            NSLog("MeetingApp: перенесены настройки со старого идентификатора: %@", moved.joined(separator: ", "))
        }
    }

    // MARK: - Переезд со старой раскладки

    // Раньше данные лежали в двух местах с кириллическими именами: ~/Встречи
    // (история, транскрипты, записи) и ~/whisper-models (модели). Кириллица в
    // путях подводит часть консольных инструментов, а разбросанные папки трудно
    // найти и удалить. Теперь всё в одной папке с латинским именем; при первом
    // запуске новой версии старая раскладка переезжает в неё автоматически.
    private func migrateLegacyLayoutIfNeeded() {
        let report = LayoutMigration.run(
            homeDirectory: NSHomeDirectory(),
            layout: layout,
            legacyFolderName: JobStore.legacyDataFolderName,
            legacyModelsFolderName: JobStore.legacyModelsFolderName
        )
        // Даже если переезд уже был раньше, в истории могли остаться старые
        // пути — чиним их отдельно.
        if LayoutMigration.repairLingeringLegacyPaths(
            homeDirectory: NSHomeDirectory(),
            layout: layout,
            legacyFolderName: JobStore.legacyDataFolderName,
            legacyModelsFolderName: JobStore.legacyModelsFolderName
        ) {
            appendLog("Пути в истории обновлены под новую папку данных.")
        }

        guard report.didSomething else { return }
        appendLog("Данные переехали в одну папку: \(baseDir).")

        // Путь к скриптам мог быть сохранён в настройках вручную — чиним.
        if scriptsDir.hasPrefix(NSHomeDirectory() + "/" + JobStore.legacyDataFolderName) {
            scriptsDir = layout.scriptsDir
        }
    }

    // Если приложение закрыли в момент работы — помечаем такие задачи паузой.
    // Сохраняем на диск, только если что-то реально изменилось: история — это
    // единственная запись о проделанной работе, её нельзя перезаписывать вслепую.
    private func normalizeStagesOnLaunch() {
        var changed = false
        for index in jobs.indices where jobs[index].stage.isRunning {
            jobs[index].stage = .paused
            jobs[index].lastError = "Приложение было закрыто во время обработки"
            changed = true
        }
        if changed {
            saveHistory()
        }
    }

    // MARK: - История

    func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        guard let data = try? Data(contentsOf: historyURL) else {
            appendLog("Не удалось прочитать историю задач: \(historyURL.path)")
            return
        }
        // Пустой файл — не ошибка (например, первый запуск), но не должен
        // считаться «пустой историей», если на самом деле не смог распарситься.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            jobs = try decoder.decode([Job].self, from: data)
            appendLog("История загружена: задач — \(jobs.count).")
        } catch {
            appendLog("История задач повреждена и не загружена, файл не тронут: \(error.localizedDescription)")
        }
    }

    func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(jobs) else { return }

        let existing = (try? Data(contentsOf: historyURL)) ?? Data()
        guard HistorySafety.allowsWrite(newJobCount: jobs.count, existingFileSize: existing.count) else {
            appendLog("Пустая история не записана поверх существующей — файл не тронут.")
            return
        }

        // Предыдущая версия остаётся рядом: если что-то пойдёт не так,
        // историю можно вернуть, не выясняя, кто и когда её перезаписал.
        if !existing.isEmpty {
            try? existing.write(to: URL(fileURLWithPath: historyURL.path + ".bak"))
        }
        try? data.write(to: historyURL)
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        let entry = "[" + stamp + "] " + line + "\n"
        logText += entry
        writeToLogFile(entry)
    }

    // Лог живёт и в файле: окно с логом человек обычно открывает уже после
    // того, как что-то пошло не так, а в памяти остаётся только текущий запуск.
    private var logFileURL: URL { return URL(fileURLWithPath: baseDir + "/app.log") }

    private func writeToLogFile(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        let fm = FileManager.default
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            // Чтобы файл не рос без предела, раз в запуск подрезаем его.
            if let size = try? fm.attributesOfItem(atPath: logFileURL.path)[.size] as? Int, size > 2_000_000 {
                trimLogFile()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func trimLogFile() {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        let tail = text.suffix(500_000)
        try? String(tail).data(using: .utf8)?.write(to: logFileURL)
    }

    // MARK: - Прогресс текущего шага (замена развёрнутого лога по умолчанию)

    private func startStageTimer(estimatedSeconds: Double?) {
        stageStartDate = Date()
        stageEstimatedSeconds = estimatedSeconds
        stageDirectFraction = nil
        stageDirectStatusText = nil
        updateProgressDisplay()

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgressDisplay() }
        }
    }

    private func stopStageTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        stageStartDate = nil
        stageEstimatedSeconds = nil
        stageDirectFraction = nil
        stageDirectStatusText = nil
        stageProgressFraction = nil
        stageStatusText = ""
    }

    private func updateProgressDisplay() {
        guard let start = stageStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)

        if let direct = stageDirectFraction {
            stageProgressFraction = direct
            stageStatusText = stageDirectStatusText ?? "\(Int(direct * 100))%"
        } else if let estimated = stageEstimatedSeconds, estimated > 0 {
            let fraction = min(elapsed / estimated, 0.97)
            stageProgressFraction = fraction
            let remaining = max(estimated - elapsed, 0)
            stageStatusText = "~" + Self.formatDuration(remaining) + " осталось"
        } else {
            stageProgressFraction = nil
            stageStatusText = "идёт " + Self.formatDuration(elapsed)
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return "\(minutes) мин \(secs) с"
        }
        return "\(secs) с"
    }

    // Вызывается из парсера вывода yt-dlp, когда встречается строка прогресса.
    private func setDirectProgress(fraction: Double, statusText: String?) {
        stageDirectFraction = fraction
        stageDirectStatusText = statusText
        updateProgressDisplay()
    }

    // Парсинг строк вида "[download]  42.3% of ... ETA 00:12".
    private func parseYtDlpProgress(_ chunk: String) {
        for line in chunk.components(separatedBy: .newlines) {
            guard line.contains("%") else { continue }
            guard let percentRange = line.range(of: #"[0-9]+\.[0-9]%"#, options: .regularExpression) else { continue }
            let percentText = line[percentRange].dropLast()
            guard let percent = Double(percentText) else { continue }
            var status = String(format: "%.0f%%", percent)
            if let etaRange = line.range(of: #"ETA [0-9:]+"#, options: .regularExpression) {
                status += " (" + line[etaRange].replacingOccurrences(of: "ETA ", with: "осталось ") + ")"
            }
            setDirectProgress(fraction: percent / 100, statusText: status)
        }
    }

    // Парсинг строки "DURATION_SECONDS:123.4", которую печатает transcribe.sh.
    private func parseTranscribeDuration(_ chunk: String) {
        guard let duration = OutputParsing.durationSeconds(in: chunk) else { return }
        stageEstimatedSeconds = max(duration * selectedModel.realtimeFactor, 5)
    }

    // MARK: - Добавление файлов

    func addFiles(_ urls: [URL]) {
        var added = 0
        for url in urls where MediaKind.isSupported(url) {
            let alreadyQueued = jobs.contains { job in
                return job.sourcePath == url.path && job.stage != .done
            }
            if alreadyQueued { continue }
            jobs.append(Job(sourcePath: url.path))
            added += 1
        }
        if added > 0 {
            appendLog("Добавлено файлов: \(added)")
            saveHistory()
            startNextIfIdle()
        } else {
            appendLog("Подходящих файлов не найдено (поддерживаются видео и аудио).")
        }
    }

    // Добавляет запись, сделанную через микрофон, как обычную задачу.
    func addRecordedFile(_ url: URL) {
        let name = "Запись " + DateFormatter.rowDate.string(from: Date())
        let destination = recordingsDir + "/" + name.replacingOccurrences(of: ":", with: "-") + "." + url.pathExtension
        try? FileManager.default.moveItem(atPath: url.path, toPath: destination)
        var job = Job(sourcePath: destination)
        job.name = name
        jobs.append(job)
        appendLog("Добавлена запись с микрофона: \(name)")
        saveHistory()
        startNextIfIdle()
    }

    // Прикрепляет готовый текстовый транскрипт — пропускаем распознавание речи
    // и сразу переходим к шагу саммари.
    func addTranscriptFile(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let destDir = transcriptsDir + "/" + name
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let destPath = destDir + "/transcript.txt"
        do {
            if FileManager.default.fileExists(atPath: destPath) {
                try FileManager.default.removeItem(atPath: destPath)
            }
            try FileManager.default.copyItem(atPath: url.path, toPath: destPath)
        } catch {
            appendLog("Не удалось скопировать транскрипт: \(error.localizedDescription)")
            return
        }

        var job = Job(sourcePath: "")
        job.name = name
        job.transcriptPath = destPath
        job.stage = .transcribed
        jobs.append(job)
        appendLog("Прикреплён готовый транскрипт: \(name)")
        saveHistory()
        startNextIfIdle()
    }

    // MARK: - Добавление ссылки на YouTube

    func addYouTubeURL(_ rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard YouTubeLink.isYouTubeURL(trimmed) else {
            appendLog("Это не похоже на ссылку YouTube: \(trimmed)")
            return
        }
        let alreadyQueued = jobs.contains { $0.youtubeURL == trimmed && $0.stage != .done }
        if alreadyQueued {
            appendLog("Эта ссылка уже в очереди.")
            return
        }
        let job = Job(youtubeURL: trimmed, name: "YouTube-видео")
        jobs.append(job)
        youtubeURLText = ""
        appendLog("Добавлена ссылка на YouTube: \(trimmed)")
        saveHistory()
        startNextIfIdle()
    }

    // MARK: - Управление очередью

    func startNextIfIdle() {
        guard currentJobID == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.stage == .queued || $0.stage == .transcribed }) else { return }
        run(jobID: jobs[index].id)
    }

    func resume(jobID: UUID) {
        guard currentJobID == nil else {
            appendLog("Сейчас уже идёт другая обработка — дождись её завершения.")
            return
        }
        run(jobID: jobID)
    }

    // Пауза — останавливает текущий шаг, но запоминает прогресс для продолжения.
    func pauseCurrent() {
        guard let process = currentProcess, process.isRunning else { return }
        pauseRequested = true
        process.terminate()
        appendLog("Запрошена пауза — останавливаю текущий шаг.")
    }

    // Стоп и очистка — прерывает текущую задачу и стирает её прогресс полностью.
    func stopAndClear(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }

        if currentJobID == jobID, let process = currentProcess, process.isRunning {
            cancelRequested = true
            process.terminate()
        }

        cleanupTempFiles(for: job)
        jobs.removeAll { $0.id == jobID }
        saveHistory()
        appendLog("Остановлено и очищено: \(job.name)")
    }

    private func cleanupTempFiles(for job: Job) {
        let fm = FileManager.default
        let tmpDir = recordingsDir + "/" + job.name
        try? fm.removeItem(atPath: tmpDir)
        if let transcriptPath = job.transcriptPath {
            try? fm.removeItem(atPath: URL(fileURLWithPath: transcriptPath).deletingLastPathComponent().path)
        }
    }

    func removeJob(jobID: UUID) {
        jobs.removeAll { $0.id == jobID }
        saveHistory()
    }

    // MARK: - Зависимости

    func missingDependencies(requireClaude: Bool, requireYtDlp: Bool = false) -> [Dependency] {
        var missing: [Dependency] = []
        if which("ffmpeg") == nil { missing.append(Dependency.ffmpeg) }
        if which("whisper-cli") == nil { missing.append(Dependency.whisper) }
        if requireYtDlp && which("yt-dlp") == nil { missing.append(Dependency.ytdlp) }
        if !FileManager.default.fileExists(atPath: modelsDir + "/ggml-silero-v5.1.2.bin") {
            missing.append(Dependency.vad)
        }
        if !FileManager.default.fileExists(atPath: modelPath) { missing.append(Dependency.model(selectedModel)) }
        if requireClaude && (which("claude") == nil || !isClaudeAuthenticated()) {
            missing.append(Dependency.claude)
        }
        return missing
    }

    // Быстрая локальная проверка (без сети) — авторизован ли Claude Code.
    private func isClaudeAuthenticated() -> Bool {
        guard let claudePath = which("claude") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.contains("\"loggedIn\": true") || output.contains("\"loggedIn\":true")
    }

    func checkDependenciesAndPrompt() {
        let missing = missingDependencies(requireClaude: true, requireYtDlp: true)
        if missing.isEmpty {
            appendLog("Все компоненты на месте.")
            return
        }
        pendingDependencies = missing
        showDependencySheet = true
    }

    func installDependencies(_ deps: [Dependency]) {
        let installable = deps.filter { $0.isAutoInstallable }
        guard !installable.isEmpty else {
            showDependencySheet = false
            return
        }
        isInstallingDependency = true
        let ids = installable.map { $0.id }
        Task {
            for id in ids {
                if id == "claude" {
                    await installAndLoginClaude()
                    continue
                }
                appendLog("Устанавливаю компонент: \(id)…")
                let arguments: [String]
                if id.hasPrefix("model:") {
                    let option = WhisperModelOption.byID(String(id.dropFirst("model:".count)))
                    arguments = ["model", option.id, option.fileName, option.downloadURL, modelsDir]
                } else if id == "vad" {
                    arguments = ["vad", modelsDir]
                } else {
                    arguments = [id]
                }
                let result = await runScript(name: "install_dep.sh", arguments: arguments, jobID: nil)
                if result.exitCode == 0 {
                    rememberInstalledComponent(id)
                    appendLog("Компонент \(id) установлен.")
                } else {
                    appendLog("Не удалось установить \(id) (код \(result.exitCode)).")
                }
            }
            isInstallingDependency = false
            showDependencySheet = false
            pendingDependencies = missingDependencies(requireClaude: true, requireYtDlp: true)
        }
    }

    // Claude Code: ставим бинарник обычным скриптом, а вот вход в аккаунт —
    // отдельный интерактивный шаг (claude auth login ждёт код из браузера).
    private func installAndLoginClaude() async {
        if which("claude") == nil {
            appendLog("Устанавливаю компонент: claude…")
            let result = await runScript(name: "install_dep.sh", arguments: ["claude"], jobID: nil)
            if result.exitCode == 0 {
                appendLog("Claude Code установлен.")
            } else {
                appendLog("Не удалось установить Claude Code (код \(result.exitCode)).")
                return
            }
        }

        guard !isClaudeAuthenticated() else {
            appendLog("В Claude Code уже выполнен вход.")
            return
        }

        showDependencySheet = false
        appendLog("Вхожу в аккаунт Anthropic…")
        let success = await runClaudeLogin()
        appendLog(success ? "Вход в Claude Code выполнен." : "Вход в Claude Code не завершён.")
    }

    // MARK: - Интерактивный вход в Claude Code (claude auth login)

    @Published var showClaudeLoginSheet: Bool = false
    @Published var claudeLoginURL: String? = nil
    @Published var claudeLoginCodeInput: String = ""

    private var claudeLoginProcess: Process?
    private var claudeLoginStdin: FileHandle?
    private var claudeLoginContinuation: CheckedContinuation<Bool, Never>?

    private func runClaudeLogin() async -> Bool {
        guard let claudePath = which("claude") else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "login"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        let collector = OutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            collector.append(text)
            Task { @MainActor in
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { self.appendLog(trimmed) }
                if self.claudeLoginURL == nil, let url = JobStore.extractLoginURL(from: collector.text) {
                    self.claudeLoginURL = url
                    self.openURL(url)
                    self.showClaudeLoginSheet = true
                }
            }
        }

        do {
            try process.run()
        } catch {
            appendLog("Не удалось запустить вход в Claude Code: \(error.localizedDescription)")
            return false
        }

        claudeLoginProcess = process
        claudeLoginStdin = stdinPipe.fileHandleForWriting

        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            claudeLoginContinuation = continuation
            process.terminationHandler = { proc in
                Task { @MainActor in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    self.claudeLoginContinuation?.resume(returning: proc.terminationStatus == 0)
                    self.claudeLoginContinuation = nil
                }
            }
        }

        claudeLoginProcess = nil
        claudeLoginStdin = nil
        showClaudeLoginSheet = false
        claudeLoginURL = nil
        return success
    }

    private static func extractLoginURL(from output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            if let range = line.range(of: "https://") {
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func submitClaudeLoginCode() {
        guard let stdin = claudeLoginStdin else { return }
        let code = claudeLoginCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        if let data = (code + "\n").data(using: .utf8) {
            stdin.write(data)
        }
        claudeLoginCodeInput = ""
        appendLog("Код отправлен, завершаю вход…")
    }

    func cancelClaudeLogin() {
        claudeLoginProcess?.terminate()
        showClaudeLoginSheet = false
    }

    private func which(_ tool: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/" + tool,
            "/usr/local/bin/" + tool,
            "/usr/bin/" + tool,
            NSHomeDirectory() + "/.npm-global/bin/" + tool
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - Запуск обработки

    private func run(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        // Не начинаем, если не хватает компонентов — спрашиваем в интерфейсе.
        let needsClaude = jobs[index].hasTranscript || jobs[index].stage == .transcribed
        let needsYtDlp = jobs[index].youtubeURL != nil && jobs[index].sourcePath.isEmpty
        let missing = missingDependencies(requireClaude: needsClaude, requireYtDlp: needsYtDlp)
        if !missing.isEmpty {
            pendingDependencies = missing
            showDependencySheet = true
            appendLog("Обработка отложена: не хватает компонентов.")
            return
        }

        pauseRequested = false
        cancelRequested = false
        currentJobID = jobID

        Task {
            await runPipeline(jobID: jobID)
            currentJobID = nil
            currentProcess = nil
            if !pauseRequested && !cancelRequested {
                startNextIfIdle()
            }
        }
    }

    private func runPipeline(jobID: UUID) async {
        guard var job = jobs.first(where: { $0.id == jobID }) else { return }

        // --- Шаг 0: загрузка с YouTube, если задача создана из ссылки ---
        if let youtubeURL = job.youtubeURL, job.sourcePath.isEmpty {
            updateJob(jobID) { $0.stage = .downloading; $0.lastError = nil; $0.lastErrorDetail = nil }
            appendLog("── Загрузка с YouTube: \(youtubeURL)")

            let outDir = recordingsDir + "/" + job.name
            startStageTimer(estimatedSeconds: nil)
            let result = await runScript(
                name: "download_youtube.sh",
                arguments: [youtubeURL, outDir],
                jobID: jobID,
                onOutputLine: { [weak self] chunk in self?.parseYtDlpProgress(chunk) }
            )
            stopStageTimer()

            if cancelRequested { return }
            if pauseRequested {
                updateJob(jobID) { $0.stage = .paused; $0.lastError = "Остановлено вручную" }
                appendLog("Поставлено на паузу: загрузка \(youtubeURL)")
                return
            }

            let downloadedPath = outDir + "/source.m4a"
            guard result.exitCode == 0, FileManager.default.fileExists(atPath: downloadedPath) else {
                updateJob(jobID) {
                    $0.stage = .failed
                    $0.lastError = "Ошибка загрузки с YouTube (код \(result.exitCode))"
                    $0.lastErrorDetail = errorDetail(from: result.output)
                }
                appendLog("Ошибка загрузки: \(youtubeURL)")
                return
            }

            let title = extractDownloadedTitle(from: result.output) ?? job.name
            updateJob(jobID) { $0.sourcePath = downloadedPath; $0.name = title }
            appendLog("Аудио с YouTube загружено: \(title)")
        }

        guard let afterDownload = jobs.first(where: { $0.id == jobID }) else { return }
        job = afterDownload

        // --- Шаг 1: транскрибация (пропускаем, если транскрипт уже есть) ---
        if !job.hasTranscript {
            updateJob(jobID) { $0.stage = .transcribing; $0.lastError = nil; $0.lastErrorDetail = nil }
            appendLog("── Транскрибация: \(job.fileName)")

            let outDir = transcriptsDir + "/" + job.name
            startStageTimer(estimatedSeconds: nil)

            // У записей встреч рядом со сведённым файлом лежат исходные дорожки:
            // системный звук (собеседники) и микрофон (я). Если они на месте —
            // распознаём их по отдельности и сшиваем в диалог с подписями.
            let tracks = separateTracks(for: job)
            if tracks.micPath != nil {
                appendLog("Распознаю дорожки раздельно — в транскрипте будет видно, кто говорит.")
            }
            let result = await runScript(
                name: "transcribe.sh",
                arguments: [
                    tracks.mainPath,
                    outDir,
                    languageID,
                    modelPath,
                    glossary,
                    tracks.micPath ?? ""
                ],
                jobID: jobID,
                onOutputLine: { [weak self] chunk in self?.parseTranscribeDuration(chunk) }
            )
            stopStageTimer()

            if cancelRequested { return }
            if pauseRequested {
                updateJob(jobID) { $0.stage = .paused; $0.lastError = "Остановлено вручную" }
                appendLog("Поставлено на паузу: \(job.fileName)")
                return
            }

            if result.exitCode != 0 {
                // Код 3 — особый случай: файл распознан, но речи в нём нет.
                let message = result.exitCode == 3
                    ? "В записи не нашлось речи. Проверь, что микрофону выдано разрешение и выбран нужный вход."
                    : "Ошибка транскрибации (код \(result.exitCode))"
                updateJob(jobID) {
                    $0.stage = .failed
                    $0.lastError = message
                    $0.lastErrorDetail = errorDetail(from: result.output)
                }
                appendLog("\(message): \(job.fileName)")
                MeetingNotifier.shared.notifyJobFinished(name: job.name, succeeded: false, detail: message)
                return
            }

            let transcriptPath = outDir + "/transcript.txt"
            updateJob(jobID) { $0.transcriptPath = transcriptPath; $0.stage = .transcribed }
            appendLog("Транскрипт готов: \(transcriptPath)")
            removeSeparateTracks(for: job)
        } else {
            appendLog("Транскрипт уже есть — пропускаю распознавание: \(job.fileName)")
        }

        guard let refreshed = jobs.first(where: { $0.id == jobID }) else { return }
        job = refreshed

        guard let transcriptPath = job.transcriptPath else {
            updateJob(jobID) { $0.stage = .failed; $0.lastError = "Не найден путь к транскрипту" }
            return
        }

        // --- Шаг 2: саммари и сохранение в Заметки/Notion ---
        if which("claude") == nil || !isClaudeAuthenticated() {
            updateJob(jobID) { $0.stage = .transcribed; $0.lastError = "Claude Code не установлен или не авторизован" }
            pendingDependencies = [Dependency.claude]
            showDependencySheet = true
            appendLog("Транскрипт сохранён, но Claude Code не готов — саммари можно собрать позже.")
            return
        }

        updateJob(jobID) { $0.stage = .summarizing; $0.lastError = nil; $0.lastErrorDetail = nil }
        appendLog("── Саммари: \(job.fileName)")

        startStageTimer(estimatedSeconds: estimatedSummarySeconds(transcriptPath: transcriptPath))
        let result = await runScript(
            name: "summarize.sh",
            arguments: [transcriptPath, job.name, glossary],
            jobID: jobID
        )
        stopStageTimer()

        if cancelRequested { return }
        if pauseRequested {
            updateJob(jobID) { $0.stage = .paused; $0.lastError = "Остановлено вручную (транскрипт сохранён)" }
            appendLog("Поставлено на паузу: \(job.fileName)")
            return
        }

        if result.exitCode != 0 {
            updateJob(jobID) {
                $0.stage = .failed
                $0.lastError = "Ошибка на шаге саммари (код \(result.exitCode))"
                $0.lastErrorDetail = errorDetail(from: result.output)
            }
            appendLog("Ошибка саммари: \(job.fileName). Транскрипт сохранён — можно продолжить позже.")
            MeetingNotifier.shared.notifyJobFinished(name: job.name, succeeded: false,
                                                     detail: "шаг саммари не прошёл")
            return
        }

        updateJob(jobID) { $0.stage = .done; $0.lastError = nil; $0.lastErrorDetail = nil }
        appendLog("Саммари готово: \(job.fileName). Выгрузить его можно кнопками в подробностях задачи.")
        MeetingNotifier.shared.notifyJobFinished(name: job.name, succeeded: true, detail: nil)

        moveSourceToArchive(jobID: jobID)
    }

    // Сколько примерно займёт сбор саммари. Точного прогресса у этого шага нет:
    // Claude не сообщает, сколько ему осталось. Но время почти линейно зависит
    // от длины транскрипта, поэтому прикидка по его размеру даёт человеку
    // понятную полосу вместо бесконечного кручения. Коэффициенты подобраны по
    // реальным прогонам: короткая встреча — около полутора минут, часовая — до пяти.
    private func estimatedSummarySeconds(transcriptPath: String) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptPath)
        let bytes = (attributes?[.size] as? Int) ?? 0
        let kilobytes = Double(bytes) / 1024
        return max(45 + kilobytes * 5, 60)
    }

    // Полный вывод шага для показа в развёрнутых подробностях ошибки.
    // Обрезаем середину длинного лога — начало и конец обычно самые информативные.
    private func errorDetail(from output: String) -> String? {
        return OutputParsing.errorDetail(from: output)
    }


    // MARK: - Запуск при входе в систему

    // Автозапуск нужен, чтобы приложение успело заметить начало встречи: если
    // оно не запущено, предлагать запись некому.
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                    appendLog("Приложение будет запускаться при входе в систему.")
                } else {
                    try SMAppService.mainApp.unregister()
                    appendLog("Автозапуск при входе в систему отключён.")
                }
            } catch {
                appendLog("Не удалось изменить автозапуск: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Пути и предпросмотр

    var dataFolderPath: String { return baseDir }

    // Первые строки файла — чтобы в подробностях задачи было видно, что
    // получилось, не открывая файл в другом приложении.
    func transcriptPreview(for job: Job) -> String? {
        guard let path = job.transcriptPath else { return nil }
        return JobStore.previewText(atPath: path, limit: 1200)
    }

    func summaryPreview(for job: Job) -> String? {
        guard let path = summaryPath(for: job) else { return nil }
        return JobStore.previewText(atPath: path, limit: 1600)
    }

    private static func previewText(atPath path: String, limit: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    // MARK: - Выбор файлов из меню и панели инструментов

    func pickMediaFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        addFiles(panel.urls)
        selectedSection = .queue
    }

    func pickTranscriptFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addTranscriptFile(url)
        selectedSection = .queue
    }

    // MARK: - Доступность выгрузки

    // Кнопка выгрузки в Notion включается, только если Notion действительно
    // подключён к Claude Code: иначе нажатие заканчивалось бы невнятной
    // ошибкой в логе через полминуты.
    @Published var isNotionConnected: Bool = false
    @Published var isCheckingNotion: Bool = false

    func refreshNotionAvailability() {
        guard !isCheckingNotion else { return }
        isCheckingNotion = true
        Task.detached { [weak self] in
            let connected = JobStore.detectNotionConnection()
            await MainActor.run {
                self?.isNotionConnected = connected
                self?.isCheckingNotion = false
            }
        }
    }

    // Спрашиваем сам claude: список подключённых MCP-серверов и их состояние.
    nonisolated private static func detectNotionConnection() -> Bool {
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          NSHomeDirectory() + "/.npm-global/bin/claude"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["mcp", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: .newlines).contains { line in
            let lower = line.lowercased()
            // Строка вида «claude.ai Notion: https://… - ✔ Connected»
            return lower.contains("notion") && !lower.contains("needs authentication")
                && (line.contains("✔") || lower.contains("connected"))
        }
    }

    // MARK: - Выгрузка готового саммари

    // Приложение само никуда ничего не отправляет: транскрипт и саммари
    // остаются на компьютере, а выгрузку в Notion или Заметки человек
    // запускает кнопкой, когда посмотрел результат.
    @Published var exportingJobIDs: Set<UUID> = []

    func summaryPath(for job: Job) -> String? {
        guard let transcriptPath = job.transcriptPath else { return nil }
        let path = URL(fileURLWithPath: transcriptPath)
            .deletingLastPathComponent()
            .appendingPathComponent("summary.md").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func hasSummary(_ job: Job) -> Bool {
        return summaryPath(for: job) != nil
    }

    func exportSummary(jobID: UUID, to target: String) {
        guard let job = jobs.first(where: { $0.id == jobID }), let summary = summaryPath(for: job) else {
            appendLog("Саммари ещё нет — выгружать нечего.")
            return
        }
        guard !exportingJobIDs.contains(jobID) else { return }
        exportingJobIDs.insert(jobID)

        Task {
            var arguments = [target, summary, job.name]
            if target == "notion" {
                arguments.append(notionDatabaseName)
                arguments.append(job.transcriptPath ?? "")
            }
            appendLog("Выгружаю саммари (\(target)): \(job.name)")
            let result = await runScript(name: "export_summary.sh", arguments: arguments, jobID: nil)
            exportingJobIDs.remove(jobID)

            if result.exitCode == 0 {
                if target == "notion", let link = extractNotionURL(from: result.output) {
                    updateJob(jobID) { $0.notionURL = link }
                }
                if target == "notes" {
                    updateJob(jobID) { $0.savedToNotes = true }
                }
                appendLog("Выгрузка завершена: \(job.name)")
            } else {
                appendLog("Не удалось выгрузить (\(target)): \(job.name)")
            }
        }
    }

    // Показать файл саммари в Finder — самый простой способ забрать результат.
    func revealSummary(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), let summary = summaryPath(for: job) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary)])
    }

    func openSummary(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), let summary = summaryPath(for: job) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: summary))
    }

    // Сохранить копию саммари в выбранное место.
    func saveSummaryCopy(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), let summary = summaryPath(for: job) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.name + ".md"
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(atPath: summary, toPath: destination.path)
            appendLog("Саммари сохранено: \(destination.path)")
        } catch {
            appendLog("Не удалось сохранить саммари: \(error.localizedDescription)")
        }
    }

    // MARK: - Учёт установленных компонентов

    // Помним, что приложение поставило само: при удалении предлагаем убрать
    // только это. То, что стояло на компьютере до установки, не трогаем — им
    // могут пользоваться другие программы.
    private var installedComponentsURL: URL {
        return URL(fileURLWithPath: baseDir + "/installed_components.json")
    }

    func installedComponentIDs() -> [String] {
        guard let data = FileManager.default.contents(atPath: installedComponentsURL.path),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func rememberInstalledComponent(_ id: String) {
        var ids = installedComponentIDs()
        guard !ids.contains(id) else { return }
        ids.append(id)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: installedComponentsURL)
    }

    // MARK: - Удаление приложения и его компонентов

    @Published var showUninstallSheet: Bool = false
    @Published var uninstallSelection: Set<String> = []
    @Published var uninstallPreview: String = ""
    @Published var isUninstalling: Bool = false

    // Что вообще можно удалить: компоненты из списка установленных плюс данные,
    // модели и само приложение.
    func uninstallOptions() -> [(id: String, title: String)] {
        var options: [(String, String)] = []
        let titles = [
            "ffmpeg": "ffmpeg (конвертация аудио и видео)",
            "whisper": "whisper.cpp (распознавание речи)",
            "ytdlp": "yt-dlp (загрузка с YouTube)",
            "node": "Node.js",
            "claude": "Claude Code (сбор саммари)"
        ]
        for id in installedComponentIDs() {
            if let title = titles[id] { options.append((id, title)) }
        }
        options.append(("models:" + modelsDir, "Языковые модели whisper (\(modelsDir))"))
        options.append(("data:" + baseDir, "Данные: записи, транскрипты, история (\(baseDir))"))
        options.append(("app:" + Bundle.main.bundleURL.path, "Само приложение (\(Bundle.main.bundleURL.path))"))
        return options
    }

    func prepareUninstall() {
        // По умолчанию отмечаем только компоненты: данные и приложение — это
        // отдельное решение, которое человек принимает осознанно.
        uninstallSelection = Set(installedComponentIDs())
        uninstallPreview = ""
        showUninstallSheet = true
    }

    func runUninstall(apply: Bool) {
        let selected = Array(uninstallSelection)
        guard !selected.isEmpty else {
            uninstallPreview = "Ничего не выбрано."
            return
        }
        isUninstalling = true
        Task {
            let result = await runScript(
                name: "uninstall.sh",
                arguments: [apply ? "--apply" : "--dry-run"] + selected,
                jobID: nil
            )
            isUninstalling = false
            uninstallPreview = result.output
            if apply {
                appendLog("Удаление компонентов завершено (код \(result.exitCode)).")
            }
        }
    }

    // MARK: - Раздельные дорожки записи встречи

    // Рядом со сведённым meeting.m4a запись встречи оставляет исходные дорожки:
    // system.m4a — голоса собеседников, mic.m4a — свой голос. Распознавание по
    // отдельности даёт разметку «кто говорит» и не портит речь наложением.
    private func separateTracks(for job: Job) -> MeetingTracks.Selection {
        return MeetingTracks.select(sourcePath: job.sourcePath, isMeetingRecording: job.isMeetingRecording)
    }

    // После удачного распознавания отдельные дорожки не нужны: остаётся
    // сведённый файл, которого достаточно, чтобы переслушать спорное место.
    private func removeSeparateTracks(for job: Job) {
        guard job.isMeetingRecording else { return }
        let dir = URL(fileURLWithPath: job.sourcePath).deletingLastPathComponent().path
        let fm = FileManager.default
        for name in [MeetingTracks.systemTrackName, MeetingTracks.micTrackName] where fm.fileExists(atPath: dir + "/" + name) {
            try? fm.removeItem(atPath: dir + "/" + name)
        }
    }

    private func moveSourceToArchive(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: job.sourcePath) else { return }

        // Все записи встреч называются meeting.m4a, поэтому имя в архиве берём
        // от названия задачи и при совпадении добавляем номер. Раньше второе
        // перемещение падало из-за существующего файла, а проверка fileExists
        // видела чужой файл — и задаче прописывался путь к записи другой встречи.
        let ext = URL(fileURLWithPath: job.sourcePath).pathExtension
        let base = job.name.replacingOccurrences(of: "/", with: "-")
        var destination = processedDir + "/" + base + (ext.isEmpty ? "" : "." + ext)
        var counter = 2
        while fm.fileExists(atPath: destination) {
            destination = processedDir + "/" + base + " (\(counter))" + (ext.isEmpty ? "" : "." + ext)
            counter += 1
        }

        do {
            try fm.moveItem(atPath: job.sourcePath, toPath: destination)
            updateJob(jobID) { $0.sourcePath = destination }
            appendLog("Исходник перемещён в папку processed.")
        } catch {
            appendLog("Не удалось переместить исходник в папку processed: \(error.localizedDescription)")
        }
    }

    private func extractNotionURL(from output: String) -> String? {
        return OutputParsing.notionURL(in: output)
    }

    private func extractDownloadedTitle(from output: String) -> String? {
        return OutputParsing.downloadedTitle(in: output)
    }

    private func updateJob(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
        jobs[index].updatedAt = Date()
        saveHistory()
    }

    // MARK: - Запуск shell-скриптов

    struct ScriptResult {
        let exitCode: Int32
        let output: String
    }

    private func runScript(
        name: String,
        arguments: [String],
        jobID: UUID?,
        onOutputLine: (@MainActor (String) -> Void)? = nil
    ) async -> ScriptResult {
        let scriptPath = scriptsDir + "/" + name
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            appendLog("Не найден скрипт: \(scriptPath). Проверь путь в настройках.")
            return ScriptResult(exitCode: 127, output: "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + arguments

        var environment = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.npm-global/bin"
        environment["PATH"] = extraPaths + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            collector.append(text)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self] in
                if !trimmed.isEmpty { self?.logText += trimmed + "\n" }
                onOutputLine?(text)
            }
        }

        do {
            try process.run()
        } catch {
            appendLog("Не удалось запустить \(name): \(error.localizedDescription)")
            pipe.fileHandleForReading.readabilityHandler = nil
            return ScriptResult(exitCode: 126, output: "")
        }

        currentProcess = process

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        return ScriptResult(exitCode: process.terminationStatus, output: collector.text)
    }

    // MARK: - Открытие файлов

    func revealInFinder(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            appendLog("Файл не найден: \(path)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // Разрешение «Запись экрана» macOS применяет только к новому запуску
    // процесса, поэтому после его выдачи приложение нужно перезапустить.
    func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Фильтрация истории

    var filteredJobs: [Job] {
        var result = jobs

        if stageFilter != "all" {
            result = result.filter { $0.stage.rawValue == stageFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { $0.name.lowercased().contains(query) }
        }

        return JobStore.sortedForDisplay(result)
    }

    var meetingRecordingJobs: [Job] {
        return JobStore.sortedForDisplay(jobs.filter { $0.isMeetingRecording })
    }

    // Порядок в списках: просто по времени, свежее — выше. Статус на порядок
    // не влияет: искать задачу глазами проще по времени, чем по стадии.
    static func sortedForDisplay(_ jobs: [Job]) -> [Job] {
        return jobs.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Потокобезопасный сбор вывода

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        buffer += chunk
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return copy
    }
}

extension DateFormatter {
    static let logStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static let rowDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
