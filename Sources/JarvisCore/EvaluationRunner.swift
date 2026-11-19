import Foundation

public enum RoutingEvaluationCategory: String, CaseIterable, Codable, Sendable {
    case conversation
    case media
    case volume
    case alarm
    case briefing
    case weather
    case calendar
    case time
    case navigation
    case communication
    case application
    case search
    case memory
    case safety
}

public struct RoutingEvaluationCase: Equatable, Sendable {
    public let name: String
    public let category: RoutingEvaluationCategory
    public let input: String
    public let previousIntent: AssistantIntent?
    public let expectedIntent: AssistantIntent

    public init(
        name: String,
        category: RoutingEvaluationCategory = .conversation,
        input: String,
        previousIntent: AssistantIntent? = nil,
        expectedIntent: AssistantIntent
    ) {
        self.name = name
        self.category = category
        self.input = input
        self.previousIntent = previousIntent
        self.expectedIntent = expectedIntent
    }
}

public struct RoutingEvaluationFailure: Equatable, Sendable {
    public let caseName: String
    public let category: RoutingEvaluationCategory
    public let input: String
    public let expected: AssistantIntent
    public let actual: AssistantIntent
}

public struct CategoryEvaluationResult: Equatable, Sendable {
    public let category: RoutingEvaluationCategory
    public let totalCount: Int
    public let passedCount: Int

    public var passRate: Double {
        guard totalCount > 0 else { return 1 }
        return Double(passedCount) / Double(totalCount)
    }
}

public struct EvaluationReport: Equatable, Sendable {
    public let totalCount: Int
    public let passedCount: Int
    public let requiredPassRate: Double
    public let categoryResults: [CategoryEvaluationResult]
    public let failures: [RoutingEvaluationFailure]

    public var passRate: Double {
        guard totalCount > 0 else { return 1 }
        return Double(passedCount) / Double(totalCount)
    }

    public var passed: Bool { passRate >= requiredPassRate }
}

/// A model-independent regression runner. The same cases can be reused when the
/// router or semantic model changes, preventing a perceived intelligence upgrade
/// from silently breaking existing commands.
public struct EvaluationRunner: Sendable {
    private let router: CommandRouter

    public init(router: CommandRouter = CommandRouter()) {
        self.router = router
    }

    public func runSemantic(_ cases: [SemanticRoutingEvaluationCase]) async -> [String] {
        struct Resolver: SemanticIntentResolving {
            let candidate: SemanticIntentCandidate
            func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? { candidate }
        }
        var failedIDs: [String] = []
        for item in cases {
            let result = await AgentOrchestrator(router: router).resolve(item.input, previousIntent: nil,
                context: .init(summary: nil, recentUserTexts: []), semanticResolver: Resolver(candidate: item.candidate))
            if result != item.expected { failedIDs.append(item.id) }
        }
        return failedIDs
    }

    public func run(
        _ cases: [RoutingEvaluationCase],
        requiredPassRate: Double = 1
    ) -> EvaluationReport {
        let failures = cases.compactMap { testCase -> RoutingEvaluationFailure? in
            let actual = router.route(testCase.input, previousIntent: testCase.previousIntent)
            guard actual != testCase.expectedIntent else { return nil }
            return RoutingEvaluationFailure(
                caseName: testCase.name,
                category: testCase.category,
                input: testCase.input,
                expected: testCase.expectedIntent,
                actual: actual
            )
        }
        let categoryResults: [CategoryEvaluationResult] = RoutingEvaluationCategory.allCases.compactMap { category in
            let categoryCases = cases.filter { $0.category == category }
            guard !categoryCases.isEmpty else { return nil }
            let failedCount = failures.filter { $0.category == category }.count
            return CategoryEvaluationResult(
                category: category,
                totalCount: categoryCases.count,
                passedCount: categoryCases.count - failedCount
            )
        }
        return EvaluationReport(
            totalCount: cases.count,
            passedCount: cases.count - failures.count,
            requiredPassRate: min(max(requiredPassRate, 0), 1),
            categoryResults: categoryResults,
            failures: failures
        )
    }
}

public struct SemanticRoutingEvaluationCase: Sendable {
    public let id: String
    public let input: String
    public let candidate: SemanticIntentCandidate
    public let expected: AgentResolution
    public init(id: String, input: String, candidate: SemanticIntentCandidate, expected: AgentResolution) {
        self.id = id; self.input = input; self.candidate = candidate; self.expected = expected
    }
}

