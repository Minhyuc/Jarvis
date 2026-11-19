import Foundation

public struct CalendarEventDraft: Equatable, Sendable {
    public enum Operation: String, Sendable { case create, move, delete }
    public var operation: Operation
    public var title: String
    public var time: AlarmRequest?
    public var durationMinutes: Int
    public var durationWasExplicit: Bool
    public var outdoor: Bool
    public init(operation: Operation = .create, title: String = "", time: AlarmRequest? = nil,
                durationMinutes: Int = 60, outdoor: Bool = false, durationWasExplicit: Bool = false) {
        self.operation = operation; self.title = title; self.time = time
        self.durationMinutes = durationMinutes; self.outdoor = outdoor
        self.durationWasExplicit = durationWasExplicit
    }
}

public struct CalendarEventChange: Equatable, Sendable {
    public let id: UUID?
    public let expectedUpdatedAt: Date?
    public let title: String
    public let start: Date
    public let end: Date
    public let outdoor: Bool
    public let deleting: Bool
    public let timeZoneID: String
    public let conflictIDs: [UUID]
    public init(id: UUID? = nil, expectedUpdatedAt: Date? = nil, title: String, start: Date,
                end: Date, outdoor: Bool, deleting: Bool = false, timeZoneID: String = TimeZone.current.identifier,
                conflictIDs: [UUID] = []) {
        self.id = id; self.expectedUpdatedAt = expectedUpdatedAt; self.title = title
        self.start = start; self.end = end; self.outdoor = outdoor; self.deleting = deleting
        self.timeZoneID = timeZoneID
        self.conflictIDs = conflictIDs
    }
}

public enum CalendarWorkflowCommand: Equatable, Sendable {
    case draft(CalendarEventDraft)
    case commit(CalendarEventChange)
    case day(offset: Int)
}

