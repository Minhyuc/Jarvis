import Foundation

/// Cleans a navigation destination before it can reach geocoding or an
/// external map app. Speech recognition and semantic models sometimes return
/// `강남역 역` or the entire request instead of the place name; this
/// deterministic boundary keeps those artifacts out of execution.
public struct NavigationDestinationNormalizer: Sendable {
    private let placeTypeSuffixes = [
        "역", "공항", "터미널", "대학교", "병원", "공원", "시장", "백화점", "시청", "구청"
    ]

    public init() {}

    /// MapKit sometimes treats a speech-recognized space as a word boundary and
    /// returns an unrelated place. Search both the spoken form and a compact
    /// Korean place-name form, while keeping execution deterministic.
    public func searchQueries(for rawValue: String) -> [String] {
        let normalized = normalize(rawValue)
        guard !normalized.isEmpty else { return [] }

        let compact = normalized.filter { !$0.isWhitespace }
        var variants = [normalized, compact]
        if let category = placeCategory(in: compact) {
            variants.append(contentsOf: category.searchQualifiers.map { qualifier in
                "\(normalized) \(qualifier)"
            })
        }

        return variants.reduce(into: []) { queries, query in
            guard !query.isEmpty, !queries.contains(query) else { return }
            queries.append(query)
        }
    }

    /// Rejects MapKit's occasional unrelated single result (for example a
    /// similarly pronounced hotel for a restaurant name). One speech syllable
    /// error is tolerated for normal-length Korean names.
    public func isPlausibleMatch(query rawQuery: String, candidate rawCandidate: String) -> Bool {
        let query = comparisonText(rawQuery)
        let candidate = comparisonText(rawCandidate)
        guard query.count >= 2, candidate.count >= 2 else { return false }
        if candidate.contains(query) || query.contains(candidate) { return true }

        // Map providers frequently use a category synonym instead of the
        // spoken suffix: `강남역` may be returned as `2호선 강남`, and
        // `서울대학교` as `서울대`. Accept only a matching place-name stem
        // paired with an equivalent category marker so unrelated nearby
        // results are still rejected.
        if let category = placeCategory(in: query) {
            let stem = String(query.dropLast(category.suffix.count))
            if stem.count >= 2, category.matches(stem: stem, candidate: candidate) {
                return true
            }
        }

        let allowedDistance = query.count >= 5 ? max(1, query.count / 5) : 0
        guard allowedDistance > 0 else { return false }
        return minimumWindowDistance(from: query, in: candidate) <= allowedDistance
    }

