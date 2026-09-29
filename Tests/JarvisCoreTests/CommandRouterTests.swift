import XCTest
@testable import JarvisCore

final class CommandRouterTests: XCTestCase {
    private let router = CommandRouter()

    func testRoutesYouTubeCommand() {
        XCTAssertEqual(
            router.route("자비스야 유튜브에서 아이유 밤편지 틀어줘"),
            .playYouTube(query: "아이유 밤편지")
        )
    }

    func testRoutesUnknownTextToConversation() {
        XCTAssertEqual(
            router.route("오늘 뭐 하고 싶어?"),
            .generalConversation(text: "오늘 뭐 하고 싶어?")
        )
    }

    func testDetectsSpacedWakeWord() {
        XCTAssertTrue(router.containsWakeWord("자 비스야"))
    }

    func testDoesNotDetectUnrelatedText() {
        XCTAssertFalse(router.containsWakeWord("지금 몇 시야"))
    }
}
