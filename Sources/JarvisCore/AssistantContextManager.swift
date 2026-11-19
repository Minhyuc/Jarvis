import Foundation

public struct ManagedAssistantContext: Equatable, Sendable {
    public let summary: String?
    public let recentTurns: [ConversationMemoryTurn]
    public let longTermMemories: [String]
    private let semanticSummary: String?
    private let semanticRecentUserTexts: [String]

    public init(
        summary: String?,
        recentTurns: [ConversationMemoryTurn],
        longTermMemories: [String],
        semanticSummary: String? = nil,
        semanticRecentUserTexts: [String] = []
    ) {
        self.summary = summary
        self.recentTurns = recentTurns
        self.longTermMemories = longTermMemories
        self.semanticSummary = semanticSummary
        self.semanticRecentUserTexts = semanticRecentUserTexts
    }

    public var semanticResolutionContext: SemanticResolutionContext {
        SemanticResolutionContext(
            summary: semanticSummary,
            recentUserTexts: semanticRecentUserTexts
        )
    }
}

/// Owns bounded conversation state and selects only relevant long-term memories
/// for each request. Storage remains outside this type so explicit user consent
/// and Keychain persistence stay under the app's control.
public struct AssistantContextManager: Sendable {
    private var conversation: ConversationMemory
    public let maximumLongTermMemories: Int

    public init(
        maximumRecentTurns: Int = 12,
        maximumSummaryItems: Int = 8,
        maximumLongTermMemories: Int = 8
    ) {
        conversation = ConversationMemory(
            maximumRecentTurns: maximumRecentTurns,
            maximumSummaryItems: maximumSummaryItems
        )
        self.maximumLongTermMemories = max(1, maximumLongTermMemories)
    }

    public var latestIntent: AssistantIntent? {
        conversation.latestIntent
    }

    @discardableResult
    public mutating func record(
        userText: String,
        assistantResponse: String,
        intent: AssistantIntent
    ) -> ConversationMemorySuggestion? {
        conversation.record(
            userText: userText,
            assistantResponse: assistantResponse,
            intent: intent
        )
    }

    public func context(
        for currentText: String,
        longTermMemories: [String]
    ) -> ManagedAssistantContext {
        let snapshot = conversation.snapshot(for: currentText)
        let shouldResolveAgainstHistory = isReferentialFollowUp(currentText)
        return ManagedAssistantContext(
            summary: snapshot.summary,
            recentTurns: snapshot.turns,
            longTermMemories: selectLongTermMemories(
                for: currentText,
                from: longTermMemories
            ),
            semanticSummary: shouldResolveAgainstHistory ? snapshot.summary : nil,
            semanticRecentUserTexts: shouldResolveAgainstHistory
                ? snapshot.turns.suffix(4).map(\.userText)
                : []
        )
    }

    public mutating func reset() {
        conversation.reset()
    }

    private func selectLongTermMemories(
        for currentText: String,
        from memories: [String]
    ) -> [String] {
        guard memories.count > maximumLongTermMemories else { return memories }

        let queryTerms = terms(in: currentText)
        let recencyStart = max(0, memories.count - 3)
        var scored: [(index: Int, score: Int)] = []
        for (index, memory) in memories.enumerated() {
            let memoryTerms = terms(in: memory)
            let overlap = overlapCount(queryTerms, memoryTerms)
            let recencyBonus = index >= recencyStart ? 1 : 0
            scored.append((index: index, score: overlap * 10 + recencyBonus))
        }

        let ranked = scored.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index > rhs.index : lhs.score > rhs.score
        }
        .prefix(maximumLongTermMemories)
        .map(\.index)
        .sorted()

        return ranked.map { memories[$0] }
    }

    private func overlapCount(_ lhs: Set<String>, _ rhs: Set<String>) -> Int {
        var count = 0
        for term in lhs {
            if rhs.contains(term) {
                count += 1
            }
        }
        return count
    }

    private func terms(in text: String) -> Set<String> {
        let ignored: Set<String> = [
            "이거", "저거", "그거", "그게", "그럼", "조금", "다시",
            "알려줘", "해줘", "뭐야", "어떤", "어떻게", "저는", "나는"
        ]
        return Set(
            text.lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { $0.count >= 2 && !ignored.contains($0) }
        )
    }

    /// Semantic history is only supplied when the current sentence actually
    /// refers back to it. Deterministic routing still receives `latestIntent`,
    /// while a self-contained new target is protected from model anchoring.
    private func isReferentialFollowUp(_ text: String) -> Bool {
        let compact = text
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        let references = [
            "그거", "그것", "그곳", "거기", "그사람", "그앱", "그노래", "그영상",
            "아까", "방금", "이어서", "다시", "한번더", "그러면", "그럼",
            "더자세히", "자세히", "추가로", "그중", "첫번째", "두번째", "세번째",
            "최고는", "최저는", "다음은", "남은건", "현재는"
        ]
        return references.contains(where: compact.contains)
    }
}

