import Foundation
import SwiftUI

enum LocalDataError: LocalizedError {
    case blocked(String), confirmation(String), permission(String), unverified(String), storage, recovery, changed
    var errorDescription: String? {
        switch self {
        case .blocked(let message), .confirmation(let message), .permission(let message), .unverified(let message): return message
        case .storage: return "저장하지 못했습니다. 기존 목록을 유지했습니다. 저장 공간과 데이터 상태를 확인해주세요."
        case .recovery: return "변경 또는 복구를 확인하지 못했습니다. 예약 상태 확인이 필요합니다. 자동으로 다시 실행하지 않습니다."
        case .changed: return "확인 중 대상이 변경되었습니다. 다시 열어 확인해주세요."
        }
    }
}

/// One boundary for UI, speech and maintenance writes. Logs contain no payloads.
@MainActor
enum LocalDataExecution {
    static func check(_ intent: AssistantIntent, origin: SafetyExecutionOrigin = .directUserRequest,
                      confirmed: Bool = false) throws {
        try Task.checkCancellation()
        switch SafetyPolicyEngine().evaluate(intent, context: .init(origin: origin,
            externalActionsLocked: SafetyControlStore.externalActionsLocked, wasExplicitlyConfirmed: confirmed)) {
        case .allow(let risk, let name):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .authorized)
        case .requireConfirmation(let risk, let name, let prompt):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .awaitingConfirmation)
            throw LocalDataError.confirmation(prompt)
        case .block(let risk, let name, let reason):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .blocked)
            throw LocalDataError.blocked(reason)
        }
    }

    static func perform<T: Sendable>(_ intent: AssistantIntent, confirmed: Bool = false,
        origin: SafetyExecutionOrigin = .directUserRequest,
        operation: @escaping @MainActor @Sendable () async throws -> T) async -> ToolExecutionResult<T> {
        await ToolExecutionCoordinator.shared.execute(key: "local-data-mutation", timeout: .seconds(45)) {
            @MainActor in
            do {
                try check(intent, origin: origin, confirmed: confirmed)
                return .succeeded(try await operation())
            } catch LocalDataError.confirmation(let message) { return .needsConfirmation(message: message)
            } catch LocalDataError.permission(let message) { return .needsPermission(message: message)
            } catch LocalDataError.blocked(let message) { return .failed(message: message, retryable: false)
            } catch LocalDataError.recovery { return .unverifiable(message: LocalDataError.recovery.localizedDescription)
            } catch LocalDataError.unverified(let message) { return .unverifiable(message: message)
            } catch {
                let message = error.localizedDescription
                if error is JarvisCalendarNotificationError || (error as? JarvisAlarmError) == .permissionDenied {
                    return .needsPermission(message: message)
                }
                return .failed(message: message, retryable: false)
            }
        }
    }

    static func value<T>(_ result: ToolExecutionResult<T>) throws -> T {
        switch result {
        case .succeeded(let value): return value
        case .needsConfirmation(let message): throw LocalDataError.confirmation(message)
        case .needsPermission(let message): throw LocalDataError.permission(message)
        case .failed(let message, _): throw LocalDataError.blocked(message)
        case .unverifiable(let message): throw LocalDataError.unverified(message)
        case .handedOff: throw LocalDataError.recovery
        }
    }
}

