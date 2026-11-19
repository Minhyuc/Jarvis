import XCTest
@testable import JarvisCore

final class NavigationDestinationNormalizerTests: XCTestCase {
    private let normalizer = NavigationDestinationNormalizer()

    func testRemovesDuplicatedStationSuffix() {
        XCTAssertEqual(normalizer.normalize("강남역 역"), "강남역")
        XCTAssertEqual(normalizer.normalize("강남역역"), "강남역")
    }

    func testRemovesFullNavigationRequestArtifacts() {
        XCTAssertEqual(normalizer.normalize("강남역으로 안내 부탁해"), "강남역")
        XCTAssertEqual(
            normalizer.normalize("현재 위치에서 광화문까지 대중교통으로 길 안내해줘"),
            "광화문"
        )
    }

    func testKeepsValidPlaceTypeSuffix() {
        XCTAssertEqual(normalizer.normalize("서울역"), "서울역")
        XCTAssertEqual(normalizer.normalize("서울대학교"), "서울대학교")
        XCTAssertEqual(normalizer.normalize("인천공항"), "인천공항")
    }

    func testRemovesOtherDuplicatedPlaceTypesAndNames() {
        XCTAssertEqual(normalizer.normalize("서울 고속버스터미널 터미널"), "서울 고속버스터미널")
        XCTAssertEqual(normalizer.normalize("광화문 광화문"), "광화문")
    }

    func testBuildsSpokenAndCompactSearchQueries() {
        XCTAssertEqual(
            normalizer.searchQueries(for: "하이디 라오까지 안내해줘"),
            ["하이디 라오", "하이디라오"]
        )
        XCTAssertEqual(
            normalizer.searchQueries(for: "강남역"),
            ["강남역", "강남역 지하철역", "강남역 전철역"]
        )
        XCTAssertEqual(
            normalizer.searchQueries(for: "인천공항"),
            ["인천공항", "인천공항 국제공항"]
        )
        XCTAssertEqual(
            normalizer.searchQueries(for: "서울 고속버스터미널"),
            [
                "서울 고속버스터미널", "서울고속버스터미널",
                "서울 고속버스터미널 버스터미널",
                "서울 고속버스터미널 고속버스터미널"
            ]
        )
    }

    func testRejectsUnrelatedMapResultAndAllowsOneSpeechSyllableError() {
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "하이디 라오", candidate: "하이디라오 강남점"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "하이디 라우", candidate: "하이디라오 명동점"))
        XCTAssertFalse(normalizer.isPlausibleMatch(query: "하이디 라오", candidate: "라마다 하이즈 호텔"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "강남역", candidate: "강남"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "강남역", candidate: "2호선 강남"))
        XCTAssertFalse(normalizer.isPlausibleMatch(query: "강남역", candidate: "강남구청"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "서울대학교", candidate: "서울대"))
        XCTAssertFalse(normalizer.isPlausibleMatch(query: "서울대학교", candidate: "서울대입구역"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "삼성병원", candidate: "삼성의료원"))
        XCTAssertTrue(normalizer.isPlausibleMatch(query: "서울터미널", candidate: "서울고속버스터미널"))
        XCTAssertFalse(normalizer.isPlausibleMatch(query: "서울터미널", candidate: "서울시장"))
    }
}
