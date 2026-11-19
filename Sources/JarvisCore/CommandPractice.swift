import Foundation

/// Synthetic, non-personal seeds. Usage is counted by these identifiers, never
/// by storing real utterances, destinations, contacts or search arguments.
public struct CommandPracticeSeed: Identifiable, Equatable, Sendable {
    public let id: String
    public let command: String
    public let target: PracticeInterpretation

    public static let standard: [Self] = [
        .init(id: "weather.summary", command: "오늘 날씨 알려줘", target: .init(capability: .weather, secondary: "summary")),
        .init(id: "weather.current", command: "현재 기온 알려줘", target: .init(capability: .weather, secondary: "current")),
        .init(id: "weather.rain", command: "오늘 비 올 확률 알려줘", target: .init(capability: .weather, secondary: "rain")),
        .init(id: "weather.umbrella", command: "오늘 우산 필요해?", target: .init(capability: .weather, secondary: "umbrella")),
        .init(id: "calendar.today", command: "오늘 일정 알려줘", target: .init(capability: .calendar, secondary: "today")),
        .init(id: "calendar.next", command: "다음 일정 알려줘", target: .init(capability: .calendar, secondary: "next")),
        .init(id: "time.time", command: "지금 몇 시야?", target: .init(capability: .time, secondary: "time")),
        .init(id: "time.date", command: "오늘 날짜 알려줘", target: .init(capability: .time, secondary: "date")),
        .init(id: "briefing", command: "현재 브리핑해줘", target: .init(capability: .fullBriefing)),
        .init(id: "identifySong", command: "지금 이 노래 뭐야?", target: .init(capability: .identifySong)),
        .init(id: "pauseMedia", command: "음악 재생 멈춰줘", target: .init(capability: .pauseMedia)),
        .init(id: "volume", command: "볼륨 30퍼센트로 해줘", target: .init(capability: .setVolume, primary: "30")),
        .init(id: "nearby.market", command: "근처 마트 찾아줘", target: .init(capability: .nearbyPlaces, primary: "market", secondary: "search")),
        .init(id: "nearby.pharmacy", command: "근처 약국 찾아줘", target: .init(capability: .nearbyPlaces, primary: "pharmacy", secondary: "search")),
        .init(id: "youtube", command: "유튜브에서 별빛 노래 틀어줘", target: .init(capability: .playYouTube, primary: "별빛 노래")),
        .init(id: "navigation", command: "서울역까지 자가용으로 안내해줘", target: .init(capability: .navigate, primary: "서울역", secondary: "car"))
    ]

    public static func matching(_ intent: AssistantIntent) -> Self? {
        // Dynamic arguments are mapped to a fixed synthetic seed, not retained.
        switch intent {
        case .playYouTube: return standard.first { $0.id == "youtube" }
        case .navigate: return standard.first { $0.id == "navigation" }
        case .setVolume: return standard.first { $0.id == "volume" }
        default: return standard.first { $0.target.intent == intent }
        }
    }
}