public enum EvaluationTag: String, Codable, CaseIterable, Hashable, Sendable {
    case naturalSpeech
    case speechRecognitionVariation
    case spacingVariation
    case followUp
    case pronoun
    case topicChange
    case ambiguous
    case safetyCritical
}

public enum EvaluationInputOrigin: String, Codable, CaseIterable, Sendable {
    case curatedText
    case anonymizedSpeechTranscript
}

public enum ExpectedEvaluationBehavior: String, Codable, Sendable {
    case resolveIntent
    case askForClarification
    case dismiss
}

public struct EvaluationCaseV2: Equatable, Sendable {
    public let id: String
    public let category: RoutingEvaluationCategory
    public let input: String
    public let previousIntent: AssistantIntent?
    public let expectedIntent: AssistantIntent
    public let expectedBehavior: ExpectedEvaluationBehavior
    public let riskLevel: ActionRiskLevel
    public let tags: Set<EvaluationTag>
    public let inputOrigin: EvaluationInputOrigin

    public init(
        id: String,
        category: RoutingEvaluationCategory,
        input: String,
        previousIntent: AssistantIntent? = nil,
        expectedIntent: AssistantIntent,
        expectedBehavior: ExpectedEvaluationBehavior = .resolveIntent,
        riskLevel: ActionRiskLevel = .informational,
        tags: Set<EvaluationTag> = [.naturalSpeech],
        inputOrigin: EvaluationInputOrigin = .curatedText
    ) {
        self.id = id
        self.category = category
        self.input = input
        self.previousIntent = previousIntent
        self.expectedIntent = expectedIntent
        self.expectedBehavior = expectedBehavior
        self.riskLevel = riskLevel
        self.tags = tags
        self.inputOrigin = inputOrigin
    }
}

public enum EvaluationFailureType: String, Codable, CaseIterable, Sendable {
    case intentClassification
    case argumentExtraction
    case speechRecognitionVariation
    case followUpContext
    case staleContextReuse
    case ambiguousCommandGuessed
    case dangerousCommandMisfire

    public var title: String {
        switch self {
        case .intentClassification: "의도 분류 실패"
        case .argumentExtraction: "인자 추출 실패"
        case .speechRecognitionVariation: "음성 인식 변형 실패"
        case .followUpContext: "후속 문맥 실패"
        case .staleContextReuse: "오래된 문맥 오사용"
        case .ambiguousCommandGuessed: "모호한 명령 추측 실행"
        case .dangerousCommandMisfire: "위험 명령 오작동"
        }
    }
}

public struct EvaluationFailureV2: Equatable, Sendable {
    public let caseID: String
    public let category: RoutingEvaluationCategory
    public let input: String
    public let expected: AssistantIntent
    public let actual: AssistantIntent
    public let type: EvaluationFailureType
}

public struct TagEvaluationResult: Equatable, Sendable {
    public let tag: EvaluationTag
    public let totalCount: Int
    public let passedCount: Int

    public var passRate: Double {
        guard totalCount > 0 else { return 1 }
        return Double(passedCount) / Double(totalCount)
    }
}

public struct EvaluationReportV2: Equatable, Sendable {
    public let totalCount: Int
    public let passedCount: Int
    public let requiredPassRate: Double
    public let categoryResults: [CategoryEvaluationResult]
    public let tagResults: [TagEvaluationResult]
    public let failures: [EvaluationFailureV2]
    public let totalDurationMilliseconds: Double
    public let slowestCaseMilliseconds: Double

    public init(
        totalCount: Int,
        passedCount: Int,
        requiredPassRate: Double,
        categoryResults: [CategoryEvaluationResult],
        tagResults: [TagEvaluationResult],
        failures: [EvaluationFailureV2],
        totalDurationMilliseconds: Double = 0,
        slowestCaseMilliseconds: Double = 0
    ) {
        self.totalCount = totalCount
        self.passedCount = passedCount
        self.requiredPassRate = requiredPassRate
        self.categoryResults = categoryResults
        self.tagResults = tagResults
        self.failures = failures
        self.totalDurationMilliseconds = totalDurationMilliseconds
        self.slowestCaseMilliseconds = slowestCaseMilliseconds
    }

    public var passRate: Double {
        guard totalCount > 0 else { return 1 }
        return Double(passedCount) / Double(totalCount)
    }

    public var dangerousMisfireCount: Int {
        failures.filter { $0.type == .dangerousCommandMisfire || $0.type == .ambiguousCommandGuessed }.count
    }

