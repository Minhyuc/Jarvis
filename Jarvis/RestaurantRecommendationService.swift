import CoreLocation
import Foundation
import Security

enum PlacesAPIKeyStore {
    private static let service = "com.minhyuc.jarvis.places"
    private static let account = "google-places-api-key"

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

@MainActor
final class RestaurantRecommendationService {
    private struct SearchResponse: Decodable {
        let places: [Place]?
    }

    private struct Place: Decodable {
        struct LocalizedText: Decodable {
            let text: String
        }

        struct Coordinate: Decodable {
            let latitude: Double
            let longitude: Double
        }

        struct Review: Decodable {
            let text: LocalizedText?
            let originalText: LocalizedText?
        }

        let displayName: LocalizedText
        let rating: Double?
        let userRatingCount: Int?
        let location: Coordinate?
        let businessStatus: String?
        let reviews: [Review]?
    }

    private struct APIErrorResponse: Decodable {
        struct Details: Decodable {
            let message: String?
        }

        let error: Details?
    }

    private enum RecommendationError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiConfiguration(String?)
        case quotaExceeded

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "맛집 추천을 사용하려면 설정에서 Google Places API 키를 먼저 등록해주세요."
            case .invalidResponse:
                return "주변 음식점 정보를 불러오지 못했습니다. 잠시 후 다시 시도해주세요."
            case .apiConfiguration(let message):
                if let message, !message.isEmpty {
                    return "Places API 설정을 확인해주세요. \(message)"
                }
                return "Places API(New) 활성화와 결제 계정, API 키 제한을 확인해주세요."
            case .quotaExceeded:
                return "Places API 사용량이 초과되었습니다. Google Cloud에서 할당량을 확인해주세요."
            }
        }
    }

    private let locationProvider = CurrentLocationProvider()
    private var shownPlaceNames: Set<String> = []
    private var lastQuery: String?

    func makeRecommendation(query: String?, excludingPrevious: Bool = false) async -> String {
        do {
            let apiKey = PlacesAPIKeyStore.load()
            guard !apiKey.isEmpty else { throw RecommendationError.missingAPIKey }

            let currentLocation = try await locationProvider.currentLocation()
            let places = try await search(
                query: query,
                around: currentLocation,
                apiKey: apiKey
            )
            if !excludingPrevious || query != lastQuery {
                shownPlaceNames.removeAll()
            }
            lastQuery = query

            let recommendations = Array(
                rankedPlaces(places, origin: currentLocation)
                    .filter { !shownPlaceNames.contains($0.displayName.text) }
                    .prefix(3)
            )

            guard !recommendations.isEmpty else {
                if excludingPrevious {
                    return "조건에 맞는 다른 음식점을 더 찾지 못했습니다."
                }
                let category = query.map { "\($0) " } ?? ""
                return "현재 위치 주변 5킬로미터 안에서 평가 정보가 있는 \(category)음식점을 찾지 못했습니다."
            }

            shownPlaceNames.formUnion(recommendations.map { $0.displayName.text })
            let lines = recommendations.map { place in
                "\(place.displayName.text) — 대표 메뉴: \(representativeMenu(for: place, requestedQuery: query))"
            }
            return lines.joined(separator: "\n")
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? "주변 음식점을 찾는 중에 문제가 발생했습니다."
        }
    }

    private func search(query: String?, around location: CLLocation, apiKey: String) async throws -> [Place] {
        guard let url = URL(string: "https://places.googleapis.com/v1/places:searchText") else {
            throw RecommendationError.invalidResponse
        }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let textQuery = trimmedQuery.flatMap { $0.isEmpty ? nil : "\($0) 맛집" } ?? "인기 맛집"
        let body: [String: Any] = [
            "textQuery": textQuery,
            "pageSize": 20,
            "includedType": "restaurant",
            "strictTypeFiltering": false,
            "minRating": 3.5,
            "languageCode": "ko",
            "regionCode": "KR",
            "rankPreference": "RELEVANCE",
            "locationBias": [
                "circle": [
                    "center": [
                        "latitude": location.coordinate.latitude,
                        "longitude": location.coordinate.longitude
                    ],
                    "radius": 5_000.0
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.displayName,places.rating,places.userRatingCount,places.location,places.businessStatus,places.reviews",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            request.setValue(bundleIdentifier, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RecommendationError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(SearchResponse.self, from: data).places ?? []
        case 429:
            throw RecommendationError.quotaExceeded
        case 400, 401, 403:
            let details = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw RecommendationError.apiConfiguration(details?.error?.message)
        default:
            throw RecommendationError.invalidResponse
        }
    }

    private func rankedPlaces(_ places: [Place], origin: CLLocation) -> [Place] {
        places
            .filter { place in
                guard place.businessStatus != "CLOSED_PERMANENTLY", place.rating != nil,
                      let coordinate = place.location else { return false }
                let destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                return origin.distance(from: destination) <= 5_000
            }
            .sorted { lhs, rhs in
                let leftScore = qualityScore(for: lhs)
                let rightScore = qualityScore(for: rhs)
                if leftScore != rightScore { return leftScore > rightScore }
                return (lhs.userRatingCount ?? 0) > (rhs.userRatingCount ?? 0)
            }
    }

    private func qualityScore(for place: Place) -> Double {
        let rating = place.rating ?? 0
        let reviews = Double(place.userRatingCount ?? 0)
        let priorRating = 4.0
        let priorWeight = 100.0
        return (reviews * rating + priorWeight * priorRating) / (reviews + priorWeight)
    }

    private func representativeMenu(for place: Place, requestedQuery: String?) -> String {
        let reviewText = (place.reviews ?? []).flatMap { review -> [String] in
            [review.originalText?.text, review.text?.text].compactMap { $0 }
        }
        let corpus = ([place.displayName.text] + reviewText).joined(separator: " ").lowercased()

        let menuCandidates = [
            "소금구이", "양념갈비", "돼지갈비", "소갈비", "삼겹살", "닭갈비", "닭한마리",
            "김치찌개", "된장찌개", "순두부찌개", "부대찌개", "비빔밥", "불고기", "냉면", "감자탕",
            "설렁탕", "갈비탕", "해장국", "국밥", "곱창", "칼국수", "수제비", "떡볶이", "순대", "김밥",
            "모듬초밥", "스시", "초밥", "사시미", "회", "라멘", "우동", "소바", "돈카츠", "돈가스", "텐동",
            "짜장면", "짬뽕", "탕수육", "마라탕", "훠궈", "딤섬", "파스타", "피자", "리조또", "스테이크",
            "햄버거", "샌드위치", "쌀국수", "분짜", "팟타이", "커리", "케밥", "타코", "브런치", "크루아상", "케이크", "커피", "치킨"
        ]
        let mentionedMenus = menuCandidates.compactMap { menu -> (String, Int)? in
            let count = corpus.components(separatedBy: menu.lowercased()).count - 1
            return count > 0 ? (menu, count) : nil
        }
        if let best = mentionedMenus.max(by: { lhs, rhs in
            lhs.1 == rhs.1
                ? menuCandidates.firstIndex(of: lhs.0)! > menuCandidates.firstIndex(of: rhs.0)!
                : lhs.1 < rhs.1
        }) {
            return best.0
        }

        let normalizedQuery = requestedQuery?.replacingOccurrences(of: "집", with: "") ?? ""
        if ["초밥", "피자", "파스타", "라멘", "커피", "냉면", "삼겹살"]
            .contains(normalizedQuery) {
            return normalizedQuery
        }
        return "확인 불가"
    }
}