/// Deliberately narrow, deterministic mutation grammar. Never silently maps an
/// unrecognized calendar write to a read-only summary or to an alarm.
public struct CalendarWorkflowParser: Sendable {
    public init() {}
    public func parse(_ raw: String) -> CalendarWorkflowCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard ["일정", "스케줄", "캘린더"].contains(where: compact.contains) else { return nil }
        if ["하지마", "하지않", "말아줘"].contains(where: compact.contains) { return nil }
        let operation: CalendarEventDraft.Operation
        if ["삭제", "취소", "지워"].contains(where: compact.contains) { operation = .delete }
        else if ["옮겨", "미뤄", "변경", "수정", "바꿔"].contains(where: compact.contains) { operation = .move }
        else if ["등록", "추가", "잡아", "넣어"].contains(where: compact.contains) { operation = .create }
        else { return compact.contains("내일") ? .day(offset: 1) : nil }
        var title = text
        let quoted = text.range(of: #"[“\"]([^”\"]+)[”\"]"#, options: .regularExpression)
        if let quoted {
            title = String(text[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
        } else {
            for pattern in [#"(?:오늘|내일|모레)"#, #"(?:오전|오후|아침|새벽|저녁|밤)?\s*\d{1,2}\s*시(?:\s*\d{1,2}\s*분|\s*반)?(?:에|로|으로)?"#,
                            #"\d+\s*(?:시간|분)\s*(?:동안|짜리)"#, #"(?:야외|실내)"#,
                            #"(?:일정|스케줄|캘린더)(?:을|를|에)?"#, #"(?:등록|추가|잡아|넣어|삭제|취소|지워|옮겨|미뤄|변경|수정|바꿔).*$"#] {
                title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ["전체", "전부", "모든"].contains(title) { title = "" } // No bulk deletion grammar.
        let duration = capture(#"(\d+)\s*분\s*(?:동안|짜리)"#, in: text).flatMap(Int.init)
            ?? capture(#"(\d+)\s*시간\s*(?:동안|짜리)"#, in: text).flatMap(Int.init).map { min($0, 100_000) * 60 }
        return .draft(.init(operation: operation, title: title,
            time: AlarmNaturalLanguageParser().timeRequest(in: text), durationMinutes: duration ?? 60,
            outdoor: compact.contains("야외"), durationWasExplicit: duration != nil))
    }

    public func refining(_ draft: CalendarEventDraft, with text: String) -> CalendarEventDraft {
        var result = draft
        if let time = AlarmNaturalLanguageParser().timeRequest(in: text) {
            result.time = time
            if case .atTime(let h, let m, let p, let d) = time,
               case .atTime(_, _, let oldP, let oldD)? = draft.time {
                result.time = .atTime(hour: h, minute: m, period: p ?? oldP, day: d == .automatic ? oldD : d)
            }
        } else if case .atTime(let h, let m, let p, let d)? = result.time {
            let nextP: AlarmPeriod? = text.contains("오전") ? .am : text.contains("오후") ? .pm : p
            let nextD: AlarmDaySelection = text.contains("내일") ? .tomorrow : text.contains("오늘") ? .today : d
            result.time = .atTime(hour: h, minute: m, period: nextP, day: nextD)
        }
        if result.title.isEmpty, result.time == draft.time,
           !["오전", "오후", "오늘", "내일"].contains(text.trimmingCharacters(in: .whitespaces)) {
            result.title = String(text.prefix(120))
        }
        return result
    }

    public func clarification(for draft: CalendarEventDraft) -> String? {
        if draft.title.isEmpty { return "일정 제목 하나를 말씀해주세요. 전체 삭제는 이 명령에서 지원하지 않습니다." }
        if draft.operation == .delete { return nil }
        guard let time = draft.time else { return "오늘 또는 내일, 오전·오후를 포함해 시작 시각을 말씀해주세요." }
        if case .atTime(_, _, let period, let day) = time {
            if day == .automatic { return "오늘과 내일 중 어느 날인가요?" }
            if period == nil { return "오전인가요, 오후인가요?" }
        }
        if !(1...1_440).contains(draft.durationMinutes) { return "일정 길이는 1분에서 24시간 사이로 말씀해주세요." }
        return nil
    }

    public func date(for draft: CalendarEventDraft, now: Date, calendar: Calendar = .current) -> Date? {
        guard clarification(for: draft) == nil, let time = draft.time else { return nil }
        switch time {
        case .afterMinutes(let minutes): return minutes > 0 && minutes <= 10_080 ? now.addingTimeInterval(Double(minutes) * 60) : nil
        case .atTime(let hour, let minute, let period, let day):
            guard let period, day != .automatic else { return nil }
            let dayDate = calendar.date(byAdding: .day, value: day == .tomorrow ? 1 : 0, to: now) ?? now
            let result = calendar.date(bySettingHour: hour % 12 + (period == .pm ? 12 : 0), minute: minute, second: 0, of: dayDate)
            return result.flatMap { $0 > now ? $0 : nil }
        }
    }
    private func capture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

public struct BoundedPlanBudget: Sendable {
    public let startedAt: Date
    public let maximumSteps: Int
    public let maximumSeconds: TimeInterval
    public private(set) var steps = 0
    public init(now: Date = Date(), maximumSteps: Int = 3, maximumSeconds: TimeInterval = 25) {
        startedAt = now; self.maximumSteps = maximumSteps; self.maximumSeconds = maximumSeconds
    }
    public mutating func takeStep(now: Date = Date()) -> Bool {
        guard !Task.isCancelled, steps < maximumSteps, now >= startedAt,
              now.timeIntervalSince(startedAt) < maximumSeconds else { return false }
        steps += 1; return true
    }
}

public struct WeatherAdviceFacts: Equatable, Sendable {
    public let high: Double
    public let low: Double
    public let rainProbability: Int
    public let yesterdayHigh: Double?
    public let observedAt: Date
    public init(high: Double, low: Double, rainProbability: Int, yesterdayHigh: Double? = nil, observedAt: Date = Date()) {
        self.high = high; self.low = low; self.rainProbability = rainProbability
        self.yesterdayHigh = yesterdayHigh; self.observedAt = observedAt
    }
}

public struct WeatherAdviceEngine: Sendable {
    public init() {}
    public func suggestion(for facts: WeatherAdviceFacts, now: Date = Date()) -> ProactiveSuggestion? {
        guard facts.high.isFinite, facts.low.isFinite, facts.high >= facts.low,
              (-80...65).contains(facts.high), (-90...65).contains(facts.low),
              (0...100).contains(facts.rainProbability), now >= facts.observedAt,
              now.timeIntervalSince(facts.observedAt) < 1_800 else { return nil }
        var advice: [String] = [], reasons: [String] = [], types: [String] = []
        if facts.rainProbability >= 40 {
            advice.append("비가 올 가능성이 있어 우산을 챙기시는 게 좋겠습니다.")
            reasons.append("오늘 최대 강수 확률 \(facts.rainProbability)%"); types.append("rain")
        }
        if let previous = facts.yesterdayHigh, previous.isFinite, previous - facts.high >= 5 {
            advice.append("오늘 최고 기온이 전날 예보보다 \(Int((previous - facts.high).rounded()))도 낮습니다. 겉옷을 챙겨주세요.")
            reasons.append("전날·오늘 최고 기온 예보 비교"); types.append("drop")
        } else if facts.low <= 5 {
            advice.append("아침저녁이 추울 수 있어 따뜻한 외투를 추천합니다.")
            reasons.append("최저 기온 \(Int(facts.low.rounded()))도"); types.append("cold")
        } else if facts.high < 18 {
            advice.append("선선한 날씨라 긴소매와 가벼운 겉옷을 추천합니다.")
            reasons.append("최고 기온 \(Int(facts.high.rounded()))도"); types.append("cool")
        } else if facts.high >= 28 {
            advice.append("낮에는 더울 수 있어 통기성 좋은 옷과 마실 물을 챙겨주세요.")
            reasons.append("최고 기온 \(Int(facts.high.rounded()))도"); types.append("hot")
        }
        if facts.high - facts.low >= 10 {
            advice.append("일교차가 커서 벗고 입기 쉬운 옷이 좋겠습니다.")
            reasons.append("일교차 \(Int((facts.high - facts.low).rounded()))도"); types.append("range")
        }
        guard !advice.isEmpty else { return nil }
        return .init(id: "weather.advice." + types.joined(separator: "."),
            title: advice.prefix(3).joined(separator: " "),
            reason: "현재 위치의 Open-Meteo 예보: " + reasons.joined(separator: ", ") + ". 옷차림은 개인 체감에 맞게 조절해주세요.",
            proposedIntent: nil, observedAt: facts.observedAt, validitySeconds: 1_800)
    }
}