public struct CloudConversationTurn: Codable, Sendable {
    public let user: String
    public let assistant: String

    public init(user: String, assistant: String) {
        self.user = user
        self.assistant = assistant
    }
}

public extension AssistantContextManager {
    func commandPracticeInput(seed: CommandPracticeSeed, variant: String? = nil,
                              index: Int, avoidedQuestions: [String] = []) throws -> String {
        struct Envelope: Encodable {
            let syntheticSeed: String
            let expectedCapability: String
            let primaryArgument: String
            let secondaryArgument: String
            let questionToReview: String?
            let exerciseNumber: Int
            let avoidDuplicates: [String]
        }
        let value = Envelope(syntheticSeed: seed.command, expectedCapability: seed.target.capability.rawValue,
            primaryArgument: seed.target.primary, secondaryArgument: seed.target.secondary,
            questionToReview: variant.map { String($0.prefix(180)) }, exerciseNumber: index,
            avoidDuplicates: Array(avoidedQuestions.filter { !PracticeHoldout.contains($0) }.suffix(3)).map { String($0.prefix(180)) })
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func cloudSemanticInput(text: String, context: SemanticResolutionContext, includeHistory: Bool) throws -> String {
        try cloudConversationInput(currentText: text, summary: context.summary,
            recentTurns: includeHistory ? context.recentUserTexts.suffix(3).map { .init(user: $0, assistant: "") } : [],
            memories: [], profile: "", includeHistory: includeHistory, includePersonalContext: false)
    }

    func cloudReviewInput(question: String, previousAnswer: String, correction: String) throws -> String {
        struct Review: Encodable { let question: String; let untrustedPreviousAnswer: String; let untrustedUserCorrection: String }
        let data = try JSONEncoder().encode(Review(question: String(question.prefix(1_000)),
            untrustedPreviousAnswer: String(previousAnswer.prefix(1_000)), untrustedUserCorrection: String(correction.prefix(1_000))))
        return String(decoding: data, as: UTF8.self)
    }

    func cloudCorrectedConversationInput(question: String, reference: String) throws -> String {
        struct Reference: Encodable { let currentRequest: String; let untrustedUserReviewedReference: String }
        guard question.count <= 2_000 else { throw OpenAIServiceError.inputTooLong }
        return String(decoding: try JSONEncoder().encode(Reference(currentRequest: question,
            untrustedUserReviewedReference: String(reference.prefix(1_000)))), as: UTF8.self)
    }
    /// Cloud input is separately bounded and personal memory is opt-in. JSON
    /// keeps untrusted content out of instruction delimiters. The transport
    /// never reads the profile or memory store itself.
    func cloudConversationInput(
        currentText: String,
        summary: String?,
        recentTurns: [CloudConversationTurn],
        memories: [String],
        profile: String,
        includeHistory: Bool,
        includePersonalContext: Bool
    ) throws -> String {
        guard currentText.count <= 2_000 else { throw OpenAIServiceError.inputTooLong }
        struct Envelope: Encodable {
            let currentRequest: String
            let summary: String
            let recentConversation: [CloudConversationTurn]
            let personalReference: [String]
        }
        let turns = includeHistory ? recentTurns.suffix(4).map {
            CloudConversationTurn(user: String($0.user.prefix(250)), assistant: String($0.assistant.prefix(350)))
        } : []
        let personal = includePersonalContext
            ? Array(memories.prefix(3).map { String($0.prefix(180)) }) + [String(profile.prefix(400))]
            : []
        let data = try JSONEncoder().encode(Envelope(
            currentRequest: currentText,
            summary: includeHistory ? String((summary ?? "").prefix(400)) : "",
            recentConversation: turns,
            personalReference: personal
        ))
        guard let input = String(data: data, encoding: .utf8) else { throw OpenAIServiceError.invalidResponse }
        return input
    }

    func cloudSearchSummaryInput(query: String, result: String) throws -> String {
        guard query.count <= 2_000 else { throw OpenAIServiceError.inputTooLong }
        struct SearchReference: Encodable {
            let question: String
            let untrustedSearchResult: String
        }
        let data = try JSONEncoder().encode(SearchReference(question: query, untrustedSearchResult: String(result.prefix(3_000))))
        guard let input = String(data: data, encoding: .utf8) else { throw OpenAIServiceError.invalidResponse }
        return input
    }
}
