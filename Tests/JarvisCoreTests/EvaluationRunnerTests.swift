import XCTest
@testable import JarvisCore

final class EvaluationRunnerTests: XCTestCase {
    func testReportsPassRateAndFailures() {
        let cases = [
            RoutingEvaluationCase(
                name: "시간",
                input: "지금 몇 시야",
                expectedIntent: .time(.currentTime)
            ),
            RoutingEvaluationCase(
                name: "의도적으로 틀린 기대값",
                input: "오늘 날씨 알려줘",
                expectedIntent: .calendar(.todaySummary)
            )
        ]

        let report = EvaluationRunner().run(cases)
        XCTAssertEqual(report.totalCount, 2)
        XCTAssertEqual(report.passedCount, 1)
        XCTAssertEqual(report.passRate, 0.5)
        XCTAssertEqual(report.failures.map(\.caseName), ["의도적으로 틀린 기대값"])
        XCTAssertEqual(report.categoryResults.count, 1)
        XCTAssertFalse(report.passed)
    }

    func testEmptyEvaluationSuitePasses() {
        let report = EvaluationRunner().run([])
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.passRate, 1)
    }

    func testStandardCorpusHasAtLeastThreeHundredCasesAndMeetsBaseline() {
        let cases = CommandEvaluationCorpus.standard
        let report = EvaluationRunner().run(
            cases,
            requiredPassRate: CommandEvaluationCorpus.minimumPassRate
        )

        XCTAssertGreaterThanOrEqual(cases.count, 300)
        XCTAssertTrue(
            report.passed,
            "평가 정확도 \(report.passRate), 실패: \(report.failures.prefix(10))"
        )
    }
}
