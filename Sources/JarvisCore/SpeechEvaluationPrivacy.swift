import Foundation

/// Only fixed, read-only command families are eligible. A human must review
/// the locally prepared candidate before it becomes a persistent test case.
public struct SpeechEvaluationPrivacyFilter: Sendable {
    public init() {}

    public func candidate(from rawText: String, intent: AssistantIntent) -> String? {
        switch intent {
        case .identifySong, .pauseMedia, .weather, .calendar, .time,
             .assistantCapabilities, .dismissConversation:
            break
        default:
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...70).contains(text.count), !text.contains("\n") else { return nil }
        let forbidden = [
            #"\d"#, #"@"#, #"https?://"#, #"www\."#,
            #"(?:전화|연락처|주소|집|회사|학교|비밀번호|계좌|주민번호|메일|이메일)"#,
            #"(?:기억해|잊어|삭제|예약|구매|결제|보내|전화해)"#
        ]
        guard !forbidden.contains(where: {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) else { return nil }
        // This filter cannot prove that arbitrary free text is anonymous.
        // Keep only phrases made from the small vocabulary of eligible intents.
        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let tokens = [
            "자비스", "야", "오늘", "내일", "지금", "현재", "이", "그", "노래", "음악", "뭐", "무슨",
            "찾아", "알려", "줘", "주세요", "볼게", "날씨", "기온", "최고", "최저", "비", "확률", "우산",
            "일정", "캘린더", "다음", "남은", "몇", "개", "시각", "시간", "날짜", "며칠", "몇시",
            "재생", "일시", "정지", "멈춰", "꺼", "아니", "잘못", "불렀어", "됐어", "할수있어", "기능"
        ]
        var remainder = compact
        for token in tokens.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: token, with: "")
        }
        guard remainder.isEmpty else { return nil }
        return text
    }
}

public struct ApprovedSpeechEvaluationCase: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let input: String
    public let expectedIntentDescription: String
    public let approvedAt: Date

    public init(id: UUID = UUID(), input: String, expectedIntentDescription: String, approvedAt: Date = Date()) {
        self.id = id
        self.input = input
        self.expectedIntentDescription = expectedIntentDescription
        self.approvedAt = approvedAt
    }
}

public struct ApprovedSpeechEvaluationReport: Equatable, Sendable {
    public let total: Int
    public let passed: Int
    public let failedIDs: [UUID]
    public var passRate: Double { total == 0 ? 1 : Double(passed) / Double(total) }
}

public struct ApprovedSpeechEvaluationRunner: Sendable {
    public init() {}

    public func run(_ cases: [ApprovedSpeechEvaluationCase]) -> ApprovedSpeechEvaluationReport {
        let router = CommandRouter()
        let failed = cases.compactMap { item -> UUID? in
            String(describing: router.route(item.input)) == item.expectedIntentDescription
                ? nil : item.id
        }
        return .init(total: cases.count, passed: cases.count - failed.count, failedIDs: failed)
    }
}
