import Foundation

public enum ConversationQuestionType: String, Codable, Equatable, Sendable {
    case factual
    case opinion
    case explanation
    case comparison
    case summary
    case smallTalk
    case ambiguous
}

public struct ConversationQuestionAnalysis: Equatable, Sendable {
    public let type: ConversationQuestionType
    public let requiresFreshInformation: Bool

    public init(type: ConversationQuestionType, requiresFreshInformation: Bool) {
        self.type = type
        self.requiresFreshInformation = requiresFreshInformation
    }
}

/// Fast, deterministic classification used before the language model. It does
/// not execute a tool; it only decides how an answer should be shaped and
/// whether a time-sensitive question should be handed to web search.
public struct ConversationQuestionClassifier: Sendable {
    public init() {}

    public func analyze(_ rawText: String) -> ConversationQuestionAnalysis {
        let text = rawText.lowercased()
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let requiresFreshInformation = [
            "최신", "오늘뉴스", "지금뉴스", "속보", "현재순위",
            "최근업데이트", "최신버전", "현재가격", "오늘주가",
            "오늘환율", "실시간", "방금"
        ].contains(where: compact.contains)

        let type: ConversationQuestionType
        if ["안녕", "반가워", "고마워", "잘지내"].contains(where: compact.contains) {
            type = .smallTalk
        } else if ["요약", "핵심만", "줄여줘", "간단히"].contains(where: compact.contains) {
            type = .summary
        } else if ["비교", "차이", "뭐가더", "뭐가달라", "장단점"].contains(where: compact.contains) {
            type = .comparison
        } else if ["생각해", "의견", "추천", "어떤것같"].contains(where: compact.contains) {
            type = .opinion
        } else if ["왜", "어떻게", "설명", "이유"].contains(where: compact.contains) {
            type = .explanation
        } else if compact.count < 3 || ["그거", "이거", "저거", "뭐", "어떻게해"] .contains(compact) {
            type = .ambiguous
        } else {
            type = .factual
        }

        return ConversationQuestionAnalysis(
            type: type,
            requiresFreshInformation: requiresFreshInformation
        )
    }
}

public struct AssistantResponsePresentation: Equatable, Sendable {
    public let screenText: String
    public let spokenText: String
    public let questionType: ConversationQuestionType
    public let isUncertain: Bool

    public init(
        screenText: String,
        spokenText: String,
        questionType: ConversationQuestionType,
        isUncertain: Bool
    ) {
        self.screenText = screenText
        self.spokenText = spokenText
        self.questionType = questionType
        self.isUncertain = isUncertain
    }
}

public struct AssistantResponsePresenter: Sendable {
    public init() {}

    public func make(
        answer rawAnswer: String,
        for question: String,
        maximumSpokenSentences: Int = 4
    ) -> AssistantResponsePresentation {
        let analysis = ConversationQuestionClassifier().analyze(question)
        let screen = normalized(rawAnswer)
        let withoutLinks = screen
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
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
        let sentences = sentenceFragments(in: withoutLinks)
        let limit = min(max(2, maximumSpokenSentences), 4)
        var spoken = sentences.prefix(limit).joined(separator: " ")
        if spoken.isEmpty { spoken = withoutLinks }
        if spoken.count > 360 { spoken = String(spoken.prefix(360)) + "…" }

        let uncertaintyTerms = [
            "확실하지 않", "불확실", "추정", "가능성", "알 수 없",
            "확인이 필요", "정확한 정보가 없"
        ]
        return AssistantResponsePresentation(
            screenText: screen,
            spokenText: normalized(spoken),
            questionType: analysis.type,
            isUncertain: uncertaintyTerms.contains(where: screen.contains)
        )
    }