/// Production uses atomic files; old UserDefaults data is read without erasing
/// it. Injected defaults keep tests isolated. Decode failure never means empty.
@MainActor
final class RecordPersistence<Value: Codable> {
    private let defaults: UserDefaults
    private let key: String
    let fileURL: URL?
    private(set) var issue: String?
    private(set) var blocked = false
    private(set) var canRestore = false
    var writeOverride: ((Data) throws -> Void)?
    init(defaults: UserDefaults, key: String, fileURL: URL? = nil) {
        self.defaults = defaults; self.key = key
        self.fileURL = fileURL ?? (defaults === UserDefaults.standard
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("JARVIS", isDirectory: true).appendingPathComponent(key + ".json") : nil)
    }
    private var backupURL: URL? { fileURL?.appendingPathExtension("backup") }
    private func primary() throws -> Data? {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) { return try Data(contentsOf: fileURL) }
        if fileURL != nil, defaults.bool(forKey: key + ".fileMigrated") { throw CocoaError(.fileReadNoSuchFile) }
        return defaults.data(forKey: key)
    }
    private func backup() throws -> Data? {
        if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) { return try Data(contentsOf: backupURL) }
        return defaults.data(forKey: key + ".backup")
    }
    func load() -> [Value] {
        do {
            guard let data = try primary() else {
                // A surviving backup proves this is not a fresh empty store.
                if try backup() != nil { throw CocoaError(.fileReadCorruptFile) }
                return []
            }
            return try JSONDecoder().decode([Value].self, from: data)
        } catch {
            blocked = true
            if let data = try? backup(), let values = try? JSONDecoder().decode([Value].self, from: data) {
                canRestore = true; issue = "저장 데이터 읽기에 실패했습니다. 백업 목록을 읽기 전용으로 표시합니다. 백업 복구 후 예약 상태를 확인해주세요."
                return values
            }
            issue = "저장 데이터를 읽지 못했습니다. 빈 목록으로 덮어쓰지 않도록 변경을 차단했습니다. 원본은 보존되어 있습니다."
            return []
        }
    }
    func ensureWritable() throws { if blocked { throw LocalDataError.blocked(issue ?? LocalDataError.storage.localizedDescription) } }
    func invalidate(_ message: String) { blocked = true; issue = message }
    func save(_ values: [Value]) throws {
        try ensureWritable()
        do {
            let data = try JSONEncoder().encode(values)
            // Keep a last-known-good copy, never copy malformed primary bytes.
            if let old = try primary() {
                _ = try JSONDecoder().decode([Value].self, from: old)
                if let backupURL { try write(old, to: backupURL) }
                else { defaults.set(old, forKey: key + ".backup") }
            }
            if let writeOverride { try writeOverride(data) }
            else if let fileURL { try write(data, to: fileURL) }
            else { defaults.set(data, forKey: key) }
            guard try primary() == data else { throw LocalDataError.storage }
            if fileURL != nil {
                defaults.set(true, forKey: key + ".fileMigrated")
                defaults.removeObject(forKey: key)
            }
            issue = nil
        } catch {
            issue = LocalDataError.storage.localizedDescription
            // If a write reached disk but verification failed, prevent later
            // writes from silently extending an uncertain state.
            if let actual = try? primary(), let encoded = try? JSONEncoder().encode(values), actual == encoded {
                blocked = true; issue = "저장 결과 확인에 실패했습니다. 디스크와 목록이 다를 수 있어 변경을 차단했습니다."
            }
            throw LocalDataError.storage
        }
    }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func restore(confirmed: Bool) throws -> [Value] {
        try LocalDataExecution.check(.localData(.restoreStorage), confirmed: confirmed)
        guard canRestore, let data = try backup() else { throw LocalDataError.storage }
        let values = try JSONDecoder().decode([Value].self, from: data)
        // Preserve the damaged original before replacing it, including legacy data.
        if let original = try? primary() {
            if let fileURL { try write(original, to: fileURL.appendingPathExtension("damaged-" + UUID().uuidString)) }
            else { defaults.set(original, forKey: key + ".damaged." + UUID().uuidString) }
        }
        if let fileURL { try write(data, to: fileURL) } else { defaults.set(data, forKey: key) }
        guard try primary() == data else { throw LocalDataError.storage }
        if fileURL != nil { defaults.set(true, forKey: key + ".fileMigrated"); defaults.removeObject(forKey: key) }
        blocked = false; issue = nil; canRestore = false
        return values
    }
}

struct StorageRecoveryNotice: View {
    let message: String?
    let canRestore: Bool
    let restore: () async throws -> Void
    @State private var confirming = false
    @State private var error = ""
    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle").font(.footnote)
                if canRestore { Button("보존된 백업으로 복구") { confirming = true } }
            }
            .foregroundStyle(.orange)
            .confirmationDialog("백업으로 목록을 복구할까요? 최근 변경은 없을 수 있으며 시스템 예약은 별도로 확인해야 합니다.", isPresented: $confirming, titleVisibility: .visible) {
                Button("백업 복구") { Task { do { try await restore() } catch { self.error = error.localizedDescription } } }
            }
            .alert("복구 실패", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(error) }
        }
    }
}