public struct PracticeInterpretation: Codable, Equatable, Sendable {
    public let capability: SemanticCapabilityID
    public let primary: String
    public let secondary: String
    public init(capability: SemanticCapabilityID, primary: String = "", secondary: String = "") {
        self.capability = capability; self.primary = primary; self.secondary = secondary
    }
    public var candidate: SemanticIntentCandidate {
        .init(capabilityID: capability, primaryArgument: primary, secondaryArgument: secondary, confidence: 1)
    }
    public var intent: AssistantIntent? {
        guard case .intent(let intent) = CapabilityRegistry().resolve(candidate, originalText: "연습 문항") else { return nil }
        return intent
    }
    public var label: String {
        let title: String
        switch capability {
        case .weather: title = "날씨 조회"
        case .calendar: title = "일정 조회"
        case .time: title = "시간·날짜 조회"
        case .fullBriefing: title = "종합 브리핑"
        case .identifySong: title = "노래 식별"
        case .pauseMedia: title = "미디어 정지"
        case .setVolume: title = "볼륨 설정"
        case .nearbyPlaces: title = "주변 장소 검색"
        case .playYouTube: title = "YouTube 재생"
        case .navigate: title = "길 안내"
        default: title = capability.rawValue
        }
        return [title, primary, secondary].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public enum PracticeDecision: String, Codable, Sendable { case pending, applied, rejected, revoked }
public enum PracticePhase: String, Codable, Sendable { case queued, generated, evaluated, failed, cancelled }
public enum PracticeReplyKind: String, Codable, Sendable {
    case executionPreview, clarification, localConversation, unavailable, simulatedTranscript
}

public struct PracticeResponseStep: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable { case progress, result, suggestion, confirmation }
    public let id: Int
    public let stage: Stage
    public let text: String
    public init(id: Int, stage: Stage, text: String) { self.id = id; self.stage = stage; self.text = text }
}

/// A dry-run utterance derived from the student's actual interpretation,
/// never from the answer key. Does not query facts or execute a device tool.
public enum PracticeResponsePreview {
    public static func text(for resolution: AgentResolution, locked: Bool = false) -> String {
        guard case .intent(let resolved) = resolution else {
            if case .clarification(let prompt) = resolution { return prompt }
            return "요청을 다시 말씀해주시겠어요?"
        }
        let origin: SafetyExecutionOrigin = resolved.source == .semanticModel ? .modelProposed : .directUserRequest
        switch SafetyPolicyEngine().evaluate(resolved.intent, context: .init(origin: origin, externalActionsLocked: locked)) {
        case .block(_, _, let reason): return reason
        case .requireConfirmation(_, _, let prompt): return prompt
        case .allow: break
        }
        switch resolved.intent {
        case .weather: return "날씨를 확인해서 알려드릴게요."
        case .calendar, .calendarWorkflow: return "요청하신 일정을 확인해드릴게요."
        case .time: return "현재 시간과 날짜를 확인해서 알려드릴게요."
        case .fullBriefing: return "날씨와 일정을 확인해서 브리핑해드릴게요."
        case .identifySong: return "노래를 찾아볼게요."
        case .pauseMedia: return "재생 중인 음악을 멈출게요."
        case .setVolume(let percent): return "볼륨을 \(percent)퍼센트로 조절할게요."
        case .adjustVolume(let delta): return "볼륨을 \(abs(delta))퍼센트만큼 \(delta >= 0 ? "높일게요" : "낮출게요")."
        case .nearbyPlaces(let category, _, _): return "근처 \(category.title)을 찾아서 알려드릴게요."
        case .navigate(let destination, let mode):
            guard let mode else { return "\(destination)까지 자가용과 대중교통 중 어떤 방법으로 안내할까요?" }
            return "\(destination)까지 \(mode == .car ? "자가용" : "대중교통") 경로를 확인할게요."
        case .playYouTube(let query): return "유튜브에서 \(query) 검색 결과를 열 준비를 할게요."
        case .playYouTubePlaylist(let name): return "\(name) 재생목록을 확인할게요."
        case .recommendRestaurants: return "주변 음식점을 찾아드릴게요."
        case .webSearch: return "인터넷에서 검색한 뒤 핵심 내용을 알려드릴게요."
        case .call(let recipient, _): return "\(recipient)에게 전화 연결을 요청할게요."
        case .openApp(let name): return "\(name) 앱을 열 준비를 할게요."
        case .assistantCapabilities: return "날씨와 일정 확인, 음악 찾기, 주변 장소 검색 등을 도와드릴 수 있어요."
        case .dismissConversation: return "알겠습니다."
        case .unknownCommand: return "어떤 작업을 원하시는지 조금 더 자세히 말씀해주시겠어요?"
        case .generalConversation: return "말씀하신 내용에 대해 답변을 준비할게요."
        case .prepareOuting: return "일정과 날씨를 확인해서 외출 준비를 도와드릴게요."
        case .setAlarm: return "알림 시간과 내용을 확인할게요."
        case .stopActiveAlarm: return "현재 울리는 알람을 확인하고 종료할게요."
        case .listAlarms: return "등록된 알람을 확인해드릴게요."
        case .cancelAlarm, .updateAlarm: return "변경할 알람을 확인할게요."
        case .remember, .forgetMemory, .listMemories, .resolveMemoryConflict:
            return "요청하신 기억을 확인할게요."
        case .projectWorkflow, .sharedProject, .codexLocal, .macWorkspace, .localData, .configureCloudAI, .disableCloudAI, .configureImprovementCollection, .reviewImprovementData,
             .deleteImprovementData, .assistImprovementData, .runResponseEvaluation, .configureCommandPractice,
             .runCommandPractice, .applyCommandPractice, .removeCommandPractice:
            return "이 설정은 설정 화면에서 직접 확인해주세요."
        }
    }
}

public struct CommandPracticeItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let seedID: String
    public let seedCommand: String
    public let expected: PracticeInterpretation
    public var question = ""
    public var technique = ""
    public var phase = PracticePhase.queued
    public var studentConclusion = "아직 판단하지 않음"
    public var studentMatched: Bool?
    public var studentReply: String?
    public var studentReplyKind: PracticeReplyKind?
    public var studentTranscript: [PracticeResponseStep]?
    public var responseScenario: String?
    public var teacher: PracticeInterpretation?
    public var teacherReason = ""
    public var teacherConfidence: Double?
    public var failureReason: String?
    public var decision = PracticeDecision.pending
    public var reviewedAt: Date?
    public var postApplicationConclusion: String?

