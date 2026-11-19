import Foundation

public struct SafetyConfirmationDialogue: Equatable, Sendable {
    public let intent: AssistantIntent
    public let originalText: String
    public let actionName: String
    public let risk: ActionRiskLevel
    public let origin: SafetyExecutionOrigin
    public let navigationCandidate: NavigationDestinationCandidate?

    public init(
        intent: AssistantIntent,
        originalText: String,
        actionName: String,
        risk: ActionRiskLevel,
        origin: SafetyExecutionOrigin,
        navigationCandidate: NavigationDestinationCandidate? = nil
    ) {
        self.intent = intent
        self.originalText = originalText
        self.actionName = actionName
        self.risk = risk
        self.origin = origin
        self.navigationCandidate = navigationCandidate
    }
}

public struct NavigationModeDialogue: Equatable, Sendable {
    public let destination: String
    public let originalText: String

    public init(destination: String, originalText: String) {
        self.destination = destination
        self.originalText = originalText
    }
}

public struct NavigationDestinationCandidate: Equatable, Sendable {
    public let name: String
    public let area: String
    public let latitude: Double
    public let longitude: Double
    public let sourceLatitude: Double
    public let sourceLongitude: Double
    public let straightLineDistance: Double

    public init(
        name: String,
        area: String,
        latitude: Double,
        longitude: Double,
        sourceLatitude: Double,
        sourceLongitude: Double,
        straightLineDistance: Double
    ) {
        self.name = name
        self.area = area
        self.latitude = latitude
        self.longitude = longitude
        self.sourceLatitude = sourceLatitude
        self.sourceLongitude = sourceLongitude
        self.straightLineDistance = straightLineDistance
    }
}

public struct NavigationDestinationSelectionDialogue: Equatable, Sendable {
    public let query: String
    public let originalText: String
    public let mode: NavigationTravelMode
    public let candidates: [NavigationDestinationCandidate]

    public init(
        query: String,
        originalText: String,
        mode: NavigationTravelMode,
        candidates: [NavigationDestinationCandidate]
    ) {
        self.query = query
        self.originalText = originalText
        self.mode = mode
        self.candidates = candidates
    }
}

public struct NavigationDestinationSelectionResolver: Sendable {
    public init() {}

