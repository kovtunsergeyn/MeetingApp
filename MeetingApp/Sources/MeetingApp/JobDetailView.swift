import SwiftUI
import MeetingCore

// Подробности выбранной задачи: этапы, ошибка, куски транскрипта и саммари,
// выгрузка. Раньше всё это теснилось в одной строке списка — на Маке для
// такого есть место справа, и HIG советует показывать больше содержимого
// сразу, а не прятать его в узкие строки.
struct JobDetailView: View {
    @ObservedObject var store: JobStore
    let job: Job

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if job.stage.isRunning, store.currentJobID == job.id {
                    StageProgressView(store: store)
                }

                if let error = job.lastError {
                    errorSection(error)
                }

                actions

                if let audio = store.audioPath(for: job) {
                    GroupBox {
                        AudioPlayerView(store: store, path: audio)
                            .padding(6)
                    }
                }

                // Кнопка открытия стоит там же, где текст, к которому она
                // относится: искать её в общем ряду наверху было незачем.
                if let preview = store.transcriptPreview(for: job) {
                    textSection(title: "Транскрипт", text: preview) {
                        Button {
                            store.openTranscript(jobID: job.id)
                        } label: {
                            Label("Открыть", systemImage: "arrow.up.forward.app")
                        }
                        .help("Открыть файл транскрипта")
                    }
                }

