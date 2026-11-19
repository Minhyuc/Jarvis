import XCTest
@testable import JarvisCore

final class ConversationMemoryTests: XCTestCase {
    func testKeepsRecentTurnsWithinLimitAndSummarizesEvictedTurns() {
        var memory = ConversationMemory(maximumRecentTurns: 4, maximumSummaryItems: 2)
        for index in 1...6 {
            memory.record(
                userText: "질문 \(index)",
                assistantResponse: "답변 \(index)",
                intent: .generalConversation(text: "질문 \(index)")
            )
        }

        let snapshot = memory.snapshot(for: "이어서 알려줘")
        XCTAssertEqual(memory.recentTurnCount, 4)
        XCTAssertEqual(snapshot.turns.map(\.userText), ["질문 3", "질문 4", "질문 5", "질문 6"])
        XCTAssertTrue(snapshot.summary?.contains("질문 1") == true)
        XCTAssertTrue(snapshot.summary?.contains("질문 2") == true)
    }

    func testPronounFollowUpIncludesUpToEightRecentTurns() {
        var memory = ConversationMemory(maximumRecentTurns: 12)
        for index in 1...10 {
            memory.record(
                userText: "주제 \(index)",
                assistantResponse: "응답 \(index)",
                intent: .generalConversation(text: "주제 \(index)")
            )
        }

        let snapshot = memory.snapshot(for: "그거 더 자세히 알려줘")
        XCTAssertEqual(snapshot.turns.count, 8)
        XCTAssertEqual(snapshot.turns.first?.userText, "주제 3")
        XCTAssertEqual(snapshot.turns.last?.userText, "주제 10")
    }

    func testTopicQuestionKeepsRelevantOlderTurnAndLatestFour() {
        var memory = ConversationMemory(maximumRecentTurns: 12)
        memory.record(
            userText: "아이폰 배터리를 알려줘",
            assistantResponse: "아이폰 배터리 정보입니다.",
            intent: .webSearch(query: "아이폰 배터리")
        )
        for index in 1...7 {
            memory.record(
                userText: "다른 주제 \(index)",
                assistantResponse: "다른 답변 \(index)",
                intent: .generalConversation(text: "다른 주제 \(index)")
            )
        }

        let snapshot = memory.snapshot(for: "아이폰 배터리는 왜 줄어들어?")
        XCTAssertTrue(snapshot.turns.contains { $0.userText.contains("아이폰 배터리") })
        XCTAssertTrue(snapshot.turns.contains { $0.userText == "다른 주제 7" })
    }

    func testResetClearsRecentTurnsAndSummary() {
        var memory = ConversationMemory(maximumRecentTurns: 4)
        for index in 1...5 {
            memory.record(
                userText: "질문 \(index)",
                assistantResponse: "답변 \(index)",
                intent: .generalConversation(text: "질문 \(index)")
            )
        }
        memory.reset()

        let snapshot = memory.snapshot(for: "뭐야?")
        XCTAssertEqual(memory.recentTurnCount, 0)
        XCTAssertNil(snapshot.summary)
        XCTAssertTrue(snapshot.turns.isEmpty)
    }

    func testSuggestsRepeatedPersonalFactOnlyAfterSecondMention() {
        var memory = ConversationMemory()
        let first = memory.record(
            userText: "나는 매운 음식을 좋아해",
            assistantResponse: "알겠습니다.",
            intent: .generalConversation(text: "나는 매운 음식을 좋아해")
        )
        let second = memory.record(
            userText: "내가 매운 음식을 좋아한다고 말했지",
            assistantResponse: "네, 그렇게 말씀하셨어요.",
            intent: .generalConversation(text: "내가 매운 음식을 좋아한다고 말했지")
        )

        XCTAssertNil(first)
        XCTAssertEqual(second?.content, "나는 매운 음식을 좋아해")
    }

    func testDoesNotSuggestToolCommandsOrUnrelatedPersonalFacts() {
        var memory = ConversationMemory()
        XCTAssertNil(memory.record(
            userText: "내 위치에서 맛집 추천해줘",
            assistantResponse: "맛집을 추천합니다.",
            intent: .recommendRestaurants(query: nil)
        ))
        XCTAssertNil(memory.record(
            userText: "저는 커피를 좋아해요",
            assistantResponse: "그렇군요.",
            intent: .generalConversation(text: "저는 커피를 좋아해요")
        ))
    }
}
