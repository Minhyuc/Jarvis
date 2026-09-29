import Foundation

public struct CommandRouter: Sendable {
    public init() {}

    public func route(_ rawText: String) -> AssistantIntent {
        let normalized = normalize(rawText)

        if normalized.contains("유튜브") && containsPlayVerb(normalized) {
            let query = extractYouTubeQuery(from: normalized)
            if !query.isEmpty {
                return .playYouTube(query: query)
            }
        }

        return .generalConversation(text: rawText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func containsWakeWord(_ rawText: String) -> Bool {
        let compact = rawText
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        return compact.contains("자비스")
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "자비스야", with: "")
            .replacingOccurrences(of: "자비스", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsPlayVerb(_ text: String) -> Bool {
        ["틀어", "재생", "들려", "플레이"].contains { text.contains($0) }
    }

    private func extractYouTubeQuery(from text: String) -> String {
        var query = text
        let removable = [
            "유튜브에서", "유튜브로", "유튜브", "재생해 줘", "재생해줘",
            "재생해", "재생", "틀어 줘", "틀어줘", "틀어", "들려 줘",
            "들려줘", "들려", "플레이해 줘", "플레이해줘", "플레이해",
            "노래를", "노래"
        ]

        for token in removable {
            query = query.replacingOccurrences(of: token, with: " ")
        }

        return query
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