@MainActor
enum CalendarDataExecution {
    static func restoreStore(_ store: JarvisCalendarStore, confirmed: Bool) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.restoreStorage), confirmed: confirmed) {
            try store.restore(confirmed: confirmed)
            store.notificationIssue = "목록을 복구했습니다. 알림 재예약으로 시스템 예약을 확인해주세요."
        })
    }
    /// Exact snapshots and a single writer are shared by UI and VM. A new
    /// event may remain saved with an explicit pending-notification status;
    /// an edit must restore its prior data on notification failure.
    static func save(_ event: JarvisCalendarEvent, store: JarvisCalendarStore,
        expectedUpdatedAt: Date?, confirmed: Bool,
        schedule: (@MainActor (JarvisCalendarEvent) async throws -> Void)? = nil) async -> ToolExecutionResult<JarvisCalendarEvent> {
        let overlaps = store.conflicts(start: event.startDate, end: event.endDate, excluding: event.id)
        let change = CalendarEventChange(id: expectedUpdatedAt == nil ? nil : event.id,
            expectedUpdatedAt: expectedUpdatedAt, title: event.title, start: event.startDate,
            end: event.endDate, outdoor: event.isOutdoor, conflictIDs: overlaps.map(\.id))
        return await LocalDataExecution.perform(.calendarWorkflow(.commit(change)), confirmed: confirmed) {
            let old = store.event(id: event.id)
            guard old?.updatedAt == expectedUpdatedAt else { throw LocalDataError.changed }
            guard TimeZone.current.identifier == change.timeZoneID,
                Set(store.conflicts(start: event.startDate, end: event.endDate, excluding: event.id).map(\.id)) == Set(change.conflictIDs) else {
                throw LocalDataError.changed
            }
            try store.ensureWritable()
            try store.beginChange()
            do {
                try store.upsert(event)
                let saved = store.event(id: event.id)!
                do {
                    if let schedule { try await schedule(saved) }
                    else { try await JarvisCalendarNotificationService.shared.schedule(saved) }
                    try LocalDataExecution.check(.calendarWorkflow(.commit(change)), confirmed: confirmed)
                    try store.finishChange()
                    return saved
                } catch {
                    let permissionDenied = error is JarvisCalendarNotificationError
                    if let old {
                        // Notification service restores exact old requests. The
                        // store also restores the version shown before editing.
                        try store.restoreEventSnapshot(old)
                        store.notificationIssue = "기존 일정 목록으로 복구했습니다. 알림 예약 확인이 필요합니다."
                        if permissionDenied { throw LocalDataError.permission(store.notificationIssue! + " 알림 권한을 확인해주세요.") }
                        throw LocalDataError.unverified(store.notificationIssue!)
                    }
                    store.notificationIssue = "일정은 저장했지만 알림 예약은 확인하지 못했습니다. 캘린더에서 알림 재예약을 눌러 확인해주세요."
                    if permissionDenied { throw LocalDataError.permission("일정은 저장했지만 알림 권한이 없어 예약하지 못했습니다. 설정에서 알림 권한을 확인해주세요.") }
                    throw LocalDataError.unverified(store.notificationIssue!)
                }
            } catch { throw error }
        }
    }

    static func delete(_ event: JarvisCalendarEvent, store: JarvisCalendarStore, confirmed: Bool,
        cancel: (@MainActor (JarvisCalendarEvent) async throws -> Void)? = nil) async -> ToolExecutionResult<Void> {
        let change = CalendarEventChange(id: event.id, expectedUpdatedAt: event.updatedAt, title: event.title,
            start: event.startDate, end: event.endDate, outdoor: event.isOutdoor, deleting: true)
        return await remove(events: [event], store: store, intent: .calendarWorkflow(.commit(change)),
                            confirmed: confirmed, cancel: cancel)
    }
    static func deleteAll(store: JarvisCalendarStore, confirmed: Bool) async -> ToolExecutionResult<Void> {
        await remove(events: store.events, store: store, intent: .localData(.deleteAllCalendarEvents), confirmed: confirmed)
    }
    private static func remove(events: [JarvisCalendarEvent], store: JarvisCalendarStore,
        intent: AssistantIntent, confirmed: Bool,
        cancel: (@MainActor (JarvisCalendarEvent) async throws -> Void)? = nil) async -> ToolExecutionResult<Void> {
        await LocalDataExecution.perform(intent, confirmed: confirmed) {
            guard events.allSatisfy({ store.event(id: $0.id)?.updatedAt == $0.updatedAt }) else { throw LocalDataError.changed }
            try store.ensureWritable()
            let before = store.events
            let ids = Set(events.map(\.id))
            try store.beginChange()
            do {
                try store.replace(before.filter { !ids.contains($0.id) })
                if let cancel { for event in events { try await cancel(event) } }
                else { try await JarvisCalendarNotificationService.shared.rebuild(events: store.events) }
                try LocalDataExecution.check(intent, confirmed: confirmed)
                try store.finishChange()
            } catch {
                do { try store.replace(before) } catch { throw LocalDataError.recovery }
                store.notificationIssue = "일정 삭제가 완료되지 않았습니다. 기존 목록을 유지했습니다. 알림 재예약으로 확인해주세요."
                throw LocalDataError.recovery
            }
        }
    }
    static func repair(store: JarvisCalendarStore, confirmed: Bool) async -> ToolExecutionResult<Void> {
        await LocalDataExecution.perform(.localData(.restoreStorage), confirmed: confirmed) {
            try store.ensureWritable()
            try store.prepareJournalRecovery(confirmed: confirmed)
            try await JarvisCalendarNotificationService.shared.rebuild(events: store.events)
            try LocalDataExecution.check(.localData(.restoreStorage), confirmed: confirmed)
            try store.finishChange()
        }
    }
}
