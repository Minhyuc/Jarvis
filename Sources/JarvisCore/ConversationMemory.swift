import Foundation

public struct ConversationMemoryTurn: Equatable, Sendable {
    public let userText: String
    public let assistantResponse: String
    public let intent: AssistantIntent

    public init(userText: String, assistantResponse: String, intent: AssistantIntent) {
        self.userText = userText
        self.assistantResponse = assistantResponse
        self.intent = intent
    }
}

public struct ConversationMemorySnapshot: Equatable, Sendable {
    public let summary: String?
    public let turns: [ConversationMemoryTurn]

    public init(summary: String?, turns: [ConversationMemoryTurn]) {
        self.summary = summary
        self.turns = turns
    }
}

public struct ConversationMemorySuggestion: Equatable, Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

/// App-session-only memory. Raw turns stay bounded and evicted turns become a
/// short rolling summary, so prompts do not grow without limit.
public struct ConversationMemory: Sendable {
    private struct PersonalFactObservation: Sendable {
        var content: String
        var terms: Set<String>
        var count: Int
        var wasSuggested: Bool
    }

    public let maximumRecentTurns: Int
    public let maximumSummaryItems: Int

    private var recentTurns: [ConversationMemoryTurn] = []
    private var summaryItems: [String] = []
    private var personalFactObservations: [PersonalFactObservation] = []

    public init(maximumRecentTurns: Int = 12, maximumSummaryItems: Int = 8) {
        self.maximumRecentTurns = max(4, maximumRecentTurns)
        self.maximumSummaryItems = max(1, maximumSummaryItems)
    }

    public var latestIntent: AssistantIntent? {
        recentTurns.last?.intent
    }

    public var recentTurnCount: Int {
        recentTurns.count
    }

    @discardableResult
    public mutating func record(
        userText: String,
        assistantResponse: String,
        intent: AssistantIntent
    ) -> ConversationMemorySuggestion? {
        let user = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { return nil }

        let suggestion = repeatedPersonalFactSuggestion(userText: user, intent: intent)

        recentTurns.append(
            ConversationMemoryTurn(
                userText: user,
                assistantResponse: assistant,
                intent: intent
            )
        )

        while recentTurns.count > maximumRecentTurns {
            let evicted = recentTurns.removeFirst()
            summaryItems.append(summaryLine(for: evicted))
        }
        if summaryItems.count > maximumSummaryItems {
            summaryItems.removeFirst(summaryItems.count - maximumSummaryItems)
        }
        return suggestion
    }

    public func snapshot(for currentText: String) -> ConversationMemorySnapshot {
        let selected = relevantTurns(for: currentText)
        return ConversationMemorySnapshot(
            summary: summaryItems.isEmpty ? nil : summaryItems.joined(separator: "\n"),
            turns: selected
        )
    }

    public mutating func reset() {
        recentTurns.removeAll()
        summaryItems.removeAll()
        personalFactObservations.removeAll()
    }

    private mutating func repeatedPersonalFactSuggestion(
        userText: String,
        intent: AssistantIntent
    ) -> ConversationMemorySuggestion? {
        guard case .generalConversation = intent,
              looksLikePersonalFact(userText) else {
            return nil
        }

        let terms = memoryTerms(in: userText)
        guard terms.count >= 2 else { return nil }

        if let index = personalFactObservations.indices.max(by: { lhs, rhs in
            similarity(terms, personalFactObservations[lhs].terms)
                < similarity(terms, personalFactObservations[rhs].terms)
        }), similarity(terms, personalFactObservations[index].terms) >= 0.45 {
            personalFactObservations[index].count += 1
            if userText.count < personalFactObservations[index].content.count {
                personalFactObservations[index].content = userText
            }
            personalFactObservations[index].terms.formUnion(terms)

            if personalFactObservations[index].count >= 2,
               !personalFactObservations[index].wasSuggested {
                personalFactObservations[index].wasSuggested = true
                return ConversationMemorySuggestion(
                    content: personalFactObservations[index].content
                )
            }
            return nil
        }

        personalFactObservations.append(
            PersonalFactObservation(
                content: userText,
                terms: terms,
                count: 1,
                wasSuggested: false
            )
        )
        if personalFactObservations.count > 20 {
            personalFactObservations.removeFirst(personalFactObservations.count - 20)
        }
        return nil
    }

