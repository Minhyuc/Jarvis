import Foundation

public struct AlarmNaturalLanguageParser: Sendable {
    public init() {}

    public func parse(_ rawText: String) -> AssistantIntent? {
        let text = normalize(rawText)
        let compact = compact(text)
        let hasAlarmTopic = compact.contains("알람")
            || compact.contains("알림")
            || compact.contains("타이머")
        let hasReminderTopic = ["알려", "말해", "깨워", "기억", "잊지않게", "알림", "챙겨줘", "리마인드"]
            .contains(where: compact.contains)
            || compact.contains("라고해줘")
            || compact.contains("다고해줘")
        let parsedTime = timeRequest(in: text)
        guard hasAlarmTopic || (hasReminderTopic && parsedTime != nil) else { return nil }

        if hasAlarmTopic && containsAny(compact, ["꺼줘", "꺼", "중지", "중단", "정지", "멈춰", "종료", "그만울려"]) {
            return .stopActiveAlarm
        }
        if containsAny(compact, ["바꿔", "변경", "미뤄", "수정", "옮겨", "당겨", "늦춰"]) {
            return parseUpdate(text)
        }
        if containsAny(compact, ["취소", "삭제", "없애", "해제", "지워", "빼줘"]) {
            return .cancelAlarm(query(from: text))
        }
        if isListRequest(compact), timeRequest(in: text) == nil {
            return .listAlarms(listFilter(from: text))
        }
        guard let request = parsedTime else {
            return hasAlarmTopic && isListRequest(compact)
                ? .listAlarms(listFilter(from: text))
                : nil
        }

        let reminder = reminderDetails(from: text)
        let delivery = systemAlarmWasExplicitlyRequested(compact) ? AlarmDeliveryMode.system : .jarvisVoice
        return .setAlarm(
            request: request,
            label: reminder.label,
            message: reminder.message,
            delivery: delivery
        )
    }

    public func timeRequest(in rawText: String) -> AlarmRequest? {
        let text = replacingKoreanTimeNumbers(in: normalize(rawText))

        if let captures = captures(
            pattern: #"(\d+)\s*시간(?:\s*(\d+)\s*분)?\s*(?:뒤|후|이후(?:에)?|있다가)"#,
            in: text
        ), let hours = Int(captures[0]) {
            let minutes = captures.count > 1 ? Int(captures[1]) ?? 0 : 0
            return .afterMinutes(hours * 60 + minutes)
        }
        if let captures = captures(
            pattern: #"(\d+)\s*분\s*(?:뒤|후|이후(?:에)?|있다가|지나면)"#,
            in: text
        ), let minutes = Int(captures[0]), minutes > 0 {
            return .afterMinutes(minutes)
        }

        guard let captures = captures(
            pattern: #"(\d{1,2})\s*시(?:\s*(?:(\d{1,2})\s*분|(반)))?"#,
            in: text
        ), let hour = Int(captures[0]), (1...12).contains(hour) else {
            return nil
        }
        let minute = captures.count > 2 && captures[2] == "반"
            ? 30
            : (captures.count > 1 ? Int(captures[1]) ?? 0 : 0)
        guard (0...59).contains(minute) else { return nil }

        let compactText = compact(text)
        let period: AlarmPeriod?
        if containsAny(compactText, ["오후", "저녁", "밤"]) {
            period = .pm
        } else if containsAny(compactText, ["오전", "새벽", "아침"]) {
            period = .am
        } else if compactText.contains("점심") {
            period = hour == 11 ? .am : .pm
        } else {
            period = nil
        }

        let day: AlarmDaySelection
        if compactText.contains("내일") {
            day = .tomorrow
        } else if compactText.contains("오늘") {
            day = .today
        } else {
            day = .automatic
        }
        return .atTime(hour: hour, minute: minute, period: period, day: day)
    }

    private func parseUpdate(_ text: String) -> AssistantIntent? {
        let compactText = compact(text)
        let query = query(from: text, forUpdate: true)

        if let label = firstCapture(
            pattern: #"이름(?:을|를)?\s*(.+?)\s*(?:으?로)\s*(?:바꿔|변경|수정)"#,
            in: text
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return .updateAlarm(query: query, update: AlarmUpdate(label: label))
        }

        // "오후 2시 알람을 오후 3시로 바꿔줘"처럼 기존 시각과
        // 새 시각이 모두 있으면 알람 뒤쪽의 시각을 변경값으로 사용한다.
        let updateText: String
        if let alarmRange = firstRange(pattern: #"(?:알람|타이머|알림)(?:을|를|이|가|은|는)?"#, in: text) {
            updateText = String(text[alarmRange.upperBound...])
        } else {
            updateText = text
        }
        guard let request = timeRequest(in: updateText) ?? timeRequest(in: text) else { return nil }
        if compactText.contains("방금") {
            return .updateAlarm(query: .latest, update: AlarmUpdate(request: request))
        }
        return .updateAlarm(query: query, update: AlarmUpdate(request: request))
    }