    public init(id: UUID = UUID(), seed: CommandPracticeSeed) {
        self.id = id; seedID = seed.id; seedCommand = seed.command; expected = seed.target
    }
}

public struct CommandPracticeBatch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let teacherModel: String
    public let studentDescription: String
    public let version: String
    public var finishedAt: Date?
    public var apiRequests: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var inputUSDPerMillion: Double?
    public var outputUSDPerMillion: Double?
    public var estimatedCostUSD: Double? {
        guard let inputUSDPerMillion, let outputUSDPerMillion,
              inputUSDPerMillion.isFinite, outputUSDPerMillion.isFinite,
              inputUSDPerMillion > 0, outputUSDPerMillion > 0 else { return nil }
        return (Double(inputTokens ?? 0) * inputUSDPerMillion + Double(outputTokens ?? 0) * outputUSDPerMillion) / 1_000_000
    }
    public var items: [CommandPracticeItem]
    public var evaluatedCount: Int { items.filter { $0.phase == .evaluated }.count }
    public init(seeds: [CommandPracticeSeed], teacherModel: String, studentDescription: String) {
        id = UUID(); createdAt = Date(); self.teacherModel = teacherModel; self.studentDescription = studentDescription
        version = "command-practice-1"; items = seeds.map { .init(seed: $0) }
    }
}

/// Curated application tests, never supplied to the generator, teacher or
/// approved-example library. Repeated use is a regression check, not proof
/// of unrestricted generalization or model-weight training.
public enum PracticeHoldout {
    public static let version = "private-command-holdout-1"
    public static let cases: [(text: String, target: PracticeInterpretation)] = [
        ("오늘 하루 날씨가 어떨지 설명해 줄래", .init(capability: .weather, secondary: "summary")),
        ("지금 공기의 차가운 정도를 수치로 들려줄 수 있을까", .init(capability: .weather, secondary: "current")),
        ("오늘 우산 챙겨야 할까", .init(capability: .weather, secondary: "umbrella")),
        ("지금 정확히 몇 시인지 궁금해", .init(capability: .time, secondary: "time")),
        ("오늘이 며칠인지 말해 줄래", .init(capability: .time, secondary: "date")),
        ("오늘 잡힌 일정 좀 확인해 줄래", .init(capability: .calendar, secondary: "today")),
        ("다음으로 잡힌 일정이 뭔지 알려 줄래", .init(capability: .calendar, secondary: "next")),
        ("이 음악의 제목 좀 알아봐 줄 수 있어", .init(capability: .identifySong)),
        ("재생 중인 음악 좀 멈춰 줄래", .init(capability: .pauseMedia)),
        ("이 주변에 있는 마트들을 찾아 줄래", .init(capability: .nearbyPlaces, primary: "market", secondary: "search")),
        ("가까운 약국들을 찾아 줄 수 있어", .init(capability: .nearbyPlaces, primary: "pharmacy", secondary: "search")),
        ("소리 크기를 30퍼센트로 설정해 줄래", .init(capability: .setVolume, primary: "30"))
    ]
    public static func contains(_ text: String) -> Bool {
        func reservedKey(_ value: String) -> String {
            value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        }
        return cases.contains { reservedKey($0.text) == reservedKey(text) }
    }
}

