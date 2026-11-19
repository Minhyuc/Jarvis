import XCTest
@testable import JarvisCore

final class AssistantContextManagerTests: XCTestCase {
    func testSelectsRelevantAndRecentLongTermMemoriesWithinLimit() {
        var manager = AssistantContextManager(maximumLongTermMemories: 3)
        manager.record(
            userText: "아이폰 배터리에 대해 알려줘",
            assistantResponse: "배터리 정보입니다.",
            intent: .generalConversation(text: "아이폰 배터리")
        )

        let context = manager.context(
            for: "배터리 관리 방법 알려줘",
            longTermMemories: [
                "나는 매운 음식을 좋아한다",
                "내 아이폰 배터리 성능은 85퍼센트다",
                "나는 부산에 산다",
                "나는 음악을 자주 듣는다",
                "내일 친구와 약속이 있다"
            ]
        )

        XCTAssertEqual(context.longTermMemories.count, 3)
        XCTAssertTrue(context.longTermMemories.contains { $0.contains("배터리") })
        XCTAssertEqual(context.recentTurns.count, 1)
    }

    func testRecordPreservesLatestIntentAndMemorySuggestion() {
        var manager = AssistantContextManager()
        XCTAssertNil(manager.record(
            userText: "나는 매운 음식을 좋아해",
            assistantResponse: "알겠습니다.",
            intent: .generalConversation(text: "나는 매운 음식을 좋아해")
        ))
        let suggestion = manager.record(
            userText: "내가 매운 음식을 좋아한다고 했지",
            assistantResponse: "네.",
            intent: .generalConversation(text: "내가 매운 음식을 좋아한다고 했지")
        )

        XCTAssertEqual(manager.latestIntent, .generalConversation(text: "내가 매운 음식을 좋아한다고 했지"))
        XCTAssertEqual(suggestion?.content, "나는 매운 음식을 좋아해")
    }

    func testSelfContainedCommandDoesNotAnchorSemanticResolverToOldTarget() {
        var manager = AssistantContextManager()
        manager.record(
            userText: "강남역까지 대중교통으로 안내해줘",
            assistantResponse: "강남역까지 안내하겠습니다.",
            intent: .navigate(destination: "강남역", mode: .publicTransit)
        )

        let context = manager.context(
            for: "하이디 라우까지 자가용으로 안내해줘",
            longTermMemories: []
        )

        XCTAssertEqual(context.recentTurns.count, 1)
        XCTAssertNil(context.semanticResolutionContext.summary)
        XCTAssertTrue(context.semanticResolutionContext.recentUserTexts.isEmpty)
    }

    func testReferentialFollowUpProvidesBoundedSemanticHistory() {
        var manager = AssistantContextManager()
        manager.record(
            userText: "강남역까지 대중교통으로 안내해줘",
            assistantResponse: "강남역까지 안내하겠습니다.",
            intent: .navigate(destination: "강남역", mode: .publicTransit)
        )

        let context = manager.context(
            for: "그곳까지 자가용으로 다시 안내해줘",
            longTermMemories: []
        )

        XCTAssertEqual(
            context.semanticResolutionContext.recentUserTexts,
            ["강남역까지 대중교통으로 안내해줘"]
        )
    }
}
