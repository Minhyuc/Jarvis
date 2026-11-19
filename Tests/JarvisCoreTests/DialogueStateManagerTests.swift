import XCTest
@testable import JarvisCore

final class DialogueStateManagerTests: XCTestCase {
    func testDialogueInputResolverKeepsAnswerButReplacesWithCompleteNewCommand() {
        let resolver = DialogueInputResolver()

        XCTAssertEqual(resolver.classify("두 번째"), .answer)
        XCTAssertEqual(resolver.classify("네"), .answer)
        XCTAssertEqual(resolver.classify("오늘 날씨 알려줘"), .replace(with: .weather(.todaySummary)))
        XCTAssertEqual(resolver.classify("아니야 됐어"), .cancel)
    }

    func testDialogueInputResolverDoesNotReusePreviousDestination() {
        let resolver = DialogueInputResolver()

        XCTAssertEqual(resolver.classify("자가용으로"), .answer)
        XCTAssertEqual(
            resolver.classify("서울역까지 자가용으로 안내해줘"),
            .replace(with: .navigate(destination: "서울역", mode: .car))
        )
    }

    func testNewTaskReplacesPreviousTask() {
        var manager = DialogueStateManager()
        manager.begin(.memorySuggestion("매운 음식을 좋아한다"))
        manager.begin(.navigationMode(.init(destination: "강남역", originalText: "강남역 안내")))

        XCTAssertEqual(
            manager.current()?.task,
            .navigationMode(.init(destination: "강남역", originalText: "강남역 안내"))
        )
    }

    func testExpiredTaskIsDiscarded() {
        var manager = DialogueStateManager(timeout: 30)
        let start = Date(timeIntervalSince1970: 100)
        manager.begin(.memorySuggestion("기억"), now: start)

        XCTAssertNil(manager.current(now: start.addingTimeInterval(31)))
        XCTAssertFalse(manager.hasPendingTask)
    }

    func testRetryLimitClearsTask() {
        var manager = DialogueStateManager(maximumRetries: 1)
        manager.begin(.memorySuggestion("기억"))

        XCTAssertNotNil(manager.registerRetry())
        XCTAssertNil(manager.registerRetry())
        XCTAssertFalse(manager.hasPendingTask)
    }

    func testCompleteReturnsAndClearsTask() {
        var manager = DialogueStateManager()
        manager.begin(.memorySuggestion("기억"))

        XCTAssertNotNil(manager.complete())
        XCTAssertNil(manager.current())
    }

    func testNavigationDestinationSelectionKeepsOnlyCurrentCandidateSet() {
        var manager = DialogueStateManager()
        let first = NavigationDestinationCandidate(
            name: "하이디라오 강남점",
            area: "서울특별시 강남구",
            latitude: 37.5,
            longitude: 127.0,
            sourceLatitude: 37.4,
            sourceLongitude: 127.1,
            straightLineDistance: 1_000
        )
        let second = NavigationDestinationCandidate(
            name: "하이디라오 대학로점",
            area: "서울특별시 종로구",
            latitude: 37.6,
            longitude: 127.0,
            sourceLatitude: 37.4,
            sourceLongitude: 127.1,
            straightLineDistance: 2_000
        )
        let task = PendingDialogueTask.navigationDestinationSelection(.init(
            query: "하이디라오",
            originalText: "하이디라오까지 안내해줘",
            mode: .car,
            candidates: [first, second]
        ))

        manager.begin(task)

        XCTAssertEqual(manager.current()?.task, task)
    }

    func testNavigationDestinationSelectionResolvesNumberNameAndUniqueArea() {
        let candidates = [
            NavigationDestinationCandidate(
                name: "하이디라오 강남점",
                area: "서울특별시 강남구",
                latitude: 37.5,
                longitude: 127.0,
                sourceLatitude: 37.4,
                sourceLongitude: 127.1,
                straightLineDistance: 1_000
            ),
            NavigationDestinationCandidate(
                name: "하이디라오 대학로점",
                area: "서울특별시 종로구",
                latitude: 37.6,
                longitude: 127.0,
                sourceLatitude: 37.4,
                sourceLongitude: 127.1,
                straightLineDistance: 2_000
            )
        ]
        let resolver = NavigationDestinationSelectionResolver()

        XCTAssertEqual(resolver.resolve("2번", candidates: candidates), candidates[1])
        XCTAssertEqual(resolver.resolve("강남점", candidates: candidates), candidates[0])
        XCTAssertEqual(resolver.resolve("아니 대학로점", candidates: candidates), candidates[1])
        XCTAssertEqual(resolver.resolve("종로구", candidates: candidates), candidates[1])
        XCTAssertNil(resolver.resolve("서울특별시", candidates: candidates))
        XCTAssertEqual(resolver.resolve("2번으로 안내해줘", candidates: candidates), candidates[1])
        XCTAssertNil(resolver.resolve("2호선 강남역으로 안내해줘", candidates: candidates))
        XCTAssertNil(resolver.resolve("강남구청까지 자가용으로 안내해줘", candidates: candidates))
        XCTAssertNil(resolver.resolve("2번 말고 1번", candidates: candidates))
        XCTAssertNil(resolver.resolve("오늘 날씨 알려줘", candidates: candidates))
    }
}