public struct PracticeHoldoutObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let before: String
    public let after: String
    public let beforeMatched: Bool
    public let afterMatched: Bool
    public init(id: Int, before: String, after: String, beforeMatched: Bool, afterMatched: Bool) {
        self.id = id; self.before = before; self.after = after
        self.beforeMatched = beforeMatched; self.afterMatched = afterMatched
    }
}

public struct PracticeValidationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public let corpusVersion: String
    public let candidateID: UUID
    public let regressionTotal: Int
    public let beforePassed: Int
    public let afterPassed: Int
    public let holdoutTotal: Int
    public let holdoutBefore: Int
    public let holdoutAfter: Int
    public let newFailures: Int
    public let safetyPassed: Bool
    public var observations: [PracticeHoldoutObservation]?
    public var holdoutDelta: Int { holdoutAfter - holdoutBefore }
    public var permitted: Bool {
        regressionTotal >= 300 && Double(afterPassed) / Double(regressionTotal) >= 0.95
            && newFailures == 0 && safetyPassed
    }
    public init(candidateID: UUID, regressionTotal: Int, beforePassed: Int, afterPassed: Int,
                holdoutTotal: Int, holdoutBefore: Int, holdoutAfter: Int, newFailures: Int, safetyPassed: Bool) {
        self.corpusVersion = CommandEvaluationCorpus.realisticV2Version + "/" + PracticeHoldout.version
        self.candidateID = candidateID; self.regressionTotal = regressionTotal
        self.beforePassed = beforePassed; self.afterPassed = afterPassed
        self.holdoutTotal = holdoutTotal; self.holdoutBefore = holdoutBefore; self.holdoutAfter = holdoutAfter
        self.newFailures = newFailures; self.safetyPassed = safetyPassed
    }
}

public struct PracticeLibraryRevision: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public let examples: [ApprovedCommandExample]
    public let enabled: Bool
    public init(examples: [ApprovedCommandExample], enabled: Bool) {
        self.examples = examples; self.enabled = enabled
    }
}

public struct ApprovedCommandExample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let question: String
    public let interpretation: PracticeInterpretation
    public let approvedAt: Date
    public let version: String
    public init(item: CommandPracticeItem) {
        id = item.id; question = item.question; interpretation = item.expected
        approvedAt = Date(); version = "command-practice-1"
    }
}

