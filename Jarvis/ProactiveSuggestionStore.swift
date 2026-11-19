import Foundation

enum ProactiveSuggestionMode: String, CaseIterable, Identifiable {
    case disabled
    case requiresApproval
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "제안 안 함"
        case .requiresApproval: "버튼·명령으로 실행"
        case .automatic: "안전한 제안 자동 실행"
        }
    }

    var detail: String {
        switch self {
        case .disabled:
            "자비스가 먼저 제안하지 않습니다."
        case .requiresApproval:
            "제안을 보여주고, 사용자가 버튼을 누르거나 제안 실행 명령을 했을 때만 실행합니다."
        case .automatic:
            "정보 안내와 낮은 위험 제안은 자동 실행하고, 보통 위험은 확인하며, 높은 위험 제안은 차단합니다. 장기 기억 저장은 별도 동의가 필요합니다."
        }
    }
}

@MainActor
final class ProactiveSuggestionSettingsStore: ObservableObject {
    static let shared = ProactiveSuggestionSettingsStore()

    @Published var mode: ProactiveSuggestionMode {
        didSet {
            defaults.set(mode.rawValue, forKey: modeKey)
            NotificationCenter.default.post(name: .jarvisSuggestionModeChanged, object: nil)
        }
    }
    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let kind: String
        let outcome: String
    }
    @Published private(set) var events: [Event] = []

    private let defaults: UserDefaults
    private let modeKey = "jarvis.proactiveSuggestions.mode"
    // Kept only to migrate the previous on/off setting.
    private let enabledKey = "jarvis.proactiveSuggestions.enabled"
    private let historyKey = "jarvis.proactiveSuggestions.lastShown"
    private let cooldown: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawMode = defaults.string(forKey: modeKey),
           let savedMode = ProactiveSuggestionMode(rawValue: rawMode) {
            mode = savedMode
        } else if defaults.object(forKey: enabledKey) != nil,
                  !defaults.bool(forKey: enabledKey) {
            mode = .disabled
        } else {
            mode = .requiresApproval
        }
        defaults.set(mode.rawValue, forKey: modeKey)
        if let data = defaults.data(forKey: "jarvis.proactive.events"),
           let saved = try? JSONDecoder().decode([Event].self, from: data) { events = Array(saved.prefix(50)) }
    }

    func canPresent(_ suggestion: ProactiveSuggestion, now: Date = Date()) -> Bool {
        guard mode != .disabled else { return false }
        guard now >= suggestion.observedAt, now < suggestion.expiresAt else { return false }
        let history = defaults.dictionary(forKey: historyKey) as? [String: Date] ?? [:]
        guard let lastShown = history[suggestion.id] else { return true }
        return now.timeIntervalSince(lastShown) >= cooldown
    }

    func markPresented(_ suggestion: ProactiveSuggestion, now: Date = Date()) {
        var history = defaults.dictionary(forKey: historyKey) as? [String: Date] ?? [:]
        history[suggestion.id] = now
        if history.count > 50 {
            let newest = history.sorted { $0.value > $1.value }.prefix(50)
            history = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        defaults.set(history, forKey: historyKey)
    }

    func resetHistory() {
        defaults.removeObject(forKey: historyKey)
    }

    func record(_ suggestion: ProactiveSuggestion, outcome: String) {
        events.insert(.init(id: UUID(), date: Date(), kind: String(suggestion.id.prefix(80)), outcome: outcome), at: 0)
        events = Array(events.prefix(50))
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: "jarvis.proactive.events") }
    }
}

extension Notification.Name { static let jarvisSuggestionModeChanged = Notification.Name("jarvis.suggestion.mode.changed") }
