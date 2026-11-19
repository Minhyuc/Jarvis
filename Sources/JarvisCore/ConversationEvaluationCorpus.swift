import Foundation

/// General conversation is measured separately from command routing. These
/// fixtures contain no user transcripts and never grant execution authority.
public struct ConversationEvaluationCase: Equatable, Sendable {
    public let id: String
    public let question: String
    public let expectedType: ConversationQuestionType
    public let requiresFreshInformation: Bool
    public let fixtureAnswer: String
    public let expectsUncertainty: Bool

    public init(
        id: String,
        question: String,
        expectedType: ConversationQuestionType,
        requiresFreshInformation: Bool = false,
        fixtureAnswer: String = "핵심 답변입니다. 추가 설명입니다. 더 자세한 내용입니다. 마지막 문장입니다. 읽지 않을 문장입니다.",
        expectsUncertainty: Bool = false
    ) {
        self.id = id
        self.question = question
        self.expectedType = expectedType
        self.requiresFreshInformation = requiresFreshInformation
        self.fixtureAnswer = fixtureAnswer
        self.expectsUncertainty = expectsUncertainty
    }
}

public enum ConversationEvaluationCorpus {
    public static let version = "conversation-1"
    public static let standard: [ConversationEvaluationCase] = [
        .init(id: "fact-01", question: "태양계에서 가장 큰 행성은 뭐야?", expectedType: .factual),
        .init(id: "fact-02", question: "물의 화학식은 무엇이야?", expectedType: .factual),
        .init(id: "fact-03", question: "지구의 위성 이름이 뭐야?", expectedType: .factual),
        .init(id: "fact-04", question: "한글을 만든 왕은 누구야?", expectedType: .factual),
        .init(id: "fact-05", question: "광합성이란 무엇이야?", expectedType: .factual),
        .init(id: "opinion-01", question: "아침 운동에 대해 어떻게 생각해?", expectedType: .opinion),
        .init(id: "opinion-02", question: "종이책과 전자책 중 어떤 게 더 좋다고 생각해?", expectedType: .opinion),
        .init(id: "opinion-03", question: "이 디자인에 대한 의견을 말해줘", expectedType: .opinion),
        .init(id: "opinion-04", question: "쉬는 날 산책하는 것에 대해 어떻게 생각해?", expectedType: .opinion),
        .init(id: "explain-01", question: "비는 왜 내려?", expectedType: .explanation),
        .init(id: "explain-02", question: "인터넷은 어떻게 작동해?", expectedType: .explanation),
        .init(id: "explain-03", question: "무지개가 생기는 이유를 설명해줘", expectedType: .explanation),
        .init(id: "explain-04", question: "배터리가 닳는 이유가 뭐야?", expectedType: .explanation),
        .init(id: "explain-05", question: "이 문제를 어떻게 풀어?", expectedType: .explanation),
        .init(id: "compare-01", question: "버스와 지하철의 차이를 비교해줘", expectedType: .comparison),
        .init(id: "compare-02", question: "두 방식의 장단점을 알려줘", expectedType: .comparison),
        .init(id: "compare-03", question: "사과와 배는 뭐가 달라?", expectedType: .comparison),
        .init(id: "compare-04", question: "와이파이와 셀룰러를 비교해줘", expectedType: .comparison),
        .init(id: "summary-01", question: "이 내용을 요약해줘", expectedType: .summary),
        .init(id: "summary-02", question: "핵심만 말해줘", expectedType: .summary),
        .init(id: "summary-03", question: "짧게 줄여줘", expectedType: .summary),
        .init(id: "summary-04", question: "간단히 정리해줘", expectedType: .summary),
        .init(id: "chat-01", question: "안녕 자비스", expectedType: .smallTalk),
        .init(id: "chat-02", question: "오늘도 반가워", expectedType: .smallTalk),
        .init(id: "chat-03", question: "고마워", expectedType: .smallTalk),
        .init(id: "chat-04", question: "잘 지내?", expectedType: .smallTalk),
        .init(id: "ambiguous-01", question: "그거", expectedType: .ambiguous),
        .init(id: "ambiguous-02", question: "이거", expectedType: .ambiguous),
        .init(id: "ambiguous-03", question: "뭐", expectedType: .ambiguous),
        .init(id: "fresh-01", question: "최신 버전이 뭐야?", expectedType: .factual, requiresFreshInformation: true),
        .init(id: "fresh-02", question: "오늘 뉴스 알려줘", expectedType: .factual, requiresFreshInformation: true),
        .init(id: "fresh-03", question: "현재 가격은 얼마야?", expectedType: .factual, requiresFreshInformation: true),
        .init(id: "fresh-04", question: "방금 발표된 내용은 뭐야?", expectedType: .factual, requiresFreshInformation: true),
        .init(id: "fresh-05", question: "실시간 소식 알려줘", expectedType: .factual, requiresFreshInformation: true),
        .init(id: "uncertain-01", question: "그 사람은 누구야?", expectedType: .factual,
              fixtureAnswer: "동명이인이 있어 확실하지 않습니다. 대상을 알려주세요.", expectsUncertainty: true),
        .init(id: "uncertain-02", question: "확인되지 않은 사실이야?", expectedType: .factual,
              fixtureAnswer: "정확한 정보가 없습니다. 확인이 필요합니다.", expectsUncertainty: true),
        .init(id: "format-01", question: "태양은 무엇이야?", expectedType: .factual,
              fixtureAnswer: "태양은 항성입니다. [출처](https://example.com)에서 확인할 수 있습니다. 세 번째 설명입니다. 네 번째 설명입니다. 다섯 번째 설명입니다.")
    ]
}

public struct ConversationEvaluationReport: Equatable, Sendable {
    public let total: Int
    public let passed: Int
    public let failureIDs: [String]
    public var passRate: Double { total == 0 ? 1 : Double(passed) / Double(total) }
}

/// Checks deterministic classification and presentation contracts, not the
/// factual correctness of a probabilistic model's generated answer.
public struct ConversationEvaluationRunner: Sendable {
    public init() {}

    public func run(_ cases: [ConversationEvaluationCase]) -> ConversationEvaluationReport {
        let classifier = ConversationQuestionClassifier()
        let presenter = AssistantResponsePresenter()
        let failures = cases.compactMap { item -> String? in
            let analysis = classifier.analyze(item.question)
            let presentation = presenter.make(answer: item.fixtureAnswer, for: item.question)
            let noLinks = !presentation.spokenText.contains("http")
                && !presentation.spokenText.contains("www.")
            let bounded = presentation.spokenText.count <= 361
            let nonempty = !presentation.spokenText.isEmpty && !presentation.screenText.isEmpty
            guard analysis.type == item.expectedType,
                  analysis.requiresFreshInformation == item.requiresFreshInformation,
                  presentation.questionType == item.expectedType,
                  presentation.isUncertain == item.expectsUncertainty,
                  noLinks, bounded, nonempty else { return item.id }
            return nil
        }
        return .init(total: cases.count, passed: cases.count - failures.count, failureIDs: failures)
    }
}
