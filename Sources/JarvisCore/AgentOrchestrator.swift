import Foundation

public enum AgentResolutionSource: Equatable, Sendable {
    case deterministic
    case semanticModel
}

public struct AgentIntentResolution: Equatable, Sendable {
    public let intent: AssistantIntent
    public let source: AgentResolutionSource

    public init(intent: AssistantIntent, source: AgentResolutionSource) {
        self.intent = intent
        self.source = source
    }
}

public enum AgentResolution: Equatable, Sendable {
    case intent(AgentIntentResolution)
    case clarification(String)
}

public enum SemanticCapabilityID: String, CaseIterable, Codable, Sendable {
    case conversation
    case playYouTube
    case playYouTubePlaylist
    case identifySong
    case pauseMedia
    case setVolume
    case adjustVolume
    case fullBriefing
    case weather
    case calendar
    case time
    case recommendRestaurants
    case webSearch
    case navigate
    case nearbyPlaces
    case call
    case openApp
    case assistantCapabilities
    case unknown
}

public struct SemanticIntentCandidate: Equatable, Sendable {
    public let capabilityID: SemanticCapabilityID
    public let primaryArgument: String
    public let secondaryArgument: String
    public let confidence: Double

    public init(
        capabilityID: SemanticCapabilityID,
        primaryArgument: String = "",
        secondaryArgument: String = "",
        confidence: Double
    ) {
        self.capabilityID = capabilityID
        self.primaryArgument = primaryArgument
        self.secondaryArgument = secondaryArgument
        self.confidence = min(max(confidence, 0), 1)
    }
}

public struct SemanticResolutionContext: Equatable, Sendable {
    public let summary: String?
    public let recentUserTexts: [String]

    public init(summary: String?, recentUserTexts: [String]) {
        self.summary = summary
        self.recentUserTexts = recentUserTexts
    }
}

public protocol SemanticIntentResolving: Sendable {
    func interpretCommand(
        _ text: String,
        capabilities: String,
        context: SemanticResolutionContext
    ) async throws -> SemanticIntentCandidate?
}

public struct CapabilityDescriptor: Equatable, Sendable {
    public let id: SemanticCapabilityID
    public let summary: String
    public let requiresPrimaryArgument: Bool

    public init(
        id: SemanticCapabilityID,
        summary: String,
        requiresPrimaryArgument: Bool = false
    ) {
        self.id = id
        self.summary = summary
        self.requiresPrimaryArgument = requiresPrimaryArgument
    }
}

public enum CapabilityResolution: Equatable, Sendable {
    case intent(AssistantIntent)
    case clarification(String)
    case unavailable
}

/// The allowlist between semantic model output and executable intents.
/// A model cannot invent a capability because only identifiers registered here
/// can become an `AssistantIntent`.
public struct CapabilityRegistry: Sendable {
    public let descriptors: [CapabilityDescriptor]

    public init(descriptors: [CapabilityDescriptor] = CapabilityRegistry.standardDescriptors) {
        self.descriptors = descriptors
    }

    public var promptDescription: String {
        descriptors
            .map { "\($0.id.rawValue): \($0.summary)" }
            .joined(separator: "\n")
    }