    private func query(from text: String, forUpdate: Bool = false) -> AlarmQuery {
        let compactText = compact(text)
        if compactText.contains("모든") || compactText.contains("전부") {
            return .all
        }
        if compactText.contains("방금") || compactText.contains("최근") {
            return .latest
        }
        if compactText.contains("다음") {
            return .next
        }
        if !forUpdate, compactText.contains("오늘") { return .today }
        if !forUpdate, compactText.contains("내일") { return .tomorrow }
        if let request = timeRequest(in: text), !forUpdate {
            return .atTime(request)
        }
        if forUpdate,
           let target = firstCapture(pattern: #"^(.+?)\s*(?:알람|타이머|알림)"#, in: text)?
            .replacingOccurrences(of: #"^(?:내|등록된|맞춘)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !target.isEmpty {
            if let request = timeRequest(in: target) {
                return .atTime(request)
            }
            return .named(target)
        }

        var name = text
        let patterns = [
            #"(?:내|등록된|맞춘)\s*"#,
            #"(?:알람|타이머|알림)(?:을|를|이|가|은|는)?"#,
            #"(?:취소|삭제|없애|해제|지워|빼줘|바꿔|변경|수정|미뤄|옮겨|당겨|늦춰).*$"#,
            #"(?:방금|최근|다음|오늘|내일)"#,
            #"(?:오전|오후|새벽|아침|점심|저녁|밤)?\s*\d{1,2}\s*시(?:\s*(?:\d{1,2}\s*분|반))?"#,
            #"\d+\s*(?:시간|분)\s*(?:뒤|후|이후(?:에)?|있다가)"#,
            #"(?:을|를|이|가|은|는|으?로)"#,
            #"\s+"#
        ]
        for pattern in patterns {
            name = name.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? .next : .named(name)
    }

    private func listFilter(from text: String) -> AlarmListFilter {
        let compactText = compact(text)
        if compactText.contains("다음") { return .next }
        if compactText.contains("오늘") { return .today }
        if compactText.contains("내일") { return .tomorrow }

        var name = text
        for pattern in [
            #"(?:내|등록된)\s*"#,
            #"(?:알람|타이머|알림)(?:을|를|이|가|은|는)?"#,
            #"(?:보여줘|보여|알려줘|알려|말해줘|말해|확인해줘|확인|언제\s*울려|언제야|뭐\s*있어|몇\s*개\s*있는지|설정된|맞춰진).*$"#,
            #"^(?:전체|목록|활성화된|지금\s*있는|맞춰\s*둔)\s*"#
        ] {
            name = name.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        for generic in ["목록", "전체", "활성화된", "지금 있는", "맞춰 둔"] {
            name = name.replacingOccurrences(of: generic, with: " ")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? .all : .named(name)
    }

    private func reminderDetails(from text: String) -> (label: String?, message: String?) {
        if let quoted = firstCapture(
            pattern: #"[\"'“‘](.+?)[\"'”’]\s*(?:라고|이라고)?\s*(?:알려|말해)"#,
            in: text
        ) {
            let value = quoted.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = value
                .replacingOccurrences(of: #"(?:하세요|해요|합니다)[.!?]?$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (label.isEmpty ? value : label, sentence(from: value))
        }

        let numberText = replacingKoreanTimeNumbers(in: text)
        let timingPattern = #"(?:\d+\s*시간(?:\s*\d+\s*분)?\s*(?:뒤|후|이후(?:에)?|있다가)|\d+\s*분\s*(?:뒤|후|이후(?:에)?|있다가)|(?:내일|오늘)?\s*(?:오전|오후|새벽|아침|점심|저녁|밤)?\s*\d{1,2}\s*시(?:\s*(?:\d{1,2}\s*분|반))?)"#
        guard let timingRange = firstRange(pattern: timingPattern, in: numberText) else {
            return (nil, nil)
        }

        var purpose = String(numberText[..<timingRange.lowerBound])
        if purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            purpose = String(numberText[timingRange.upperBound...])
                .replacingOccurrences(of: #"^\s*(?:에|에는|쯤|정도)?\s*"#, with: "", options: .regularExpression)
        }
        let cleaned = cleanPurpose(purpose)
        guard !cleaned.isEmpty else { return (nil, nil) }
        let label = actionLabel(from: cleaned)
        return (label, alarmMessage(from: label))
    }

    private func cleanPurpose(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: #"[,.!?]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["내가 ", "나 ", "저 ", "제가 "] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        for pattern in [
            #"\s*(?:라고|이라고|다고)?\s*(?:알람|타이머|알림)(?:을|를)?\s*(?:맞춰|설정해|울려|해|등록해).*$"#,
            #"\s*(?:라고|이라고|다고)?\s*(?:알려|말해|기억해|깨워).*$"#,
            #"\s*(?:라고|이라고|다고)?\s*해\s*줘.*$"#,
            #"\s*잊지\s*않게.*$"#
        ] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for connector in [
            "해야 하니까", "해야하니까", "해야 하니", "해야하니", "해야 해서", "해야해서",
            "해야 되니까", "해야되니까", "할 거니까", "할거니까", "할 예정이니까",
            "할예정이니까", "하려고 하니까", "하려고하니까", "하니까", "때문에",
            "으니까", "니까", "해서"
        ] where value.hasSuffix(connector) {
            value.removeLast(connector.count)
            break
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func actionLabel(from purpose: String) -> String {
        let rules: [(String, String)] = [
            ("꺼야", "끄기"), ("꺼", "끄기"), ("끄라고", "끄기"), ("끄", "끄기"),
            ("먹어야", "먹기"), ("먹어", "먹기"), ("먹으", "먹기"),
            ("마셔야", "마시기"), ("마셔", "마시기"), ("마시", "마시기"),
            ("가야", "가기"), ("가", "가기"), ("와야", "오기"), ("와", "오기"),
            ("자야", "자기"), ("자", "자기"), ("일어나야", "일어나기"),
            ("일어나", "일어나기"), ("전화해야", "전화하기"), ("전화해", "전화하기"),
            ("출발해야", "출발하기"), ("출발해", "출발하기"), ("출발한", "출발하기"),
            ("확인해야", "확인하기"), ("확인해", "확인하기"),
            ("해야", "하기"), ("해", "하기"), ("하", "하기")
        ]
        for (ending, replacement) in rules where purpose.hasSuffix(ending) {
            return String(purpose.dropLast(ending.count)) + replacement
        }
        return purpose
    }

    private func alarmMessage(from label: String) -> String {
        let endings: [(String, String)] = [
            ("일어나기", "일어나실 시간입니다."), ("먹기", "드실 시간입니다."),
            ("마시기", "드실 시간입니다."), ("자기", "주무실 시간입니다."),
            ("오기", "오실 시간입니다."), ("가기", "가실 시간입니다."),
            ("끄기", "끄실 시간입니다."), ("하기", "하실 시간입니다.")
        ]
        for (ending, replacement) in endings where label.hasSuffix(ending) {
            return String(label.dropLast(ending.count)) + replacement
        }
        return label.hasSuffix("기")
            ? String(label.dropLast()) + "실 시간입니다."
            : "\(label) 알림입니다."
    }

    private func isListRequest(_ compactText: String) -> Bool {
        containsAny(compactText, ["보여", "뭐있", "뭐가있", "언제", "목록", "등록된", "설정된", "맞춰진", "맞춰둔", "지금있는", "확인", "알려줘", "말해줘"])
    }

    private func systemAlarmWasExplicitlyRequested(_ compactText: String) -> Bool {
        let subjects = ["알람", "알림", "타이머"]
        let actions = ["맞춰", "설정해", "설정", "울려", "등록해", "등록"]
        return subjects.contains(where: compactText.contains)
            && actions.contains(where: compactText.contains)
    }

    private func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "자비스야", with: "")
            .replacingOccurrences(of: "자비스", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }

    private func sentence(from text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    private func replacingKoreanTimeNumbers(in text: String) -> String {
        var result = text
        let replacements = [
            "오십": "50", "사십": "40", "삼십": "30",
            "스물네": "24", "스물세": "23", "스물두": "22", "스물한": "21",
            "열아홉": "19", "열여덟": "18", "열일곱": "17", "열여섯": "16",
            "열다섯": "15", "열네": "14", "열세": "13", "열두": "12", "열한": "11",
            "스무": "20", "스물": "20", "열": "10", "아홉": "9", "여덟": "8",
            "일곱": "7", "여섯": "6", "다섯": "5", "네": "4", "세": "3",
            "두": "2", "한": "1"
        ]
        for (word, number) in replacements {
            result = result.replacingOccurrences(
                of: #"\#(word)\s*(?=시간|분|시)"#,
                with: number,
                options: .regularExpression
            )
        }
        return result
    }

    private func captures(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        captures(pattern: pattern, in: text)?.first
    }

    private func firstRange(pattern: String, in text: String) -> Range<String.Index>? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return Range(match.range, in: text)
    }
}
