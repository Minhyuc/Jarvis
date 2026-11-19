import CoreLocation
import Foundation
import UserNotifications

@MainActor
protocol NotificationReservationBackend: AnyObject {
    func pending() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func remove(_ ids: [String])
    func authorize(requestIfNeeded: Bool) async throws
}

@MainActor
private final class SystemNotificationReservations: NotificationReservationBackend {
    private let center = UNUserNotificationCenter.current()
    func pending() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func remove(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func authorize(requestIfNeeded: Bool) async throws {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return
        case .notDetermined:
            if requestIfNeeded, try await center.requestAuthorization(options: [.alert, .sound]) { return }
        case .denied: break
        @unknown default: break
        }
        throw JarvisCalendarNotificationError.permissionDenied
    }
}

enum JarvisCalendarNotificationError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "일정 알림을 받으려면 설정에서 JARVIS의 알림 권한을 허용해주세요."
    }
}

@MainActor
final class JarvisCalendarNotificationService: ObservableObject {
    static let shared = JarvisCalendarNotificationService()

    private let backend: any NotificationReservationBackend
    private let store: JarvisCalendarStore
    private let renderOverride: (@MainActor (String, String) async -> String?)?
    private let speechRenderer = AlarmSpeechRenderer()
    private let weatherService = CalendarWeatherForecastService()
    private let lastRefreshKey = "jarvis.calendar.notifications.lastRefresh"
    @Published private(set) var statusMessage: String?
    @Published private(set) var coverageEnd: Date?
    private var busy = false
    init(store: JarvisCalendarStore? = nil, backend: (any NotificationReservationBackend)? = nil,
         render: (@MainActor (String, String) async -> String?)? = nil) {
        self.store = store ?? .shared
        self.backend = backend ?? SystemNotificationReservations()
        renderOverride = render
        coverageEnd = UserDefaults.standard.object(forKey: "jarvis.calendar.notifications.coverageEnd") as? Date
    }

    func schedule(_ event: JarvisCalendarEvent) async throws {
        var events = store.events.filter { $0.id != event.id }
        events.append(event)
        try await rebuild(events: events)
        if let minutes = event.reminderMinutesBefore {
            let future = Self.plannedOccurrences(events: [event], store: store, now: Date())
            guard !future.isEmpty else {
                throw LocalDataError.unverified("일정은 저장했지만 알림 시각이 지났거나 예약 범위 밖이어서 알림을 예약하지 않았습니다.")
            }
            if let next = future.first {
                let identifier = notificationIdentifier(for: next.id, timestamp: Int(next.startDate.timeIntervalSince1970))
                let pending = await backend.pending()
                guard pending.contains(where: { $0.identifier == identifier }) else {
                    throw LocalDataError.unverified("일정은 저장했지만 예약 공간이 부족하여 알림을 예약하지 못했습니다. \(minutes)분 전 알림의 예약 범위를 확인해주세요.")
                }
            }
        }
    }

