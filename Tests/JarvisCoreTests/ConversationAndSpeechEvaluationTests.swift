import XCTest
@testable import JarvisCore

final class ConversationAndSpeechEvaluationTests: XCTestCase {
    func testGeneralConversationCorpusIsSeparateAndDeterministic() {
        let cases = ConversationEvaluationCorpus.standard
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        let report = ConversationEvaluationRunner().run(cases)
        XCTAssertEqual(report.failureIDs, [], "Failed: \(report.failureIDs)")
        XCTAssertEqual(report.total, cases.count)
    }

    func testSpeechFilterAllowsOnlyFixedReadOnlyCommands() {
        let filter = SpeechEvaluationPrivacyFilter()
        XCTAssertEqual(filter.candidate(from: "오늘 날씨 알려줘", intent: .weather(.todaySummary)), "오늘 날씨 알려줘")
        XCTAssertNil(filter.candidate(from: "민혁이한테 전화해", intent: .call(recipient: "민혁", speakerRequested: false)))
        XCTAssertNil(filter.candidate(from: "내 주소 오늘 날씨 알려줘", intent: .weather(.todaySummary)))
        XCTAssertNil(filter.candidate(from: "서울역까지 안내해줘", intent: .navigate(destination: "서울역", mode: nil)))
        XCTAssertNil(filter.candidate(from: "01012341234 오늘 날씨 알려줘", intent: .weather(.todaySummary)))
    }

    func testApprovedSpeechSamplesHaveIndependentRouterRegressionResult() {
        let expected = String(describing: AssistantIntent.weather(.todaySummary))
        let good = ApprovedSpeechEvaluationCase(input: "오늘 날씨 알려줘", expectedIntentDescription: expected)
        let mismatch = ApprovedSpeechEvaluationCase(input: "지금 몇 시야?", expectedIntentDescription: expected)
        let report = ApprovedSpeechEvaluationRunner().run([good, mismatch])
        XCTAssertEqual(report.total, 2)
        XCTAssertEqual(report.passed, 1)
        XCTAssertEqual(report.failedIDs, [mismatch.id])
    }
}
