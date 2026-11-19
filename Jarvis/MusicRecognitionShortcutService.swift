import Foundation
import UIKit

struct MusicRecognitionShortcutRequest: Equatable {
    let token: String
}

@MainActor
struct MusicRecognitionShortcutService {
    static let shortcutName = "노래 찾기"

    func makeRequest() -> MusicRecognitionShortcutRequest {
        MusicRecognitionShortcutRequest(token: UUID().uuidString)
    }

    func run(_ request: MusicRecognitionShortcutRequest) async -> ToolExecutionResult<Void> {
        guard !Task.isCancelled else { return .failed(message: "노래 찾기를 취소했습니다.", retryable: false) }
        switch SafetyPolicyEngine().evaluate(.identifySong, context: .init(externalActionsLocked: SafetyControlStore.externalActionsLocked)) {
        case .allow: break
        case .block(_, _, let reason): return .failed(message: reason, retryable: false)
        case .requireConfirmation(_, _, let prompt): return .needsConfirmation(message: prompt)
        }
        guard let url = makeRunURL(for: request) else {
            return .failed(message: "노래 찾기 단축어 주소를 만들지 못했습니다.", retryable: false)
        }
        if await UIApplication.shared.open(url) {
            return .handedOff(())
        }
        return .failed(message: "노래 찾기 단축어를 열지 못했습니다.", retryable: true)
    }

    private func makeRunURL(for request: MusicRecognitionShortcutRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: Self.shortcutName),
            URLQueryItem(
                name: "x-success",
                value: callbackURL(path: "song-success", token: request.token)
            ),
            URLQueryItem(
                name: "x-cancel",
                value: callbackURL(path: "song-cancel", token: request.token)
            ),
            URLQueryItem(
                name: "x-error",
                value: callbackURL(path: "song-error", token: request.token)
            )
        ]
        return components.url
    }

    private func callbackURL(path: String, token: String) -> String {
        var components = URLComponents()
        components.scheme = "jarvis"
        components.host = "shortcut"
        components.path = "/\(path)"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url?.absoluteString ?? ""
    }
}
