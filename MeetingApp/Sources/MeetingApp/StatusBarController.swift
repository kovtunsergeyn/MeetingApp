import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreAudio
import MeetingCore

// Значок в строке меню (справа вверху, рядом с часами) с быстрыми действиями:
// запись встречи начинается в один клик, не разыскивая окно приложения.
// Меню собирается заново при каждом открытии — состав пунктов зависит от того,
// идёт ли сейчас запись.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private weak var store: JobStore?

    func install(store: JobStore) {
        guard statusItem == nil else { return }
        self.store = store

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform.circle",
            accessibilityDescription: "Обработка встреч"
        )
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // Пока идёт запись, значок красный — видно, что микрофон и экран слушают.
    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let recording = store?.isMeetingRecordingActive ?? false
        button.image = NSImage(
            systemSymbolName: recording ? "record.circle" : "waveform.circle",
            accessibilityDescription: "Обработка встреч"
        )
        button.contentTintColor = recording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let store else { return }
        menu.removeAllItems()

        if store.isMeetingRecordingActive {
            let elapsed = store.meetingRecordingElapsedSeconds
            let time = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            menu.addItem(disabledItem("Идёт запись встречи — \(time)"))
            menu.addItem(actionItem("Остановить запись и обработать", #selector(stopRecording), "stop.circle"))
        } else {
            menu.addItem(actionItem("Начать запись встречи", #selector(startRecording), "record.circle"))
        }

        menu.addItem(.separator())
        // Микрофон выбирается прямо отсюда: во время встречи это быстрее, чем
        // искать настройку в окне приложения.
        menu.addItem(microphoneMenuItem())

        menu.addItem(.separator())
        menu.addItem(actionItem("Добавить видео или аудио…", #selector(addMedia), "film"))
        menu.addItem(actionItem("Добавить готовый транскрипт…", #selector(addTranscript), "doc.text"))

        menu.addItem(.separator())
        let running = store.jobs.filter { $0.stage.isRunning }
        if let current = running.first {
            menu.addItem(disabledItem("\(current.stage.title): \(current.name)"))
        } else {
            menu.addItem(disabledItem("Активных задач нет"))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Открыть приложение", #selector(openApp), "macwindow"))
        menu.addItem(actionItem("Настройки…", #selector(openSettings), "gearshape"))
        menu.addItem(.separator())
        menu.addItem(actionItem("Завершить", #selector(quitApp), "power"))

        refreshIcon()
    }

    // Иконку задаём каждому пункту: если у части пунктов её нет, macOS
    // подставляет свою (например, шестерёнку к «Настройки…») и выравнивает
    // соседние пункты по колонке иконок — строки разъезжаются.
    private func actionItem(_ title: String, _ selector: Selector, _ symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: selector, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func microphoneMenuItem() -> NSMenuItem {
        guard let store else { return disabledItem("Микрофон") }
        store.refreshMicrophoneList()

        let item = NSMenuItem(title: NSLocalizedString("Микрофон", comment: ""), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)

        let submenu = NSMenu()
        let currentID = store.selectedMicrophoneDeviceID ?? AudioDevices.defaultInputDeviceID()
        for device in store.availableMicrophones {
            let deviceItem = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.representedObject = device.id
            deviceItem.state = device.id == currentID ? .on : .off
            submenu.addItem(deviceItem)
        }
        if store.availableMicrophones.isEmpty {
            submenu.addItem(disabledItem("Микрофонов не найдено"))
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let store, let deviceID = sender.representedObject as? AudioDeviceID else { return }
        store.selectedMicrophoneDeviceID = deviceID == AudioDevices.defaultInputDeviceID() ? nil : deviceID
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Действия

    @objc private func startRecording() {
        store?.startMeetingRecording()
        refreshIcon()
    }

    @objc private func stopRecording() {
        store?.stopMeetingRecording()
        refreshIcon()
    }

    @objc private func addMedia() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            store.addFiles(panel.urls)
            openApp()
        }
    }

    @objc private func addTranscript() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            store.addTranscriptFile(url)
            openApp()
        }
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    // Системную сцену настроек открывает стандартное действие — то же самое,
    // что пункт «Настройки…» в меню приложения и ⌘,.
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