    public func resolve(
        _ candidate: SemanticIntentCandidate,
        originalText: String
    ) -> CapabilityResolution {
        guard let descriptor = descriptors.first(where: { $0.id == candidate.capabilityID }) else {
            return .unavailable
        }

        let primary = candidate.primaryArgument.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = candidate.secondaryArgument
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if descriptor.requiresPrimaryArgument, primary.isEmpty {
            return .clarification(clarificationPrompt(for: candidate.capabilityID))
        }

        switch candidate.capabilityID {
        case .conversation:
            return .intent(.generalConversation(text: originalText))
        case .playYouTube:
            return .intent(.playYouTube(query: primary))
        case .playYouTubePlaylist:
            return .intent(.playYouTubePlaylist(name: primary))
        case .identifySong:
            return .intent(.identifySong)
        case .pauseMedia:
            return .intent(.pauseMedia)
        case .setVolume:
            guard let percent = integer(in: primary) else {
                return .clarification("볼륨을 몇 퍼센트로 조절할까요?")
            }
            return .intent(.setVolume(percent: min(max(percent, 0), 100)))
        case .adjustVolume:
            guard let delta = integer(in: primary), delta != 0 else {
                return .clarification("볼륨을 얼마나 올리거나 내릴까요?")
            }
            return .intent(.adjustVolume(delta: min(max(delta, -100), 100)))
        case .fullBriefing:
            return .intent(.fullBriefing)
        case .weather:
            return .intent(.weather(weatherRequest(from: secondary)))
        case .calendar:
            return .intent(.calendar(calendarRequest(from: secondary)))
        case .time:
            return .intent(.time(timeRequest(from: secondary)))
        case .recommendRestaurants:
            return .intent(.recommendRestaurants(query: primary.isEmpty ? nil : primary))
        case .webSearch:
            return .intent(.webSearch(query: primary))
        case .navigate:
            let destination = NavigationDestinationNormalizer().normalize(primary)
            guard !destination.isEmpty else {
                return .clarification(clarificationPrompt(for: .navigate))
            }
            return .intent(.navigate(
                destination: destination,
                mode: travelMode(from: secondary) ?? .publicTransit
            ))
        case .call:
            let speakerRequested = ["speaker", "speakerphone", "스피커", "스피커폰"]
                .contains(where: secondary.contains)
            return .intent(.call(recipient: primary, speakerRequested: speakerRequested))
        case .nearbyPlaces:
            guard let category = NearbyPlaceCategory(rawValue: primary) ?? NearbyPlaceCategory.parse(primary) else {
                return .clarification("마트, 약국, 병원, 주차장, 카페 중 어떤 장소를 찾을까요?")
            }
            return .intent(.nearbyPlaces(category: category, navigate: secondary.hasPrefix("navigate"),
                                        mode: travelMode(from: secondary)))
        case .openApp:
            return .intent(.openApp(name: primary))
        case .assistantCapabilities:
            return .intent(.assistantCapabilities)
        case .unknown:
            return .unavailable
        }
    }

    public static let standardDescriptors: [CapabilityDescriptor] = [
        .init(id: .conversation, summary: "일반적인 대화나 질문. 기기 동작을 실행하지 않음"),
        .init(id: .playYouTube, summary: "YouTube에서 영상이나 노래 재생", requiresPrimaryArgument: true),
        .init(id: .playYouTubePlaylist, summary: "사용자의 YouTube 재생목록 재생", requiresPrimaryArgument: true),
        .init(id: .identifySong, summary: "현재 들리는 노래 찾기"),
        .init(id: .pauseMedia, summary: "현재 미디어 재생 중지"),
        .init(id: .setVolume, summary: "볼륨을 특정 퍼센트로 설정", requiresPrimaryArgument: true),
        .init(id: .adjustVolume, summary: "볼륨을 양수만큼 올리거나 음수만큼 내림", requiresPrimaryArgument: true),
        .init(id: .fullBriefing, summary: "시간, 날씨, 오늘 일정을 함께 브리핑"),
        .init(id: .weather, summary: "날씨 조회. secondaryArgument는 current/high/low/range/rain/umbrella/summary 중 하나"),
        .init(id: .calendar, summary: "일정 조회. secondaryArgument는 today/remaining/next/count 중 하나"),
        .init(id: .time, summary: "시간이나 날짜 조회. secondaryArgument는 time/date/both 중 하나"),
        .init(id: .recommendRestaurants, summary: "현재 위치 주변 음식점 추천. 음식 종류는 primaryArgument"),
        .init(id: .webSearch, summary: "최신 정보나 인터넷 검색", requiresPrimaryArgument: true),
        .init(id: .navigate, summary: "목적지 길 안내. secondaryArgument는 car 또는 transit", requiresPrimaryArgument: true),
        .init(id: .nearbyPlaces, summary: "주변 업종 검색. primaryArgument: market/pharmacy/hospital/parking/cafe. secondaryArgument: search/navigate/navigate_car/navigate_transit", requiresPrimaryArgument: true),
        .init(id: .call, summary: "연락처나 번호로 전화. 스피커 요청은 secondaryArgument", requiresPrimaryArgument: true),
        .init(id: .openApp, summary: "설치된 앱 열기", requiresPrimaryArgument: true),
        .init(id: .assistantCapabilities, summary: "JARVIS가 할 수 있는 기능 안내"),
        .init(id: .unknown, summary: "의도를 안정적으로 판단할 수 없음")
    ]

