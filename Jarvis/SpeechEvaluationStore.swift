import Foundation
import SwiftUI

struct PendingSpeechEvaluationCase: Identifiable, Equatable {
    let id = UUID()
    let input: String
    let expectedIntentDescription: String
}

/// Raw speech transcripts are never persisted by this store. Only explicit
/// user-approved, vocabulary-limited examples are kept on this device.
@MainActor
final class SpeechEvaluationStore: ObservableObject {
    static let shared = SpeechEvaluationStore()

    @Published var collectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(collectionEnabled, forKey: Self.enabledKey)
            if !collectionEnabled { pending.removeAll() }
        }
    }
    @Published private(set) var pending: [PendingSpeechEvaluationCase] = []
    @Published private(set) var approved: [ApprovedSpeechEvaluationCase]

    private static let enabledKey = "jarvis.speech-evaluation.collection-enabled"
    private static let approvedKey = "jarvis.speech-evaluation.approved-v1"
    private let filter = SpeechEvaluationPrivacyFilter()

    private init() {
        collectionEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let data = UserDefaults.standard.data(forKey: Self.approvedKey)
        approved = data.flatMap { try? JSONDecoder().decode([ApprovedSpeechEvaluationCase].self, from: $0) } ?? []
    }

    func consider(_ rawText: String, intent: AssistantIntent) {
        guard collectionEnabled,
              let input = filter.candidate(from: rawText, intent: intent) else { return }
        let expected = String(describing: intent)
        guard !pending.contains(where: { $0.input == input }),
              !approved.contains(where: { $0.input == input }) else { return }
        pending.append(.init(input: input, expectedIntentDescription: expected))
        if pending.count > 20 { pending.removeFirst(pending.count - 20) }
    }

    func approve(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        approved.append(.init(input: item.input, expectedIntentDescription: item.expectedIntentDescription))
        if approved.count > 200 { approved.removeFirst(approved.count - 200) }
        persist()
    }

    func reject(_ id: UUID) {
        pending.removeAll { $0.id == id }
    }

    func deleteApproved(_ id: UUID) {
        approved.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        pending.removeAll()
        approved.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.approvedKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(approved) else { return }
        UserDefaults.standard.set(data, forKey: Self.approvedKey)
    }
}
