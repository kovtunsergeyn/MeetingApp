import Foundation
import AppKit
import UserNotifications
import MeetingCore

// Предложение записать встречу приходит системным уведомлением, а не своим
// плавающим окном. Так оно уважает режим фокусирования, копится в Центре
// уведомлений, если человек отошёл, и не спорит за внимание с окном встречи.
// Микрофон при этом выбирается в меню строки состояния — в уведомление такой
// список не поместить.
//
// Если разрешение на уведомления не выдано, остаётся прежнее облако внизу
// экрана: предложить запись всё равно нужно.
@MainActor
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingNotifier()

    private weak var store: JobStore?
    private var isAuthorized = false

    private let categoryID = "meeting.detected"
    private let startAction = "meeting.start"
    private let dismissAction = "meeting.dismiss"

    func prepare(store: JobStore) {
        self.store = store

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [
                UNNotificationAction(identifier: startAction, title: "Записать", options: [.foreground]),
                UNNotificationAction(identifier: dismissAction, title: "Не сейчас", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.isAuthorized = granted }
        }
    }

    // Возвращает false, если уведомление показать нельзя — тогда вызывающий
    // показывает облако внизу экрана.
    func notifyMeetingDetected(platform: String) -> Bool {
        guard isAuthorized else { return false }

        let content = UNMutableNotificationContent()
        content.title = "Похоже, у вас встреча"
        content.body = "\(platform) — записать и подготовить саммари?"
        content.categoryIdentifier = categoryID
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return true
    }

    // Обработка идёт минутами, и человек за это время уходит в другое окно.
    // Уведомление говорит, что всё готово, даже если приложение свёрнуто.
    func notifyJobFinished(name: String, succeeded: Bool, detail: String?) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = succeeded ? "Саммари готово" : "Обработка не удалась"
        content.body = succeeded ? name : (detail.map { "\(name): \($0)" } ?? name)
        content.sound = succeeded ? .default : .defaultCritical

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Ответ на уведомление

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case startAction, UNNotificationDefaultActionIdentifier:
                store?.startMeetingRecording()
            default:
                store?.dismissDetectedMeeting()
            }
            completionHandler()
        }
    }

    // Пока приложение впереди, уведомление всё равно показываем: человек может
    // смотреть на другое окно, а решение нужно принять сейчас.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
