import Foundation

public enum AssistantIntent: Equatable, Sendable {
    case playYouTube(query: String)
    case generalConversation(text: String)
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
