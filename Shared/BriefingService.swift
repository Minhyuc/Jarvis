import CoreLocation
import Foundation

enum BriefingError: LocalizedError {
    case locationServicesUnavailable
    case locationPermissionDenied
    case locationUnavailable

    var errorDescription: String? {
        switch self {
        case .locationServicesUnavailable:
            return "위치 서비스를 사용할 수 없습니다."
        case .locationPermissionDenied:
            return "현재 위치 기능을 사용하려면 위치 권한이 필요합니다."
        case .locationUnavailable:
            return "현재 위치를 확인하지 못했습니다."
        }
    }
}

@MainActor
final class CurrentLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var requestID: UUID?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw BriefingError.locationServicesUnavailable
        }
        guard continuation == nil else {
            throw BriefingError.locationUnavailable
        }

        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.requestID = token
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled, self?.requestID == token else { return }
                    self?.finish(with: .failure(BriefingError.locationUnavailable))
                }
                switch manager.authorizationStatus {
                case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
                case .notDetermined: manager.requestWhenInUseAuthorization()
                case .denied, .restricted: finish(with: .failure(BriefingError.locationPermissionDenied))
                @unknown default: finish(with: .failure(BriefingError.locationUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.requestID == token else { return }
                self.finish(with: .failure(CancellationError()))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: .failure(BriefingError.locationPermissionDenied))
        case .notDetermined:
            break
        @unknown default:
            finish(with: .failure(BriefingError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(with: .failure(BriefingError.locationUnavailable))
            return
        }
        finish(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(error))
    }

    private func finish(with result: Result<CLLocation, Error>) {
        let pending = continuation
        continuation = nil
        requestID = nil
        timeoutTask?.cancel(); timeoutTask = nil
        manager.stopUpdatingLocation()
        pending?.resume(with: result)
    }
}

@MainActor
final class BriefingService {
    private struct WeatherResponse: Decodable {
        struct Current: Decodable {
            let temperature: Double

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
            }
        }

        struct Daily: Decodable {
            let time: [String]
            let highTemperatures: [Double?]
            let lowTemperatures: [Double?]
            let precipitationProbabilities: [Int?]

            enum CodingKeys: String, CodingKey {
                case time
                case highTemperatures = "temperature_2m_max"
                case lowTemperatures = "temperature_2m_min"
                case precipitationProbabilities = "precipitation_probability_max"
            }
        }

        let current: Current
        let daily: Daily
    }

    struct WeatherSnapshot {
        let currentTemperature: Double
        let highTemperature: Double
        let lowTemperature: Double
        let precipitationProbability: Int
    }

    /// Explicit synthetic inputs for practice. A missing mock weather value
    /// means a simulated failure, never permission to fall back to networking.
    struct Simulation {
        let weather: WeatherSnapshot?
        let events: [JarvisCalendarEvent]
    }
    private let simulation: Simulation?
    init(simulation: Simulation? = nil) { self.simulation = simulation }

    private let locationProvider = CurrentLocationProvider()
    private var calendarStore: JarvisCalendarStore { .shared }
    private(set) var latestWeatherAdviceFacts: WeatherAdviceFacts?

    func makeFullBriefing(now: Date = Date()) async -> String {
        var lines = [
            "좋은 \(timePeriod(for: now))입니다.",
            "현재 시각은 \(clockFormatter.string(from: now))입니다."
        ]

        do {
            let weather = try await loadWeatherSnapshot()
            lines.append("현재 기온은 \(degrees(weather.currentTemperature))도입니다.")
            lines.append(
                "오늘 최고 기온은 \(degrees(weather.highTemperature))도, "
                    + "최저 기온은 \(degrees(weather.lowTemperature))도입니다."
            )
            lines.append(precipitationSentence(for: weather.precipitationProbability))
            if weather.precipitationProbability >= 40 {
                lines.append("우산을 챙기시는 게 좋겠습니다.")
            }
        } catch {
            lines.append(weatherFailureMessage(for: error))
        }

        lines.append(await makeTodayScheduleResponse(now: now))
        lines.append("이상입니다.")
        return lines.joined(separator: "\n")
    }

    func makeWeatherSummary() async -> String {
        do {
            let weather = try await loadWeatherSnapshot()
            return [
                "현재 기온은 \(degrees(weather.currentTemperature))도이고, "
                    + "오늘 최고 기온은 \(degrees(weather.highTemperature))도, "
                    + "최저 기온은 \(degrees(weather.lowTemperature))도입니다.",
                precipitationSentence(for: weather.precipitationProbability)
            ].joined(separator: "\n")
        } catch {
            return weatherFailureMessage(for: error)
        }
    }

    func makeCurrentTemperatureResponse() async -> String {
        await weatherResponse { weather in
            "현재 기온은 \(self.degrees(weather.currentTemperature))도입니다."
        }
    }

    func makeHighTemperatureResponse() async -> String {
        await weatherResponse { weather in
            "오늘 최고 기온은 \(self.degrees(weather.highTemperature))도입니다."
        }
    }

    func makeLowTemperatureResponse() async -> String {
        await weatherResponse { weather in
            "오늘 최저 기온은 \(self.degrees(weather.lowTemperature))도입니다."
        }
    }

    func makeTemperatureRangeResponse() async -> String {
        await weatherResponse { weather in
            let difference = self.degrees(weather.highTemperature - weather.lowTemperature)
            return "오늘 최고 기온은 \(self.degrees(weather.highTemperature))도, "
                + "최저 기온은 \(self.degrees(weather.lowTemperature))도로, "
                + "일교차는 \(difference)도입니다."
        }
    }

    func makePrecipitationResponse() async -> String {
        await weatherResponse { weather in
            self.precipitationSentence(for: weather.precipitationProbability)
        }
    }

    func makeUmbrellaAdvice() async -> String {
        await weatherResponse { weather in
            let chance = weather.precipitationProbability
            switch chance {
            case 40...100:
                return "오늘 비가 올 확률은 \(chance)%입니다. 우산을 챙기시는 게 좋겠습니다."
            case 1..<40:
                return "오늘 비가 올 확률은 \(chance)%입니다. 필요하다면 작은 우산을 준비하세요."
            default:
                return "오늘 비 소식은 없습니다. 우산은 챙기지 않으셔도 되겠습니다."
            }
        }
    }

    /// Typed boundary for the assistant executor. A permission or transport
    /// failure must not be wrapped as a verified successful weather answer.
    func weatherResult(for request: WeatherRequest) async -> ToolExecutionResult<String> {
        do {
            let weather = try await loadWeatherSnapshot()
            let message: String
            switch request {
            case .todaySummary:
                message = "현재 기온은 \(degrees(weather.currentTemperature))도이고, 오늘 최고 기온은 \(degrees(weather.highTemperature))도, 최저 기온은 \(degrees(weather.lowTemperature))도입니다.\n"
                    + precipitationSentence(for: weather.precipitationProbability)
            case .currentTemperature:
                message = "현재 기온은 \(degrees(weather.currentTemperature))도입니다."
            case .highTemperature:
                message = "오늘 최고 기온은 \(degrees(weather.highTemperature))도입니다."
            case .lowTemperature:
                message = "오늘 최저 기온은 \(degrees(weather.lowTemperature))도입니다."
            case .temperatureRange:
                message = "오늘 최고 기온은 \(degrees(weather.highTemperature))도, 최저 기온은 \(degrees(weather.lowTemperature))도로, 일교차는 \(degrees(weather.highTemperature - weather.lowTemperature))도입니다."
            case .precipitationProbability:
                message = precipitationSentence(for: weather.precipitationProbability)
            case .umbrellaAdvice:
                let chance = weather.precipitationProbability
                if chance >= 40 {
                    message = "오늘 비가 올 확률은 \(chance)%입니다. 우산을 챙기시는 게 좋겠습니다."
                } else if chance > 0 {
                    message = "오늘 비가 올 확률은 \(chance)%입니다. 필요하다면 작은 우산을 준비하세요."
                } else {
                    message = "오늘 비 소식은 없습니다. 우산은 챙기지 않으셔도 되겠습니다."
                }
            }
            return .succeeded(message)
        } catch let error as BriefingError {
            switch error {
            case .locationPermissionDenied:
                return .needsPermission(message: error.localizedDescription)
            case .locationServicesUnavailable, .locationUnavailable:
                return .failed(message: error.localizedDescription, retryable: false)
            }
        } catch {
            return .failed(message: weatherFailureMessage(for: error), retryable: error is URLError)
        }
    }

    func calendarResult(for request: CalendarRequest, now: Date = Date()) async -> ToolExecutionResult<String> {
        do {
            let today = try await events(on: now)
            let message: String
            switch request {
            case .todaySummary:
                message = scheduleSummary(for: today, emptyMessage: "오늘 예정된 일정은 없습니다.")
            case .remainingToday:
                message = scheduleSummary(for: today.filter { $0.endDate > now }, emptyMessage: "오늘 남은 일정은 없습니다.", prefix: "오늘 남은 일정은")
            case .nextEvent:
                if let event = today.first(where: { $0.endDate > now }) {
                    message = "다음 일정은 \(eventDescription(event))입니다."
                } else {
                    message = "오늘 남은 일정은 없습니다."
                }
            case .eventCount:
                message = today.isEmpty ? "오늘 예정된 일정은 없습니다." : "오늘 예정된 일정은 \(today.count)개입니다."
            }
            return .succeeded(message)
        } catch {
            return .failed(message: calendarFailureMessage(for: error), retryable: false)
        }
    }

    func makeTodayScheduleResponse(now: Date = Date()) async -> String {
        do {
            return scheduleSummary(for: try await events(on: now), emptyMessage: "오늘 예정된 일정은 없습니다.")
        } catch {
            return calendarFailureMessage(for: error)
        }
    }

    func makeRemainingScheduleResponse(now: Date = Date()) async -> String {
        do {
            let remaining = try await events(on: now).filter { $0.endDate > now }
            return scheduleSummary(for: remaining, emptyMessage: "오늘 남은 일정은 없습니다.", prefix: "오늘 남은 일정은")
        } catch {
            return calendarFailureMessage(for: error)
        }
    }

    func makeNextEventResponse(now: Date = Date()) async -> String {
        do {
            guard let event = try await events(on: now).first(where: { $0.endDate > now }) else {
                return "오늘 남은 일정은 없습니다."
            }
            return "다음 일정은 \(eventDescription(event))입니다."
        } catch {
            return calendarFailureMessage(for: error)
        }
    }

    func makeEventCountResponse(now: Date = Date()) async -> String {
        do {
            let count = try await events(on: now).count
            return count == 0
                ? "오늘 예정된 일정은 없습니다."
                : "오늘 예정된 일정은 \(count)개입니다."
        } catch {
            return calendarFailureMessage(for: error)
        }
    }

    func makeCurrentTimeResponse(now: Date = Date()) -> String {
        "현재 시각은 \(clockFormatter.string(from: now))입니다."
    }

    func makeTodayDateResponse(now: Date = Date()) -> String {
        "오늘은 \(dateFormatter.string(from: now))입니다."
    }

    func makeCurrentDateAndTimeResponse(now: Date = Date()) -> String {
        "오늘은 \(dateFormatter.string(from: now))이고, 현재 시각은 \(clockFormatter.string(from: now))입니다."
    }

    private func weatherResponse(
        _ makeResponse: (WeatherSnapshot) -> String
    ) async -> String {
        do {
            return makeResponse(try await loadWeatherSnapshot())
        } catch {
            return weatherFailureMessage(for: error)
        }
    }

    private func loadWeatherSnapshot() async throws -> WeatherSnapshot {
        latestWeatherAdviceFacts = nil
        if let simulation {
            guard let weather = simulation.weather else { throw URLError(.notConnectedToInternet) }
            return weather
        }
        let location = try await locationProvider.currentLocation()
        let response = try await fetchWeather(at: location)
        // past_days adds yesterday at index 0; select by local forecast date,
        // never accidentally describe yesterday's weather as today's.
        let today = DateFormatter()
        today.calendar = Calendar(identifier: .gregorian)
        today.locale = Locale(identifier: "en_US_POSIX")
        today.timeZone = .current; today.dateFormat = "yyyy-MM-dd"
        guard let index = response.daily.time.firstIndex(of: today.string(from: Date())),
              response.daily.highTemperatures.indices.contains(index),
              response.daily.lowTemperatures.indices.contains(index),
              response.daily.precipitationProbabilities.indices.contains(index),
              let high = response.daily.highTemperatures[index],
              let low = response.daily.lowTemperatures[index],
              let precipitation = response.daily.precipitationProbabilities[index],
              high >= low, (-80...65).contains(high), (-90...65).contains(low),
              (-90...65).contains(response.current.temperature), (0...100).contains(precipitation) else {
            throw URLError(.cannotParseResponse)
        }
        latestWeatherAdviceFacts = .init(high: high, low: low, rainProbability: precipitation,
            yesterdayHigh: index > 0 ? response.daily.highTemperatures[index - 1] : nil)
        return WeatherSnapshot(
            currentTemperature: response.current.temperature,
            highTemperature: high,
            lowTemperature: low,
            precipitationProbability: max(0, min(100, precipitation))
        )
    }

    private func fetchWeather(at location: CLLocation) async throws -> WeatherResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(
                name: "daily",
                value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "past_days", value: "1")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(WeatherResponse.self, from: data)
    }

    private func events(on date: Date) async throws -> [JarvisCalendarEvent] {
        if let simulation { return simulation.events }
        return calendarStore.events(on: date)
    }

    private func scheduleSummary(
        for events: [JarvisCalendarEvent],
        emptyMessage: String,
        prefix: String = "오늘 일정은"
    ) -> String {
        guard !events.isEmpty else { return emptyMessage }
        return "\(prefix) \(events.map(eventDescription).joined(separator: ", "))입니다."
    }

    private func eventDescription(_ event: JarvisCalendarEvent) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeTitle = title.isEmpty ? "제목 없는 일정" : title
        return event.isAllDay
            ? "하루 종일 \(safeTitle)"
            : "\(eventTimeFormatter.string(from: event.startDate)) \(safeTitle)"
    }

    private func precipitationSentence(for chance: Int) -> String {
        chance == 0
            ? "오늘 비 소식은 없습니다."
            : "오늘 비가 올 확률은 \(chance)%입니다."
    }

    private func weatherFailureMessage(for error: Error) -> String {
        if let briefingError = error as? BriefingError {
            return briefingError.localizedDescription
        }
        return "날씨 정보를 확인하지 못했습니다."
    }

    private func calendarFailureMessage(for error: Error) -> String {
        "JARVIS 캘린더 오류로 일정을 확인하지 못했습니다."
    }

    private func timePeriod(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<12: return "아침"
        case 12..<18: return "오후"
        default: return "저녁"
        }
    }

    private func degrees(_ value: Double) -> Int {
        Int(value.rounded())
    }

    private var clockFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH시 mm분"
        return formatter
    }

    private var eventTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h시 mm분"
        return formatter
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 EEEE"
        return formatter
    }
}
