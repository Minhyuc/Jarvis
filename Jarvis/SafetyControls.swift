import Combine
import Foundation

enum SafetyControlStore {
    static let externalActionsLockKey = "jarvis.safety.externalActionsLocked"

    static var externalActionsLocked: Bool {
        get { UserDefaults.standard.bool(forKey: externalActionsLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: externalActionsLockKey) }
    }
}

enum SafetyAuditOutcome: String, Codable {
    case authorized
    case awaitingConfirmation
    case blocked
    case confirmed
    case cancelled
}

struct SafetyAuditEvent: Identifiable, Codable {
    let id: UUID
    let date: Date
    let actionName: String
    let risk: ActionRiskLevel
    let outcome: SafetyAuditOutcome
}

/// Records only a generic action category and the policy result. Command text,
/// contact names, destinations, memory contents, and other personal data are
/// deliberately excluded.
@MainActor
final class SafetyAuditStore: ObservableObject {
    static let shared = SafetyAuditStore()

    @Published private(set) var events: [SafetyAuditEvent]

    private let defaultsKey = "jarvis.safety.audit.v1"
    private let maximumEventCount = 200

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SafetyAuditEvent].self, from: data) else {
            events = []
            return
        }
        events = decoded
    }

    func record(
        actionName: String,
        risk: ActionRiskLevel,
        outcome: SafetyAuditOutcome
    ) {
        events.insert(
            SafetyAuditEvent(
                id: UUID(),
                date: Date(),
                actionName: actionName,
                risk: risk,
                outcome: outcome
            ),
            at: 0
        )
        if events.count > maximumEventCount {
            events.removeLast(events.count - maximumEventCount)
        }
        persist()
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