    public func resolve(
        _ text: String,
        candidates: [NavigationDestinationCandidate]
    ) -> NavigationDestinationCandidate? {
        let compact = compactText(text).replacingOccurrences(
            of: #"^(그게아니라|아니)"#, with: "", options: .regularExpression)
        // A complete request for a different place must not be captured by an
        // ordinal prefix or the old candidate's area (e.g. 강남구청 ≠ 강남구).
        if case .navigate(let target, _) = CommandRouter().route(text) {
            let key = compactText(target)
            let exact = candidates.filter { compactText($0.name) == key }
            if exact.count == 1 { return exact[0] }
            if !Self.isOrdinalAnswer(key) { return nil }
        } else if case .replace = DialogueInputResolver().classify(text) {
            return nil
        }
        let ordinalTerms = [
            ["1", "1번", "첫번째", "첫째", "하나"],
            ["2", "2번", "두번째", "둘째", "둘"],
            ["3", "3번", "세번째", "셋째", "셋"],
            ["4", "4번", "네번째", "넷째", "넷"],
            ["5", "5번", "다섯번째", "다섯째", "다섯"]
        ]
        let matchesByNumber = ordinalTerms.indices.filter { index in
            ordinalTerms[index].contains { term in
                compact == term || Self.ordinalSuffixes.contains { compact == term + $0 }
            }
        }
        if matchesByNumber.count == 1, let index = matchesByNumber.first,
           candidates.indices.contains(index) { return candidates[index] }
        if !matchesByNumber.isEmpty { return nil }

        let matches = candidates.filter { candidate in
            let candidateName = compactText(candidate.name)
            let nameMatches = compact.count >= 2
                && (candidateName.contains(compact) || compact.contains(candidateName))
            let areaTerms = candidate.area
                .split(whereSeparator: { $0.isWhitespace })
                .map { compactText(String($0)) }
                .filter { $0.count >= 2 }
            return nameMatches || areaTerms.contains(where: compact.contains)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func compactText(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private static let ordinalSuffixes = ["으로", "로", "요", "으로가줘", "로가줘", "으로안내해줘", "로안내해줘", "장소", "장소로안내해줘"]

    private static func isOrdinalAnswer(_ text: String) -> Bool {
        let terms = ["1", "2", "3", "4", "5", "1번", "2번", "3번", "4번", "5번",
                     "첫번째", "두번째", "세번째", "네번째", "다섯번째", "첫째", "둘째", "셋째", "넷째", "다섯째", "하나", "둘", "셋", "넷", "다섯"]
        return terms.contains { term in text == term || ordinalSuffixes.contains { text == term + $0 } }
    }
}

public enum AlarmSelectionOperation: Equatable, Sendable {
    case cancel
    case update(AlarmUpdate)
}

public struct AlarmSelectionDialogue: Equatable, Sendable {
    public let candidateIDs: [UUID]
    public let operation: AlarmSelectionOperation

    public init(candidateIDs: [UUID], operation: AlarmSelectionOperation) {
        self.candidateIDs = candidateIDs
        self.operation = operation
    }
}

public enum PendingDialogueTask: Equatable, Sendable {
    case projectNote(text: String, sessionID: UUID)
    case calendarDraft(CalendarEventDraft)
    case calendarEventSelection(draft: CalendarEventDraft, ids: [UUID])
    case nearbyPlaces(NearbyPlaceDialogue)
    case safetyConfirmation(SafetyConfirmationDialogue)
    case navigationMode(NavigationModeDialogue)
    case navigationDestinationSelection(NavigationDestinationSelectionDialogue)
    case memorySuggestion(String)
    case sensitiveMemoryRequest(String)
    case alarmSelection(AlarmSelectionDialogue)
}

public enum DialogueInputDisposition: Equatable, Sendable {
    /// The user explicitly cancelled the active task.
    case cancel
    /// The utterance is a plausible answer to the one active question.
    case answer
    /// A complete new command supersedes the active task.
    case replace(with: AssistantIntent)
}

/// Classifies an utterance without borrowing the last completed intent. This is
/// deliberately conservative: an incomplete or conversational answer stays in
/// the active dialogue, while a complete deterministic command replaces it.
/// It prevents stale destinations, contacts and confirmations from capturing a
/// new request merely because both requests belong to the same command family.
public struct DialogueInputResolver: Sendable {
    private let router: CommandRouter

    public init(router: CommandRouter = CommandRouter()) {
        self.router = router
    }

    public func classify(_ text: String) -> DialogueInputDisposition {
        let intent = router.route(text, previousIntent: nil)
        if intent == .dismissConversation { return .cancel }
        switch intent {
        case .generalConversation, .unknownCommand:
            return .answer
        default:
            return .replace(with: intent)
        }
    }
}

public struct PendingDialogue: Equatable, Sendable {
    public let id: UUID
    public let task: PendingDialogueTask
    public let startedAt: Date
    public private(set) var retryCount: Int

    fileprivate init(task: PendingDialogueTask, startedAt: Date) {
        id = UUID()
        self.task = task
        self.startedAt = startedAt
        retryCount = 0
    }

    fileprivate mutating func registerRetry() {
        retryCount += 1
    }

    fileprivate init(id: UUID, task: PendingDialogueTask, startedAt: Date, retryCount: Int) {
        self.id = id; self.task = task; self.startedAt = startedAt; self.retryCount = retryCount
    }
}

/// Owns exactly one active multi-turn task. Starting a new task cancels the old
/// one, and stale or repeatedly misunderstood tasks are discarded instead of
/// leaking context into unrelated commands.
public struct DialogueStateManager: Sendable {
    public let timeout: TimeInterval
    public let maximumRetries: Int
    private var pending: PendingDialogue?

    public init(timeout: TimeInterval = 120, maximumRetries: Int = 2) {
        self.timeout = max(10, timeout)
        self.maximumRetries = max(0, maximumRetries)
    }

    public var hasPendingTask: Bool { pending != nil }

    @discardableResult
    public mutating func begin(
        _ task: PendingDialogueTask,
        now: Date = Date()
    ) -> PendingDialogue {
        let dialogue = PendingDialogue(task: task, startedAt: now)
        pending = dialogue
        return dialogue
    }

    public mutating func current(now: Date = Date()) -> PendingDialogue? {
        guard let pending else { return nil }
        guard now.timeIntervalSince(pending.startedAt) <= timeout else {
            self.pending = nil
            return nil
        }
        return pending
    }

    @discardableResult
    public mutating func registerRetry(now: Date = Date()) -> PendingDialogue? {
        guard var current = current(now: now) else { return nil }
        guard current.retryCount < maximumRetries else {
            pending = nil
            return nil
        }
        current.registerRetry()
        pending = current
        return current
    }

    /// Refine one task without extending its original expiry or retry budget.
    public mutating func updateNearbyPlaces(_ value: NearbyPlaceDialogue, now: Date = Date()) {
        guard let current = current(now: now), case .nearbyPlaces = current.task else { return }
        pending = PendingDialogue(id: current.id, task: .nearbyPlaces(value),
                                  startedAt: current.startedAt, retryCount: current.retryCount)
    }

    public mutating func updateCalendarDraft(_ value: CalendarEventDraft, now: Date = Date()) {
        guard let current = current(now: now), case .calendarDraft = current.task else { return }
        pending = PendingDialogue(id: current.id, task: .calendarDraft(value), startedAt: current.startedAt, retryCount: current.retryCount)
    }

    @discardableResult
    public mutating func complete() -> PendingDialogue? {
        defer { pending = nil }
        return pending
    }

    public mutating func cancel() {
        pending = nil
    }
}

public struct ConversationScenarioTurn: Equatable, Sendable {
    public let input: String
    public let expectedIntent: AssistantIntent

    public init(input: String, expectedIntent: AssistantIntent) {
        self.input = input
        self.expectedIntent = expectedIntent
    }
}

public struct ConversationEvaluationScenario: Equatable, Sendable {
    public let id: String
    public let turns: [ConversationScenarioTurn]

    public init(id: String, turns: [ConversationScenarioTurn]) {
        self.id = id
        self.turns = turns
    }
}

public struct ConversationScenarioFailure: Equatable, Sendable {
    public let scenarioID: String
    public let turnIndex: Int
    public let input: String
    public let expected: AssistantIntent
    public let actual: AssistantIntent
}

public struct ConversationScenarioReport: Equatable, Sendable {
    public let scenarioCount: Int
    public let turnCount: Int
    public let passedTurnCount: Int
    public let failures: [ConversationScenarioFailure]

    public var passRate: Double {
        guard turnCount > 0 else { return 1 }
        return Double(passedTurnCount) / Double(turnCount)
    }

    public var passed: Bool { passRate >= 0.95 }
}

/// Replays complete conversations in order. The actual result of each turn is
/// carried into the next turn, so one bad interpretation can expose cascading
/// stale-context failures instead of evaluating each sentence in isolation.
public struct ConversationScenarioRunner: Sendable {
    private let router: CommandRouter

    public init(router: CommandRouter = CommandRouter()) {
        self.router = router
    }

    public func run(_ scenarios: [ConversationEvaluationScenario]) -> ConversationScenarioReport {
        var failures: [ConversationScenarioFailure] = []
        var totalTurns = 0
        for scenario in scenarios {
            var previousIntent: AssistantIntent?
            for (index, turn) in scenario.turns.enumerated() {
                totalTurns += 1
                let actual = router.route(turn.input, previousIntent: previousIntent)
                if actual != turn.expectedIntent {
                    failures.append(ConversationScenarioFailure(
                        scenarioID: scenario.id,
                        turnIndex: index,
                        input: turn.input,
                        expected: turn.expectedIntent,
                        actual: actual
                    ))
                }
                previousIntent = actual
            }
        }
        return ConversationScenarioReport(
            scenarioCount: scenarios.count,
            turnCount: totalTurns,
            passedTurnCount: totalTurns - failures.count,
            failures: failures
        )
    }
}

public enum ConversationScenarioCorpus {
    public static let standard: [ConversationEvaluationScenario] = {
        var scenarios: [ConversationEvaluationScenario] = []

        let navigationPairs = [
            ("강남역", "서울역"), ("잠실역", "사당역"), ("판교역", "수원역"),
            ("광화문", "홍대입구역"), ("부산역", "대구역"), ("대전역", "광주송정역"),
            ("종로3가역", "여의도역"), ("성수역", "용산역"), ("건대입구역", "왕십리역"),
            ("고속터미널역", "신도림역")
        ]
        for (index, pair) in navigationPairs.enumerated() {
            scenarios.append(ConversationEvaluationScenario(
                id: "navigation-\(index + 1)",
                turns: [
                    .init(
                        input: "\(pair.0)까지 대중교통으로 안내해줘",
                        expectedIntent: .navigate(destination: pair.0, mode: .publicTransit)
                    ),
                    .init(
                        input: "아니 자가용으로 안내해줘",
                        expectedIntent: .navigate(destination: pair.0, mode: .car)
                    ),
                    .init(
                        input: "그런데 \(pair.1)까지 대중교통으로 바꿔줘",
                        expectedIntent: .navigate(destination: pair.1, mode: .publicTransit)
                    )
                ]
            ))
        }

        let songPairs = [
            ("체념", "밤편지"), ("좋은 날", "너랑 나"), ("사랑했지만", "초혼"),
            ("여수 밤바다", "흔들리는 꽃들 속에서"), ("아무노래", "신호등"),
            ("사건의 지평선", "예뻐다"), ("마지막 처럼", "어제처럼"), ("라일락", "스티커 사진"),
            ("프라이드", "다시 만난 날"), ("거짓말 거짓말 거짓말", "기억을 걷는 시간")
        ]
        for (index, pair) in songPairs.enumerated() {
            scenarios.append(ConversationEvaluationScenario(
                id: "youtube-\(index + 1)",
                turns: [
                    .init(
                        input: "유튜브에서 \(pair.0) 틀어줘",
                        expectedIntent: .playYouTube(query: pair.0)
                    ),
                    .init(input: "아까 그 노래 다시", expectedIntent: .playYouTube(query: pair.0)),
                    .init(
                        input: "이번엔 유튜브에서 \(pair.1) 틀어줘",
                        expectedIntent: .playYouTube(query: pair.1)
                    )
                ]
            ))
        }

        let appPairs = [
            ("카카오톡", "인스타그램"), ("유튜브", "네이버지도"), ("네이버", "카메라"),
            ("사진", "메모"), ("설정", "캘린더"), ("음악", "시계"), ("계산기", "날씨"),
            ("전화", "연락처"), ("파일", "메일"), ("단축어", "건강")
        ]
        for (index, pair) in appPairs.enumerated() {
            scenarios.append(ConversationEvaluationScenario(
                id: "application-\(index + 1)",
                turns: [
                    .init(input: "\(pair.0) 앱 열어줘", expectedIntent: .openApp(name: pair.0)),
                    .init(input: "그 앱 다시 열어줘", expectedIntent: .openApp(name: pair.0)),
                    .init(input: "아니 \(pair.1) 앱을 열어줘", expectedIntent: .openApp(name: pair.1))
                ]
            ))
        }

        let weatherOpenings = [
            "오늘 날씨 알려줘", "오늘 날씨가 어때", "밖의 날씨 알려줘", "오늘 날씨 브리핑해줘",
            "오늘의 날씨를 말해줘", "날씨 상태 확인해줘", "오늘 전체 날씨 보여줘", "지금 밖 날씨 어때",
            "오늘은 날씨가 어떻대", "실시간 날씨 알려줘"
        ]
        for (index, opening) in weatherOpenings.enumerated() {
            let followUp: ConversationScenarioTurn = index.isMultiple(of: 2)
                ? .init(input: "그럼 최고는", expectedIntent: .weather(.highTemperature))
                : .init(input: "그럼 최저는", expectedIntent: .weather(.lowTemperature))
            scenarios.append(ConversationEvaluationScenario(
                id: "weather-\(index + 1)",
                turns: [
                    .init(input: opening, expectedIntent: .weather(.todaySummary)),
                    followUp,
                    .init(input: "이제 지금 몇 시인지 알려줘", expectedIntent: .time(.currentTime))
                ]
            ))
        }

        let calendarOpenings = [
            "오늘 일정 알려줘", "오늘 스케줄 보여줘", "오늘 무슨 일정이 있어", "오늘 캘린더 확인해줘",
            "오늘 예정된 일정을 말해줘", "오늘의 전체 일정은", "오늘 할 일이 뭐야", "오늘 일정 브리핑해줘",
            "오늘 캘린더에 뭐가 있어", "오늘 스케줄 요약해줘"
        ]
        for (index, opening) in calendarOpenings.enumerated() {
            scenarios.append(ConversationEvaluationScenario(
                id: "calendar-\(index + 1)",
                turns: [
                    .init(input: opening, expectedIntent: .calendar(.todaySummary)),
                    .init(input: "그럼 다음 일정은", expectedIntent: .calendar(.nextEvent)),
                    .init(input: "일정 말고 오늘 날씨를 알려줘", expectedIntent: .weather(.todaySummary))
                ]
            ))
        }

        return scenarios
    }()
}

public enum DialogueStateScenarioAction: Equatable, Sendable {
    case begin(PendingDialogueTask)
    case inspect
    case retry
    case complete
    case cancel
}

public struct DialogueStateScenarioStep: Equatable, Sendable {
    public let action: DialogueStateScenarioAction
    public let timeOffset: TimeInterval
    public let expectedTask: PendingDialogueTask?
    public let expectedRetryCount: Int?

    public init(
        action: DialogueStateScenarioAction,
        timeOffset: TimeInterval = 0,
        expectedTask: PendingDialogueTask?,
        expectedRetryCount: Int? = nil
    ) {
        self.action = action
        self.timeOffset = timeOffset
        self.expectedTask = expectedTask
        self.expectedRetryCount = expectedRetryCount
    }
}

public struct DialogueStateEvaluationScenario: Equatable, Sendable {
    public let id: String
    public let steps: [DialogueStateScenarioStep]

    public init(id: String, steps: [DialogueStateScenarioStep]) {
        self.id = id
        self.steps = steps
    }
}

public struct DialogueStateScenarioFailure: Equatable, Sendable {
    public let scenarioID: String
    public let stepIndex: Int
    public let expectedTask: PendingDialogueTask?
    public let actualTask: PendingDialogueTask?
    public let expectedRetryCount: Int?
    public let actualRetryCount: Int?
}

public struct DialogueStateScenarioReport: Equatable, Sendable {
    public let scenarioCount: Int
    public let stepCount: Int
    public let passedStepCount: Int
    public let failures: [DialogueStateScenarioFailure]

    public var passRate: Double {
        guard stepCount > 0 else { return 1 }
        return Double(passedStepCount) / Double(stepCount)
    }

    public var passed: Bool { passRate >= 0.95 }
}

/// Exercises the real `DialogueStateManager`, including replacement, explicit
/// cancellation, completion, expiry and retry exhaustion. This complements
/// router-only conversation replay and catches stale approval/context leaks.
public struct DialogueStateScenarioRunner: Sendable {
    public init() {}

    public func run(
        _ scenarios: [DialogueStateEvaluationScenario],
        timeout: TimeInterval = 120,
        maximumRetries: Int = 2
    ) -> DialogueStateScenarioReport {
        let start = Date(timeIntervalSince1970: 1_000)
        var failures: [DialogueStateScenarioFailure] = []
        var stepCount = 0

        for scenario in scenarios {
            var manager = DialogueStateManager(timeout: timeout, maximumRetries: maximumRetries)
            for (index, step) in scenario.steps.enumerated() {
                stepCount += 1
                let now = start.addingTimeInterval(step.timeOffset)
                switch step.action {
                case .begin(let task): manager.begin(task, now: now)
                case .inspect: break
                case .retry: manager.registerRetry(now: now)
                case .complete: manager.complete()
                case .cancel: manager.cancel()
                }
                let current = manager.current(now: now)
                let taskMatches = current?.task == step.expectedTask
                let retryMatches = step.expectedRetryCount == nil
                    || current?.retryCount == step.expectedRetryCount
                if !taskMatches || !retryMatches {
                    failures.append(DialogueStateScenarioFailure(
                        scenarioID: scenario.id,
                        stepIndex: index,
                        expectedTask: step.expectedTask,
                        actualTask: current?.task,
                        expectedRetryCount: step.expectedRetryCount,
                        actualRetryCount: current?.retryCount
                    ))
                }
            }
        }
        return DialogueStateScenarioReport(
            scenarioCount: scenarios.count,
            stepCount: stepCount,
            passedStepCount: stepCount - failures.count,
            failures: failures
        )
    }
}

public enum DialogueStateScenarioCorpus {
    /// Fifty 3–5 step state-machine scenarios. Values are synthetic and contain
    /// no contacts, personal places or other user data.
    public static let standard: [DialogueStateEvaluationScenario] = {
        var scenarios: [DialogueStateEvaluationScenario] = []

        for index in 1...10 {
            let first = PendingDialogueTask.memorySuggestion("선호 항목 \(index)")
            let replacement = PendingDialogueTask.navigationMode(.init(
                destination: "테스트 목적지 \(index)",
                originalText: "안내 요청 \(index)"
            ))
            scenarios.append(.init(id: "replace-\(index)", steps: [
                .init(action: .begin(first), expectedTask: first),
                .init(action: .begin(replacement), timeOffset: 1, expectedTask: replacement),
                .init(action: .inspect, timeOffset: 2, expectedTask: replacement)
            ]))
        }

        for index in 1...10 {
            let task = PendingDialogueTask.memorySuggestion("취소 항목 \(index)")
            scenarios.append(.init(id: "cancel-\(index)", steps: [
                .init(action: .begin(task), expectedTask: task),
                .init(action: .cancel, timeOffset: 1, expectedTask: nil),
                .init(action: .inspect, timeOffset: 2, expectedTask: nil)
            ]))
        }

        for index in 1...10 {
            let task = PendingDialogueTask.memorySuggestion("완료 항목 \(index)")
            scenarios.append(.init(id: "complete-\(index)", steps: [
                .init(action: .begin(task), expectedTask: task),
                .init(action: .complete, timeOffset: 1, expectedTask: nil),
                .init(action: .inspect, timeOffset: 2, expectedTask: nil)
            ]))
        }

        for index in 1...10 {
            let task = PendingDialogueTask.memorySuggestion("만료 항목 \(index)")
            scenarios.append(.init(id: "expiry-\(index)", steps: [
                .init(action: .begin(task), expectedTask: task),
                .init(action: .inspect, timeOffset: 119, expectedTask: task),
                .init(action: .inspect, timeOffset: 121, expectedTask: nil)
            ]))
        }

        for index in 1...10 {
            let task = PendingDialogueTask.memorySuggestion("재시도 항목 \(index)")
            scenarios.append(.init(id: "retry-\(index)", steps: [
                .init(action: .begin(task), expectedTask: task, expectedRetryCount: 0),
                .init(action: .retry, timeOffset: 1, expectedTask: task, expectedRetryCount: 1),
                .init(action: .retry, timeOffset: 2, expectedTask: task, expectedRetryCount: 2),
                .init(action: .retry, timeOffset: 3, expectedTask: nil)
            ]))
        }
        return scenarios
    }()
}
