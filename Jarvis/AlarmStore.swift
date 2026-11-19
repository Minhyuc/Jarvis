import Foundation

enum JarvisAlarmBackend: String, Codable, Sendable {
    case alarmKit
    case localNotification
}

struct JarvisAlarmRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var date: Date
    var label: String
    var message: String
    var delivery: AlarmDeliveryMode
    var isEnabled: Bool
    var backend: JarvisAlarmBackend
    var notificationIdentifier: String?
    var soundFileName: String?
    let createdAt: Date

    var effectiveLabel: String { label.isEmpty ? "알람" : label }
}

extension JarvisAlarmRecord {
    private enum CodingKeys: String, CodingKey {
        case id, date, label, message, delivery, isEnabled, backend
        case notificationIdentifier, soundFileName, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        label = try values.decode(String.self, forKey: .label)
        message = try values.decode(String.self, forKey: .message)
        // 기존 저장 데이터는 모두 시스템 알람으로 마이그레이션한다.
        delivery = try values.decodeIfPresent(AlarmDeliveryMode.self, forKey: .delivery) ?? .system
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        backend = try values.decode(JarvisAlarmBackend.self, forKey: .backend)
        notificationIdentifier = try values.decodeIfPresent(String.self, forKey: .notificationIdentifier)
        soundFileName = try values.decodeIfPresent(String.self, forKey: .soundFileName)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

@MainActor
final class AlarmStore: ObservableObject {
    static let shared = AlarmStore()

    @Published private(set) var alarms: [JarvisAlarmRecord]
    @Published private(set) var storageIssue: String?
    let persistence: RecordPersistence<JarvisAlarmRecord>
    var canRestore: Bool { persistence.canRestore }

    init(defaults: UserDefaults = .standard, persistence: RecordPersistence<JarvisAlarmRecord>? = nil) {
        let persistence = persistence ?? RecordPersistence<JarvisAlarmRecord>(defaults: defaults, key: "jarvis.savedAlarms.v2")
        self.persistence = persistence
        alarms = persistence.load().sorted { $0.date < $1.date }
        if Set(alarms.map(\.id)).count != alarms.count {
            persistence.invalidate("중복된 알람 식별자가 있습니다. 원본을 보존하고 변경을 차단했습니다.")
        }
        storageIssue = persistence.issue
    }
    func ensureWritable() throws { try persistence.ensureWritable() }
    func restore(confirmed: Bool) throws {
        alarms = try persistence.restore(confirmed: confirmed).sorted { $0.date < $1.date }
        storageIssue = persistence.issue
    }

    func record(id: UUID) -> JarvisAlarmRecord? { alarms.first { $0.id == id } }

    func upsert(_ record: JarvisAlarmRecord) throws {
        var next = alarms
        if let index = next.firstIndex(where: { $0.id == record.id }) {
            next[index] = record
        } else {
            next.append(record)
        }
        try replace(with: next)
    }

    func remove(id: UUID) throws {
        try replace(with: alarms.filter { $0.id != id })
    }

    func replace(with records: [JarvisAlarmRecord]) throws {
        do { try persistence.save(records) }
        catch { storageIssue = persistence.issue; throw error }
        alarms = records.sorted { $0.date < $1.date }
        storageIssue = persistence.issue
    }
}
