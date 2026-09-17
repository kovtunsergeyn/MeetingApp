import Foundation
import AppKit
import CoreAudio

@MainActor
final class JobStore: ObservableObject {

    // MARK: - Публикуемое состояние

    @Published var jobs: [Job] = []
    @Published var logText: String = ""
    @Published var currentJobID: UUID?

    // Интерфейсное состояние (вместо @State — property wrapper-макросы не работают без Xcode).
    @Published var selectedTab: Int = 0
    @Published var searchText: String = ""
    @Published var stageFilter: String = "all"
    @Published var showSettings: Bool = false
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

    // Куда сохранять итог — спрашиваем один раз, дальше это настройка по умолчанию.
    @Published var showSaveDestinationSheet: Bool = false
    @Published var pendingSaveNotes: Bool = SaveDestinations.default.notes
    @Published var pendingSaveNotion: Bool = SaveDestinations.default.notion
    private var saveDestinationContinuation: CheckedContinuation<SaveDestinations, Never>?

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
    }

    func removeCustomMeetingDomain(_ id: UUID) {
        customMeetingDomains.removeAll { $0.id == id }
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
        MeetingAlertPanelController.shared.show(
            store: self,
            platform: platform,
            onStart: { [weak self] in self?.startMeetingRecording() },
            onDismiss: { [weak self] in self?.dismissDetectedMeeting() }
        )
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

        appendLog("Запускаю запись встречи…")

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
        let destDir = baseDir + "/tmp/" + safeName
        try? FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        let mixedPath = destDir + "/meeting.m4a"

        let result = await runScript(
            name: "mix_meeting_audio.sh",
            arguments: [systemURL.path, micURL?.path ?? "/dev/null", mixedPath],
            jobID: nil
        )

        try? FileManager.default.removeItem(at: systemURL)
        if let micURL { try? FileManager.default.removeItem(at: micURL) }

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
        ?? (NSHomeDirectory() + "/Встречи/scripts") {
        didSet { UserDefaults.standard.set(scriptsDir, forKey: "scriptsDir") }
    }

    @Published var languageID: String = UserDefaults.standard.string(forKey: "languageID") ?? "auto" {
        didSet { UserDefaults.standard.set(languageID, forKey: "languageID") }
    }

    @Published var modelID: String = UserDefaults.standard.string(forKey: "modelID")
        ?? WhisperModelOption.recommended().id {
        didSet { UserDefaults.standard.set(modelID, forKey: "modelID") }
    }

    private var selectedModel: WhisperModelOption { return WhisperModelOption.byID(modelID) }

    private var saveDestinationsConfigured: Bool {
        return UserDefaults.standard.bool(forKey: "saveDestinationsConfigured")
    }

    private func persistedSaveDestinations() -> SaveDestinations {
        return SaveDestinations(
            notes: UserDefaults.standard.bool(forKey: "saveToNotes"),
            notion: UserDefaults.standard.object(forKey: "saveToNotion") == nil
                ? SaveDestinations.default.notion
                : UserDefaults.standard.bool(forKey: "saveToNotion")
        )
    }

    func setDefaultSaveDestinations(notes: Bool, notion: Bool) {
        UserDefaults.standard.set(notes, forKey: "saveToNotes")
        UserDefaults.standard.set(notion, forKey: "saveToNotion")
        UserDefaults.standard.set(true, forKey: "saveDestinationsConfigured")
    }

    // MARK: - Пути

    private var baseDir: String { return NSHomeDirectory() + "/Встречи" }
    private var historyURL: URL { return URL(fileURLWithPath: baseDir + "/history.json") }
    private var modelsDir: String { return NSHomeDirectory() + "/whisper-models" }
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
                arguments: ["model", option.id, option.fileName, option.downloadURL],
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
        createDirectories()
        loadHistory()
        normalizeStagesOnLaunch()
        MeetingLinkDetector.customPatterns = customMeetingDomains.map { ($0.domain, $0.label) }
        startMeetingDetection()
    }

    private func createDirectories() {
        let fm = FileManager.default
        for path in [baseDir, baseDir + "/обработано", baseDir + "/транскрипты", baseDir + "/tmp"] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
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
        } catch {
            appendLog("История задач повреждена и не загружена, файл не тронут: \(error.localizedDescription)")
        }
    }

    func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(jobs) {
            try? data.write(to: historyURL)
        }
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        logText += "[" + stamp + "] " + line + "\n"
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
        for line in chunk.components(separatedBy: .newlines) {
            guard line.hasPrefix("DURATION_SECONDS:") else { continue }
            let value = line.replacingOccurrences(of: "DURATION_SECONDS:", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let duration = Double(value), duration > 0 else { continue }
            let estimated = duration * selectedModel.realtimeFactor
            stageEstimatedSeconds = max(estimated, 5)
        }
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
        let destination = baseDir + "/tmp/" + name.replacingOccurrences(of: ":", with: "-") + "." + url.pathExtension
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
        let destDir = baseDir + "/транскрипты/" + name
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
        let tmpDir = baseDir + "/tmp/" + job.name
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
                    arguments = ["model", option.id, option.fileName, option.downloadURL]
                } else {
                    arguments = [id]
                }
                let result = await runScript(name: "install_dep.sh", arguments: arguments, jobID: nil)
                if result.exitCode == 0 {
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

    // MARK: - Выбор места сохранения (спрашиваем один раз, дальше — как настройка)

    func confirmSaveDestinations() {
        setDefaultSaveDestinations(notes: pendingSaveNotes, notion: pendingSaveNotion)
        showSaveDestinationSheet = false
        saveDestinationContinuation?.resume(returning: SaveDestinations(notes: pendingSaveNotes, notion: pendingSaveNotion))
        saveDestinationContinuation = nil
    }

    private func ensureSaveDestinationsChosen() async -> SaveDestinations {
        if saveDestinationsConfigured {
            return persistedSaveDestinations()
        }
        let current = persistedSaveDestinations()
        pendingSaveNotes = current.notes
        pendingSaveNotion = current.notion
        showSaveDestinationSheet = true
        return await withCheckedContinuation { continuation in
            saveDestinationContinuation = continuation
        }
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

            let outDir = baseDir + "/tmp/" + job.name
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

            let outDir = baseDir + "/транскрипты/" + job.name
            startStageTimer(estimatedSeconds: nil)
            let result = await runScript(
                name: "transcribe.sh",
                arguments: [job.sourcePath, outDir, languageID, modelPath],
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
                updateJob(jobID) {
                    $0.stage = .failed
                    $0.lastError = "Ошибка транскрибации (код \(result.exitCode))"
                    $0.lastErrorDetail = errorDetail(from: result.output)
                }
                appendLog("Ошибка транскрибации: \(job.fileName)")
                return
            }

            let transcriptPath = outDir + "/transcript.txt"
            updateJob(jobID) { $0.transcriptPath = transcriptPath; $0.stage = .transcribed }
            appendLog("Транскрипт готов: \(transcriptPath)")
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
            appendLog("Транскрипт сохранён, но Claude Code не готов — шаг сохранения можно продолжить позже.")
            return
        }

        let destinations = await ensureSaveDestinationsChosen()
        if cancelRequested { return }

        updateJob(jobID) { $0.stage = .summarizing; $0.lastError = nil; $0.lastErrorDetail = nil }
        appendLog("── Саммари и сохранение (\(destinationsLabel(destinations))): \(job.fileName)")

        startStageTimer(estimatedSeconds: nil)
        let result = await runScript(
            name: "summarize.sh",
            arguments: [
                transcriptPath,
                job.name,
                destinations.notes ? "1" : "0",
                destinations.notion ? "1" : "0"
            ],
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
            return
        }

        let notionLink = extractNotionURL(from: result.output)
        updateJob(jobID) { $0.stage = .done; $0.notionURL = notionLink; $0.lastError = nil; $0.lastErrorDetail = nil }
        appendLog("Готово: \(job.fileName)")

        moveSourceToArchive(jobID: jobID)
    }

    // Полный вывод шага для показа в развёрнутых подробностях ошибки.
    // Обрезаем середину длинного лога — начало и конец обычно самые информативные.
    private func errorDetail(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let limit = 4000
        guard trimmed.count > limit else { return trimmed }

        let head = String(trimmed.prefix(limit / 2))
        let tail = String(trimmed.suffix(limit / 2))
        return head + "\n\n… (пропущено) …\n\n" + tail
    }

    private func destinationsLabel(_ destinations: SaveDestinations) -> String {
        var parts: [String] = []
        if destinations.notes { parts.append("Заметки") }
        if destinations.notion { parts.append("Notion") }
        return parts.isEmpty ? "без сохранения" : parts.joined(separator: " + ")
    }

    private func moveSourceToArchive(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: job.sourcePath) else { return }
        let destination = baseDir + "/обработано/" + job.fileName
        try? fm.moveItem(atPath: job.sourcePath, toPath: destination)
        if fm.fileExists(atPath: destination) {
            updateJob(jobID) { $0.sourcePath = destination }
            appendLog("Исходник перемещён в «обработано».")
        }
    }

    private func extractNotionURL(from output: String) -> String? {
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

    private func extractDownloadedTitle(from output: String) -> String? {
        for rawLine in output.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("TITLE:") {
                let title = rawLine.replacingOccurrences(of: "TITLE:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        return nil
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

        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    var meetingRecordingJobs: [Job] {
        return jobs.filter { $0.isMeetingRecording }.sorted { $0.createdAt > $1.createdAt }
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
