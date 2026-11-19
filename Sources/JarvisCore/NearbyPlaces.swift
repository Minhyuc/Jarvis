import Foundation

public enum NearbyPlaceCategory: String, Codable, CaseIterable, Sendable {
    case market, pharmacy, hospital, parking, cafe

    public var title: String {
        switch self {
        case .market: "마트"
        case .pharmacy: "약국"
        case .hospital: "병원"
        case .parking: "주차장"
        case .cafe: "카페"
        }
    }

    public static func parse(_ text: String) -> Self? {
        let compact = text.filter { !$0.isWhitespace }
        if compact.contains("마트") || compact.contains("슈퍼") { return .market }
        return allCases.first { compact.contains($0.title) }
    }
}

/// Provider identity, address and coordinates stay together. A model never
/// supplies coordinates or asserts that a business is open.
public struct NearbyPlace: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let address: String
    public let latitude: Double
    public let longitude: Double
    public let sourceLatitude: Double
    public let sourceLongitude: Double
    public let distance: Double
    public let openNow: Bool?
    public let observedAt: Date

    public init(id: String, name: String, address: String, latitude: Double, longitude: Double,
                sourceLatitude: Double, sourceLongitude: Double, distance: Double,
                openNow: Bool? = nil, observedAt: Date = Date()) {
        self.id = id; self.name = name; self.address = address
        self.latitude = latitude; self.longitude = longitude
        self.sourceLatitude = sourceLatitude; self.sourceLongitude = sourceLongitude
        self.distance = distance; self.openNow = openNow; self.observedAt = observedAt
    }

    public var navigationCandidate: NavigationDestinationCandidate {
        .init(name: name, area: address, latitude: latitude, longitude: longitude,
              sourceLatitude: sourceLatitude, sourceLongitude: sourceLongitude, straightLineDistance: distance)
    }

    public func hoursDescription(now: Date = Date()) -> String {
        guard now.timeIntervalSince(observedAt) >= 0, now.timeIntervalSince(observedAt) < 300,
              let openNow else { return "현재 영업 여부는 확인하지 못했습니다." }
        return openNow ? "검색 서비스에서 현재 영업 중으로 표시됩니다." : "검색 서비스에서 현재 영업 종료로 표시됩니다."
    }
}

public struct NearbyPlaceDialogue: Equatable, Sendable {
    public let category: NearbyPlaceCategory
    public let candidates: [NearbyPlace]
    public var selectedID: String?
    public var mode: NavigationTravelMode?
    public let navigationRequested: Bool
    public let origin: SafetyExecutionOrigin

    public init(category: NearbyPlaceCategory, candidates: [NearbyPlace], selectedID: String? = nil,
                mode: NavigationTravelMode? = nil, navigationRequested: Bool = false,
                origin: SafetyExecutionOrigin = .directUserRequest) {
        self.category = category; self.candidates = Array(candidates.prefix(5))
        self.selectedID = selectedID; self.mode = mode
        self.navigationRequested = navigationRequested; self.origin = origin
    }
}

public enum NearbyPlaceFollowUp: Equatable, Sendable {
    case details(NearbyPlace)
    case navigate(NearbyPlace, NavigationTravelMode?)
    case select(NearbyPlace)
    case ambiguous
    case unrelated
}

public struct NearbyPlaceFollowUpResolver: Sendable {
    public init() {}
    public func resolve(_ text: String, dialogue: NearbyPlaceDialogue) -> NearbyPlaceFollowUp {
        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let hours = ["영업", "열었", "열려", "문열", "몇시", "주소", "어디있"].contains(where: compact.contains)
        let mode = CommandRouter().navigationTravelMode(from: text)
        let navigation = mode != nil || ["안내", "가자", "갈래", "길찾", "데려다"].contains(where: compact.contains)
        let selected: NearbyPlace?
        let ordinals = [["1번", "첫번째", "첫째"], ["2번", "두번째", "둘째"], ["3번", "세번째", "셋째"],
                        ["4번", "네번째", "넷째"], ["5번", "다섯번째", "다섯째"]]
        let modeOnly = ["자가용으로", "자동차로", "차로", "대중교통으로", "버스로", "지하철로", "아니자가용으로", "아니대중교통으로"].contains(compact)
        var routedSelection: NearbyPlace?
        if case .navigate(let target, _) = CommandRouter().route(text), !modeOnly,
           !["거기", "그곳"].contains(where: compact.contains),
           !ordinals.flatMap({ $0 }).contains(where: compact.contains) {
            let targetKey = target.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
            let exact = dialogue.candidates.filter { $0.name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation } == targetKey }
            let matches = exact.isEmpty ? dialogue.candidates.filter {
                targetKey.count >= 2 && $0.name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }.hasPrefix(targetKey)
            } : exact
            if matches.isEmpty { return .unrelated }
            if matches.count > 1 { return .ambiguous }
            routedSelection = matches[0]
        }
        let ordinalMatches = ordinals.indices.filter { index in ordinals[index].contains(where: compact.contains) }
        if ordinalMatches.count > 1 { return .ambiguous }
        if let index = ordinalMatches.first {
            selected = dialogue.candidates.indices.contains(index) ? dialogue.candidates[index] : nil
        } else if let routedSelection {
            selected = routedSelection
        } else {
            let matches = dialogue.candidates.filter {
                let name = $0.name.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
                return !name.isEmpty && compact.contains(name)
            }
            if matches.count == 1 { selected = matches[0] }
            else if matches.count > 1 { return .ambiguous }
            else if ["거기", "그곳", "그중", "그마트", "그약국"].contains(where: compact.contains)
                        || modeOnly {
                selected = dialogue.candidates.first { $0.id == dialogue.selectedID }
            } else { selected = nil }
        }
        guard let selected else {
            let direct = CommandRouter().route(text)
            switch direct {
            case .generalConversation, .unknownCommand:
                return hours || navigation || ordinals.flatMap({ $0 }).contains(where: compact.contains) ? .ambiguous : .unrelated
            default: return .unrelated
            }
        }
        if hours { return .details(selected) }
        if navigation { return .navigate(selected, mode ?? dialogue.mode) }
        return .select(selected)
    }
}