    /// Shared rolling budget across calendar events; other app requests (in
    /// particular alarms) are never evicted. Old requests remain until verified.
    func rebuild(events: [JarvisCalendarEvent], requestPermission: Bool = true) async throws {
        guard !busy else { throw LocalDataError.blocked("알림을 갱신 중입니다. 잠시 후 다시 시도해주세요.") }
        busy = true; defer { busy = false }
        try LocalDataExecution.check(.localData(.refreshNotifications))
        try store.ensureWritable()
        let existing = await backend.pending()
        let old = existing.filter { $0.identifier.hasPrefix("jarvis.calendar.") }
        let otherCount = existing.filter { !$0.identifier.hasPrefix("jarvis.calendar.") }.count
        let capacity = max(0, min(48, 56 - otherCount)) // Leave headroom for alarms.
        let now = Date()
        let all = Self.plannedOccurrences(events: events, store: store, now: now)
        let selected = Array(all.prefix(capacity))
        if !selected.isEmpty { try await backend.authorize(requestIfNeeded: requestPermission) }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.identifier, $0) })
        var prepared: [UNNotificationRequest] = []
        var generatedFiles: [String] = []
        var weatherLookups = 0
        do {
        for occurrence in selected {
            try LocalDataExecution.check(.localData(.refreshNotifications))
            let fireDate = notificationDate(for: occurrence)
                .addingTimeInterval(-Double(occurrence.reminderMinutesBefore ?? 0) * 60)
            guard fireDate > now else { continue }

            var weatherSentence: String?
            if occurrence.isOutdoor, weatherLookups < 3 {
                weatherSentence = try? await weatherService.summary(
                    for: occurrence.startDate,
                    locationName: occurrence.location
                )
                weatherLookups += 1
            }
            let message = briefingMessage(
                for: occurrence,
                reminderMinutesBefore: occurrence.reminderMinutesBefore ?? 0,
                weatherSentence: weatherSentence
            )
            let timestamp = Int(occurrence.startDate.timeIntervalSince1970)
            let fileToken = "calendar-\(occurrence.id.uuidString)-\(timestamp)-\(UUID().uuidString)"
            let soundFileName: String?
            if let renderOverride { soundFileName = await renderOverride(message, fileToken) }
            else { soundFileName = await speechRenderer.render(message: message, fileToken: fileToken) }
            if let soundFileName { generatedFiles.append(soundFileName) }

            let content = UNMutableNotificationContent()
            content.title = "JARVIS 일정 · \(occurrence.title)"
            content.body = message
            content.userInfo = [
                "jarvisCalendarEventID": occurrence.id.uuidString,
                "jarvisCalendarOccurrence": timestamp
            ]
            if let soundFileName {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFileName))
            } else {
                content.sound = .default
            }

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            prepared.append(UNNotificationRequest(
                identifier: notificationIdentifier(for: occurrence.id, timestamp: timestamp),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            ))
        }
        // Budget may be full during replacement. Remove only obsolete calendar
        // requests; exact old requests below are retained for rollback.
        try LocalDataExecution.check(.localData(.refreshNotifications))
        let newIDs = Set(prepared.map(\.identifier))
        backend.remove(old.filter { !newIDs.contains($0.identifier) }.map(\.identifier))
        for request in prepared {
            try LocalDataExecution.check(.localData(.refreshNotifications))
            try await backend.add(request)
        }
        let actual = await backend.pending()
        try LocalDataExecution.check(.localData(.refreshNotifications))
        guard prepared.allSatisfy({ request in actual.contains {
            $0.identifier == request.identifier && $0.content.isEqual(request.content)
        } }) else { throw LocalDataError.recovery }
        coverageEnd = selected.map { notificationDate(for: $0).addingTimeInterval(-Double($0.reminderMinutesBefore ?? 0) * 60) }.max()
        if let coverageEnd { UserDefaults.standard.set(coverageEnd, forKey: "jarvis.calendar.notifications.coverageEnd") }
        else { UserDefaults.standard.removeObject(forKey: "jarvis.calendar.notifications.coverageEnd") }
        let limited = all.count > selected.count || events.contains { $0.recurrence != .none && $0.reminderMinutesBefore != nil }
        statusMessage = limited ? "가까운 일정 알림 \(selected.count)개를 예약했습니다. 반복·장기 일정은 앱을 열 때 갱신됩니다. 예약 범위를 확인해주세요." : nil
        } catch {
            let restored = await Task { @MainActor in
                do {
                    self.backend.remove(prepared.filter { oldByID[$0.identifier] == nil }.map(\.identifier))
                    for request in old { try await self.backend.add(request) }
                    let restored = await self.backend.pending()
                    return old.allSatisfy { request in restored.contains {
                        $0.identifier == request.identifier && $0.content.isEqual(request.content)
                    } }
                } catch { return false }
            }.value
            if restored { generatedFiles.forEach { speechRenderer.remove(fileName: $0) } }
            statusMessage = restored ? "알림 갱신에 실패하여 이전 예약으로 복구했습니다." : "일부 알림 예약의 복구를 확인하지 못했습니다. 예약 상태를 다시 확인해주세요."
            throw LocalDataError.recovery
        }
    }

    static func plannedOccurrences(events: [JarvisCalendarEvent], store: JarvisCalendarStore,
                                   now: Date) -> [JarvisCalendarEvent] {
        events.filter { $0.reminderMinutesBefore != nil }.flatMap { event in
            let occurrences = event.recurrence == .none ? [event] : store.upcomingOccurrences(
                of: event, after: Calendar.current.startOfDay(for: now), limit: 64)
            return occurrences.filter { fireDate($0) > now }
        }.sorted { fireDate($0) < fireDate($1) }
    }
    static func fireDate(_ event: JarvisCalendarEvent) -> Date {
        let start = event.isAllDay ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
            of: event.startDate) ?? event.startDate : event.startDate
        return start.addingTimeInterval(-Double(event.reminderMinutesBefore ?? 0) * 60)
    }

    func cancel(_ event: JarvisCalendarEvent) async throws {
        try LocalDataExecution.check(.localData(.refreshNotifications))
        let prefix = notificationPrefix(for: event.id)
        let requests = await backend.pending()
        let identifiers = requests.map(\.identifier).filter {
            $0 == String(prefix.dropLast()) || $0.hasPrefix(prefix)
        }
        backend.remove(identifiers)
        let remaining = await backend.pending()
        try LocalDataExecution.check(.localData(.refreshNotifications))
        guard !remaining.contains(where: { identifiers.contains($0.identifier) }) else { throw LocalDataError.recovery }
        // Keep sound assets until the replacement transaction commits. Deleting
        // them here would also silence restored notification requests.
    }

    /// Refreshes outdoor forecasts at most every six hours. iOS does not let a
    /// normal local notification fetch network data at the exact fire time, so
    /// notifications are updated whenever the app is active.
    func refreshUpcomingNotifications(force: Bool = false) async {
        let defaults = UserDefaults.standard
        let lastRefresh = defaults.object(forKey: lastRefreshKey) as? Date ?? .distantPast
        let needsRefill = coverageEnd.map { $0 < Date().addingTimeInterval(3_600) } ?? true
        guard force || needsRefill || Date().timeIntervalSince(lastRefresh) >= 6 * 60 * 60 else { return }

        let result: ToolExecutionResult<Void> = await LocalDataExecution.perform(.localData(.refreshNotifications), origin: .backgroundAutomation) { [self] in
            guard store.notificationIssue == nil else { throw LocalDataError.recovery }
            try await rebuild(events: store.events, requestPermission: false)
        }
        switch result {
        case .succeeded: defaults.set(Date(), forKey: lastRefreshKey)
        case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message):
            statusMessage = "일정 알림 갱신 실패: " + message
        case .handedOff: statusMessage = "일정 알림 예약 결과를 확인하지 못했습니다."
        }
    }

    private func notificationDate(for event: JarvisCalendarEvent) -> Date {
        guard event.isAllDay else { return event.startDate }
        return Calendar.current.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: event.startDate
        ) ?? event.startDate
    }

    private func briefingMessage(
        for event: JarvisCalendarEvent,
        reminderMinutesBefore: Int,
        weatherSentence: String?
    ) -> String {
        let address = UserProfileStore.load().addressForGreeting
        let prefix = address.map { "\($0), " } ?? ""
        let timing: String
        switch reminderMinutesBefore {
        case 0:
            timing = "일정 시간입니다."
        case 60:
            timing = "1시간 뒤 시작됩니다."
        case 1_440:
            timing = "내일 시작됩니다."
        default:
            timing = "\(reminderMinutesBefore)분 뒤 시작됩니다."
        }
        var message = "\(prefix)\(event.title) \(timing)"
        if event.isOutdoor {
            message += " " + (weatherSentence ?? "야외 일정입니다. 출발 전에 날씨를 확인해주세요.")
        }
        return message
    }

    private func notificationPrefix(for id: UUID) -> String {
        "jarvis.calendar.\(id.uuidString)."
    }

    private func notificationIdentifier(for id: UUID, timestamp: Int) -> String {
        "\(notificationPrefix(for: id))\(timestamp)"
    }
}

