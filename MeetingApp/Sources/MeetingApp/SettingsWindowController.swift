import AppKit
import SwiftUI
import MeetingCore

// Настройки открываются отдельным окном, а не листом поверх главного:
// лист прибит к родительскому окну — его нельзя ни отодвинуть, ни оставить
// открытым, пока смотришь на список задач. Обычное окно двигается, меняет
// размер и запоминает своё положение между запусками.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(store: JobStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsSheet(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Настройки"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Закрыли окно крестиком — снимаем флаг, иначе кнопка «Настройки»
        // перестанет открывать его снова.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                store.showSettings = false
                self?.window = nil
            }
        }

        self.window = window
    }

    func hide() {
        window?.close()
        window = nil
    }
}
