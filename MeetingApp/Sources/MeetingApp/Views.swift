import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                    Text("Перетащи сюда видео или аудио встречи")
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
                        store.addFiles([finalURL])
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

// MARK: - Вкладка «Обработка»

struct QueueTabView: View {
    @ObservedObject var store: JobStore

    private var activeJobs: [Job] {
        return store.jobs.filter { $0.stage != .done }.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DropZoneView(store: store)
            YouTubeInputView(store: store)
            HStack(spacing: 10) {
                MicrophoneRecorderView(store: store)
                AttachTranscriptView(store: store)
            }

            if activeJobs.isEmpty {
                Text("Активных задач нет.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("В работе")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                List(activeJobs) { job in
                    JobRowView(store: store, job: job)
                }
                .frame(minHeight: 130, maxHeight: 210)
                .listStyle(.inset)
            }

            if store.currentJobID != nil {
                StageProgressView(store: store)
            }

            LogPanelView(store: store)
        }
        .padding(16)
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
        .help("Есть готовый текст встречи — пропустить распознавание речи и сразу сделать саммари")
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

// MARK: - Вкладка «История»

struct HistoryTabView: View {
    @ObservedObject var store: JobStore

    private var stageOptions: [(String, String)] {
        var options: [(String, String)] = [("all", "Все статусы")]
        for stage in JobStage.allCases {
            options.append((stage.rawValue, stage.title))
        }
        return options
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
                .frame(width: 180)
            }

            if store.filteredJobs.isEmpty {
                Spacer()
                Text("Ничего не найдено.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(store.filteredJobs) { job in
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

// MARK: - Вкладка «Записи встреч»

struct MeetingRecordingsTabView: View {
    @ObservedObject var store: JobStore

    private var elapsedText: String {
        let minutes = store.meetingRecordingElapsedSeconds / 60
        let seconds = store.meetingRecordingElapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.isMeetingRecordingActive {
                HStack(spacing: 10) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("Идёт запись встречи… \(elapsedText)")
                        .font(.headline)
                    Spacer()
                    Button("Остановить запись") {
                        store.stopMeetingRecording()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .cornerRadius(10)
            } else {
                HStack {
                    Text("Автоопределение ВКС в браузере")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.meetingDetectionEnabled },
                        set: { store.meetingDetectionEnabled = $0 }
                    ))
                    .labelsHidden()
                    Button("Начать запись сейчас") {
                        store.startMeetingRecording()
                    }
                }
                .font(.callout)
                .foregroundColor(.secondary)
            }

            Divider()

            if store.meetingRecordingJobs.isEmpty {
                Spacer()
                Text("Записей встреч пока нет.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(store.meetingRecordingJobs) { job in
                    JobRowView(store: store, job: job)
                        .contextMenu {
                            Button("Удалить из истории") {
                                store.removeJob(jobID: job.id)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .alert("Нет доступа к записи экрана", isPresented: Binding(
            get: { store.meetingRecordingPermissionIssue },
            set: { store.meetingRecordingPermissionIssue = $0 }
        )) {
            Button("Ок", role: .cancel) {}
        } message: {
            Text("Разреши доступ в Настройках системы → Конфиденциальность и безопасность → Запись экрана → MeetingApp, затем попробуй снова.")
        }
    }
}

// MARK: - Обнаружена встреча

struct MeetingDetectedSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Похоже, у тебя встреча", systemImage: "video.fill")
                .font(.title3).bold()

            if let platform = store.detectedMeetingPlatform {
                Text("Обнаружена активная вкладка: \(platform). Начать запись и потом сделать транскрипт с саммари?")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Не сейчас") { store.dismissDetectedMeeting() }
                Spacer()
                Button("Начать запись") { store.startMeetingRecording() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
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

// MARK: - Диалог «Куда сохранять итог»

struct SaveDestinationSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Куда сохранять саммари?", systemImage: "tray.and.arrow.down")
                .font(.title3).bold()

            Text("Выбор станет значением по умолчанию для всех задач — поменять можно в Настройках.")
                .font(.callout)
                .foregroundColor(.secondary)

            Toggle("В заметки (Notes.app)", isOn: Binding(
                get: { store.pendingSaveNotes },
                set: { store.pendingSaveNotes = $0 }
            ))
            Toggle("В Notion (база «Саммари встреч»)", isOn: Binding(
                get: { store.pendingSaveNotion },
                set: { store.pendingSaveNotion = $0 }
            ))

            HStack {
                Spacer()
                Button("Сохранить выбор") {
                    store.confirmSaveDestinations()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.pendingSaveNotes && !store.pendingSaveNotion)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

// MARK: - Настройки

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
        let modelBinding = Binding<String>(
            get: { store.modelID },
            set: { newValue in store.modelID = newValue }
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
                Text("Модель распознавания (whisper)")
                    .font(.subheadline)
                Picker("", selection: modelBinding) {
                    ForEach(WhisperModelOption.all) { option in
                        Text(option.id == WhisperModelOption.recommended().id
                             ? "\(option.title) — рекомендовано для этого Mac"
                             : option.title)
                        .tag(option.id)
                    }
                }
                .labelsHidden()
                Text("Твой Mac: \(MacHardware.summaryText)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Куда сохранять саммари по умолчанию")
                    .font(.subheadline)
                Toggle("В заметки (Notes.app)", isOn: Binding(
                    get: { store.pendingSaveNotes },
                    set: {
                        store.pendingSaveNotes = $0
                        store.setDefaultSaveDestinations(notes: store.pendingSaveNotes, notion: store.pendingSaveNotion)
                    }
                ))
                Toggle("В Notion", isOn: Binding(
                    get: { store.pendingSaveNotion },
                    set: {
                        store.pendingSaveNotion = $0
                        store.setDefaultSaveDestinations(notes: store.pendingSaveNotes, notion: store.pendingSaveNotion)
                    }
                ))
            }

            Divider()

            Button {
                store.checkDependenciesAndPrompt()
            } label: {
                Label("Проверить компоненты", systemImage: "checkmark.seal")
            }

            HStack {
                Spacer()
                Button("Готово") { store.showSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
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
        let settingsBinding = Binding<Bool>(
            get: { store.showSettings },
            set: { newValue in store.showSettings = newValue }
        )
        let depsBinding = Binding<Bool>(
            get: { store.showDependencySheet },
            set: { newValue in store.showDependencySheet = newValue }
        )
        let saveDestBinding = Binding<Bool>(
            get: { store.showSaveDestinationSheet },
            set: { newValue in store.showSaveDestinationSheet = newValue }
        )
        let claudeLoginBinding = Binding<Bool>(
            get: { store.showClaudeLoginSheet },
            set: { newValue in store.showClaudeLoginSheet = newValue }
        )
        let meetingDetectedBinding = Binding<Bool>(
            get: { store.detectedMeetingURL != nil },
            set: { newValue in if !newValue { store.dismissDetectedMeeting() } }
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

                MeetingRecordingsTabView(store: store)
                    .tabItem { Label("Записи встреч", systemImage: "video.fill") }
                    .tag(2)
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 680, minHeight: 620)
        .sheet(isPresented: settingsBinding) {
            SettingsSheet(store: store)
        }
        .sheet(isPresented: depsBinding) {
            DependencySheet(store: store)
        }
        .sheet(isPresented: saveDestBinding) {
            SaveDestinationSheet(store: store)
        }
        .sheet(isPresented: claudeLoginBinding) {
            ClaudeLoginSheet(store: store)
        }
        .sheet(isPresented: meetingDetectedBinding) {
            MeetingDetectedSheet(store: store)
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
