import Foundation

enum JarvisCalendarRecurrence: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case daily
    case weekly
    case monthly
    case yearly
}

struct JarvisCalendarEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isOutdoor: Bool
    var location: String
    var notes: String
    var urlString: String
    var recurrence: JarvisCalendarRecurrence
    /// `nil` disables alerts, `0` means at the event time.
    var reminderMinutesBefore: Int?
    let createdAt: Date
    var updatedAt: Date
}

extension JarvisCalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, endDate, isAllDay, isOutdoor
        case location, notes, urlString, recurrence, reminderMinutesBefore
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        startDate = try values.decode(Date.self, forKey: .startDate)
        endDate = try values.decode(Date.self, forKey: .endDate)
        isAllDay = try values.decode(Bool.self, forKey: .isAllDay)
        isOutdoor = try values.decodeIfPresent(Bool.self, forKey: .isOutdoor) ?? false
        location = try values.decode(String.self, forKey: .location)
        notes = try values.decode(String.self, forKey: .notes)
        urlString = try values.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        recurrence = try values.decodeIfPresent(
            JarvisCalendarRecurrence.self,
            forKey: .recurrence
        ) ?? .none
        if values.contains(.reminderMinutesBefore) {
            reminderMinutesBefore = try values.decodeIfPresent(
                Int.self,
                forKey: .reminderMinutesBefore
            )
        } else {
            // Existing events created before reminders were configurable keep
            // the original behaviour: notify at the event time.
            reminderMinutesBefore = 0
        }
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

enum JarvisCalendarError: LocalizedError {
    case emptyTitle
    case invalidDateRange

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "일정 제목을 입력해주세요."
        case .invalidDateRange:
            return "종료 시각은 시작 시각보다 늦어야 합니다."
        }
    }
}

/// JARVIS 전용 로컬 캘린더입니다. Apple 캘린더와 동기화하거나
/// EventKit 데이터를 읽지 않으며, 이 앱의 샌드박스에만 저장합니다.
@MainActor
final class JarvisCalendarStore: ObservableObject {
    static let shared = JarvisCalendarStore()

    @Published private(set) var events: [JarvisCalendarEvent]

    @Published private(set) var storageIssue: String?
    let persistence: RecordPersistence<JarvisCalendarEvent>
    var canRestore: Bool { persistence.canRestore }
    @Published var notificationIssue: String?
    private let changeJournal: RecordPersistence<CalendarChangeMarker>

    init(defaults: UserDefaults = .standard, persistence: RecordPersistence<JarvisCalendarEvent>? = nil) {
        let persistence = persistence ?? RecordPersistence<JarvisCalendarEvent>(defaults: defaults, key: "jarvis.calendar.events.v1")
        self.persistence = persistence
        changeJournal = RecordPersistence<CalendarChangeMarker>(defaults: defaults,
            key: "jarvis.calendar.pending-mutation", fileURL: persistence.fileURL?.appendingPathExtension("journal"))
        events = persistence.load().sorted { $0.startDate < $1.startDate }
        if Set(events.map(\.id)).count != events.count {
            persistence.invalidate("중복된 일정 식별자가 있습니다. 원본을 보존하고 변경을 차단했습니다.")
        }
        storageIssue = persistence.issue
        if !changeJournal.load().isEmpty || changeJournal.blocked { notificationIssue = "이전 일정 변경의 알림 예약 확인이 필요합니다. 알림 재예약을 눌러주세요." }
    }
    func ensureWritable() throws { try persistence.ensureWritable() }
    func beginChange() throws {
        try ensureWritable()
        guard changeJournal.load().isEmpty, !changeJournal.blocked else {
            throw LocalDataError.blocked(notificationIssue ?? "미완료 일정 변경이 있습니다. 알림 재예약으로 확인해주세요.")
        }
        try changeJournal.save([CalendarChangeMarker(startedAt: Date())])
    }
    func finishChange() throws {
        try ensureWritable()
        try changeJournal.save([]); notificationIssue = nil
    }
    func prepareJournalRecovery(confirmed: Bool) throws {
        if changeJournal.blocked { _ = try changeJournal.restore(confirmed: confirmed) }
    }
    func restoreEventSnapshot(_ event: JarvisCalendarEvent) throws {
        try replace(events.filter { $0.id != event.id } + [event])
    }
    func restore(confirmed: Bool) throws {
        events = try persistence.restore(confirmed: confirmed).sorted { $0.startDate < $1.startDate }
        storageIssue = persistence.issue
    }

    func event(id: UUID) -> JarvisCalendarEvent? {
        events.first { $0.id == id }
    }

    func conflicts(start: Date, end: Date, excluding id: UUID? = nil, calendar: Calendar = .current) -> [JarvisCalendarEvent] {
        guard end > start else { return [] }
        return events.filter { $0.id != id }.flatMap {
            occurrences(of: $0, intersecting: start..<end, calendar: calendar)
        }.sorted { $0.startDate < $1.startDate }
    }