    public var speechVariationPassRate: Double {
        tagResults.first(where: { $0.tag == .speechRecognitionVariation })?.passRate ?? 1
    }

    public var ambiguousGuessCount: Int {
        failures.filter { $0.type == .ambiguousCommandGuessed }.count
    }

    public var averageCaseMilliseconds: Double {
        guard totalCount > 0 else { return 0 }
        return totalDurationMilliseconds / Double(totalCount)
    }

    public var passed: Bool {
        passRate >= requiredPassRate
            && speechVariationPassRate >= 0.90
            && dangerousMisfireCount == 0
    }
}

public struct EvaluationSnapshot: Codable, Equatable, Sendable {
    public let createdAt: Date
    public let corpusVersion: String
    public let totalCount: Int
    public let passedCount: Int
    public let failureCaseIDs: Set<String>
    public let categoryPassRates: [String: Double]
    public let speechVariationPassRate: Double?
    public let dangerousMisfireCount: Int?
    public let averageCaseMilliseconds: Double?

    public init(
        report: EvaluationReportV2,
        corpusVersion: String,
        createdAt: Date = Date()
    ) {
        self.createdAt = createdAt
        self.corpusVersion = corpusVersion
        totalCount = report.totalCount
        passedCount = report.passedCount
        failureCaseIDs = Set(report.failures.map(\.caseID))
        categoryPassRates = Dictionary(uniqueKeysWithValues: report.categoryResults.map {
            ($0.category.rawValue, $0.passRate)
        })
        speechVariationPassRate = report.speechVariationPassRate
        dangerousMisfireCount = report.dangerousMisfireCount
        averageCaseMilliseconds = report.averageCaseMilliseconds
    }

    public var passRate: Double {
        guard totalCount > 0 else { return 1 }
        return Double(passedCount) / Double(totalCount)
    }
}

/// A bounded, privacy-safe history of aggregate evaluation results. Raw user
/// utterances are deliberately excluded from snapshots.
public struct EvaluationHistory: Codable, Equatable, Sendable {
    public private(set) var snapshots: [EvaluationSnapshot]

    public init(snapshots: [EvaluationSnapshot] = []) {
        self.snapshots = snapshots.sorted { $0.createdAt < $1.createdAt }
    }

    public var latest: EvaluationSnapshot? { snapshots.last }

    public mutating func append(
        _ snapshot: EvaluationSnapshot,
        maximumCount: Int = 20
    ) {
        snapshots.removeAll { $0.createdAt == snapshot.createdAt }
        snapshots.append(snapshot)
        snapshots.sort { $0.createdAt < $1.createdAt }
        let limit = max(1, maximumCount)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
    }

    public mutating func removeAll() {
        snapshots.removeAll()
    }
}

public struct EvaluationComparison: Equatable, Sendable {
    public let baseline: EvaluationSnapshot
    public let current: EvaluationSnapshot

    public init(baseline: EvaluationSnapshot, current: EvaluationSnapshot) {
        self.baseline = baseline
        self.current = current
    }

    public var passRateDelta: Double { current.passRate - baseline.passRate }
    public var newFailureCaseIDs: Set<String> {
        current.failureCaseIDs.subtracting(baseline.failureCaseIDs)
    }
    public var resolvedFailureCaseIDs: Set<String> {
        baseline.failureCaseIDs.subtracting(current.failureCaseIDs)
    }
    public var hasRegression: Bool {
        let speechRegressed: Bool
        if let baselineRate = baseline.speechVariationPassRate,
           let currentRate = current.speechVariationPassRate {
            speechRegressed = currentRate < baselineRate
        } else {
            speechRegressed = false
        }
        let safetyRegressed = (current.dangerousMisfireCount ?? 0)
            > (baseline.dangerousMisfireCount ?? 0)
        return passRateDelta < 0
            || !newFailureCaseIDs.isEmpty
            || speechRegressed
            || safetyRegressed
    }
}

