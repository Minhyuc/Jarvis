import XCTest
@testable import JarvisCore

final class ConversationalResponseTests: XCTestCase {
    func testClassifiesQuestionTypesAndFreshInformation() {
        let classifier = ConversationQuestionClassifier()

        XCTAssertEqual(classifier.analyze("두 제품의 차이를 비교해줘").type, .comparison)
        XCTAssertEqual(classifier.analyze("왜 그런지 설명해줘").type, .explanation)
        XCTAssertTrue(classifier.analyze("최신 AI 뉴스 알려줘").requiresFreshInformation)
        XCTAssertFalse(classifier.analyze("광합성을 설명해줘").requiresFreshInformation)
    }

    func testSpokenPresentationRemovesLinksAndLimitsSentences() {
        let answer = """
        결론입니다. 첫 번째 근거입니다. 두 번째 근거입니다.
        자세한 내용은 https://example.com 에서 확인할 수 있습니다. 다섯 번째 문장입니다.
        """
        let result = AssistantResponsePresenter().make(answer: answer, for: "요약해줘")

        XCTAssertEqual(result.questionType, .summary)
        XCTAssertFalse(result.spokenText.contains("http"))
        XCTAssertTrue(result.screenText.contains("https://example.com"))
        XCTAssertFalse(result.spokenText.contains("다섯 번째"))
    }

    func testProactiveSuggestionOnlyProposesAnIntent() {
        let suggestion = ProactiveSuggestionEngine().suggestion(
            after: .weather(.todaySummary),
            response: "오늘 비 올 확률은 70%입니다.",
            recentIntentKeys: ["weather"]
        )

        XCTAssertEqual(suggestion?.id, "weather.umbrella")
        XCTAssertEqual(suggestion?.proposedIntent, .weather(.umbrellaAdvice))
    }

    func testRepeatedSuggestionHasNoExecutableAction() {
        let suggestion = ProactiveSuggestionEngine().suggestion(
            after: .time(.currentTime),
            response: "현재 시각은 9시입니다.",
            recentIntentKeys: ["time", "time", "time"]
        )

        XCTAssertEqual(suggestion?.id, "repeat.time")
        XCTAssertNil(suggestion?.proposedIntent)
    }
}
