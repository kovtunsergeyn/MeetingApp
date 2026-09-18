import AppKit
import SwiftUI
import MeetingCore

// Лог живёт в отдельном окне, а не полосой внизу главного: Apple советует не
// держать нужное у нижнего края — окно часто двигают так, что низ уходит за
// экран. Открывается из меню «Вид» сочетанием ⇧⌘L.
@MainActor
final class LogWindowController {
    static let shared = LogWindowController()

    private var window: NSWindow?

    func show(store: JobStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: LogPanelView(store: store).padding(12))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Лог обработки"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 420))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LogWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }

        self.window = window
    }
}
