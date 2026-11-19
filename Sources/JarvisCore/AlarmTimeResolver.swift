import Foundation

public enum AlarmTimeResolverError: LocalizedError, Equatable {
    case invalidTime
    case requestedTodayTimeHasPassed

    public var errorDescription: String? {
        switch self {
        case .invalidTime:
            return "알람 시간을 확인하지 못했습니다."
        case .requestedTodayTimeHasPassed:
            return "오늘의 해당 시각은 이미 지났습니다. 다른 시각을 말씀해주세요."
        }
    }
}

public struct AlarmTimeResolver: Sendable {
    public init() {}

    public func resolve(
        _ request: AlarmRequest,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) throws -> Date {
        var calendar = inputCalendar
        calendar.timeZone = inputCalendar.timeZone

        switch request {
        case .afterMinutes(let minutes):
            guard minutes > 0,
                  let date = calendar.date(byAdding: .minute, value: minutes, to: now) else {
                throw AlarmTimeResolverError.invalidTime
            }
            return date

        case .atTime(let hour, let minute, let period, let day):
            guard (1...12).contains(hour), (0...59).contains(minute) else {
                throw AlarmTimeResolverError.invalidTime
            }

            let dayOffset = day == .tomorrow ? 1 : 0
            guard let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
                throw AlarmTimeResolverError.invalidTime
            }

            if let period {
                let resolvedHour = twentyFourHour(hour: hour, period: period)
                guard var candidate = date(
                    on: baseDate,
                    hour: resolvedHour,
                    minute: minute,
                    calendar: calendar
                ) else { throw AlarmTimeResolverError.invalidTime }

                if day == .today, candidate <= now {
                    throw AlarmTimeResolverError.requestedTodayTimeHasPassed
                }
                if day == .automatic, candidate <= now {
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
                return candidate
            }

            let amHour = twentyFourHour(hour: hour, period: .am)
            let pmHour = twentyFourHour(hour: hour, period: .pm)
            let candidates = [amHour, pmHour].compactMap {
                date(on: baseDate, hour: $0, minute: minute, calendar: calendar)
            }

            if day == .today {
                guard let candidate = candidates.filter({ $0 > now }).min() else {
                    throw AlarmTimeResolverError.requestedTodayTimeHasPassed
                }
                return candidate
            }

            if day == .tomorrow {
                guard let candidate = candidates.min() else {
                    throw AlarmTimeResolverError.invalidTime
                }
                return candidate
            }

            let futureCandidates = candidates.map { candidate -> Date in
                guard candidate <= now else { return candidate }
                return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            guard let nearest = futureCandidates.min() else {
                throw AlarmTimeResolverError.invalidTime
            }
            return nearest
        }
    }

    private func twentyFourHour(hour: Int, period: AlarmPeriod) -> Int {
        switch period {
        case .am: return hour == 12 ? 0 : hour
        case .pm: return hour == 12 ? 12 : hour + 12
        }
    }

    private func date(
        on baseDate: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }
}
