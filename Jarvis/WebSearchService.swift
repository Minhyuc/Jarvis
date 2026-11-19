import Foundation
import Security

struct WebSearchSource: Equatable, Sendable {
    let title: String
    let url: URL
}

struct WebSearchAnswer: Equatable, Sendable {
    let text: String
    let sources: [WebSearchSource]
}

enum WebSearchAPIKeyStore {
    private static let service = "com.minhyuc.jarvis.web-search"
    private static let account = "tavily-api-key"

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
        if trimmed.isEmpty { return delete() }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        if SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }
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

actor WebSearchService {
    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let title: String
            let url: String
            let content: String
        }

        let answer: String?
        let results: [Result]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let error: String?
        }

        let detail: Detail?
    }

    enum SearchError: LocalizedError {
        case missingAPIKey
        case invalidAPIKey
        case quotaExceeded
        case invalidResponse
        case noResults

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "인터넷 검색을 사용하려면 설정에서 Tavily API 키를 등록해주세요."
            case .invalidAPIKey:
                return "Tavily API 키가 올바르지 않습니다. 설정에서 키를 확인해주세요."
            case .quotaExceeded:
                return "인터넷 검색 사용량이 초과되었습니다. Tavily 대시보드에서 사용량을 확인해주세요."
            case .invalidResponse:
                return "인터넷 검색 결과를 불러오지 못했습니다. 잠시 후 다시 시도해주세요."
            case .noResults:
                return "관련된 인터넷 검색 결과를 찾지 못했습니다. 검색어를 바꿔서 말씀해주세요."
            }
        }
    }

    func search(query: String) async throws -> WebSearchAnswer {
        let apiKey = WebSearchAPIKeyStore.load()
        guard !apiKey.isEmpty else { throw SearchError.missingAPIKey }
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw SearchError.invalidResponse
        }

        let body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "max_results": 5,
            "topic": "general",
            "include_answer": "basic",
            "include_raw_content": false,
            "include_images": false,
            "language": "ko",
            "country": "south korea",
            "safe_search": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 401:
            throw SearchError.invalidAPIKey
        case 429, 432, 433:
            throw SearchError.quotaExceeded
        default:
            _ = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw SearchError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        let sources = uniqueSources(from: decoded.results)
        let answer = decoded.answer.map(cleanAnswer)

        if let answer, !answer.isEmpty {
            return WebSearchAnswer(text: answer, sources: sources)
        }

        guard let first = decoded.results.first else { throw SearchError.noResults }
        let fallback = cleanAnswer(first.content)
        guard !fallback.isEmpty else { throw SearchError.noResults }
        return WebSearchAnswer(text: fallback, sources: sources)
    }

    private func cleanAnswer(_ answer: String) -> String {
        answer
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\(https?://[^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"https?://[^\s]+"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueSources(from results: [SearchResponse.Result]) -> [WebSearchSource] {
        var seenURLs = Set<String>()
        return results.compactMap { result in
            guard let url = URL(string: result.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seenURLs.insert(url.absoluteString).inserted else {
                return nil
            }
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return WebSearchSource(
                title: title.isEmpty ? (url.host ?? "출처") : title,
                url: url
            )
        }
    }
}
