import SwiftUI
import AppKit
import MeetingCore

// Главное окно построено как принято в macOS: слева боковая панель с разделами,
// в середине список задач, справа подробности выбранной. Раньше это были
// вкладки по центру окна — приём из мобильных приложений, который на Маке
// отнимает ширину и не даёт места для новых разделов.

enum AppSection: String, Identifiable, CaseIterable {
    case queue
    case history
    case meetings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Очередь"
        case .history: return "История"
        case .meetings: return "Записи встреч"
        }
    }

    var symbol: String {
        switch self {
        case .queue: return "gearshape.2"
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "video.fill"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: JobStore

    private var jobs: [Job] {
        switch store.selectedSection {
        case .queue:
            return JobStore.sortedForDisplay(store.jobs.filter { $0.stage != .done })
        case .history:
            return store.filteredJobs
        case .meetings:
            return store.meetingRecordingJobs
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<AppSection?>(
                get: { store.selectedSection },
                set: { store.selectedSection = $0 ?? .queue }
            )) {
                Section("Разделы") {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(badge(for: section))
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } content: {
            JobListView(store: store, jobs: jobs)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let selected = store.selectedJobID,
               let job = store.jobs.first(where: { $0.id == selected }) {
                JobDetailView(store: store, job: job)
            } else {
                AddWorkView(store: store)
            }
        }
        .navigationTitle(store.selectedSection.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .onAppear { StatusBarController.shared.install(store: store) }
        .sheet(isPresented: Binding(
            get: { store.showDependencySheet },
            set: { store.showDependencySheet = $0 }
        )) { DependencySheet(store: store) }
        .sheet(isPresented: Binding(
            get: { store.showClaudeLoginSheet },
            set: { store.showClaudeLoginSheet = $0 }
        )) { ClaudeLoginSheet(store: store) }
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

    private var subtitle: String {
        if store.isMeetingRecordingActive {
            let seconds = store.meetingRecordingElapsedSeconds
            return String(format: "запись встречи — %02d:%02d", seconds / 60, seconds % 60)
        }
        let active = store.jobs.filter { $0.stage.isRunning }.count
        return active > 0 ? "в работе: \(active)" : ""
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .queue: return store.jobs.filter { $0.stage != .done }.count
        case .history: return store.jobs.count
        case .meetings: return store.meetingRecordingJobs.count
        }
    }

    // Панель инструментов окна вместо самодельной шапки: слева — место для
    // кнопки боковой панели, которую добавляет система, в центре — частые
    // действия, справа — поиск.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button {
                if store.isMeetingRecordingActive {
                    store.stopMeetingRecording()
                } else {
                    store.startMeetingRecording()
                }
            } label: {
                Label(store.isMeetingRecordingActive ? "Остановить запись" : "Записать встречу",
                      systemImage: store.isMeetingRecordingActive ? "stop.circle" : "record.circle")
            }
            .help(store.isMeetingRecordingActive
                  ? "Остановить запись и отправить её в обработку"
                  : "Записать идущую встречу: системный звук и микрофон")

            Button {
                store.pickMediaFiles()
            } label: {
                Label("Добавить файл", systemImage: "plus")
            }
            .help("Добавить видео или аудио для расшифровки")
        }

        ToolbarItem(placement: .automatic) {
            Toggle(isOn: Binding(
                get: { store.meetingDetectionEnabled },
                set: { store.meetingDetectionEnabled = $0 }
            )) {
                Label("Следить за встречами", systemImage: "eye")
            }
            .help("Предлагать запись, когда начинается встреча в браузере или календаре")
        }
    }
}

// MARK: - Список задач

struct JobListView: View {
    @ObservedObject var store: JobStore
    let jobs: [Job]

    var body: some View {
        Group {
            if jobs.isEmpty {
                EmptyStateView(store: store, section: store.selectedSection)
            } else {
                List(jobs, selection: Binding<UUID?>(
                    get: { store.selectedJobID },
                    set: { store.selectedJobID = $0 }
                )) { job in
                    JobRowView(store: store, job: job)
                        .tag(job.id)
                        .contextMenu {
                            if store.hasSummary(job) {
                                Button("Показать саммари в Finder") { store.revealSummary(jobID: job.id) }
                                Button("Сохранить копию саммари…") { store.saveSummaryCopy(jobID: job.id) }
                                Divider()
                            }
                            Button("Удалить из истории") { store.removeJob(jobID: job.id) }
                        }
                }
            }
        }
        .searchable(text: Binding(
            get: { store.searchText },
            set: { store.searchText = $0 }
        ), placement: .toolbar, prompt: "Поиск по названию")
    }
}

// MARK: - Пустые состояния

// Пустой список объясняет, что делать дальше, а не просто сообщает, что пусто.
struct EmptyStateView: View {
    @ObservedObject var store: JobStore
    let section: AppSection

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if section == .meetings {
                Button("Записать встречу") { store.startMeetingRecording() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Добавить файл…") { store.pickMediaFiles() }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch section {
        case .queue: return "Очередь пуста"
        case .history: return store.searchText.isEmpty ? "Пока ничего не обработано" : "Ничего не найдено"
        case .meetings: return "Записей встреч пока нет"
        }
    }

    private var subtitle: String {
        switch section {
        case .queue: return "Здесь появятся задачи, которые сейчас распознаются или ждут очереди."
        case .history: return store.searchText.isEmpty
            ? "Перетащите видео или аудио в окно, добавьте ссылку на YouTube или запишите встречу."
            : "Попробуйте другое слово или снимите фильтр."
        case .meetings: return "Запись встречи можно начать вручную или доверить приложению — оно предложит, когда встреча начнётся."
        }
    }
}

// MARK: - Панель добавления работы

// Показывается, когда задача не выбрана: место для перетаскивания и способы
// начать работу. Раньше это была отдельная вкладка с нарисованными карточками.
struct AddWorkView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DropZoneView(store: store)

                GroupBox("Ссылка на YouTube") {
                    YouTubeInputView(store: store)
                        .padding(6)
                }

                GroupBox("Наговорить текст") {
                    MicrophoneRecorderView(store: store)
                        .padding(6)
                }

                GroupBox("Готовый транскрипт") {
                    HStack {
                        AttachTranscriptView(store: store)
                        Spacer()
                    }
                    .padding(6)
                }

                if store.currentJobID != nil {
                    GroupBox("Сейчас выполняется") {
                        StageProgressView(store: store)
                            .padding(6)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
