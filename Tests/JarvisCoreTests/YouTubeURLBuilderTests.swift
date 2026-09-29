import XCTest
@testable import JarvisCore

final class YouTubeURLBuilderTests: XCTestCase {
    func testBuildsEncodedSearchURL() throws {
        let url = try XCTUnwrap(YouTubeURLBuilder().searchURL(for: "아이유 밤편지"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.youtube.com")
        XCTAssertEqual(components.queryItems?.first?.value, "아이유 밤편지")
    }
}
