import XCTest
@testable import JarvisCore

final class AlarmTimeResolverTests: XCTestCase {
    private let resolver = AlarmTimeResolver()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    func testTenAMTwoOClockResolvesToTodayTwoPM() throws {
        let now = date(2026, 9, 30, 10, 0)
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 0, period: nil, day: .automatic),
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 9, 30, 14, 0))
    }

    func testOnePMTwoOClockResolvesToTodayTwoPM() throws {
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 0, period: nil, day: .automatic),
            now: date(2026, 9, 30, 13, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 9, 30, 14, 0))
    }

    func testThreePMTwoOClockResolvesToTomorrowTwoAM() throws {
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 0, period: nil, day: .automatic),
            now: date(2026, 9, 30, 15, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 10, 1, 2, 0))
    }

    func testElevenPMSevenOClockResolvesToTomorrowSevenAM() throws {
        let result = try resolver.resolve(
            .atTime(hour: 7, minute: 0, period: nil, day: .automatic),
            now: date(2026, 9, 30, 23, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 10, 1, 7, 0))
    }

    func testExplicitTomorrowAfternoonWins() throws {
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 0, period: .pm, day: .tomorrow),
            now: date(2026, 9, 30, 23, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 10, 1, 14, 0))
    }

    func testExplicitMorningTwoUsesNearestFutureMorning() throws {
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 0, period: .am, day: .automatic),
            now: date(2026, 9, 30, 3, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 10, 1, 2, 0))
    }

    func testHalfPastTimeKeepsThirtyMinutes() throws {
        let result = try resolver.resolve(
            .atTime(hour: 2, minute: 30, period: nil, day: .automatic),
            now: date(2026, 9, 30, 13, 0),
            calendar: calendar
        )
        XCTAssertEqual(result, date(2026, 9, 30, 14, 30))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
