import SwiftUI
import MeetingCore

// Команды строки меню. По рекомендациям Apple каждое действие панели
// инструментов обязано быть и командой меню: панель можно скрыть или
// перенастроить, а строка меню — единственное место, где человек наверняка
// найдёт всё, что приложение умеет. Раньше меню у приложения не было вовсе.
struct AppCommands: Commands {
    @ObservedObject var store: JobStore

    var body: some Commands {
        // Пункты «Новый», «Открыть», «Печать» нам не нужны — заменяем их
        // своими способами добавить работу.
        CommandGroup(replacing: .newItem) {
            Button("Добавить файл…") { store.pickMediaFiles() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Прикрепить транскрипт…") { store.pickTranscriptFile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Запись") {
            Button(store.isMeetingRecordingActive ? "Остановить запись" : "Записать встречу") {
                if store.isMeetingRecordingActive {
                    store.stopMeetingRecording()
                } else {
                    store.startMeetingRecording()
                }
            }
            .keyboardShortcut("r", modifiers: .command)

            Toggle("Следить за встречами", isOn: Binding(
                get: { store.meetingDetectionEnabled },
                set: { store.meetingDetectionEnabled = $0 }
            ))

            Divider()

            Menu("Микрофон") {
                MicrophoneMenuItems(store: store)
            }
        }

        CommandGroup(after: .toolbar) {
            Menu("Показывать") {
                Button("Все") { store.stageFilter = "all" }
                Button("Только записи встреч") { store.stageFilter = "meetings" }
                Divider()
                ForEach(JobStage.allCases, id: \.rawValue) { stage in
                    Button(stage.title) { store.stageFilter = stage.rawValue }
                }
            }
            Button("Сбросить фильтр") { store.stageFilter = "all" }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Показать лог") { LogWindowController.shared.show(store: store) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Пересобрать историю из папок") { store.rebuildHistoryFromFolders() }
            Button("Проверить компоненты") {
                store.checkDependenciesAndPrompt()
                store.refreshNotionAvailability()
            }
        }
    }
}

// Список микрофонов — общий для меню в строке меню и меню в строке состояния.
struct MicrophoneMenuItems: View {
    @ObservedObject var store: JobStore

    var body: some View {
        ForEach(store.availableMicrophones) { device in
            Button {
                store.selectedMicrophoneDeviceID =
                    device.id == AudioDevices.defaultInputDeviceID() ? nil : device.id
            } label: {
                if isSelected(device) {
                    Label(device.name, systemImage: "checkmark")
                } else {
                    Text(device.name)
                }
            }
        }
    }

    private func isSelected(_ device: AudioDevices.Device) -> Bool {
        let current = store.selectedMicrophoneDeviceID ?? AudioDevices.defaultInputDeviceID()
        return current == device.id
    }
}
