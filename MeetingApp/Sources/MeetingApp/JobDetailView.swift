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

                if let preview = store.transcriptPreview(for: job) {
                    textSection(title: "Транскрипт", text: preview) {
                        if let path = job.transcriptPath {
                            Button("Показать в Finder") { store.revealInFinder(path: path) }
                        }
                    }
                }

                if let summary = store.summaryPreview(for: job) {
                    textSection(title: "Саммари", text: summary) {
                        Button("Открыть") { store.openSummary(jobID: job.id) }
                        Button("Сохранить копию…") { store.saveSummaryCopy(jobID: job.id) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.name)
                .font(.title2).bold()
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label(job.stage.title, systemImage: job.stage.symbolName)
                    .foregroundStyle(color(for: job.stage))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(DateFormatter.rowDate.string(from: job.updatedAt))
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

    private var actions: some View {
        // Действий много, поэтому они переносятся на следующую строку, а не
        // сжимаются до нечитаемых огрызков.
        FlowRow(spacing: 8) {
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

            if store.hasSummary(job) {
                Button {
                    store.openSummary(jobID: job.id)
                } label: {
                    Label("Открыть саммари", systemImage: "doc.richtext").fixedSize()
                }
                .help("Открыть файл саммари в приложении по умолчанию")

                Button {
                    store.revealSummary(jobID: job.id)
                } label: {
                    Label("В Finder", systemImage: "folder").fixedSize()
                }
                .help("Показать файл саммари в Finder")

                Button {
                    store.saveSummaryCopy(jobID: job.id)
                } label: {
                    Label("Сохранить копию…", systemImage: "square.and.arrow.down").fixedSize()
                }

                Divider().frame(height: 16)

                Button {
                    store.exportSummary(jobID: job.id, to: "notion")
                } label: {
                    // Индикатор рисуется поверх подписи, а не вместо неё:
                    // иначе кнопка меняет ширину и соседние съезжают.
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
                    Label("Открыть в Notion", systemImage: "arrow.up.forward.square").fixedSize()
                }
            }

            Button(role: .destructive) {
                store.stopAndClear(jobID: job.id)
            } label: {
                Label("Удалить", systemImage: "trash").fixedSize()
            }
            .help("Удалить задачу и её промежуточные файлы")
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