                if let summary = store.summaryPreview(for: job) {
                    textSection(title: "Саммари", text: summary) {
                        Button {
                            store.openSummary(jobID: job.id)
                        } label: {
                            Label("Открыть", systemImage: "arrow.up.forward.app")
                        }
                        .help("Открыть файл саммари")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(
            get: { store.renameJobID != nil },
            set: { if !$0 { store.renameJobID = nil } }
        )) {
            RenameSheet(store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(job.name)
                    .font(.title2).bold()
                    .textSelection(.enabled)
                Button {
                    store.startRename(jobID: job.id)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Переименовать встречу")
                .accessibilityLabel("Переименовать встречу")
            }
            HStack(spacing: 8) {
                Label(job.stage.title, systemImage: job.stage.symbolName)
                    .foregroundStyle(color(for: job.stage))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(DateFormatter.rowDate.string(from: job.createdAt))
                    .foregroundStyle(.secondary)
                if job.isMeetingRecording {
                    Text("·").foregroundStyle(.secondary)
                    Label("запись встречи", systemImage: "video")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private func errorSection(_ error: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = job.lastErrorDetail {
                    DisclosureGroup("Подробности") {
                        ErrorDetailView(text: detail)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Порядок кнопок: сверху то, ради чего всё делалось — отправить саммари
    // наружу. Ниже — посмотреть результат. Внизу — то, что делают редко.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.currentJobID == job.id, job.stage.isRunning {
                Button {
                    store.pauseCurrent()
                } label: {
                    Label("Остановить", systemImage: "pause.fill").fixedSize()
                }
                .help("Остановить текущий шаг и запомнить, на чём остановились")
            } else if job.stage.isResumable {
                Button {
                    store.resume(jobID: job.id)
                } label: {
                    Label(job.hasTranscript ? "Продолжить" : "Запустить", systemImage: "play.fill").fixedSize()
                }
                .buttonStyle(.borderedProminent)
            }

            if store.hasSummary(job) || job.hasTranscript {
                HStack(spacing: 8) {
                    if store.hasSummary(job) {
                        Button {
                            store.exportSummary(jobID: job.id, to: "notion")
                        } label: {
                            // Индикатор поверх подписи: иначе кнопка меняет
                            // ширину и соседние съезжают.
                            ZStack {
                                Label("В Notion", systemImage: "arrow.up.doc")
                                    .opacity(store.exportingJobIDs.contains(job.id) ? 0 : 1)
                                if store.exportingJobIDs.contains(job.id) {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .fixedSize()
                        }
                        .disabled(!store.isNotionConnected || store.exportingJobIDs.contains(job.id))
                        .help(store.isNotionConnected
                              ? "Выгрузить саммари в Notion"
                              : "Notion не подключён к Claude Code")

                        Button {
                            store.exportSummary(jobID: job.id, to: "notes")
                        } label: {
                            Label("В Заметки", systemImage: "note.text").fixedSize()
                        }
                        .disabled(store.exportingJobIDs.contains(job.id))
                    }

                    if let link = job.notionURL {
                        Button {
                            store.openURL(link)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .help("Открыть страницу в Notion")
                        .accessibilityLabel("Открыть страницу в Notion")
                    }

                    Spacer()

                    Button {
                        store.revealSummary(jobID: job.id)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .disabled(!store.hasSummary(job))
                    .help("Показать файлы встречи в Finder")
                    .accessibilityLabel("Показать файлы встречи в Finder")
                }

            }

            HStack(spacing: 8) {
                if store.hasSummary(job) {
                    Button {
                        store.saveSummaryCopy(jobID: job.id)
                    } label: {
                        Label("Сохранить копию…", systemImage: "square.and.arrow.down").fixedSize()
                    }
                }

                Button(role: .destructive) {
                    store.stopAndClear(jobID: job.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Удалить задачу и её файлы")
                .accessibilityLabel("Удалить задачу и её файлы")
            }
            .padding(.top, 2)
        }
    }

    private func textSection<Buttons: View>(
        title: String,
        text: String,
        @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    buttons()
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(14)
            }
            .padding(6)
        }
    }

    private func color(for stage: JobStage) -> Color {
        switch stage {
        case .done: return .green
        case .failed: return .red
        case .paused: return .orange
        case .downloading, .transcribing, .summarizing: return .blue
        case .transcribed: return .purple
        case .queued: return .secondary
        }
    }
}


// MARK: - Строка, переносящая кнопки

// Простая раскладка «в строку с переносом»: кнопок в подробностях много, и на
// узком окне они должны переноситься, а не сжиматься до многоточий.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// MARK: - Переименование

struct RenameSheet: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Переименовать встречу")
                .font(.headline)

            TextField("Название", text: Binding(
                get: { store.renameText },
                set: { store.renameText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 360)
            .onSubmit { store.confirmRename() }

            Text("Папка с транскриптом будет переименована вместе со встречей, если это возможно.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Отмена") { store.renameJobID = nil }
                Button("Переименовать") { store.confirmRename() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}


// MARK: - Проигрыватель записи

struct AudioPlayerView: View {
    @ObservedObject var store: JobStore
    @ObservedObject private var playback: AudioPlayback
    let path: String

    init(store: JobStore, path: String) {
        self.store = store
        self.playback = store.playback
        self.path = path
    }

    private var isCurrent: Bool { playback.currentPath == path }

    private var safeDuration: Double {
        let value = isCurrent ? playback.duration : 0
        return value.isFinite && value > 0 ? value : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Запись встречи", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Text("\(AudioPlayback.timeText(isCurrent ? playback.currentTime : 0)) / \(AudioPlayback.timeText(isCurrent ? playback.duration : 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    playback.load(path: path)
                    playback.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .help("Назад на 15 секунд")
                .accessibilityLabel("Назад на 15 секунд")

                Button {
                    playback.load(path: path)
                    playback.toggle()
                } label: {
                    Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .help(isCurrent && playback.isPlaying ? "Пауза" : "Слушать запись")
                .accessibilityLabel(isCurrent && playback.isPlaying ? "Пауза" : "Слушать запись")

                Button {
                    playback.load(path: path)
                    playback.skip(by: 15)
                } label: {
                    Image(systemName: "goforward.15")
                }
                .help("Вперёд на 15 секунд")
                .accessibilityLabel("Вперёд на 15 секунд")

                Slider(
                    value: Binding(
                        get: { isCurrent ? playback.currentTime : 0 },
                        set: { newValue in
                            playback.load(path: path)
                            playback.seek(to: newValue)
                        }
                    ),
                    // Длительность может прийти нулевой или нечисловой, если
                    // файл повреждён: недопустимый диапазон роняет приложение.
                    in: 0...safeDuration
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onAppear { playback.load(path: path) }
        .onChange(of: path) { newPath in playback.load(path: newPath) }
    }
}
