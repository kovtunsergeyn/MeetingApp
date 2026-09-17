import Foundation
import EventKit

// Смотрит на события во ВСЕХ календарях, которые видит macOS — свои (iCloud)
// и любые подключённые через Системные настройки → Интернет-аккаунты
// (в том числе Google, Exchange и т.д.). Отдельная авторизация Google не
// нужна: если аккаунт добавлен в систему, EventKit уже видит его календари.
final class CalendarMeetingDetector {
    var onMeetingDetected: ((String, String) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private let pollInterval: TimeInterval = 30
    private var handledEventIDs: Set<String> = []

    func start() {
        guard timer == nil else { return }
        requestAccessIfNeeded { [weak self] granted in
            guard granted, let self else { return }
            self.poll()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async { completion(granted) }
            }
        }
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