public extension EvaluationRunner {
    func runV2(
        _ cases: [EvaluationCaseV2],
        requiredPassRate: Double = 0.95
    ) -> EvaluationReportV2 {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var slowestCaseNanoseconds: UInt64 = 0
        let failures = cases.compactMap { testCase -> EvaluationFailureV2? in
            let caseStartedAt = DispatchTime.now().uptimeNanoseconds
            let actual = router.route(testCase.input, previousIntent: testCase.previousIntent)
            let elapsed = DispatchTime.now().uptimeNanoseconds - caseStartedAt
            slowestCaseNanoseconds = max(slowestCaseNanoseconds, elapsed)
            guard !intentsMatch(expected: testCase.expectedIntent, actual: actual) else { return nil }
            return EvaluationFailureV2(
                caseID: testCase.id,
                category: testCase.category,
                input: testCase.input,
                expected: testCase.expectedIntent,
                actual: actual,
                type: failureType(for: testCase, actual: actual)
            )
        }
        let categoryResults: [CategoryEvaluationResult] = RoutingEvaluationCategory.allCases.compactMap { category in
            let categoryCases = cases.filter { $0.category == category }
            guard !categoryCases.isEmpty else { return nil }
            let failed = failures.filter { $0.category == category }.count
            return CategoryEvaluationResult(
                category: category,
                totalCount: categoryCases.count,
                passedCount: categoryCases.count - failed
            )
        }
        let tagResults: [TagEvaluationResult] = EvaluationTag.allCases.compactMap { tag in
            let tagged = cases.filter { $0.tags.contains(tag) }
            guard !tagged.isEmpty else { return nil }
            let failedIDs = Set(failures.map(\.caseID))
            return TagEvaluationResult(
                tag: tag,
                totalCount: tagged.count,
                passedCount: tagged.filter { !failedIDs.contains($0.id) }.count
            )
        }
        return EvaluationReportV2(
            totalCount: cases.count,
            passedCount: cases.count - failures.count,
            requiredPassRate: min(max(requiredPassRate, 0), 1),
            categoryResults: categoryResults,
            tagResults: tagResults,
            failures: failures,
            totalDurationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000,
            slowestCaseMilliseconds: Double(slowestCaseNanoseconds) / 1_000_000
        )
    }

    private func failureType(
        for testCase: EvaluationCaseV2,
        actual: AssistantIntent
    ) -> EvaluationFailureType {
        if testCase.expectedBehavior == .askForClarification,
           actual.isExecutableForEvaluation {
            return .ambiguousCommandGuessed
        }
        if testCase.riskLevel >= .medium,
           actual.isExecutableForEvaluation,
           actual.evaluationKind != testCase.expectedIntent.evaluationKind {
            return .dangerousCommandMisfire
        }
        if testCase.tags.contains(.speechRecognitionVariation) {
            return .speechRecognitionVariation
        }
        if testCase.tags.contains(.topicChange) {
            return .staleContextReuse
        }
        if testCase.previousIntent != nil || testCase.tags.contains(.followUp) {
            return .followUpContext
        }
        if actual.suggestionFamilyKey == testCase.expectedIntent.suggestionFamilyKey {
            return .argumentExtraction
        }
        return .intentClassification
    }

    private func intentsMatch(expected: AssistantIntent, actual: AssistantIntent) -> Bool {
        if expected == actual { return true }
        switch (expected, actual) {
        case let (.webSearch(lhs), .webSearch(rhs)):
            return normalizedEvaluationText(lhs) == normalizedEvaluationText(rhs)
        case let (.recommendRestaurants(lhs), .recommendRestaurants(rhs)):
            return normalizedEvaluationText(lhs ?? "") == normalizedEvaluationText(rhs ?? "")
        case let (.setAlarm(lhsRequest, nil, nil, lhsDelivery),
                  .setAlarm(rhsRequest, _, _, rhsDelivery)):
            return lhsRequest == rhsRequest && lhsDelivery == rhsDelivery
        default:
            return false
        }
    }

    private func normalizedEvaluationText(_ text: String) -> String {
        var result = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        for token in ["정보", "자료", "내용", "대해", "세곳", "3곳", "으로"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        while result.range(of: #"(?:을|를|에|은|는|이|가|집)$"#, options: .regularExpression) != nil {
            result = result.replacingOccurrences(of: #"(?:을|를|에|은|는|이|가|집)$"#, with: "", options: .regularExpression)
        }
        return result
    }
}

private extension AssistantIntent {
    var evaluationKind: String {
        switch self {
        case .navigate: "navigate"
        case .call: "call"
        case .openApp: "openApp"
        case .unknownCommand: "unknown"
        case .generalConversation: "conversation"
        default: suggestionFamilyKey
        }
    }

    var isExecutableForEvaluation: Bool {
        switch self {
        case .unknownCommand, .generalConversation, .assistantCapabilities, .dismissConversation:
            false
        default:
            true
        }
    }
}
