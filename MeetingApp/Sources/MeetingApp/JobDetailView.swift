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
        HStack(spacing: 8) {
            if store.currentJobID == job.id, job.stage.isRunning {
                Button {
                    store.pauseCurrent()
                } label: {
                    Label("Остановить", systemImage: "pause.fill")
                }
                .help("Остановить текущий шаг и запомнить, на чём остановились")
            } else if job.stage.isResumable {
                Button {
                    store.resume(jobID: job.id)
                } label: {
                    Label(job.hasTranscript ? "Продолжить" : "Запустить", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if store.hasSummary(job) {
                Button {
                    store.exportSummary(jobID: job.id, to: "notion")
                } label: {
                    if store.exportingJobIDs.contains(job.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("В Notion", systemImage: "arrow.up.doc")
                    }
                }
                .disabled(!store.isNotionConnected || store.exportingJobIDs.contains(job.id))
                .help(store.isNotionConnected
                      ? "Выгрузить саммари в Notion"
                      : "Notion не подключён к Claude Code")

                Button {
                    store.exportSummary(jobID: job.id, to: "notes")
                } label: {
                    Label("В Заметки", systemImage: "note.text")
                }
                .disabled(store.exportingJobIDs.contains(job.id))
            }

            if let link = job.notionURL {
                Button {
                    store.openURL(link)
                } label: {
                    Label("Открыть в Notion", systemImage: "arrow.up.forward.square")
                }
            }

            Spacer()

            Button(role: .destructive) {
                store.stopAndClear(jobID: job.id)
            } label: {
                Label("Удалить", systemImage: "trash")
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
