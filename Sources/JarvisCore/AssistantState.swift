import Foundation

public enum AssistantState: Equatable, Sendable {
    case idle
    case preparing
    case waitingForWakeWord
    case wakeWordDetected
    case listeningForCommand
    case transcribing
    case thinking
    case speaking
    case interrupted
    case error(String)

    public var displayText: String {
        switch self {
        case .idle: return "대기 중"
        case .preparing: return "준비 중"
        case .waitingForWakeWord: return "‘자비스’를 기다리는 중"
        case .wakeWordDetected: return "호출됨"
        case .listeningForCommand: return "듣는 중"
        case .transcribing: return "음성을 처리하는 중"
        case .thinking: return "생각하는 중"
        case .speaking: return "말하는 중"
        case .interrupted: return "오디오가 중단됨"
        case .error(let message): return message
        }
    }
}
