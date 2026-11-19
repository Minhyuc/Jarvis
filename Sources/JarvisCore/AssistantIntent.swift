import Foundation

public enum WeatherRequest: Equatable, Sendable {
    case todaySummary
    case currentTemperature
    case highTemperature
    case lowTemperature
    case temperatureRange
    case precipitationProbability
    case umbrellaAdvice
}

public enum CalendarRequest: Equatable, Sendable {
    case todaySummary
    case remainingToday
    case nextEvent
    case eventCount
}

public enum TimeRequest: Equatable, Sendable {
    case currentTime
    case todayDate
    case currentDateAndTime
}

public enum NavigationTravelMode: String, Equatable, Sendable {
    case car
    case publicTransit
}

public enum AlarmRequest: Equatable, Sendable {
    case afterMinutes(Int)
    case atTime(
        hour: Int,
        minute: Int,
        period: AlarmPeriod?,
        day: AlarmDaySelection
    )
}

public enum AlarmPeriod: String, Equatable, Sendable {
    case am
    case pm
}

public enum AlarmDaySelection: String, Equatable, Sendable {
    case automatic
    case today
    case tomorrow
}

public enum AlarmDeliveryMode: String, Codable, Equatable, Hashable, Sendable {
    case system
    case jarvisVoice
}

public enum MemoryForgetScope: Equatable, Sendable {
    case all
    case latest
    case matching(String)
}

public enum AlarmListFilter: Equatable, Sendable {
    case all
    case today
    case tomorrow
    case next
    case named(String)
}

public enum AlarmQuery: Equatable, Sendable {
    case all
    case today
    case tomorrow
    case latest
    case next
    case named(String)
    case atTime(AlarmRequest)
}

public struct AlarmUpdate: Equatable, Sendable {
    public let request: AlarmRequest?
    public let label: String?

    public init(request: AlarmRequest? = nil, label: String? = nil) {
        self.request = request
        self.label = label
    }
}

public enum AssistantIntent: Equatable, Sendable {
    case codexLocal(CodexLocalAction)
    case projectWorkflow(SharedProjectWorkflow)
    /// User-selected document-provider folder. UI-only; not a semantic tool.
    case sharedProject(SharedProjectAction)
    /// Explicit development-space UI only; never a semantic capability.
    case macWorkspace(MacWorkspaceAction)
    /// Deterministic maintenance/UI operations. Never model-selectable.
    case localData(LocalDataAction)
    case dismissConversation
    case identifySong
    case playYouTube(query: String)
    case playYouTubePlaylist(name: String)
    case pauseMedia
    case setVolume(percent: Int)
    case adjustVolume(delta: Int)
    case setAlarm(
        request: AlarmRequest,
        label: String?,
        message: String?,
        delivery: AlarmDeliveryMode
    )
    case stopActiveAlarm
    case listAlarms(AlarmListFilter)
    case cancelAlarm(AlarmQuery)
    case updateAlarm(query: AlarmQuery, update: AlarmUpdate)
    case fullBriefing
    case weather(WeatherRequest)
    case calendar(CalendarRequest)
    case calendarWorkflow(CalendarWorkflowCommand)
    case prepareOuting(dayOffset: Int)
    case resolveMemoryConflict(keepID: UUID, removeIDs: [UUID])
    case time(TimeRequest)
    case recommendRestaurants(query: String?)
    case webSearch(query: String)
    case remember(content: String)
    case forgetMemory(MemoryForgetScope)
    case listMemories
    case navigate(destination: String, mode: NavigationTravelMode?)
    case nearbyPlaces(category: NearbyPlaceCategory, navigate: Bool, mode: NavigationTravelMode?)
    /// Settings-only review/collection controls; never semantic capabilities.
    case configureImprovementCollection
    case reviewImprovementData
    case deleteImprovementData
    case assistImprovementData
    case runResponseEvaluation
    case configureCommandPractice
    case runCommandPractice
    case applyCommandPractice
    case removeCommandPractice
    case call(recipient: String, speakerRequested: Bool)
    case openApp(name: String)
    case assistantCapabilities
    case unknownCommand(text: String)
    case generalConversation(text: String)
    /// Settings-only. Never exposed to semantic model capability selection.
    case configureCloudAI
    case disableCloudAI
}

public enum LocalDataAction: Equatable, Sendable {
    case createAlarm, changeAlarm, deleteAlarm, deleteAllCalendarEvents
    case refreshNotifications, reconcileAlarms, restoreStorage
}

public struct CommandResult: Equatable, Sendable {
    public let success: Bool
    public let spokenResponse: String
    public let action: AssistantIntent

    public init(success: Bool, spokenResponse: String, action: AssistantIntent) {
        self.success = success
        self.spokenResponse = spokenResponse
        self.action = action
    }
}
