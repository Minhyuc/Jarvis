import Foundation

public struct CommandRouter: Sendable {
    public init() {}

    public func route(_ rawText: String) -> AssistantIntent {
        route(rawText, previousIntent: nil)
    }

    public func route(
        _ rawText: String,
        previousIntent: AssistantIntent?
    ) -> AssistantIntent {
        let normalized = normalize(rawText)

        if requestsConversationDismissal(normalized) {
            return .dismissConversation
        }
        if let project = SharedProjectCommandParser().parse(rawText) { return .projectWorkflow(project) }
        let compact = normalized.filter { !$0.isWhitespace && !$0.isPunctuation }
        if ["외출준비", "나갈준비"].contains(where: compact.contains) {
            return .prepareOuting(dayOffset: compact.contains("내일") ? 1 : 0)
        }
        if let calendar = CalendarWorkflowParser().parse(normalized) {
            return .calendarWorkflow(calendar)
        }

        if ["근처", "주변", "가까운"].contains(where: normalized.contains),
           let category = NearbyPlaceCategory.parse(normalized) {
            let compact = normalized.filter { !$0.isWhitespace }
            let navigate = ["안내", "길찾", "가자", "데려다"].contains(where: compact.contains)
            if navigate || ["뭐", "어떤", "어디", "찾아", "있어", "검색", "알려", "추천"].contains(where: compact.contains) {
                return .nearbyPlaces(category: category, navigate: navigate, mode: navigationTravelMode(from: normalized))
            }
        }

        if previousIntent == nil, isUnresolvedDeicticCommand(normalized) {
            return .unknownCommand(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let memoryIntent = memoryIntent(from: normalized, originalText: rawText) {
            return memoryIntent
        }

        if let alarmIntent = AlarmNaturalLanguageParser().parse(normalized) {
            return alarmIntent
        }

        if requestsMediaPause(normalized) {
            return .pauseMedia
        }

        if let volumeIntent = volumeIntent(from: normalized) {
            return volumeIntent
        }

        if requestsSongIdentification(normalized) {
            return .identifySong
        }

        if containsPlaylistTopic(normalized)
            && (containsPlayVerb(normalized) || normalized.contains("열어")) {
            let playlistName = extractPlaylistName(from: normalized)
            if !playlistName.isEmpty {
                return .playYouTubePlaylist(name: playlistName)
            }
            return .unknownCommand(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if containsYouTubeName(normalized) && containsPlayVerb(normalized) {
            let query = extractYouTubeQuery(from: normalized)
            if !query.isEmpty {
                return .playYouTube(query: query)
            }
        }

        if containsCallVerb(normalized) {
            let recipient = extractCallRecipient(from: normalized)
            if !recipient.isEmpty {
                return .call(
                    recipient: recipient,
                    speakerRequested: requestsSpeakerphone(normalized)
                )
            }
        }

        if case let .navigate(destination, _)? = previousIntent,
           let mode = navigationTravelMode(from: normalized),
           isNavigationModeOnlyFollowUp(normalized) {
            return .navigate(destination: destination, mode: mode)
        }

        // A complete target in the current utterance must win over stale context
        // from a previous command in the same family. Only elliptical requests
        // such as "again" or "there" reach the follow-up resolver below.
        if let navigationIntent = navigationIntent(from: normalized) {
            return navigationIntent
        }

        if requestsFullBriefing(normalized) {
            return .fullBriefing
        }

        // "날씨 앱 열어줘"는 날씨 조회가 아니라 앱 실행이다.
        if containsAppOpenVerb(normalized) {
            let appName = extractAppName(from: normalized)
            if !appName.isEmpty, !isContextOnlyAppName(appName) {
                return .openApp(name: appName)
            }
        }

        if requestsRestaurantRecommendation(normalized) {
            let query = extractRestaurantQuery(from: normalized)
            return .recommendRestaurants(query: query.isEmpty ? nil : query)
        }

        if let query = extractWebSearchQuery(from: normalized) {
            return query.isEmpty
                ? .unknownCommand(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
                : .webSearch(query: query)
        }

        if let weatherRequest = weatherRequest(from: normalized) {
            return .weather(weatherRequest)
        }

        if let calendarRequest = calendarRequest(from: normalized) {
            return .calendar(calendarRequest)
        }

        if let timeRequest = timeRequest(from: normalized) {
            return .time(timeRequest)
        }

        // Time-sensitive factual questions should not be answered from an
        // on-device model's static knowledge. Deterministic device features
        // above keep priority; every other fresh-information question uses
        // web search.
        if ConversationQuestionClassifier().analyze(normalized).requiresFreshInformation {
            return .webSearch(query: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let followUp = followUpIntent(from: normalized, previousIntent: previousIntent) {
            return followUp
        }

        if requestsCapabilities(normalized) {
            return .assistantCapabilities
        }

        if looksLikeIncompleteCommand(normalized) {
            return .unknownCommand(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return .generalConversation(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func containsWakeWord(_ rawText: String) -> Bool {
        let compact = rawText
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        return compact.contains("자비스")
    }

    public func navigationTravelMode(from rawText: String) -> NavigationTravelMode? {
        let compact = rawText
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }

        if ["대중교통", "지하철", "버스", "전철", "대중교통으로"]
            .contains(where: compact.contains) {
            return .publicTransit
        }
        if ["자가용", "자동차", "차량", "운전", "차로", "자동차로"]
            .contains(where: compact.contains) {
            return .car
        }
        return nil
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "자비스야", with: "")
            .replacingOccurrences(of: "자비스", with: "")
            .replacingOccurrences(of: "유 투브", with: "유튜브")
            .replacingOccurrences(of: "유 튜브", with: "유튜브")
            .replacingOccurrences(of: "유투브", with: "유튜브")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsPlayVerb(_ text: String) -> Bool {
        ["틀어", "재생", "들려", "플레이", "켜줘", "켜 줘", "켜봐", "시작해", "듣고 싶어"]
            .contains { text.contains($0) }
    }

    private func requestsConversationDismissal(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        if ["재생", "노래", "음악", "미디어", "유튜브"].contains(where: compact.contains),
           ["그만", "멈춰", "중지", "정지", "종료"].contains(where: compact.contains) {
            return false
        }
        let phrases: Set<String> = [
            "아니야", "아냐", "아무것도아니야", "별일아니야",
            "잘못불렀어", "잘못불렀어요", "잘못호출했어", "잘못호출했어요",
            "됐어", "됐어요", "괜찮아", "괜찮아요", "취소할게", "취소해줘"
        ]
        if phrases.contains(compact) { return true }
        let dismissalTerms = [
            "잘못불렀", "실수로불렀", "요청취소", "명령취소", "명령은취소",
            "대화끝내", "아무것도아니", "아냐그만해"
        ]
        if dismissalTerms.contains(where: compact.contains) { return true }
        // Natural speech often combines or repeats short rejections, such as
        // `아냐 아냐` and `아냐 됐어`. Accept the whole utterance only when
        // every segment is itself a dismissal phrase.
        let shortPhrases = ["아니야", "괜찮아", "아냐", "됐어"]
        var remainder = compact
        var matched = false
        while !remainder.isEmpty {
            guard let phrase = shortPhrases.first(where: { remainder.hasPrefix($0) }) else {
                return false
            }
            remainder.removeFirst(phrase.count)
            matched = true
        }
        return matched
    }

    private func memoryIntent(from text: String, originalText: String) -> AssistantIntent? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }

        let listPhrases = [
            "기억목록", "장기기억목록", "저장된기억", "기억한내용",
            "뭘기억하고있어", "무엇을기억하고있어", "내정보뭐알아",
            "저장한기억", "장기기억에뭐", "모든기억확인", "기억하고있는항목",
            "기억항목"
        ]
        if listPhrases.contains(where: compact.contains) {
            return .listMemories
        }

        let forgetTerms = ["잊어줘", "잊어버려", "기억에서삭제", "기억삭제", "기억지워"]
        if forgetTerms.contains(where: compact.contains) {
            if ["모두", "전부", "전체", "모든기억", "다잊어"].contains(where: compact.contains) {
                return .forgetMemory(.all)
            }
            if ["방금", "최근", "마지막", "그거", "그내용"].contains(where: compact.contains) {
                return .forgetMemory(.latest)
            }

            let query = memoryContent(
                from: text,
                removing: forgetTerms + [
                    "내가", "말한", "내용을", "내용", "정보를", "정보",
                    "기억을", "기억", "관련된", "좀"
                ]
            )
            if !query.isEmpty {
                return .forgetMemory(.matching(query))
            }
            return .unknownCommand(text: originalText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let rememberTerms = [
            "기억해줘", "기억해 줘", "기억해둬", "기억해 둬",
            "기억해", "기억해요", "기억해 주세요", "기억해줘요"
        ]
        if rememberTerms.contains(where: text.contains) || compact.hasSuffix("기억해") {
            let content = memoryContent(
                from: text,
                removing: rememberTerms + ["이걸", "이것을", "내용을", "정보를", "꼭"]
            )
            if !content.isEmpty {
                return .remember(content: content)
            }
            return .unknownCommand(text: originalText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }

    private func memoryContent(from text: String, removing tokens: [String]) -> String {
        var content = text
        for token in tokens.sorted(by: { $0.count > $1.count }) {
            content = content.replacingOccurrences(of: token, with: " ")
        }
        return content
            .replacingOccurrences(of: #"^[,.:;!?\s]+|[,.:;!?\s]+$"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestsMediaPause(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let mediaTopics = ["유튜브", "youtube", "노래", "음악", "재생", "미디어", "영상", "오디오", "나오는소리"]
        let stopTerms = [
            "꺼줘", "꺼", "멈춰", "멈춰줘", "중지", "정지", "일시정지",
            "그만해줘", "그만해", "그만틀어", "그만재생", "그만들려", "끄고싶어", "종료", "중단"
        ]
        return mediaTopics.contains(where: compact.contains)
            && stopTerms.contains(where: compact.contains)
    }

    private func volumeIntent(from text: String) -> AssistantIntent? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard compact.contains("볼륨")
                || compact.contains("음량")
                || compact.contains("음소거")
                || compact.contains("소리")
                || compact.contains("크게틀어")
                || compact.contains("작게틀어") else {
            return nil
        }

        if compact.contains("음소거") || compact.contains("소리를꺼") {
            return .setVolume(percent: 0)
        }
        if compact.contains("최대") {
            return .setVolume(percent: 100)
        }
        if compact.contains("최소") {
            return .setVolume(percent: 0)
        }
        if ["올려", "높여", "크게", "키워", "커지게"].contains(where: compact.contains) {
            return .adjustVolume(delta: 10)
        }
        if ["내려", "낮춰", "작게", "줄여", "조용히", "작아지게"].contains(where: compact.contains) {
            return .adjustVolume(delta: -10)
        }

        guard let value = firstInteger(in: text) else { return nil }
        return .setVolume(percent: min(max(value, 0), 100))
    }

    private func firstInteger(in text: String) -> Int? {
        captures(pattern: #"(\d{1,3})"#, in: text).flatMap { Int($0[0]) }
    }

    private func captures(pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }

        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private func requestsSongIdentification(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard !containsYouTubeName(text) else { return false }

        let directRequests = [
            "지금나오는노래", "지금들리는노래", "현재나오는노래", "현재재생중인노래",
            "지금무슨노래", "이노래뭐", "이음악뭐", "이곡뭐",
            "무슨노래야", "무슨노래인지", "노래제목알려", "노래이름알려",
            "노래찾아줘", "음악찾아줘", "노래알아맞혀", "음악인식"
        ]
        if directRequests.contains(where: compact.contains) { return true }

        let audioTopics = ["노래", "음악", "곡"]
        guard audioTopics.contains(where: compact.contains) else { return false }
        let currentContext = ["지금", "현재", "이노래", "이음악", "이곡", "들리", "나오", "재생중"]
            .contains(where: compact.contains)
        let identityQuestion = ["뭐", "무슨", "제목", "이름", "알려", "찾아", "누가", "가수", "부른"]
            .contains(where: compact.contains)
        return identityQuestion && (currentContext || compact.contains("누가부른"))
    }

    private func containsCallVerb(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        if compact.contains("연락해") { return true }
        let hasPhoneTopic = compact.contains("전화") || compact.contains("통화")
        let hasCallAction = ["걸어", "걸어줘", "해줘", "해줘요", "연결", "시작", "하고싶어", "시도", "통화하게"]
            .contains(where: compact.contains)
        return hasPhoneTopic && hasCallAction
    }

    private func navigationIntent(from text: String) -> AssistantIntent? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let navigationTerms = [
            "가는방법", "가는길", "길안내", "경로안내", "네비게이션", "내비게이션",
            "네비", "내비", "안내해", "안내해줘", "안내부탁", "안내시작", "길찾기",
            "차량경로", "운전경로", "대중교통경로", "지하철경로", "버스경로",
            "대중교통길", "바꿔줘", "바꿔"
        ]
        guard navigationTerms.contains(where: compact.contains) else { return nil }

        var simplified = text
        let removable = [
            "현재 위치에서", "자동차로", "자가용으로", "차량으로", "차로", "운전해서",
            "대중교통으로", "버스나 지하철", "지하철로", "버스로", "전철로",
            "네비게이션 시작해줘", "내비게이션 시작해줘", "네비 시작해줘", "내비 시작해줘",
            "차량 경로를 열어줘", "운전 경로 시작해줘", "대중교통 경로를 열어줘",
            "대중교통 경로 안내해줘", "지하철 경로를 보여줘", "대중교통 길을 열어줘",
            "버스나 지하철 경로 열어줘", "대중교통 안내해줘", "대중교통 네비 시작해줘",
            "가는 대중교통 길을 열어줘", "그런데", "바꿔줘", "바꿔",
            "자동차 길찾기 해줘", "대중교통 길찾기 해줘", "자가용 네비 열어줘",
            "가는 방법을 안내해줘", "가는 방법을 알려줘", "가는 방법 알려줘", "가는 길 알려줘",
            "길 안내해줘", "안내해줘", "안내해 줘"
        ]
        for token in removable.sorted(by: { $0.count > $1.count }) {
            simplified = simplified.replacingOccurrences(of: token, with: " ")
        }
        // Spoken requests often omit the particle after a travel mode.
        // Remove only standalone mode words, not substrings of a place name.
        simplified = simplified.replacingOccurrences(
            of: #"(?:^|\s)(?:자가용|자동차|차량|대중교통)(?=\s|$)"#,
            with: " ", options: .regularExpression
        )
        simplified = simplified
            .replacingOccurrences(of: #"(?:까지|으로|로)\s*$"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let simplifiedDestination = NavigationDestinationNormalizer().normalize(simplified)
        if !simplifiedDestination.isEmpty,
           !isContextOnlyNavigationDestination(simplifiedDestination) {
            return .navigate(
                destination: simplifiedDestination,
                mode: navigationTravelMode(from: text) ?? .publicTransit
            )
        }

        let patterns = [
            #"^(?:현재\s*위치에서\s*)?(.+?)(?:까지|으로|로)\s*(?:(?:자가용|자동차|차량|차|대중교통|지하철|버스|전철)(?:으?로)?\s*)?(?:가는\s*(?:방법|길)|가려면|길\s*안내|경로\s*안내|안내|네비게이션|내비게이션|네비|내비)"#,
            #"^(?:현재\s*위치에서\s*)?(.+?)\s*가는\s*(?:방법|길)"#,
            #"^(?:현재\s*위치에서\s*)?(.+?)\s*(?:길\s*안내|경로\s*안내|네비게이션|내비게이션|네비|내비)"#,
            #"^(?:현재\s*위치에서\s*)?(.+?)\s*안내\s*(?:부탁|시작)"#
        ]

        for pattern in patterns {
            guard let rawDestination = captures(pattern: pattern, in: text)?.first else {
                continue
            }
            let destination = NavigationDestinationNormalizer().normalize(rawDestination)
            guard !destination.isEmpty,
                  !isContextOnlyNavigationDestination(destination) else {
                continue
            }
            return .navigate(
                destination: destination,
                mode: navigationTravelMode(from: text) ?? .publicTransit
            )
        }
        return nil
    }

    private func isContextOnlyNavigationDestination(_ destination: String) -> Bool {
        let compact = destination.filter { !$0.isWhitespace && !$0.isPunctuation }
        return [
            "자가용", "자동차", "차량", "차", "운전",
            "대중교통", "지하철", "버스", "전철", "거기", "그곳", "그곳으로", "그곳까지",
            "아니", "길", "길좀"
        ].contains(compact)
    }

    private func isNavigationModeOnlyFollowUp(_ text: String) -> Bool {
        var compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        for token in [
            "아니", "그럼", "그러면", "이번엔", "자가용으로", "자동차로", "차로",
            "대중교통으로", "지하철로", "버스로", "안내해줘", "안내해", "바꿔줘", "바꿔"
        ] {
            compact = compact.replacingOccurrences(of: token, with: "")
        }
        return compact.isEmpty
    }

    private func requestsSpeakerphone(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return compact.contains("스피커폰") || compact.contains("스피커로")
    }

    private func extractCallRecipient(from text: String) -> String {
        var recipient = text
        let removable = [
            "휴대폰으로", "휴대전화로", "핸드폰으로",
            "스피커폰으로", "스피커폰", "스피커로",
            "전화 걸어 줄래요", "전화 걸어줄래요", "전화 걸어 줄래", "전화 걸어줄래",
            "전화걸어줄래요", "전화걸어줄래", "전화 걸어 주세요", "전화 걸어주세요",
            "전화 걸어 줘요", "전화 걸어줘요", "전화 걸어 줘", "전화 걸어줘", "전화 걸어",
            "전화걸어 줘요", "전화걸어줘요", "전화걸어 줘", "전화걸어줘", "전화걸어",
            "전화해 줘요", "전화해줘요", "전화해 줘", "전화해줘", "전화해",
            "통화해 줘요", "통화해줘요", "통화해 줘", "통화해줘", "통화해",
            "전화 연결해 줘", "전화 연결해줘", "전화연결해줘", "전화 연결해", "전화 연결", "전화연결",
            "통화 연결해 줘", "통화 연결해줘", "통화 연결", "통화하고 싶어", "통화하게 해줘", "통화 시도해줘",
            "연락해 줘", "연락해줘", "연락해", "전화", "통화", "걸어줄래요", "걸어줄래", "걸어주세요", "좀", "부탁해",
            "연락처로", "전화번호로", "번호로", "걸기 해줘", "시도해줘", "연결해줘", "하게 해줘",
            "에게", "한테", "를", "랑"
        ]

        for token in removable {
            recipient = recipient.replacingOccurrences(of: token, with: " ")
        }
        recipient = recipient.replacingOccurrences(
            of: #"[()\[\]{}\"'“”]"#,
            with: " ",
            options: .regularExpression
        )

        var result = recipient
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("로") {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestsFullBriefing(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }

        if compact.contains("날씨와일정") || compact.contains("일정과날씨")
            || compact.contains("날씨랑일정") || compact.contains("일정이랑날씨")
            || compact.contains("스케줄과날씨") || compact.contains("날씨와스케줄") {
            return true
        }

        if (compact.contains("일정") || compact.contains("스케줄"))
            && compact.contains("브리핑")
            && !compact.contains("날씨") {
            return false
        }
        let fullBriefingTerms = ["현재브리핑", "오늘브리핑", "전체브리핑", "아침브리핑", "하루브리핑"]
        return fullBriefingTerms.contains(where: compact.contains)
            || compact.contains("브리핑") && !compact.contains("날씨브리핑")
    }

    private func weatherRequest(from text: String) -> WeatherRequest? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }

        if compact.contains("우산") {
            return .umbrellaAdvice
        }
        if ["일교차", "최고와최저", "최고최저"].contains(where: compact.contains) {
            return .temperatureRange
        }
        if compact.contains("최고기온") || compact.contains("오늘최고") || compact.contains("가장따뜻")
            || compact.contains("가장높은온도") || compact.contains("기온이최고")
            || compact.contains("제일따뜻") {
            return .highTemperature
        }
        if compact.contains("최저기온") || compact.contains("오늘최저") || compact.contains("가장추울")
            || compact.contains("가장낮은온도") || compact.contains("기온이최저")
            || compact.contains("제일추울") {
            return .lowTemperature
        }
        let temperatureTopics = ["기온", "온도", "몇도"]
        if ["현재기온", "지금기온", "지금몇도", "밖에몇도", "현재온도", "밖온도"]
            .contains(where: compact.contains)
            || temperatureTopics.contains(where: compact.contains)
                && ["지금", "현재", "밖", "어떻", "알려"].contains(where: compact.contains) {
            return .currentTemperature
        }
        if [
            "강수확률", "비올확률", "비가올확률", "비올까", "비오니", "비와", "비가와",
            "비예보", "오늘비", "비오는지", "비가오는지"
        ].contains(where: compact.contains) {
            return .precipitationProbability
        }

        if compact.contains("날씨") || compact.contains("오늘기온")
            || compact.contains("밖에어때") || compact.contains("오늘추워")
            || compact.contains("오늘더워") || compact.contains("오늘쌀쌀해") {
            return .todaySummary
        }

        return nil
    }

    private func calendarRequest(from text: String) -> CalendarRequest? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let calendarTopics = ["일정", "스케줄", "캘린더", "약속", "회의", "할일", "계획", "예정"]
        let implicitTodaySchedule = ["오늘뭐있어", "오늘뭐가있어", "오늘해야할거", "오늘해야할것"]
            .contains(where: compact.contains)
        let implicitRemaining = ["오늘앞으로뭐가남았어", "앞으로뭐가남았어"]
            .contains(where: compact.contains)
        guard implicitTodaySchedule || implicitRemaining || calendarTopics.contains(where: compact.contains) else { return nil }

        if compact.contains("몇개") || compact.contains("개수") || compact.contains("항목수")
            || compact.contains("일정수") || compact.contains("수를세어") {
            return .eventCount
        }
        if compact.contains("다음") || compact.contains("가장가까운") || compact.contains("가장먼저")
            || compact.contains("첫번째") || compact.contains("첫일정") || compact.contains("이제무슨") {
            return .nextEvent
        }
        if compact.contains("남은") || compact.contains("남아있는") || compact.contains("지금부터")
            || compact.contains("지금이후") || compact.contains("오늘이후")
            || compact.contains("오늘앞으로") || compact.contains("오늘뒤에") {
            return .remainingToday
        }
        return .todaySummary
    }

    private func timeRequest(from text: String) -> TimeRequest? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let asksTime = [
            "몇시", "현재시각", "지금시각", "지금시간", "현재시간", "정확한시간",
            "시간이어떻게돼", "시간알려", "시간확인", "현재몇시", "시각을말해"
        ].contains(where: compact.contains)
        let asksDate = [
            "오늘날짜", "오늘며칠", "오늘몇일", "오늘이몇일", "오늘이몇월몇일", "오늘이몇월며칠",
            "현재날짜", "무슨요일", "몇월몇일", "몇월며칠", "날짜", "날짜알려", "날짜확인", "오늘일자",
            "오늘의날짜", "날짜가어떻게돼"
        ].contains(where: compact.contains)

        if asksTime && asksDate || ["날짜와시간", "날짜랑시각", "현재일시", "날짜시간", "일자와시간", "날짜그리고시간"]
            .contains(where: compact.contains) {
            return .currentDateAndTime
        }
        if asksTime {
            return .currentTime
        }
        if asksDate {
            return .todayDate
        }
        return nil
    }

    private func requestsCapabilities(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return [
            "무엇을할수있", "뭐할수있", "사용가능한명령", "쓸수있는명령",
            "기능설명", "자비스기능", "어떤기능", "무슨기능", "기능알려",
            "기능이뭐", "뭘할줄알아", "할수있는걸", "기능목록", "명령을지원",
            "가능한기능", "부탁할수있", "할수있는작업"
        ]
            .contains(where: compact.contains)
    }

    private func followUpIntent(
        from text: String,
        previousIntent: AssistantIntent?
    ) -> AssistantIntent? {
        guard let previousIntent else { return nil }
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }

        switch previousIntent {
        case .identifySong:
            if compact.contains("다시") || compact.contains("한번더") {
                return .identifySong
            }

        case .weather, .fullBriefing:
            if previousIntent == .fullBriefing {
                if compact.contains("다음") || compact.contains("가장가까운") {
                    return .calendar(.nextEvent)
                }
                if compact.contains("남은") || compact.contains("지금부터") {
                    return .calendar(.remainingToday)
                }
                if compact.contains("일정") || compact.contains("스케줄") {
                    return .calendar(.todaySummary)
                }
            }
            if compact.contains("우산") { return .weather(.umbrellaAdvice) }
            if compact.contains("비") || compact.contains("강수") {
                return .weather(.precipitationProbability)
            }
            if compact.contains("일교차") || compact.contains("최고와최저") {
                return .weather(.temperatureRange)
            }
            if compact.contains("최고") || compact.contains("따뜻") {
                return .weather(.highTemperature)
            }
            if compact.contains("최저") || compact.contains("추울") {
                return .weather(.lowTemperature)
            }
            if ["지금은", "현재는", "현재기온은"].contains(where: compact.contains) {
                return .weather(.currentTemperature)
            }

        case .calendar:
            if compact.contains("몇개") || compact.contains("개수") {
                return .calendar(.eventCount)
            }
            if compact.contains("다음") || compact.contains("가장가까운") {
                return .calendar(.nextEvent)
            }
            if compact.contains("남은") || compact.contains("지금부터") {
                return .calendar(.remainingToday)
            }

        case .time:
            if compact.contains("날짜") || compact.contains("며칠") || compact.contains("요일") {
                return .time(.todayDate)
            }
            if compact.contains("시간") || compact.contains("몇시") {
                return .time(.currentTime)
            }

        case .recommendRestaurants(let query):
            if ["다시", "다른곳", "다른집", "다른가게", "또다른", "또추천"]
                .contains(where: compact.contains) {
                return .recommendRestaurants(query: query)
            }

        case .webSearch(let query):
            if ["더", "자세히", "추가", "다시", "최신"]
                .contains(where: compact.contains) {
                return .webSearch(query: query)
            }

        case .navigate(let destination, _):
            if let mode = navigationTravelMode(from: text) {
                return .navigate(destination: destination, mode: mode)
            }

        case .playYouTube(let query):
            if compact.contains("다시") && (containsPlayVerb(text) || compact.contains("노래")) {
                return .playYouTube(query: query)
            }

        case .playYouTubePlaylist(let name):
            if compact.contains("다시") && containsPlayVerb(text) {
                return .playYouTubePlaylist(name: name)
            }

        case .openApp(let name):
            if compact.contains("다시") && containsAppOpenVerb(text) {
                return .openApp(name: name)
            }

        default:
            break
        }

        return nil
    }

    private func requestsRestaurantRecommendation(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let implicitFoodRequest = ["뭐먹지", "뭐먹을까", "먹을데", "먹을곳", "식사할곳", "어디서먹"]
            .contains(where: compact.contains)
        if implicitFoodRequest { return true }

        let restaurantTopics = [
            "맛집", "음식점", "음식집", "식당", "레스토랑", "밥집",
            "한식집", "초밥집", "고깃집", "횟집", "카페", "먹을곳", "먹을데", "디저트집"
        ]
        let recommendationTerms = [
            "추천", "찾아", "찾어", "알려", "어디", "좋은", "인기", "평점", "평가",
            "근처", "주변", "가까운", "가까이"
        ]
        return restaurantTopics.contains(where: compact.contains)
            && recommendationTerms.contains(where: compact.contains)
    }

    private func extractWebSearchQuery(from text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let searchSources = ["인터넷", "웹", "온라인", "구글"]
        let searchActions = ["검색", "서칭", "찾아", "찾어", "알아봐"]

        guard searchSources.contains(where: compact.contains),
              searchActions.contains(where: compact.contains) else {
            return nil
        }

        var query = text
        let removable = [
            "인터넷에서", "인터넷으로", "인터넷에", "인터넷",
            "웹에서", "웹으로", "웹에", "웹",
            "온라인에서", "온라인으로", "온라인",
            "구글에서", "구글로", "구글에", "구글",
            "검색해서 알려 줘요", "검색해서 알려줘요", "검색해서 알려 줘", "검색해서 알려줘",
            "검색하고 알려 줘", "검색하고 알려줘", "검색해 줘요", "검색해줘요",
            "검색해 줘", "검색해줘", "검색해", "검색", "서칭해줘", "서칭해", "서칭",
            "찾아서 알려 줘", "찾아서 알려줘", "찾아 줘", "찾아줘",
            "찾어 줘", "찾어줘", "알아봐 줘", "알아봐줘", "알아봐",
            "결과를 알려 줘", "결과 알려 줘", "결과를 알려줘", "결과 알려줘",
            "알려 줘요", "알려줘요", "알려 줘", "알려줘", "좀", "부탁해"
        ]
        for token in removable {
            query = query.replacingOccurrences(of: token, with: " ")
        }

        return query
            .replacingOccurrences(of: #"[?!,.]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractRestaurantQuery(from text: String) -> String {
        var query = text
        let removable = [
            "현재 위치를 기반으로 해서", "현재 위치를 기반으로", "현재 위치 기반으로", "현재 위치 기준",
            "현재 위치에서", "지금 위치에서", "내 위치에서", "내 주변에서", "내 주변",
            "이 근처에서", "이 근처", "근처에서", "근처에", "주변에서", "주변에",
            "가까운", "가까이", "근처", "주변",
            "가장 인기가 많고", "가장 인기 있는", "인기가 많은", "인기 있는",
            "평가가 좋은", "평점이 높은", "평점 좋은", "평가 좋은", "제일 좋은",
            "추천해 줘요", "추천해줘요", "추천해 줘", "추천해줘", "추천해", "추천",
            "찾아 줘요", "찾아줘요", "찾아 줘", "찾아줘", "찾어 줘", "찾어줘", "찾아", "찾어",
            "알려 줘요", "알려줘요", "알려 줘", "알려줘", "알려줘", "어디야", "어디가 좋아",
            "음식점을", "음식점", "음식집을", "음식집", "맛집을", "맛집", "식당을", "식당",
            "레스토랑을", "레스토랑", "세 곳", "3곳", "기준", "잘하는", "가장", "인기", "평가", "평점", "좋은",
            "뭐 먹지", "뭐 먹을까", "먹을 데", "먹을 곳", "식사할 곳"
        ]

        for token in removable {
            query = query.replacingOccurrences(of: token, with: " ")
        }

        let cleanedQuery = query
            .replacingOccurrences(of: #"[?!,.]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "밥 먹을 데"의 '밥'은 음식 종류가 아니라 일반적인 식사 표현이다.
        // 단, "초밥집"처럼 음식명 안에 포함된 글자는 보존한다.
        if ["밥", "밥을"].contains(cleanedQuery) {
            return ""
        }
        if cleanedQuery == "한식집" { return "한식" }
        return cleanedQuery
    }

    private func looksLikeIncompleteCommand(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let incompleteCommands = [
            "틀어줘", "재생해줘", "들려줘", "열어줘", "실행해줘",
            "전화해줘", "전화걸어줘", "통화해줘", "알려줘", "해줘"
        ]
        return incompleteCommands.contains(compact)
    }

    private func containsAppOpenVerb(_ text: String) -> Bool {
        ["열어", "실행", "켜 줘", "켜줘", "켜주", "켜줘요", "띄워", "시작해", "접속해", "들어가", "전환해"].contains {
            text.contains($0)
        }
    }

    private func extractAppName(from text: String) -> String {
        var appName = text
        let removable = [
            "열어 줘요", "열어줘요", "열어 줘", "열어줘", "열어",
            "실행해 줘요", "실행해줘요", "실행해 줘", "실행해줘",
            "실행해", "실행", "켜주세요", "켜줘요", "켜 줘", "켜줘", "켜주",
            "띄워 줘요", "띄워줘요", "띄워 줘", "띄워줘", "띄워",
            "시작해 줘", "시작해줘", "시작해", "접속해 줘", "접속해줘", "접속해",
            "들어가 줘", "들어가줘", "들어가", "전환해 줘", "전환해줘", "전환해",
            "화면을", "화면", "어플을", "어플", "줄래요", "줄래", "주세요", "혹시", "좀", "부탁해", "앱을", "앱",
            "다시", "그거", "그것", "그 앱", "그앱", "아니"
        ]

        for token in removable {
            appName = appName.replacingOccurrences(of: token, with: " ")
        }

        var result = appName
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"(?:으로|로|을|를)$"#, with: "", options: .regularExpression)
        if result == "카톡" { return "카카오톡" }
        return result
    }

    private func isContextOnlyAppName(_ appName: String) -> Bool {
        let compact = appName.filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["그", "그거", "그것", "그앱", "이거", "저거"].contains(compact)
    }

    private func containsYouTubeName(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return compact.contains("유튜브") || compact.contains("youtube")
    }

    private func containsPlaylistTopic(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return compact.contains("재생목록") || compact.contains("플레이리스트")
            || compact.contains("저장된") && compact.contains("목록")
            || compact.contains("유튜브") && compact.contains("목록")
    }

    private func extractPlaylistName(from text: String) -> String {
        var name = text.replacingOccurrences(
            of: #"(?i)(?:유튜브|you\s*tube)\s*(?:에서|에|로)?"#,
            with: " ",
            options: .regularExpression
        )
        let removable = [
            "사용자가 따로 저장한", "내가 따로 저장한", "내가 저장한", "내가 만든",
            "사용자가 저장한", "따로 저장한", "저장한", "만든",
            "재생 목록", "재생목록", "플레이리스트", "저장된", "목록을", "목록", "내",
            "재생해 줘", "재생해줘", "재생해", "재생", "틀어 줘", "틀어줘", "틀어",
            "들려 줘", "들려줘", "들려", "플레이해 줘", "플레이해줘", "플레이해",
            "시작해 줘", "시작해줘", "시작해", "켜 줘", "켜줘", "열어 줘", "열어줘", "열어",
            "줄래요", "줄래", "주세요", "주라", "혹시", "좀", "부탁해"
        ]

        for token in removable {
            name = name.replacingOccurrences(of: token, with: " ")
        }

        return name
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractYouTubeQuery(from text: String) -> String {
        var query = text.replacingOccurrences(
            of: #"(?i)(?:유튜브|you\s*tube)\s*(?:에서|에|로)?"#,
            with: " ",
            options: .regularExpression
        )
        let removable = [
            "재생해 줘", "재생해줘", "재생해", "재생", "틀어 줘", "틀어줘", "틀어", "들려 줘",
            "들려줘", "들려", "플레이해 줘", "플레이해줘", "플레이해",
            "켜 줘", "켜줘", "시작해 줘", "시작해줘", "시작해", "듣고 싶어", "듣고싶어",
            "검색해서", "검색하고", "검색", "이번엔", "이번에는", "켜봐", "줄래요", "줄래", "주세요", "주라", "혹시", "좀", "부탁해", "노래를"
        ]

        for token in removable {
            query = query.replacingOccurrences(of: token, with: " ")
        }

        return query
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: #"(?:을|를)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isUnresolvedDeicticCommand(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let references = ["그거", "저거", "이거", "아까거", "거기로", "그사람", "그대로", "다음걸", "아까말한곳", "필요한거"]
        let actions = ["해줘", "열어", "실행", "가줘", "취소", "진행"]
        return references.contains(where: compact.contains)
            && actions.contains(where: compact.contains)
    }
}
