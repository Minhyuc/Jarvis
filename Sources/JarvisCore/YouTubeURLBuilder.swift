import Foundation

public struct YouTubeURLBuilder: Sendable {
    public init() {}

    public func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url
    }
}