public enum CommandPracticeValidation {
    public static func containsCancellation(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["하지마", "하지말", "취소", "하지않", "안해", "말고", "아니라", "거절", "그만"].contains(where: compact.contains)
    }
    public static func containsUnresolvedReference(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["그거", "이거", "저거", "그곳", "거기", "그사람", "그노래", "아까", "방금", "그중", "두번째", "첫번째"].contains(where: compact.contains)
    }
    public static func key(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func hasBoundArguments(_ text: String, target: PracticeInterpretation) -> Bool {
        let compact = key(text).filter { !$0.isWhitespace && !$0.isPunctuation }
        switch target.capability {
        case .navigate, .playYouTube:
            let argument = key(target.primary).filter { !$0.isWhitespace && !$0.isPunctuation }
            return !argument.isEmpty && compact.contains(argument)
        case .setVolume:
            return compact.contains("30") || compact.contains("삼십") || compact.contains("서른")
        default: return true
        }
    }

    public static func variant(_ json: String) -> (text: String, technique: String)? {
        struct Value: Decodable { let text: String; let technique: String }
        guard json.count <= 1_500, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              (3...180).contains(value.text.count), value.technique.count <= 60,
              !value.text.contains("\n"),
              !["http", "@", "비밀번호", "api키", "시스템지시", "안전정책", "권한변경", "잠금해제"].contains(where: key(value.text).contains) else { return nil }
        return (value.text, value.technique)
    }

    public static func teacher(_ json: String) -> (interpretation: PracticeInterpretation, confidence: Double, reason: String)? {
        struct Value: Decodable {
            let capabilityID: SemanticCapabilityID
            let primaryArgument: String
            let secondaryArgument: String
            let confidence: Double
            let reason: String
        }
        guard json.count <= 2_000, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              value.primaryArgument.count <= 180, value.secondaryArgument.count <= 80,
              value.confidence.isFinite, (0...1).contains(value.confidence), value.reason.count <= 500 else { return nil }
        return (.init(capability: value.capabilityID, primary: value.primaryArgument, secondary: value.secondaryArgument), value.confidence, value.reason)
    }

    /// No arbitrary model capability/argument can be installed. The teacher
    /// must agree with the immutable synthetic seed AND the user's decision.
    public static func applicationBlockReason(_ item: CommandPracticeItem, approved: [ApprovedCommandExample]) -> String? {
        guard !PracticeHoldout.contains(item.question) else {
            return "별도 평가 문장은 연습·적용 자료로 사용할 수 없습니다."
        }
        guard item.phase == .evaluated, item.teacherConfidence ?? 0 >= 0.8,
              let seed = CommandPracticeSeed.standard.first(where: { $0.id == item.seedID }),
              seed.command == item.seedCommand, seed.target == item.expected,
              item.teacher == seed.target, let expected = seed.target.intent else {
            return "교사 판단과 고정 기준이 일치하지 않거나 평가가 완료되지 않아 적용할 수 없습니다."
        }
        guard (3...180).contains(item.question.count), !containsCancellation(item.question),
              !containsUnresolvedReference(item.question) else {
            return "취소·부정·대상 변경·이전 문맥이 필요한 문항은 독립 명령 예제로 적용하지 않습니다."
        }
        guard hasBoundArguments(item.question, target: seed.target) else {
            return "문장에 목적지·검색 대상·볼륨 수치가 없어 고정 예제의 인자를 임의로 적용할 수 없습니다."
        }
        let routed = CommandRouter().route(item.question)
        switch routed {
        case .generalConversation, .unknownCommand: break
        default:
            if routed != expected { return "기존 명령과 충돌합니다. 사용자 승인으로 기존 라우터를 덮어쓰지 않습니다. 코드 수정이 필요한 사례입니다." }
        }
        if approved.contains(where: { key($0.question) == key(item.question) && $0.interpretation != seed.target }) {
            return "이미 승인한 다른 해석과 충돌합니다. 기존 적용을 먼저 철회해주세요."
        }
        return nil
    }

    public static func approvedCandidate(for text: String, examples: [ApprovedCommandExample]) -> SemanticIntentCandidate? {
        // Quarantine legacy overlap too; a reserved test must never succeed
        // because an old library happened to contain its exact wording.
        guard !PracticeHoldout.contains(text) else { return nil }
        // Never normalize punctuation away, use fuzzy similarity, or execute.
        // Router-first behaviour is enforced again at this boundary.
        switch CommandRouter().route(text) {
        case .generalConversation, .unknownCommand: break
        default: return nil
        }
        guard !containsCancellation(text), !containsUnresolvedReference(text) else { return nil }
        let matches = examples.filter { key($0.question) == key(text) && $0.version == "command-practice-1" }
        guard let first = matches.first, matches.allSatisfy({ $0.interpretation == first.interpretation }),
              CommandPracticeSeed.standard.contains(where: { $0.target == first.interpretation }),
              hasBoundArguments(text, target: first.interpretation) else { return nil }
        return first.interpretation.candidate
    }

    public static func conclusion(_ result: AgentResolution) -> String {
        switch result {
        case .clarification(let text): return "재질문: " + String(text.prefix(300))
        case .intent(let value):
            if let seed = CommandPracticeSeed.standard.first(where: { $0.target.intent == value.intent }) { return seed.target.label }
            return String(describing: value.intent)
        }
    }

    public static func matches(_ result: AgentResolution, expected: PracticeInterpretation) -> Bool {
        guard case .intent(let value) = result else { return false }
        return value.intent == expected.intent
    }
}
