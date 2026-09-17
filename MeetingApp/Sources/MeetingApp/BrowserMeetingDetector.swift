import Foundation
import AppKit

// Раз в несколько секунд спрашивает открытые браузеры, какая страница активна,
// и сверяет с известными ссылками ВКС. Работает через AppleScript — при первом
// обращении к каждому браузеру macOS попросит разрешение «Автоматизация»
// (отдельно на каждый браузер).
final class BrowserMeetingDetector {
    var onMeetingDetected: ((String, String) -> Void)?
    // Для диагностики в логе приложения — какие браузеры проверили и что пошло не так.
    var onDiagnostic: ((String) -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 8
    private var reportedErrors: Set<String> = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for browser in MonitoredBrowser.all {
                guard self.isRunning(browser.processName) else { continue }
                switch self.frontTabURL(for: browser) {
                case .success(let url):
                    if let match = MeetingLinkDetector.firstMeetingLink(in: url) {
                        let callback = self.onMeetingDetected
                        DispatchQueue.main.async {
                            callback?(match.url, match.platform)
                        }
                        return
                    }
                case .empty:
                    continue
                case .failure(let message):
                    // Одна и та же ошибка по одному браузеру не должна засорять
                    // лог каждые 8 секунд — сообщаем один раз.
                    let key = browser.processName + ":" + message
                    if !self.reportedErrors.contains(key) {
                        self.reportedErrors.insert(key)
                        let diag = self.onDiagnostic
                        DispatchQueue.main.async {
                            diag?("\(browser.processName): \(message)")
                        }
                    }
                }
            }
        }
    }

    private func isRunning(_ processName: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.localizedName == processName }
    }

    private enum TabURLResult {
        case success(String)
        case empty
        case failure(String)
    }

    private func frontTabURL(for browser: MonitoredBrowser) -> TabURLResult {
        let script: String
        switch browser.dialect {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                return URL of front document
            end tell
            """
        case .chromium:
            script = """
            tell application "\(browser.appleScriptName)"
                if (count of windows) = 0 then return ""
                return URL of active tab of front window
            end tell
            """
        }

        guard let appleScript = NSAppleScript(source: script) else {
            return .failure("не удалось разобрать AppleScript")
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "неизвестная ошибка (\(error))"
            return .failure(message)
        }
        guard let value = result.stringValue, !value.isEmpty else { return .empty }
        return .success(value)
    }
}
