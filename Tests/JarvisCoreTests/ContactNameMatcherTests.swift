import XCTest
@testable import JarvisCore

final class ContactNameMatcherTests: XCTestCase {
    private let matcher = ContactNameMatcher()

    func testIgnoresSpacesAndPunctuation() {
        XCTAssertEqual(matcher.normalized("향수 이 여자!"), "향수이여자")
    }

    func testMatchesSameNameWithDifferentSpacing() {
        XCTAssertEqual(
            matcher.similarity(query: "향수 이 여자", candidate: "향수이여자"),
            1
        )
    }

    func testAcceptsOneSyllableRecognitionDifferenceInLongName() {
        let score = matcher.similarity(query: "김민수 대리", candidate: "김민수 리")
        XCTAssertTrue(matcher.isAcceptable(score: score, query: "김민수 대리"))
    }

    func testRejectsWeakTwoSyllableMatch() {
        let score = matcher.similarity(query: "민수", candidate: "영수")
        XCTAssertFalse(matcher.isAcceptable(score: score, query: "민수"))
    }

    func testAcceptsSimilarHangulSpeechRecognitionResult() {
        let score = matcher.similarity(query: "황 소이 어제", candidate: "향수이 여자")
        XCTAssertTrue(matcher.isAcceptable(score: score, query: "황 소이 어제"))
    }
}
