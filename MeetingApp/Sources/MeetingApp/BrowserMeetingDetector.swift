import Foundation
import AppKit

// Раз в несколько секунд спрашивает открытые браузеры, какая страница активна,
// и сверяет с известными ссылками ВКС. Работает через AppleScript — при первом
// обращении к каждому браузеру macOS попросит разрешение «Автоматизация».
final class BrowserMeetingDetector {
    var onMeetingDetected: ((String, String) -> Void)?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 8

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
                guard let url = self.frontTabURL(for: browser) else { continue }
                if let platform = MeetingLinkDetector.matchedPlatformName(in: url) {
                    let callback = self.onMeetingDetected
                    DispatchQueue.main.async {
                        callback?(url, platform)
                    }
                    return
                }
            }
        }
    }

    private func isRunning(_ processName: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.localizedName == processName }
    }

    private func frontTabURL(for browser: MonitoredBrowser) -> String? {
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

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let value = result.stringValue
        return (value?.isEmpty ?? true) ? nil : value
    }
}
