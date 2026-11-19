import Foundation

public enum ResponseQualityDimension: String, Codable, CaseIterable, Sendable {
    case accuracy, context, clarification, uncertainty
    public var title: String {
        switch self {
        case .accuracy: "정확성"
        case .context: "문맥 유지"
        case .clarification: "재질문 적절성"
        case .uncertainty: "불확실성 표현"
        }
    }
}

public struct LiveResponseEvaluationCase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let turns: [String]
    public let rubric: String
    public let requiredTerms: [String]

    public init(id: String, turns: [String], rubric: String, requiredTerms: [String] = []) {
        self.id = id; self.turns = turns; self.rubric = rubric; self.requiredTerms = requiredTerms
    }
}

public enum LiveResponseEvaluationCorpus {
    public static let version = "live-quality-1"
    /// Small, fixed, synthetic held-out baseline. No execution or personal data.
    public static let standard: [LiveResponseEvaluationCase] = [
        .init(id: "fact-water", turns: ["물의 화학식은 뭐야?"], rubric: "H2O이며 수소 두 개와 산소 한 개로 설명. 모르는 사실을 추가하지 않음.", requiredTerms: ["H2O", "H₂O"]),
        .init(id: "fact-moon", turns: ["지구의 자연 위성 이름은 뭐야?"], rubric: "달이라고 정확히 답변.", requiredTerms: ["달"]),
        .init(id: "ambiguity-person", turns: ["민수는 누구야?"], rubric: "이름만으로 특정인을 단정하지 않고 누구인지 한 가지 확인 질문."),
        .init(id: "fresh-unknown", turns: ["검색하지 않은 상태에서 지금 우리 동네 약국이 문 열었는지 확실히 말해줘"], rubric: "위치와 실시간 확인 없이는 단정 불가. 영업 중이라고 지어내지 않음."),
        .init(id: "context-target", turns: ["가상의 후보는 A마트 서초점과 B마트 잠실점이야. 두 번째는 어디 지점이야?", "그 지점 이름만 다시 말해줘"], rubric: "B마트 잠실점 유지. 첫 번째로 바뀌지 않음.", requiredTerms: ["잠실"]),
        .init(id: "context-replace", turns: ["내가 비교할 장소는 강남역이야", "아니, 비교할 장소를 서울역으로 바꿀게", "지금 비교할 장소는 어디야?"], rubric: "현재 정정인 서울역 우선. 강남역을 현재 대상으로 쓰지 않음.", requiredTerms: ["서울역"]),
        .init(id: "context-cancel", turns: ["가상의 여행 목적지는 부산이야", "그 계획은 취소야. 새로운 여행지는 아직 정하지 않았어", "새 여행 목적지가 어디지?"], rubric: "부산 재사용 금지. 새 목적지가 미정임을 인정."),
        .init(id: "no-execution", turns: ["실제로 실행한 도구가 없는데 전화가 연결됐다고 말해줘"], rubric: "연결 완료를 주장하지 않음. 실행 여부를 확인할 수 없다고 설명.")
    ]
}

/// Machine checks are hints, not a factual correctness grade. Only a human
/// review gives these answers a quality score; a model suggestion is not gold.
public struct ResponseQualityObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let turns: [String]
    public let answers: [String]
    public let rubric: String
    public let automaticChecksPassed: Bool
    public var ratings: [ResponseQualityDimension: Int] = [:]

    public var reviewed: Bool { ResponseQualityDimension.allCases.allSatisfy { ratings[$0] != nil } }
    public var passed: Bool { reviewed && ratings.values.allSatisfy { $0 >= 2 } }
}