    private func sentenceFragments(in text: String) -> [String] {
        text
            .split(whereSeparator: { ".!?\n。".contains($0) })
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }
    }

    private func normalized(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ProactiveSuggestion: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let reason: String
    public let proposedIntent: AssistantIntent?
    public let observedAt: Date
    public let expiresAt: Date

    public init(id: String, title: String, reason: String, proposedIntent: AssistantIntent?, observedAt: Date = Date(), validitySeconds: TimeInterval = 300) {
        self.id = id
        self.title = title
        self.reason = reason
        self.proposedIntent = proposedIntent
        self.observedAt = observedAt
        self.expiresAt = observedAt.addingTimeInterval(validitySeconds)
    }
}

/// Creates a suggestion only. It never executes the proposed intent. The app
/// must wait for an explicit tap or answer and pass the intent through the
/// normal safety policy with `modelProposed` origin.
public struct ProactiveSuggestionEngine: Sendable {
    public init() {}

    public func suggestion(
        after intent: AssistantIntent,
        response: String,
        recentIntentKeys: [String]
    ) -> ProactiveSuggestion? {
        switch intent {
        case .weather(.todaySummary), .weather(.precipitationProbability):
            if maximumPercentage(in: response) >= 40 || response.contains("우산") {
                return ProactiveSuggestion(
                    id: "weather.umbrella",
                    title: "우산이 필요한지 더 확인할까요?",
                    reason: "강수 가능성이 있는 날씨 안내가 확인됐습니다.",
                    proposedIntent: .weather(.umbrellaAdvice)
                )
            }
        case .calendar(.todaySummary), .calendar(.remainingToday):
            if !response.contains("일정이 없") {
                return ProactiveSuggestion(
                    id: "calendar.next",
                    title: "가장 가까운 일정만 다시 알려드릴까요?",
                    reason: "오늘 확인할 일정이 있습니다.",
                    proposedIntent: .calendar(.nextEvent)
                )
            }
        default:
            break
        }

        let key = intent.suggestionFamilyKey
        if recentIntentKeys.suffix(5).filter({ $0 == key }).count >= 3 {
            return ProactiveSuggestion(
                id: "repeat.\(key)",
                title: "이 명령을 자주 사용하고 있어요.",
                reason: "최근 명령에서 같은 기능이 반복됐습니다. 자동 실행은 하지 않습니다.",
                proposedIntent: nil
            )
        }
        return nil
    }

    private func maximumPercentage(in text: String) -> Int {
        let pattern = #"(\d{1,3})\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[valueRange])
        }.max() ?? 0
    }
}

public extension AssistantIntent {
    var suggestionFamilyKey: String {
        switch self {
        case .weather: "weather"
        case .calendar, .calendarWorkflow: "calendar"
        case .prepareOuting: "outing"
        case .resolveMemoryConflict: "memory"
        case .time: "time"
        case .webSearch: "webSearch"
        case .recommendRestaurants: "restaurants"
        case .playYouTube, .playYouTubePlaylist: "youtube"
        case .navigate: "navigation"
        case .nearbyPlaces: "nearbyPlaces"
        case .configureImprovementCollection, .reviewImprovementData, .deleteImprovementData,
             .assistImprovementData, .runResponseEvaluation, .configureCommandPractice,
             .runCommandPractice, .applyCommandPractice, .removeCommandPractice: "improvementReview"
        case .call: "call"
        case .openApp: "openApp"
        case .setAlarm, .updateAlarm, .cancelAlarm, .listAlarms, .stopActiveAlarm: "alarm"
        case .remember, .forgetMemory, .listMemories: "memory"
        case .identifySong: "identifySong"
        case .pauseMedia: "pauseMedia"
        case .setVolume, .adjustVolume: "volume"
        case .fullBriefing: "briefing"
        case .assistantCapabilities: "capabilities"
        case .dismissConversation: "dismiss"
        case .unknownCommand: "unknown"
        case .generalConversation: "conversation"
        case .macWorkspace: "macWorkspace"
        case .sharedProject: "sharedProject"
        case .codexLocal: "codexLocal"
        case .projectWorkflow: "sharedProjectCommand"
        case .localData: "localDataMaintenance"
        case .configureCloudAI, .disableCloudAI: "cloudSettings"
        }
    }
}