    func events(on date: Date, calendar: Calendar = .current) -> [JarvisCalendarEvent] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.flatMap { occurrences(of: $0, intersecting: start..<end, calendar: calendar) }
            .sorted { $0.startDate < $1.startDate }
    }

    func upcoming(after date: Date = Date()) -> [JarvisCalendarEvent] {
        upcomingOccurrences(after: date, limit: 40)
    }

    func upcomingOccurrences(
        of selectedEvent: JarvisCalendarEvent? = nil,
        after date: Date = Date(),
        limit: Int,
        horizonDays: Int = 370,
        calendar: Calendar = .current
    ) -> [JarvisCalendarEvent] {
        let source = selectedEvent.map { [$0] } ?? events
        let startDay = calendar.startOfDay(for: date)
        let horizon = calendar.date(byAdding: .day, value: horizonDays, to: startDay)
            ?? date.addingTimeInterval(Double(horizonDays) * 86_400)
        var results: [JarvisCalendarEvent] = []
        var day = startDay

        while day < horizon, results.count < limit {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let interval = day..<nextDay
            for event in source {
                for occurrence in occurrences(of: event, intersecting: interval, calendar: calendar)
                    where occurrence.startDate >= date {
                    let duplicate = results.contains {
                        $0.id == occurrence.id && $0.startDate == occurrence.startDate
                    }
                    if !duplicate { results.append(occurrence) }
                }
            }
            day = nextDay
        }
        return results.sorted { $0.startDate < $1.startDate }.prefix(limit).map { $0 }
    }

    @discardableResult
    func create(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        isOutdoor: Bool,
        location: String,
        notes: String,
        urlString: String = "",
        recurrence: JarvisCalendarRecurrence = .none,
        reminderMinutesBefore: Int? = 0
    ) throws -> JarvisCalendarEvent {
        let now = Date()
        let event = JarvisCalendarEvent(
            id: UUID(),
            title: title,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            isOutdoor: isOutdoor,
            location: location,
            notes: notes,
            urlString: urlString,
            recurrence: recurrence,
            reminderMinutesBefore: reminderMinutesBefore,
            createdAt: now,
            updatedAt: now
        )
        try upsert(event)
        return event
    }

    func upsert(_ rawEvent: JarvisCalendarEvent) throws {
        var event = rawEvent
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = event.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.urlString = event.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.title.isEmpty else { throw JarvisCalendarError.emptyTitle }
        guard event.endDate > event.startDate else { throw JarvisCalendarError.invalidDateRange }
        event.updatedAt = Date()

        var next = events
        if let index = next.firstIndex(where: { $0.id == event.id }) {
            next[index] = event
        } else {
            next.append(event)
        }
        try replace(next)
    }

    func remove(id: UUID) throws {
        try replace(events.filter { $0.id != id })
    }

    func removeAll() throws {
        try replace([])
    }

    func replace(_ next: [JarvisCalendarEvent]) throws {
        do { try persistence.save(next) }
        catch { storageIssue = persistence.issue; throw error }
        events = next.sorted { $0.startDate < $1.startDate }
        storageIssue = persistence.issue
    }

    private func occurrences(
        of event: JarvisCalendarEvent,
        intersecting interval: Range<Date>,
        calendar: Calendar
    ) -> [JarvisCalendarEvent] {
        guard event.recurrence != .none else {
            return event.startDate < interval.upperBound && event.endDate > interval.lowerBound
                ? [event]
                : []
        }

        let duration = max(1, event.endDate.timeIntervalSince(event.startDate))
        let lookBackDays = max(1, Int(ceil(duration / 86_400)))
        var results: [JarvisCalendarEvent] = []
        for offset in (-lookBackDays)...0 {
            guard let candidateDay = calendar.date(
                byAdding: .day,
                value: offset,
                to: interval.lowerBound
            ),
            let occurrenceStart = occurrenceStart(
                for: event,
                on: candidateDay,
                calendar: calendar
            ) else { continue }
            let occurrenceEnd = occurrenceStart.addingTimeInterval(duration)
            guard occurrenceStart < interval.upperBound,
                  occurrenceEnd > interval.lowerBound else { continue }
            var occurrence = event
            occurrence.startDate = occurrenceStart
            occurrence.endDate = occurrenceEnd
            results.append(occurrence)
        }
        return results
    }

    private func occurrenceStart(
        for event: JarvisCalendarEvent,
        on candidateDate: Date,
        calendar: Calendar
    ) -> Date? {
        let baseDay = calendar.startOfDay(for: event.startDate)
        let candidateDay = calendar.startOfDay(for: candidateDate)
        guard candidateDay >= baseDay else { return nil }

        let base = calendar.dateComponents(
            [.month, .day, .weekday, .hour, .minute, .second],
            from: event.startDate
        )
        let candidate = calendar.dateComponents([.month, .day, .weekday], from: candidateDay)
        let matches: Bool
        switch event.recurrence {
        case .none:
            matches = candidateDay == baseDay
        case .daily:
            matches = true
        case .weekly:
            matches = candidate.weekday == base.weekday
        case .monthly:
            matches = candidate.day == base.day
        case .yearly:
            matches = candidate.month == base.month && candidate.day == base.day
        }
        guard matches else { return nil }

        if event.isAllDay { return candidateDay }
        return calendar.date(
            bySettingHour: base.hour ?? 0,
            minute: base.minute ?? 0,
            second: base.second ?? 0,
            of: candidateDay
        )
    }
}

private struct CalendarChangeMarker: Codable { let startedAt: Date }
