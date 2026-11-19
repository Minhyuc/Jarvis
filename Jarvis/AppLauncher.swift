import Foundation
import UIKit

struct AppLaunchDestination {
    let url: URL
    let usesShortcut: Bool
    let shortcutName: String?
}

@MainActor
struct AppLauncher {
    func shortcut(named rawName: String, input: String? = nil) -> AppLaunchDestination? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let input, !input.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "input", value: "text"))
            components.queryItems?.append(URLQueryItem(name: "text", value: input))
        }
        guard let url = components.url else { return nil }
        return AppLaunchDestination(url: url, usesShortcut: true, shortcutName: name)
    }

    func destination(for requestedName: String) -> AppLaunchDestination? {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if let directURL = directURL(for: name) {
            return AppLaunchDestination(url: directURL, usesShortcut: false, shortcutName: nil)
        }

        return shortcut(named: "\(name) 열기")
    }

    func open(_ destination: AppLaunchDestination) async -> ToolExecutionResult<Void> {
        if await UIApplication.shared.open(destination.url) {
            return .handedOff(())
        }
        return .failed(message: "요청한 앱을 열지 못했습니다.", retryable: true)
    }

    private func directURL(for requestedName: String) -> URL? {
        let compact = requestedName
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }

        let urlString: String?
        switch compact {
        case "유튜브", "youtube":
            urlString = "https://www.youtube.com"
        case "사파리", "브라우저", "safari":
            urlString = "https://www.apple.com"
        case "지도", "애플지도", "maps":
            urlString = "https://maps.apple.com"
        case "메시지", "문자", "messages":
            urlString = "sms:"
        case "메일", "mail":
            urlString = "mailto:"
        case "페이스타임", "facetime":
            urlString = "facetime:"
        case "단축어", "shortcuts":
            urlString = "shortcuts://"
        default:
            urlString = nil
        }

        return urlString.flatMap(URL.init(string:))
    }
}