    private func looksLikePersonalFact(_ text: String) -> Bool {
        let compact = normalize(text)
        guard !text.contains("?") else { return false }

        let personalMarkers = ["나는", "내가", "저는", "제가", "내 ", "제 ", "우리"]
        let durableFactMarkers = [
            "좋아", "싫어", "선호", "생일", "알레르기", "못먹", "안먹",
            "살고", "살아", "사는곳", "직업", "일해", "근무", "전공",
            "취미", "관심", "자주", "사용해", "이름은", "습관"
        ]
        return personalMarkers.contains(where: text.contains)
            && durableFactMarkers.contains(where: compact.contains)
    }

    private func memoryTerms(in text: String) -> Set<String> {
        let ignored: Set<String> = [
            "나는", "내가", "저는", "제가", "나도", "저도", "그리고",
            "그런데", "정말", "진짜", "자주", "기억해", "말했지"
        ]
        let suffixes = [
            "이라고", "라는", "한다는", "한다고", "합니다", "이에요", "예요",
            "이야", "이야요", "해요", "하고", "해서", "에게", "에서",
            "으로", "은", "는", "이", "가", "을", "를", "도", "에"
        ]

        return Set(
            text.lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !ignored.contains($0) }
                .map { token in
                    for suffix in suffixes where token.count > suffix.count + 1 && token.hasSuffix(suffix) {
                        return String(token.dropLast(suffix.count))
                    }
                    return token
                }
                .filter { $0.count >= 2 }
        )
    }

    private func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let overlap = lhs.intersection(rhs).count
        guard overlap >= 2 else { return 0 }
        return Double(overlap) / Double(max(1, min(lhs.count, rhs.count)))
    }

    private func relevantTurns(for currentText: String) -> [ConversationMemoryTurn] {
        guard recentTurns.count > 4 else { return recentTurns }

        let normalized = normalize(currentText)
        let pronounTerms = [
            "그거", "그것", "그게", "그곳", "거기", "그사람", "그노래",
            "그앱", "그중", "첫번째", "두번째", "세번째", "이것", "이거",
            "방금", "아까", "이어서", "더자세히", "그럼"
        ]
        if pronounTerms.contains(where: normalized.contains) {
            return Array(recentTurns.suffix(8))
        }

        let alwaysRecentIndices = Set(recentTurns.indices.suffix(4))
        let queryTokens = tokens(in: currentText)
        guard !queryTokens.isEmpty else { return Array(recentTurns.suffix(4)) }

        let olderMatches = recentTurns.indices
            .filter { !alwaysRecentIndices.contains($0) }
            .compactMap { index -> (Int, Int)? in
                let turn = recentTurns[index]
                let haystack = normalize(turn.userText + " " + turn.assistantResponse)
                let score = queryTokens.reduce(0) { result, token in
                    result + (haystack.contains(token) ? 1 : 0)
                }
                return score > 0 ? (index, score) : nil
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 > rhs.1
            }
            .prefix(4)
            .map(\.0)

        let selectedIndices = alwaysRecentIndices.union(olderMatches).sorted()
        return selectedIndices.map { recentTurns[$0] }
    }

    private func tokens(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "이거", "저거", "그거", "그게", "그럼", "조금", "좀", "다시",
            "알려줘", "해줘", "뭐야", "어떤", "어떻게", "왜"
        ]
        return text
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func summaryLine(for turn: ConversationMemoryTurn) -> String {
        "• 사용자: \(shortened(turn.userText, limit: 80)) / 자비스: \(shortened(turn.assistantResponse, limit: 120))"
    }

    private func shortened(_ text: String, limit: Int) -> String {
        let withoutURLs = text.replacingOccurrences(
            of: #"https?://[^\s]+"#,
            with: "",
            options: .regularExpression
        )
        let singleLine = withoutURLs
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}
