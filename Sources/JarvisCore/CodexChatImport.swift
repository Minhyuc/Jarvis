import CryptoKit
import Foundation

/// Reads the active text branch of a user-selected ChatGPT conversation export.
public struct CodexChatImport: Identifiable, Sendable {
    public let id = UUID()
    public let threads: [CodexChatThread]
    public let omittedCount: Int
    public static let byteLimit = 32 * 1024 * 1024

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= byteLimit,
              let records = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CodexLocalError.invalid
        }
        var threads: [CodexChatThread] = []
        var fingerprints = Set<String>()
        var bytes = 0
        for record in records {
            try Task.checkCancellation()
            guard threads.count < 30 else { break }
            guard let record = record as? [String: Any],
                  let rawID = (record["conversation_id"] ?? record["id"]) as? String,
                  !rawID.isEmpty, rawID.utf8.count <= 256,
                  let mapping = record["mapping"] as? [String: Any], mapping.count <= 10_000,
                  let current = record["current_node"] as? String,
                  let messages = activeMessages(mapping: mapping, current: current),
                  !messages.isEmpty else { continue }

            let fingerprint = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()
            guard !fingerprints.contains(fingerprint) else { continue }
            var title = (record["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = "가져온 대화" }
            title = String(title.prefix(40))
            while title.utf8.count > 160 { title.removeLast() }
            if title.isEmpty { title = "가져온 대화" }
            var thread = CodexChatThread(title: title)
            thread.importFingerprint = fingerprint
            thread.messages = messages
            let size = try JSONEncoder().encode(thread).count
            guard bytes + size <= 4 * 1024 * 1024 else { continue }
            fingerprints.insert(fingerprint)
            threads.append(thread)
            bytes += size
        }
        return Self(threads: threads, omittedCount: records.count - threads.count)
    }

    private static func activeMessages(mapping: [String: Any], current: String) -> [CodexChatMessage]? {
        var cursor: String? = current
        var visited = Set<String>()
        var messages: [CodexChatMessage] = []
        while let key = cursor {
            guard visited.insert(key).inserted, let node = mapping[key] as? [String: Any] else { return nil }
            if let parent = node["parent"], !(parent is NSNull) {
                guard let parentKey = parent as? String else { return nil }
                cursor = parentKey
            } else {
                cursor = nil
            }

            guard let message = node["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let roleName = author["role"] as? String, let role = CodexChatMessage.Role(rawValue: roleName),
                  role == .user || role == .assistant,
                  (message["recipient"] as? String ?? "all") == "all",
                  (message["channel"] as? String) != "analysis",
                  (message["metadata"] as? [String: Any])?["is_visually_hidden_from_conversation"] as? Bool != true,
                  let content = message["content"] as? [String: Any],
                  content["content_type"] as? String == "text",
                  let parts = content["parts"] as? [String] else { continue }
            let text = parts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // Keep a complete branch within the local store limits.
            guard messages.count < 197, text.utf8.count <= 8192 else { return nil }
            var item = CodexChatMessage(role: role, text: text)
            item.imported = true
            if let seconds = message["create_time"] as? Double, seconds.isFinite, (0...4102444800).contains(seconds) {
                item.date = Date(timeIntervalSince1970: seconds)
            }
            messages.append(item)
        }
        return messages.reversed()
    }
}