@MainActor
final class CalendarWeatherForecastService {
    private struct ForecastResponse: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let temperature: [Double]
            let precipitation: [Int]
            let weatherCode: [Int]

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case precipitation = "precipitation_probability"
                case weatherCode = "weather_code"
            }
        }
        let hourly: Hourly
    }

    private let locationProvider = CurrentLocationProvider()

    func summary(for eventDate: Date, locationName: String) async throws -> String? {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: eventDate)
        ).day ?? 0
        guard days >= 0, days < 16 else { return nil }

        let location = try await forecastLocation(named: locationName)
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,precipitation_probability,weather_code"
            ),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
            URLQueryItem(name: "forecast_days", value: String(min(16, days + 1)))
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else { return nil }
        let forecast = try JSONDecoder().decode(ForecastResponse.self, from: data)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let datedHours = forecast.hourly.time.enumerated().compactMap { index, value -> (Int, Date)? in
            formatter.date(from: value).map { (index, $0) }
        }
        guard let closest = datedHours.min(by: {
            abs($0.1.timeIntervalSince(eventDate)) < abs($1.1.timeIntervalSince(eventDate))
        }),
        forecast.hourly.temperature.indices.contains(closest.0),
        forecast.hourly.precipitation.indices.contains(closest.0),
        forecast.hourly.weatherCode.indices.contains(closest.0) else { return nil }

        let temperature = Int(forecast.hourly.temperature[closest.0].rounded())
        let rain = forecast.hourly.precipitation[closest.0]
        let condition = conditionName(code: forecast.hourly.weatherCode[closest.0])
        var result = "예보는 \(condition), 기온 \(temperature)도, 비 올 확률 \(rain)%입니다."
        if rain >= 40 { result += " 우산을 챙기시는 게 좋겠습니다." }
        return result
    }

    private func forecastLocation(named rawName: String) async throws -> CLLocation {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let geocoder = CLGeocoder()
            let placemarks = try await withTaskCancellationHandler {
                try await geocoder.geocodeAddressString(name)
            } onCancel: {
                Task { @MainActor in geocoder.cancelGeocode() }
            }
            guard placemarks.count == 1, let location = placemarks.first?.location else {
                throw BriefingError.locationUnavailable
            }
            return location
        }
        return try await locationProvider.currentLocation()
    }

    private func conditionName(code: Int) -> String {
        switch code {
        case 0: "맑음"
        case 1...3: "구름이 조금 있음"
        case 45, 48: "안개"
        case 51...67, 80...82: "비"
        case 71...77, 85, 86: "눈"
        case 95...99: "천둥번개"
        default: "변동 가능"
        }
    }
}
