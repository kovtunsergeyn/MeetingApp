import AppKit

// Возврат окна, когда его не видно.
//
// Щелчок по значку в Dock приходит приложению отдельным вызовом —
// applicationShouldHandleReopen. Раньше разворот висел на уведомлении
// «приложение стало активным», и этого не хватало: у приложения есть значок в
// строке меню, оно часто уже активно, уведомление не приходит, и свёрнутое
// окно оставалось в Dock навсегда.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Окно создаётся, пока SwiftUI строит сцену, поэтому берём его
        // следующим проходом цикла, а не прямо здесь.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.delegate = self
            }
        }
    }

    // Крестик не уничтожает окно, а прячет его. Иначе приложение остаётся без
    // окна совсем: SwiftUI своё окно обратно не создаёт, щелчок по значку в
    // Dock ничего не даёт, и добраться до приложения становится нечем.
    // Заодно сохраняется всё, что было на экране.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // Щелчок по значку в Dock. Возвращаем false, если окно подняли сами;
    // true — если своего окна не нашлось и его должен создать AppKit.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return !WindowRestore.restore()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        WindowRestore.restore()
    }
}

enum WindowRestore {
    // true — окно нашлось и показано.
    @discardableResult
    static func restore() -> Bool {
        // Приложение, спрятанное через ⌘H, не разворачивается, а показывается:
        // окна у него при этом не свёрнуты, просто скрыты целиком.
        if NSApp.isHidden {
            NSApp.unhide(nil)
        }

        // Берём окна с заголовком: так отсеивается окно значка в строке меню,
        // а главное и настройки остаются. Проверять canBecomeMain нельзя —
        // убранное с экрана окно отвечает на него «нет», и восстанавливать
        // становилось нечего. Из нескольких кандидатов берём самое большое:
        // главное окно заметно крупнее настроек.
        let candidates = NSApp.windows
            .filter { $0.styleMask.contains(.titled) }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

        if let miniaturized = candidates.first(where: { $0.isMiniaturized }) {
            miniaturized.deminiaturize(nil)
            miniaturized.makeKeyAndOrderFront(nil)
            return true
        }

        // Сюда попадают и спрятанные крестиком окна: они живы, просто убраны
        // с экрана, и возвращаются тем же способом.
        if let window = candidates.first {
            window.makeKeyAndOrderFront(nil)
            return true
        }

        // Окон нет вовсе — его закрыли крестиком. Создать новое может только
        // AppKit, поэтому говорим об этом вызывающему.
        return false
    }
}
