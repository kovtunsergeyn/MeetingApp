import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeetingCore

// MARK: - Зона перетаскивания

struct DropZoneView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundColor(.secondary.opacity(0.5))
            .frame(height: 130)
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("Перетащи сюда видео, аудио или готовый транскрипт (.txt)")
                        .font(.headline)
                    Text("или нажми, чтобы выбрать файлы")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
            .onTapGesture { openFilePicker() }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK {
            store.addFiles(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolved: URL?
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    resolved = direct
                }
                if let finalURL = resolved {
                    Task { @MainActor in
                        if finalURL.pathExtension.lowercased() == "txt" {
                            store.addTranscriptFile(finalURL)
                        } else {
                            store.addFiles([finalURL])
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Ссылка на YouTube

struct YouTubeInputView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        let textBinding = Binding<String>(
            get: { store.youtubeURLText },
            set: { store.youtubeURLText = $0 }
        )

        return HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .foregroundColor(.red)
            TextField("Ссылка на видео YouTube", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.addYouTubeURL(store.youtubeURLText) }
            Button("Добавить") {
                store.addYouTubeURL(store.youtubeURLText)
            }
            .disabled(store.youtubeURLText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Запись с микрофона

struct MicrophoneRecorderView: View {
    @ObservedObject var store: JobStore
    @ObservedObject var recorder: AudioRecorder

    init(store: JobStore) {
        self.store = store
        self.recorder = store.audioRecorder
    }

    private var timeText: String {
        let minutes = recorder.elapsedSeconds / 60
        let seconds = recorder.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: 10) {
            if recorder.isRecording {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Идёт запись… \(timeText)")
                    .font(.callout)
                Spacer()
                Button("Остановить и добавить") {
                    if let url = recorder.stop() {
                        store.addRecordedFile(url)
                    }
                }
                Button("Отменить") { recorder.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    recorder.start()
                } label: {
                    Label("Наговорить текст с микрофона", systemImage: "mic.fill")
                }
                Spacer()
            }
        }
        .alert("Нет доступа к микрофону", isPresented: Binding(
            get: { recorder.permissionDenied },
            set: { recorder.permissionDenied = $0 }
        )) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text("Разреши доступ к микрофону в Настройках системы → Конфиденциальность и безопасность → Микрофон.")
        }
    }
}

// MARK: - Подробности ошибки (разворачиваемый вывод упавшего шага)

struct ErrorDetailView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.leading, 28)
    }
}

// MARK: - Строка задачи

struct JobRowView: View {
    @ObservedObject var store: JobStore
    let job: Job

    private var isCurrent: Bool {
        return store.currentJobID == job.id
    }

    private var showErrorDetail: Bool {
        return store.expandedErrorJobIDs.contains(job.id)
    }