    private func clarificationPrompt(for id: SemanticCapabilityID) -> String {
        switch id {
        case .playYouTube: return "어떤 영상이나 노래를 재생할까요?"
        case .playYouTubePlaylist: return "어떤 재생목록을 재생할까요?"
        case .setVolume: return "볼륨을 몇 퍼센트로 조절할까요?"
        case .adjustVolume: return "볼륨을 얼마나 올리거나 내릴까요?"
        case .webSearch: return "인터넷에서 무엇을 검색할까요?"
        case .navigate: return "어디까지 길 안내를 시작할까요?"
        case .call: return "누구에게 전화할까요?"
        case .openApp: return "어떤 앱을 열까요?"
        default: return "필요한 대상을 조금 더 구체적으로 말씀해주세요."
        }
    }

    private func integer(in text: String) -> Int? {
        let pattern = #"-?\d+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    private func weatherRequest(from detail: String) -> WeatherRequest {
        if detail.contains("current") || detail.contains("현재") { return .currentTemperature }
        if detail.contains("high") || detail.contains("최고") { return .highTemperature }
        if detail.contains("low") || detail.contains("최저") { return .lowTemperature }
        if detail.contains("range") || detail.contains("범위") { return .temperatureRange }
        if detail.contains("rain") || detail.contains("비") || detail.contains("강수") {
            return .precipitationProbability
        }
        if detail.contains("umbrella") || detail.contains("우산") { return .umbrellaAdvice }
        return .todaySummary
    }

    private func calendarRequest(from detail: String) -> CalendarRequest {
        if detail.contains("remaining") || detail.contains("남은") { return .remainingToday }
        if detail.contains("next") || detail.contains("다음") { return .nextEvent }
        if detail.contains("count") || detail.contains("개수") { return .eventCount }
        return .todaySummary
    }

    private func timeRequest(from detail: String) -> TimeRequest {
        if detail.contains("date") || detail.contains("날짜") { return .todayDate }
        if detail.contains("both") || detail.contains("둘다") { return .currentDateAndTime }
        return .currentTime
    }

    private func travelMode(from detail: String) -> NavigationTravelMode? {
        if detail.contains("car") || detail.contains("차") || detail.contains("운전") { return .car }
        if detail.contains("transit") || detail.contains("대중교통") { return .publicTransit }
        return nil
    }
}

/// Routes exact commands first and asks a language model only when deterministic
/// parsing returns conversation or an incomplete command. Model output still has
/// to pass through `CapabilityRegistry` and `SafetyPolicyEngine`.
public struct AgentOrchestrator: Sendable {
    public let router: CommandRouter
    public let registry: CapabilityRegistry
    public let minimumSemanticConfidence: Double

    public init(
        router: CommandRouter = CommandRouter(),
        registry: CapabilityRegistry = CapabilityRegistry(),
        minimumSemanticConfidence: Double = 0.80
    ) {
        self.router = router
        self.registry = registry
        self.minimumSemanticConfidence = min(max(minimumSemanticConfidence, 0.5), 1)
    }

    public func resolve(
        _ text: String,
        previousIntent: AssistantIntent?,
        context: SemanticResolutionContext,
        semanticResolver: any SemanticIntentResolving
    ) async -> AgentResolution {
        let deterministic = router.route(text, previousIntent: previousIntent)
        guard needsSemanticInterpretation(deterministic) else {
            return .intent(.init(intent: deterministic, source: .deterministic))
        }

        guard let candidate = try? await semanticResolver.interpretCommand(
            text,
            capabilities: registry.promptDescription,
            context: context
        ) else {
            return .intent(.init(intent: deterministic, source: .deterministic))
        }

        if candidate.capabilityID == .conversation {
            return .intent(.init(
                intent: .generalConversation(text: text),
                source: .semanticModel
            ))
        }

        guard candidate.confidence >= minimumSemanticConfidence else {
            if case .unknownCommand = deterministic, candidate.confidence >= 0.55 {
                return .clarification("요청을 정확히 이해하지 못했습니다. 대상과 할 일을 조금 더 구체적으로 말씀해주세요.")
            }
            return .intent(.init(intent: deterministic, source: .deterministic))
        }

        switch registry.resolve(candidate, originalText: text) {
        case .intent(let intent):
            return .intent(.init(intent: intent, source: .semanticModel))
        case .clarification(let prompt):
            return .clarification(prompt)
        case .unavailable:
            return .intent(.init(intent: deterministic, source: .deterministic))
        }
    }

    private func needsSemanticInterpretation(_ intent: AssistantIntent) -> Bool {
        switch intent {
        case .generalConversation, .unknownCommand: true
        default: false
        }
    }
}
