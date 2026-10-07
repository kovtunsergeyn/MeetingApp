import Foundation
import EventKit
import MeetingCore

// Смотрит на события во ВСЕХ календарях, которые видит macOS — свои (iCloud)
// и любые подключённые через Системные настройки → Интернет-аккаунты
// (в том числе Google, Exchange и т.д.). Отдельная авторизация Google не
// нужна: если аккаунт добавлен в систему, EventKit уже видит его календари.
final class CalendarMeetingDetector {
    var onMeetingDetected: ((String, String) -> Void)?
    // Для диагностики в логе приложения — сообщает текущий статус доступа.
    var onAccessStatus: ((String) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private let pollInterval: TimeInterval = 30
    private let retryInterval: TimeInterval = 60
    private var handledEventIDs: Set<String> = []
    private var isActive = false

    func start() {
        guard !isActive else { return }
        isActive = true
        attemptStart()
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }

    private func attemptStart() {
        requestAccessIfNeeded { [weak self] granted, statusText in
            guard let self, self.isActive else { return }
            self.onAccessStatus?(statusText)
            if granted {
                self.poll()
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
                    self?.poll()
                }
            } else {
                // Доступ ещё не дали (или пользователь пока не ответил на диалог) —
                // не сдаёмся насовсем, пробуем снова через минуту.
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: self.retryInterval, repeats: false) { [weak self] _ in
                    self?.attemptStart()
                }
            }
        }
    }

    private func requestAccessIfNeeded(completion: @escaping (Bool, String) -> Void) {
        if #available(macOS 14.0, *) {
            let current = EKEventStore.authorizationStatus(for: .event)
            if current == .fullAccess {
                completion(true, "доступ уже разрешён")
                return
            }
            store.requestFullAccessToEvents { granted, error in
                let text = granted ? "доступ разрешён" : "доступ не получен (\(error?.localizedDescription ?? "нет ответа"))"
                DispatchQueue.main.async { completion(granted, text) }
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                let text = granted ? "доступ разрешён" : "доступ не получен (\(error?.localizedDescription ?? "нет ответа"))"
                DispatchQueue.main.async { completion(granted, text) }
            }
        }
    }

    // Название события, которое идёт прямо сейчас. Если таких несколько,
    // выбираем то, где есть ссылка на созвон: запись почти наверняка о нём.
    func currentEventTitle(at now: Date = Date()) -> String? {
        guard hasAccess else { return nil }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(10 * 60),
                                                 calendars: calendars)
        let current = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.startDate <= now.addingTimeInterval(10 * 60) && $0.endDate > now
        }
        let hasLink = { (event: EKEvent) -> Bool in
            [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
                .contains { MeetingLinkDetector.firstMeetingLink(in: $0) != nil }
        }
        let best = current.first(where: hasLink) ?? current.first
        let title = best?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private var hasAccess: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    private func poll() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-30 * 60)
        let windowEnd = now.addingTimeInterval(5 * 60)
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return }

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
        let events = store.events(matching: predicate)

        for event in events {
            // Ловим момент начала (за минуту до и позже) до самого конца встречи.
            guard event.startDate <= now.addingTimeInterval(60), event.endDate > now else { continue }
            checkForMeetingLink(in: event)
        }
    }

    private func checkForMeetingLink(in event: EKEvent) {
        guard let id = event.eventIdentifier, !handledEventIDs.contains(id) else { return }
        let candidates = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        for text in candidates {
            if let match = MeetingLinkDetector.firstMeetingLink(in: text) {
                handledEventIDs.insert(id)
                onMeetingDetected?(match.url, match.platform)
                return
            }
        }
    }
}