    public func normalize(_ rawValue: String) -> String {
        var value = rawValue
            .replacingOccurrences(of: #"[\"'“”]"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"[\s]*[.!?,。，！？]+[\s]*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        value = replacingTrailingRequest(in: value)
        value = value.replacingOccurrences(
            of: #"^(?:자비스(?:야)?\s*)?(?:현재\s*위치에서\s*)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s*(?:까지|으로|로)$"#,
            with: "",
            options: .regularExpression
        )
        value = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove an adjacent duplicate place name, e.g. `강남역 강남역`.
        var words = value.split(separator: " ").map(String.init)
        while words.count >= 2, words[words.count - 1] == words[words.count - 2] {
            words.removeLast()
        }
        value = words.joined(separator: " ")

        // Remove a duplicate category suffix, e.g. `강남역 역` or `강남역역`.
        for suffix in placeTypeSuffixes {
            let spacedDuplicate = "\(suffix) \(suffix)"
            while value.hasSuffix(spacedDuplicate) {
                value.removeLast(suffix.count + 1)
            }
            let compactDuplicate = suffix + suffix
            while value.hasSuffix(compactDuplicate) {
                value.removeLast(suffix.count)
            }
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacingTrailingRequest(in value: String) -> String {
        let patterns = [
            #"\s*(?:까지|으로|로)?\s*(?:(?:자가용|자동차|차량|차|대중교통|지하철|버스|전철)(?:으로|로)?\s*)?(?:가는\s*(?:방법|길)|가려면|길\s*안내|경로\s*안내|안내|네비게이션|내비게이션|네비|내비)(?:를)?\s*(?:바로\s*)?(?:시작\s*)?(?:부탁(?:해|해요|해줘|드려|드려요|드립니다|했어|했어요|했는데)?|해\s*줘|해줘|해\s*줘요|해줘요|알려\s*줘|알려줘)?\s*$"#,
            #"\s*(?:까지|으로|로)\s*(?:안내\s*)?(?:부탁(?:해|해요|해줘|드려|드려요|드립니다)?|해\s*줘|해줘|알려\s*줘|알려줘)\s*$"#
        ]

        var result = value
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func comparisonText(_ value: String) -> String {
        normalize(value)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func placeCategory(in compactValue: String) -> PlaceCategory? {
        PlaceCategory.allCases.first { compactValue.hasSuffix($0.suffix) }
    }

    private func minimumWindowDistance(from query: String, in candidate: String) -> Int {
        let queryCharacters = Array(query)
        let candidateCharacters = Array(candidate)
        let minimumLength = max(1, queryCharacters.count - 1)
        let maximumLength = min(candidateCharacters.count, queryCharacters.count + 1)
        guard minimumLength <= maximumLength else {
            return editDistance(queryCharacters, candidateCharacters)
        }

        var best = Int.max
        for length in minimumLength...maximumLength {
            guard length <= candidateCharacters.count else { continue }
            for start in 0...(candidateCharacters.count - length) {
                let window = Array(candidateCharacters[start..<(start + length)])
                best = min(best, editDistance(queryCharacters, window))
            }
        }
        return best
    }

    private func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)
        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private enum PlaceCategory: CaseIterable, Equatable {
        case university
        case departmentStore
        case terminal
        case hospital
        case airport
        case station
        case park
        case market
        case cityHall
        case districtOffice

        var suffix: String {
            switch self {
            case .university: "대학교"
            case .departmentStore: "백화점"
            case .terminal: "터미널"
            case .hospital: "병원"
            case .airport: "공항"
            case .station: "역"
            case .park: "공원"
            case .market: "시장"
            case .cityHall: "시청"
            case .districtOffice: "구청"
            }
        }

        var searchQualifiers: [String] {
            switch self {
            case .station: ["지하철역", "전철역"]
            case .airport: ["국제공항"]
            case .terminal: ["버스터미널", "고속버스터미널"]
            case .university: ["대학 캠퍼스"]
            case .hospital: ["의료원", "의료기관"]
            case .park: ["도시공원"]
            case .market: ["전통시장"]
            case .departmentStore: ["쇼핑"]
            case .cityHall, .districtOffice: ["청사"]
            }
        }

        private var equivalentMarkers: [String] {
            switch self {
            case .station: ["역", "호선", "station"]
            case .airport: ["공항", "국제공항", "airport"]
            case .terminal: ["터미널", "버스터미널", "고속버스터미널", "terminal"]
            case .university: ["대학교", "대학", "대", "university"]
            case .hospital: ["병원", "의료원", "의료센터", "hospital"]
            case .park: ["공원", "park"]
            case .market: ["시장", "전통시장", "market"]
            case .departmentStore: ["백화점", "departmentstore"]
            case .cityHall: ["시청", "시청사", "cityhall"]
            case .districtOffice: ["구청", "구청사", "districtoffice"]
            }
        }

        func matches(stem: String, candidate: String) -> Bool {
            guard candidate.contains(stem) else { return false }
            if self == .station, candidate == stem { return true }

            return equivalentMarkers.contains { marker in
                if self == .university, marker == "대" {
                    return candidate == stem + marker
                }
                return candidate.contains(stem + marker)
                    || candidate.contains(marker + stem)
            }
        }
    }
}
