import SwiftUI
import MeetingCore

// Настройки — системное окно: открывается пунктом в меню приложения и
// сочетанием ⌘, как принято в macOS, а разделы переключаются панелью
// инструментов. Раньше это было окно, собранное вручную, с кнопкой-шестерёнкой
// внутри содержимого — Apple советует не занимать ею место в панели окна.
struct SettingsView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        TabView {
            GeneralSettingsPane(store: store)
                .tabItem { Label("Основные", systemImage: "gearshape") }

            GlossarySettingsPane(store: store)
                .tabItem { Label("Словарь", systemImage: "character.book.closed") }

            ModelsSettingsPane(store: store)
                .tabItem { Label("Распознавание", systemImage: "waveform") }

            IntegrationsSettingsPane(store: store)
                .tabItem { Label("Интеграции", systemImage: "square.and.arrow.up") }

            MeetingsSettingsPane(store: store)
                .tabItem { Label("Встречи", systemImage: "video") }

            MaintenanceSettingsPane(store: store)
                .tabItem { Label("Обслуживание", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - Основные

struct GeneralSettingsPane: View {
    @ObservedObject var store: JobStore

    var body: some View {
        Form {
            Picker("Язык записи:", selection: Binding(
                get: { store.languageID },
                set: { store.languageID = $0 }
            )) {
                ForEach(TranscriptionLanguage.all) { language in
                    Text(language.title).tag(language.id)
                }
            }

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
            Text("Нужно, чтобы приложение успевало заметить начало встречи и предложить запись.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Папка данных:") {
                HStack {
                    Text(store.dataFolderPath)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Показать") { store.revealInFinder(path: store.dataFolderPath) }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Словарь

struct GlossarySettingsPane: View {
    @ObservedObject var store: JobStore

    private var termCount: Int {
        store.glossary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Аббревиатуры, названия систем, фамилии и имена — через запятую. Подсказывается распознаванию, чтобы оно не коверкало их, и Claude при сборе саммари, чтобы он не расшифровывал их наугад.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: Binding(
                get: { store.glossary },
                set: { store.glossary = $0 }
            ))
            .font(.body)
            .frame(minHeight: 220)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            Text("Терминов: \(termCount). Распознавание учитывает примерно первые 200 токенов — важное держите в начале.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Модели распознавания

struct ModelsSettingsPane: View {
    @ObservedObject var store: JobStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Компьютер: \(MacHardware.summaryText). Рекомендуется «\(WhisperModelOption.recommended().title)».")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(WhisperModelOption.all) { option in
                    WhisperModelRow(store: store, option: option, isSelected: option.id == store.modelID)
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
    }
}

// MARK: - Интеграции

struct IntegrationsSettingsPane: View {
    @ObservedObject var store: JobStore

    var body: some View {
        Form {
            Section("Notion") {
                TextField("База для саммари:", text: Binding(
                    get: { store.notionDatabaseName },
                    set: { store.notionDatabaseName = $0 }
                ))
                LabeledContent("Состояние:") {
                    HStack(spacing: 6) {
                        if store.isCheckingNotion {
                            ProgressView().controlSize(.small)
                            Text("проверяю…")
                        } else if store.isNotionConnected {
                            Label("подключён", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("не подключён", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Button("Проверить") { store.refreshNotionAvailability() }
                            .controlSize(.small)
                    }
                }
                Text("Если базы с таким именем нет, она будет создана при первой выгрузке. Подключение к Notion берётся из Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Заметки") {
                Text("Саммари сохраняется новой заметкой по кнопке в подробностях задачи. Приложение ничего не отправляет само.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Встречи

struct MeetingsSettingsPane: View {
    @ObservedObject var store: JobStore

    var body: some View {
        Form {
            Section("Свои платформы видеосвязи") {
                Text("Zoom, Google Meet и Microsoft Teams узнаются сами. Для внутренней платформы добавьте фрагмент ссылки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(store.customMeetingDomains) { domain in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(domain.label)
                            Text(domain.domain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.removeCustomMeetingDomain(domain.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Удалить платформу \(domain.label)")
                    }
                }

                HStack {
                    TextField("Фрагмент ссылки, например vcs.example.com", text: Binding(
                        get: { store.newMeetingDomainText },
                        set: { store.newMeetingDomainText = $0 }
                    ))
                    TextField("Название", text: Binding(
                        get: { store.newMeetingLabelText },
                        set: { store.newMeetingLabelText = $0 }
                    ))
                    .frame(width: 150)
                    Button("Добавить") {
                        store.addCustomMeetingDomain(domain: store.newMeetingDomainText,
                                                     label: store.newMeetingLabelText)
                        store.newMeetingDomainText = ""
                        store.newMeetingLabelText = ""
                    }
                    .disabled(store.newMeetingDomainText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Микрофон") {
                MicrophonePickerView(store: store)
                Text("Микрофон можно сменить и из меню в строке состояния — во время встречи это быстрее.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Обслуживание

struct MaintenanceSettingsPane: View {
    @ObservedObject var store: JobStore

    var body: some View {
        Form {
            Section("Компоненты") {
                LabeledContent("Папка со скриптами:") {
                    Text(store.scriptsDir)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Проверить компоненты") {
                    store.checkDependenciesAndPrompt()
                    store.refreshNotionAvailability()
                }
            }

            Section("Удаление") {
                Text("Приложение помнит, что установило само, и предложит убрать только это. Программы, которые уже были на компьютере, не тронет.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    store.prepareUninstall()
                } label: {
                    Label("Удалить приложение…", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(
            get: { store.showUninstallSheet },
            set: { store.showUninstallSheet = $0 }
        )) {
            UninstallSheet(store: store)
        }
    }
}
