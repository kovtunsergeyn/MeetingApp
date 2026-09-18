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
            // Диктовка и запись встречи используют один и тот же микрофон, и
            // раньше блок диктовки показывал таймер идущей встречи, хотя к ней
            // отношения не имеет. Во время записи встречи блок просто выключен.
            if store.isMeetingRecordingActive {
                Button {
                } label: {
                    Label("Наговорить текст с микрофона", systemImage: "mic.fill")
                }
                .disabled(true)
                .help("Сейчас идёт запись встречи — микрофон занят")
                Spacer()
            } else if recorder.isRecording {
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
            // отдельные кнопки. Неактивная кнопка сразу показывает, что
            // действие недоступно, вместо ошибки после нажатия.
            if store.hasSummary(job) {
                Button {
                    store.openSummary(jobID: job.id)
                } label: {
                    Image(systemName: "doc.richtext")
                }
                .help("Открыть саммари")

                Button {
                    store.exportSummary(jobID: job.id, to: "notion")
                } label: {
                    if store.exportingJobIDs.contains(job.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("В Notion", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(!store.isNotionConnected || store.exportingJobIDs.contains(job.id))
                .help(store.isNotionConnected
                      ? (job.notionURL == nil ? "Выгрузить саммари в Notion" : "Выгрузить в Notion ещё раз")
                      : "Notion не подключён к Claude Code — подключи его в настройках Claude")

                Button {
                    store.exportSummary(jobID: job.id, to: "notes")
                } label: {
                    Label("В Заметки", systemImage: "note.text")
                }
                .disabled(store.exportingJobIDs.contains(job.id))
                .help(job.savedToNotes ? "Сохранить в Заметки ещё раз" : "Сохранить саммари в Заметки")
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

    // Название текущего шага: полоса одна и та же на распознавании, загрузке и
    // саммари, и без подписи непонятно, чего ждать.
    private var stageTitle: String? {
        guard let id = store.currentJobID,
              let job = store.jobs.first(where: { $0.id == id }) else { return nil }
        return job.stage.isRunning ? job.stage.title : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = store.stageProgressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            HStack(spacing: 6) {
                if let stageTitle {
                    Text(stageTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(store.stageStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Панель лога

struct LogPanelView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        let content = store.logText.isEmpty ? "Пока пусто — жду файлы…" : store.logText

        return VStack(alignment: .leading, spacing: 4) {
            if true {
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

// MARK: - Точка входа

@main
struct MeetingAppEntry: App {
    @StateObject private var store = JobStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 860, minHeight: 560)
        }
        .commands { AppCommands(store: store) }

        // Системная сцена настроек: даёт пункт в меню приложения и ⌘, без
        // собственного окна и кнопок внутри содержимого.
        Settings {
            SettingsView(store: store)
        }
    }
}