    private var statusColor: Color {
        switch job.stage {
        case .done: return .green
        case .failed: return .red
        case .paused: return .orange
        case .downloading, .transcribing, .summarizing: return .blue
        case .transcribed: return .purple
        case .queued: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: job.stage.symbolName)
                    .foregroundColor(statusColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name)
                        .font(.body)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(job.stage.title)
                            .foregroundColor(statusColor)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(DateFormatter.rowDate.string(from: job.updatedAt))
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    if let error = job.lastError {
                        if job.lastErrorDetail != nil {
                            Button {
                                store.toggleErrorDetail(jobID: job.id)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: showErrorDetail ? "chevron.down" : "chevron.right")
                                    Text(error)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("Показать подробности ошибки")
                        } else {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                actionButtons
            }

            if showErrorDetail, let detail = job.lastErrorDetail {
                ErrorDetailView(text: detail)
            }
        }
        .padding(.vertical, 4)
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if isCurrent && job.stage.isRunning {
                Button {
                    store.pauseCurrent()
                } label: {
                    Label("Отмена", systemImage: "pause.fill")
                }
                .help("Остановить текущий шаг и запомнить, на чём остановились — можно продолжить позже")
            } else if job.stage.isResumable {
                Button {
                    store.resume(jobID: job.id)
                } label: {
                    Label(job.hasTranscript ? "Продолжить" : "Запустить",
                          systemImage: "play.fill")
                }
                .help(job.hasTranscript
                      ? "Транскрипт уже готов — продолжим с шага саммари"
                      : "Начать обработку")
            }

            if job.stage != .done {
                Button(role: .destructive) {
                    store.stopAndClear(jobID: job.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Удалить: убрать задачу и стереть её промежуточные файлы насовсем")
            }

            if job.hasTranscript, let path = job.transcriptPath {
                Button {
                    store.revealInFinder(path: path)
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Показать транскрипт в Finder")
            }

            // Куда отправить готовое саммари — решает человек, поэтому это
            // кнопки, а не шаг обработки.
            if store.hasSummary(job) {
                Button {
                    store.openSummary(jobID: job.id)
                } label: {
                    Image(systemName: "doc.richtext")
                }
                .help("Открыть саммари")

                Menu {
                    Button("Открыть саммари") { store.openSummary(jobID: job.id) }
                    Button("Показать в Finder") { store.revealSummary(jobID: job.id) }
                    Button("Сохранить копию…") { store.saveSummaryCopy(jobID: job.id) }
                    Divider()
                    Button(job.notionURL == nil ? "Выгрузить в Notion" : "Выгрузить в Notion ещё раз") {
                        store.exportSummary(jobID: job.id, to: "notion")
                    }
                    Button(job.savedToNotes ? "Сохранить в Заметки ещё раз" : "Сохранить в Заметки") {
                        store.exportSummary(jobID: job.id, to: "notes")
                    }
                    if let link = job.notionURL {
                        Divider()
                        Button("Открыть страницу в Notion") { store.openURL(link) }
                    }
                } label: {
                    if store.exportingJobIDs.contains(job.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Выгрузить саммари: Notion, Заметки или файл")
            }

            if let link = job.notionURL {
                Button {
                    store.openURL(link)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .help("Открыть запись в Notion")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Прикрепить готовый транскрипт

struct AttachTranscriptView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.plainText]
            if panel.runModal() == .OK, let url = panel.url {
                store.addTranscriptFile(url)
            }
        } label: {
            Label("Прикрепить транскрипт (.txt)", systemImage: "doc.badge.plus")
        }
        .help("Есть готовый текст встречи — пропустить распознавание речи и сразу сделать саммари. Совет: перетаскивание файла в зону выше не открывает системный диалог выбора и не спрашивает доступ к папкам.")
    }
}

// MARK: - Индикатор прогресса текущего шага

struct StageProgressView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = store.stageProgressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            Text(store.stageStatusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Вкладка «Обработка»

struct QueueTabView: View {
    @ObservedObject var store: JobStore

    private var activeJobs: [Job] {
        return store.jobs.filter { $0.stage != .done }.sorted { $0.createdAt < $1.createdAt }
    }

    private var elapsedText: String {
        let minutes = store.meetingRecordingElapsedSeconds / 60
        let seconds = store.meetingRecordingElapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Всё, с чего начинается работа, собрано на одной вкладке: запись
            // идущей встречи — такой же способ добавить материал, как файл или
            // ссылка, и разносить их по разным вкладкам незачем.
            SectionBox(title: "Запись встречи", systemImage: "video.fill") {
                meetingRecordingBlock
            }

            SectionBox(title: "Добавить файл или ссылку", systemImage: "tray.and.arrow.down") {
                VStack(alignment: .leading, spacing: 10) {
                    DropZoneView(store: store)
                    YouTubeInputView(store: store)
                    HStack(spacing: 10) {
                        MicrophoneRecorderView(store: store)
                        AttachTranscriptView(store: store)
                    }
                }
            }

            SectionBox(title: "В работе", systemImage: "gearshape.2") {
                VStack(alignment: .leading, spacing: 8) {
                    if activeJobs.isEmpty {
                        Text("Активных задач нет.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        List(activeJobs) { job in
                            JobRowView(store: store, job: job)
                        }
                        .frame(minHeight: 120, maxHeight: 200)
                        .listStyle(.inset)
                    }

                    if store.currentJobID != nil {
                        StageProgressView(store: store)
                    }
                }
            }

            LogPanelView(store: store)
        }
        .padding(16)
        .alert("Не удалось начать запись", isPresented: Binding(
            get: { store.meetingRecordingPermissionIssue },
            set: { store.meetingRecordingPermissionIssue = $0 }
        )) {
            if store.systemAudioRecorder.needsRestartForPermission {
                Button("Открыть настройки") { store.openScreenRecordingSettings() }
                Button("Перезапустить приложение") { store.restartApp() }
            }
            Button("Ок", role: .cancel) {}
        } message: {
            Text(store.systemAudioRecorder.lastErrorMessage ?? "Причина неизвестна.")
        }
    }

    private var meetingRecordingBlock: some View {
        Group {
            if store.isMeetingRecordingActive {
                HStack(spacing: 10) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Идёт запись… \(elapsedText)")
                        .font(.headline)
                    Spacer()
                    Button("Остановить и обработать") {
                        store.stopMeetingRecording()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        MicrophonePickerView(store: store)
                        Spacer()
                        Button {
                            store.startMeetingRecording()
                        } label: {
                            Label("Записать встречу", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Toggle(isOn: Binding(
                        get: { store.meetingDetectionEnabled },
                        set: { store.meetingDetectionEnabled = $0 }
                    )) {
                        Text("Предлагать запись, когда начинается встреча в браузере или календаре")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Блок с заголовком

// Рамка с подписью: на вкладке несколько разных дел подряд, и без границ
// они сливаются в одну простыню.
struct SectionBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Вкладка «История»

struct HistoryTabView: View {
    @ObservedObject var store: JobStore

    // Записи встреч и загруженные файлы проходят один и тот же путь, поэтому
    // живут в одном списке: отдельная вкладка только заставляла искать задачу
    // в двух местах. Отделить их по-прежнему можно фильтром.
    private var stageOptions: [(String, String)] {
        var options: [(String, String)] = [("all", "Все"), ("meetings", "Только записи встреч")]
        for stage in JobStage.allCases {
            options.append((stage.rawValue, stage.title))
        }
        return options
    }

    private var visibleJobs: [Job] {
        if store.stageFilter == "meetings" {
            let search = store.searchText.trimmingCharacters(in: .whitespaces).lowercased()
            return store.meetingRecordingJobs.filter {
                search.isEmpty || $0.name.lowercased().contains(search)
            }
        }
        return store.filteredJobs
    }

    var body: some View {
        let searchBinding = Binding<String>(
            get: { store.searchText },
            set: { newValue in store.searchText = newValue }
        )
        let filterBinding = Binding<String>(
            get: { store.stageFilter },
            set: { newValue in store.stageFilter = newValue }
        )

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Поиск по названию", text: searchBinding)
                    .textFieldStyle(.roundedBorder)

                Picker("", selection: filterBinding) {
                    ForEach(stageOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .frame(width: 200)
            }

            if visibleJobs.isEmpty {
                Spacer()
                Text("Ничего не найдено.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(visibleJobs) { job in
                    JobRowView(store: store, job: job)
                        .contextMenu {
                            Button("Удалить из истории") {
                                store.removeJob(jobID: job.id)
                            }
                        }
                }
                .listStyle(.inset)
            }

            Text("Всего записей: \(store.jobs.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
    }
}

// MARK: - Панель лога

struct LogPanelView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        let content = store.logText.isEmpty ? "Пока пусто — жду файлы…" : store.logText

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                store.isLogExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.isLogExpanded ? "chevron.down" : "chevron.right")
                    Text("Лог")
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundColor(.secondary)

            if store.isLogExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                            .id("logBottom")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .onChange(of: store.logText) { _ in
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Диалог зависимостей (внутри приложения)

struct DependencySheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Не хватает компонентов", systemImage: "shippingbox")
                .font(.title3).bold()

            Text("Чтобы обработка заработала, нужно доустановить:")
                .font(.callout)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.pendingDependencies) { dep in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: dep.isAutoInstallable ? "arrow.down.circle" : "hand.raised")
                            .foregroundColor(dep.isAutoInstallable ? .accentColor : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dep.title).bold()
                            Text(dep.details)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if store.isInstallingDependency {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Устанавливаю… это может занять несколько минут.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Отмена") {
                    store.showDependencySheet = false
                }
                .disabled(store.isInstallingDependency)

                Spacer()

                Button("Установить") {
                    store.installDependencies(store.pendingDependencies)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isInstallingDependency
                          || !store.pendingDependencies.contains { $0.isAutoInstallable })
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Диалог входа в Claude Code

struct ClaudeLoginSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        let codeBinding = Binding<String>(
            get: { store.claudeLoginCodeInput },
            set: { store.claudeLoginCodeInput = $0 }
        )

        return VStack(alignment: .leading, spacing: 16) {
            Label("Вход в Claude Code", systemImage: "person.crop.circle.badge.checkmark")
                .font(.title3).bold()

            Text("Открылась страница входа в аккаунт Anthropic в браузере. Войди там, скопируй код подтверждения и вставь его сюда.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = store.claudeLoginURL {
                Button {
                    store.openURL(url)
                } label: {
                    Label("Открыть страницу входа ещё раз", systemImage: "safari")
                }
            }

            TextField("Код подтверждения", text: codeBinding)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.submitClaudeLoginCode() }

            HStack {
                Button("Отмена") { store.cancelClaudeLogin() }
                Spacer()
                Button("Подтвердить") { store.submitClaudeLoginCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.claudeLoginCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

// MARK: - Настройки

// MARK: - Строка модели whisper в настройках

struct WhisperModelRow: View {
    @ObservedObject var store: JobStore
    let option: WhisperModelOption
    let isSelected: Bool

    private var isDownloaded: Bool { store.isModelDownloaded(option) }
    private var isDownloading: Bool { store.modelDownloadInProgress == option.id }
    private var isRecommended: Bool { option.id == WhisperModelOption.recommended().id }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.title)
                        .font(.callout)
                    if isRecommended {
                        Text("рекомендовано")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text(store.modelFileSizeText(option) ?? option.approxSizeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloading {
                ProgressView().controlSize(.small)
            } else if isDownloaded {
                if !isSelected {
                    Button(role: .destructive) {
                        store.deleteModel(option)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button("Скачать") {
                    store.downloadModel(option)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.modelDownloadInProgress != nil)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded { store.modelID = option.id }
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        let pathBinding = Binding<String>(
            get: { store.scriptsDir },
            set: { newValue in store.scriptsDir = newValue }
        )
        let languageBinding = Binding<String>(
            get: { store.languageID },
            set: { newValue in store.languageID = newValue }
        )
        return VStack(alignment: .leading, spacing: 16) {
            Text("Настройки").font(.title3).bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("Папка со скриптами")
                    .font(.subheadline)
                HStack {
                    TextField("Путь к папке scripts", text: pathBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Выбрать…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            store.scriptsDir = url.path
                        }
                    }
                }
                Text("Ожидаются файлы: transcribe.sh, summarize.sh, download_youtube.sh, install_dep.sh")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Язык транскрибации")
                    .font(.subheadline)
                Picker("", selection: languageBinding) {
                    ForEach(TranscriptionLanguage.all) { language in
                        Text(language.title).tag(language.id)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("База Notion для саммари")
                    .font(.subheadline)
                TextField("Саммари встреч", text: Binding(
                    get: { store.notionDatabaseName },
                    set: { store.notionDatabaseName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Text("Имя базы в твоём Notion. Если такой базы нет, она будет создана при первом сохранении.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Словарь терминов и имён")
                        .font(.subheadline)
                    Spacer()
                    Button("Открыть словарь…") { store.showGlossarySheet = true }
                        .controlSize(.small)
                }
                Text(store.glossary.isEmpty
                     ? "Пока пусто — распознавание будет коверкать аббревиатуры и фамилии."
                     : store.glossary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Модели распознавания (whisper)")
                    .font(.subheadline)
                Text("Твой Mac: \(MacHardware.summaryText)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 0) {
                    ForEach(WhisperModelOption.all) { option in
                        WhisperModelRow(store: store, option: option, isSelected: store.modelID == option.id)
                        if option.id != WhisperModelOption.all.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Свои платформы ВКС (внутрикорпоративные и т.п.)")
                    .font(.subheadline)
                Text("Zoom, Google Meet и MS Teams узнаются сами. Для остального — добавь фрагмент ссылки.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(store.customMeetingDomains) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label).font(.callout)
                            Text(entry.domain).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.removeCustomMeetingDomain(entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("Фрагмент ссылки, например vcs.example.com", text: Binding(
                        get: { store.newMeetingDomainText },
                        set: { store.newMeetingDomainText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    TextField("Название", text: Binding(
                        get: { store.newMeetingLabelText },
                        set: { store.newMeetingLabelText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    Button("Добавить") {
                        store.addCustomMeetingDomain(domain: store.newMeetingDomainText, label: store.newMeetingLabelText)
                        store.newMeetingDomainText = ""
                        store.newMeetingLabelText = ""
                    }
                    .disabled(store.newMeetingDomainText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запускать при входе в систему")
                    Text("Нужно, чтобы приложение успевало заметить начало встречи и предложить запись.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button {
                    store.checkDependenciesAndPrompt()
                } label: {
                    Label("Проверить компоненты", systemImage: "checkmark.seal")
                }
                Spacer()
                Button(role: .destructive) {
                    store.prepareUninstall()
                } label: {
                    Label("Удалить приложение…", systemImage: "trash")
                }
            }

            HStack {
                Spacer()
                Button("Готово") {
                    store.showSettings = false
                    SettingsWindowController.shared.hide()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .sheet(isPresented: Binding<Bool>(
            get: { store.showGlossarySheet },
            set: { store.showGlossarySheet = $0 }
        )) {
            GlossarySheet(store: store)
        }
        .sheet(isPresented: Binding<Bool>(
            get: { store.showUninstallSheet },
            set: { store.showUninstallSheet = $0 }
        )) {
            UninstallSheet(store: store)
        }
    }
}

// MARK: - Удаление приложения и его компонентов

struct UninstallSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Удаление приложения")
                .font(.title3).bold()

            Text("Отмечено то, что приложение установило само. Программы, которые уже были на компьютере до его установки, в списке не появятся — их могли поставить для других задач.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.uninstallOptions(), id: \.id) { option in
                        Toggle(isOn: Binding(
                            get: { store.uninstallSelection.contains(option.id) },
                            set: { isOn in
                                if isOn { store.uninstallSelection.insert(option.id) }
                                else { store.uninstallSelection.remove(option.id) }
                            }
                        )) {
                            Text(option.title)
                                .font(.callout)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)

            if !store.uninstallPreview.isEmpty {
                ScrollView {
                    Text(store.uninstallPreview)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            }

            HStack {
                Button("Проверить без удаления") { store.runUninstall(apply: false) }
                    .disabled(store.isUninstalling)
                Spacer()
                Button("Закрыть") { store.showUninstallSheet = false }
                Button(role: .destructive) {
                    store.runUninstall(apply: true)
                } label: {
                    Text("Удалить отмеченное")
                }
                .disabled(store.isUninstalling || store.uninstallPreview.isEmpty)
            }

            Text("Кнопка удаления включается после проверки: сначала видно точный список, потом действие.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 560)
    }
}

// MARK: - Словарь терминов (отдельное окно: список длинный, в строку не помещается)

struct GlossarySheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Словарь терминов и имён")
                .font(.title3).bold()

            Text("Аббревиатуры, названия систем, фамилии и имена — через запятую. Подсказывается распознаванию, чтобы оно не коверкало их, и Claude при сборе саммари, чтобы он не расшифровывал их наугад.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: Binding(
                get: { store.glossary },
                set: { store.glossary = $0 }
            ))
            .font(.body)
            .frame(minHeight: 260)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))

            HStack(alignment: .firstTextBaseline) {
                Text("Слов в словаре: \(glossaryTermCount). Whisper учитывает примерно первые 200 токенов — самые важные термины держи в начале.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Готово") { store.showGlossarySheet = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var glossaryTermCount: Int {
        return store.glossary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}

// MARK: - Главный экран

struct ContentView: View {
    @StateObject private var store = JobStore()

    private var headerRow: some View {
        HStack {
            Text("Обработка встреч")
                .font(.title2).bold()
            Spacer()
            if store.currentJobID != nil {
                ProgressView().controlSize(.small)
            }
            Button {
                store.showSettings = true
                SettingsWindowController.shared.show(store: store)
            } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    var body: some View {
        let tabBinding = Binding<Int>(
            get: { store.selectedTab },
            set: { newValue in store.selectedTab = newValue }
        )
        let depsBinding = Binding<Bool>(
            get: { store.showDependencySheet },
            set: { newValue in store.showDependencySheet = newValue }
        )
        let claudeLoginBinding = Binding<Bool>(
            get: { store.showClaudeLoginSheet },
            set: { newValue in store.showClaudeLoginSheet = newValue }
        )
        return VStack(spacing: 0) {
            headerRow

            TabView(selection: tabBinding) {
                QueueTabView(store: store)
                    .tabItem { Label("Обработка", systemImage: "waveform") }
                    .tag(0)

                HistoryTabView(store: store)
                    .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }
                    .tag(1)
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 680, minHeight: 620)
        .onAppear { StatusBarController.shared.install(store: store) }
        .sheet(isPresented: depsBinding) {
            DependencySheet(store: store)
        }
        .sheet(isPresented: claudeLoginBinding) {
            ClaudeLoginSheet(store: store)
        }
    }
}

// MARK: - Точка входа

@main
struct MeetingAppEntry: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
