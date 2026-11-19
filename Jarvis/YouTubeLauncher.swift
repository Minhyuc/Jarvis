import Foundation
import Security
import UIKit

enum YouTubeDestination: Equatable, Sendable {
    case video(URL)
    case playlist(URL)
    case search(URL)

    var opensVideoDirectly: Bool {
        if case .video = self { return true }
        return false
    }

    var url: URL {
        switch self {
        case .video(let url), .playlist(let url), .search(let url): return url
        }
    }
}

enum YouTubeAPIKeyStore {
    private static let service = "com.minhyuc.jarvis.youtube"
    private static let account = "youtube-data-api-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete()
        }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var item = lookup
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

@MainActor
struct YouTubeLauncher {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct Identifier: Decodable {
                let videoId: String?
            }

            let id: Identifier
        }

        let items: [Item]
    }

    private struct PlaylistItemsResponse: Decodable {
        struct Item: Decodable {
            struct ContentDetails: Decodable {
                let videoId: String
            }

            let contentDetails: ContentDetails
        }

        let items: [Item]
    }

    func resolveDestination(query: String) async -> YouTubeDestination? {
        guard let fallbackURL = YouTubeURLBuilder().searchURL(for: query) else { return nil }
        let apiKey = YouTubeAPIKeyStore.load()
        guard !apiKey.isEmpty else { return .search(fallbackURL) }

        do {
            guard let videoID = try await firstVideoID(query: query, apiKey: apiKey),
                  var components = URLComponents(string: "https://www.youtube.com/watch") else {
                return .search(fallbackURL)
            }
            components.queryItems = [
                URLQueryItem(name: "v", value: videoID),
                URLQueryItem(name: "autoplay", value: "1")
            ]
            guard let videoURL = components.url else { return .search(fallbackURL) }
            return .video(videoURL)
        } catch {
            return .search(fallbackURL)
        }
    }

    func resolvePlaylistDestination(named name: String) async -> YouTubeDestination? {
        if let ownedPlaylist = YouTubeOwnedPlaylistStore.playlist(named: name),
           let playlistURL = ownedPlaylist.url {
            do {
                let accessToken = try await YouTubeAccountService.shared.freshAccessToken()
                if let videoID = try await firstPlaylistVideoID(
                    playlistID: ownedPlaylist.id,
                    accessToken: accessToken
                ), var components = URLComponents(string: "https://www.youtube.com/watch") {
                    components.queryItems = [
                        URLQueryItem(name: "v", value: videoID),
                        URLQueryItem(name: "list", value: ownedPlaylist.id),
                        URLQueryItem(name: "autoplay", value: "1")
                    ]
                    if let url = components.url { return .playlist(url) }
                }
            } catch {
                return .playlist(playlistURL)
            }
            return .playlist(playlistURL)
        }

        return nil
    }

    func open(_ destination: YouTubeDestination) async -> ToolExecutionResult<Void> {
        if await UIApplication.shared.open(destination.url) {
            return .handedOff(())
        }
        return .failed(message: "YouTube를 열지 못했습니다.", retryable: true)
    }

    private func firstVideoID(query: String, apiKey: String) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "order", value: "relevance"),
            URLQueryItem(name: "relevanceLanguage", value: "ko"),
            URLQueryItem(name: "regionCode", value: "KR"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        return try JSONDecoder()
            .decode(SearchResponse.self, from: data)
            .items
            .first?
            .id
            .videoId
    }

    private func firstPlaylistVideoID(playlistID: String, accessToken: String) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails"),
            URLQueryItem(name: "playlistId", value: playlistID),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        return try JSONDecoder()
            .decode(PlaylistItemsResponse.self, from: data)
            .items
            .first?
            .contentDetails
            .videoId
    }
}
