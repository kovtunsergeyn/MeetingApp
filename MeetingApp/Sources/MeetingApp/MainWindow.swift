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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Обработка"
        case .history: return "История"
        }
    }

    var symbol: String {
        switch self {
        case .queue: return "waveform"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: JobStore

    private var jobs: [Job] {
        switch store.selectedSection {
        case .queue:
            // Только что законченные задачи остаются в очереди ещё десять
            // минут: иначе результат работы исчезает с экрана ровно в тот
            // момент, когда человек его ждал, и это выглядит как потеря.
            let recently = Date().addingTimeInterval(-600)
            return JobStore.sortedForDisplay(store.jobs.filter {
                $0.stage != .done || $0.updatedAt > recently
            })
        case .history:
            return store.stageFilter == "meetings" ? store.meetingRecordingJobs : store.filteredJobs
        }
    }

    var body: some View {
        // Панель разделов закреплена: раньше она сворачивалась сама, и вместе
        // с ней исчезал единственный способ попасть в историю — выглядело
        // так, будто пропали все задачи.
        NavigationSplitView(columnVisibility: Binding(
            get: { store.sidebarVisibility },
            set: { store.sidebarVisibility = $0 == .detailOnly ? .all : $0 }
        )) {
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
        .navigationSplitViewStyle(.balanced)
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
        }
    }

    // Панель инструментов окна вместо самодельной шапки: слева — место для
    // кнопки боковой панели, которую добавляет система, в центре — частые
    // действия, справа — поиск.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if store.isMeetingRecordingActive {
            ToolbarItem(placement: .navigation) {
                RecordingIndicatorView(store: store)
            }
        }

        ToolbarItemGroup(placement: .principal) {
            // Подписи рядом со значками: по одному значку непонятно, что
            // делает кнопка, а запись встречи — самое важное действие окна.
            Button {
                if store.isMeetingRecordingActive {
                    store.stopMeetingRecording()
                } else {
                    store.startMeetingRecording()
                }
            } label: {
                Label(store.isMeetingRecordingActive ? "Остановить запись" : "Записать встречу",
                      systemImage: store.isMeetingRecordingActive ? "stop.circle.fill" : "record.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isMeetingRecordingActive ? .red : .accentColor)
            .help(store.isMeetingRecordingActive
                  ? "Остановить запись и отправить её в обработку"
                  : "Записать идущую встречу: системный звук и микрофон")

            Button {
                store.pickMediaFiles()
            } label: {
                Label("Добавить файл", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .help("Добавить видео или аудио для расшифровки")
        }

        if store.selectedSection == .history {
            ToolbarItem(placement: .automatic) {
                Picker("Фильтр", selection: Binding(
                    get: { store.stageFilter },
                    set: { store.stageFilter = $0 }
                )) {
                    Text("Все").tag("all")
                    Text("Только записи встреч").tag("meetings")
                    Divider()
                    ForEach(JobStage.allCases, id: \.rawValue) { stage in
                        Text(stage.title).tag(stage.rawValue)
                    }
                }
                .frame(width: 200)
            }
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
                List(selection: Binding<UUID?>(
                    get: { store.selectedJobID },
                    set: { store.selectedJobID = $0 }
                )) {
                    ForEach(jobs) { job in
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
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Поиск нужен только в истории: в обработке задач единицы, а поле
        // вытесняло из панели кнопку добавления файла.
        .modifier(SearchIfNeeded(store: store))
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
            Button("Добавить файл…") { store.pickMediaFiles() }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch section {
        case .queue: return "Очередь пуста"
        case .history: return store.searchText.isEmpty ? "Пока ничего не обработано" : "Ничего не найдено"
        }
    }

    private var subtitle: String {
        switch section {
        case .queue: return "Здесь появятся задачи, которые сейчас распознаются или ждут очереди. Готовые остаются тут ещё десять минут, а дальше живут в истории."
        case .history: return store.searchText.isEmpty
            ? "Перетащите видео или аудио в окно, добавьте ссылку на YouTube или запишите встречу."
            : "Попробуйте другое слово или снимите фильтр."
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


// MARK: - Поиск только там, где он нужен

struct SearchIfNeeded: ViewModifier {
    @ObservedObject var store: JobStore

    func body(content: Content) -> some View {
        if store.selectedSection == .history {
            content.searchable(text: Binding(
                get: { store.searchText },
                set: { store.searchText = $0 }
            ), placement: .toolbar, prompt: "Поиск по названию")
        } else {
            content
        }
    }
}


// MARK: - Индикатор записи

// Пока идёт запись, в панели видно живую шкалу голоса и красную точку.
// Бегущего таймера мало: по нему не понять, слышно ли микрофон и работает ли
// запись вообще — а это единственное, что человек хочет знать в этот момент.
struct RecordingIndicatorView: View {
    @ObservedObject var store: JobStore
    @ObservedObject private var recorder: AudioRecorder

    init(store: JobStore) {
        self.store = store
        self.recorder = store.audioRecorder
    }

    private var elapsedText: String {
        let seconds = store.meetingRecordingElapsedSeconds
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        // Мигание берём из TimelineView: @State без Xcode не работает —
        // макрос property wrapper'а недоступен голым Command Line Tools.
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let blink = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
            indicator(blink: blink)
        }
    }

    private func indicator(blink: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(blink ? 1 : 0.35)

            LevelMeterView(level: recorder.level)

            Text(elapsedText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.red.opacity(0.12), in: Capsule())
        .help("Идёт запись встречи. Полосы показывают уровень микрофона.")
        .accessibilityLabel("Идёт запись встречи, \(elapsedText)")
    }
}

// Пять полос, растущих от уровня сигнала: середина выше краёв, чтобы это
// читалось как эквалайзер, а не как индикатор загрузки.
struct LevelMeterView: View {
    let level: Double

    private let weights: [Double] = [0.55, 0.8, 1.0, 0.8, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: height(for: index))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 16)
    }

    private func height(for index: Int) -> Double {
        let minimum = 3.0
        let maximum = 16.0
        return minimum + (maximum - minimum) * min(max(level, 0), 1) * weights[index]
    }
}