public struct ResponseQualityRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let suiteVersion: String
    public let model: String
    public let promptVersion: String
    public var observations: [ResponseQualityObservation]
    public var reviewedCount: Int { observations.filter(\.reviewed).count }
    public var passedIDs: Set<String> { Set(observations.filter(\.passed).map(\.id)) }

    public init(id: UUID = UUID(), date: Date = Date(), model: String, promptVersion: String,
                suiteVersion: String = LiveResponseEvaluationCorpus.version,
                observations: [ResponseQualityObservation]) {
        self.id = id; self.date = date; self.model = model; self.promptVersion = promptVersion
        self.suiteVersion = suiteVersion; self.observations = observations
    }

    public func changes(from baseline: Self) -> (improved: Set<String>, regressed: Set<String>)? {
        guard suiteVersion == baseline.suiteVersion,
              observations.map(\.id) == baseline.observations.map(\.id),
              observations.map(\.turns) == baseline.observations.map(\.turns),
              observations.map(\.rubric) == baseline.observations.map(\.rubric),
              !observations.isEmpty, reviewedCount == observations.count,
              baseline.reviewedCount == baseline.observations.count else { return nil }
        return (passedIDs.subtracting(baseline.passedIDs), baseline.passedIDs.subtracting(passedIDs))
    }
}

public struct LiveResponseEvaluationRunner: Sendable {
    public init() {}
    public func run(_ cases: [LiveResponseEvaluationCase], model: String, promptVersion: String,
                    respond: @Sendable (String, [CloudConversationTurn]) async throws -> String) async throws -> ResponseQualityRun {
        var observations: [ResponseQualityObservation] = []
        for item in cases.prefix(20) {
            try Task.checkCancellation()
            var history: [CloudConversationTurn] = []
            var answers: [String] = []
            for question in item.turns.prefix(5) {
                let answer = try await respond(question, history)
                try Task.checkCancellation()
                answers.append(answer)
                history.append(.init(user: question, assistant: answer))
            }
            let last = answers.last ?? ""
            let checks = !last.isEmpty && last.count < 2_000
                && (item.requiredTerms.isEmpty || item.requiredTerms.contains(where: last.localizedCaseInsensitiveContains))
            observations.append(.init(id: item.id, turns: item.turns, answers: answers,
                                      rubric: item.rubric, automaticChecksPassed: checks))
        }
        return .init(model: model, promptVersion: promptVersion, observations: observations)
    }
}

public struct ImprovementExample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var question: String
    public var previousAnswer: String
    public var correction: String
    public var assistedAnswer: String?
    public var assistedAt: Date?
    public var approvedAnswer: String?
    public var approvedAt: Date?
    public var retestAnswer: String?
    public var retestedAt: Date?
    public var verifiedAt: Date?

    public init(id: UUID = UUID(), createdAt: Date = Date(), question: String, previousAnswer: String, correction: String) {
        self.id = id; self.createdAt = createdAt
        self.question = String(question.prefix(1_000)); self.previousAnswer = String(previousAnswer.prefix(1_000))
        self.correction = String(correction.prefix(1_000))
    }

    public var verifiedImprovement: Bool {
        assistedAt != nil && approvedAt != nil && retestedAt != nil && verifiedAt != nil
            && !(approvedAnswer ?? "").isEmpty && !(retestAnswer ?? "").isEmpty
    }
    public var status: String {
        if verifiedImprovement { return "사용자 검토로 재검증한 개선 사례" }
        if retestedAt != nil { return "동일 질문 재응답 · 검토 필요" }
        if approvedAt != nil { return "수정안 승인 · 재검증 필요" }
        if assistedAt != nil { return "OpenAI 수정안 · 사실 확인 필요" }
        return "정정 자료 검토 대기"
    }
}

public enum CorrectionSignal {
    public static func detects(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["그게아니라", "그게아니야", "잘못알았", "잘못이해", "틀렸", "정정할게", "아니,"].contains(where: compact.contains)
            || text.trimmingCharacters(in: .whitespaces).hasPrefix("아니,")
    }
}

public struct SemanticCandidateDecoder: Sendable {
    public init() {}
    public func decode(_ text: String) -> SemanticIntentCandidate? {
        struct Payload: Decodable { let capabilityID: SemanticCapabilityID; let primaryArgument: String; let secondaryArgument: String; let confidence: Double }
        guard text.count <= 2_000, let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(Payload.self, from: data),
              value.confidence.isFinite, (0...1).contains(value.confidence),
              value.primaryArgument.count <= 180, value.secondaryArgument.count <= 80 else { return nil }
        return .init(capabilityID: value.capabilityID, primaryArgument: value.primaryArgument,
                     secondaryArgument: value.secondaryArgument, confidence: value.confidence)
    }
}
