import Foundation
import SQLite3

/// Version-one exchange records contain application data, never OS identifiers,
/// credentials, safety approvals, executable instructions or model context.
public struct SharedSyncRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case alarm, calendar }
    public let id: UUID
    public let kind: Kind
    public var title: String
    public var start: Date
    public var end: Date?
    public var timeZoneID: String
    public var allDay: Bool
    public var outdoor: Bool
    public var location: String
    public var notes: String
    public var url: String
    public var recurrence: String
    public var reminderMinutes: Int?
    public var delivery: String
    public var enabled: Bool
    public var message: String
    public var createdAt: Date
    public var key: String { kind.rawValue + ":" + id.uuidString }

    public init(id: UUID, kind: Kind, title: String, start: Date, end: Date? = nil,
                timeZoneID: String, allDay: Bool = false, outdoor: Bool = false,
                location: String = "", notes: String = "", url: String = "",
                recurrence: String = "none", reminderMinutes: Int? = nil,
                delivery: String = "system", enabled: Bool = true, message: String = "", createdAt: Date) {
        self.id = id; self.kind = kind; self.title = title; self.start = start; self.end = end
        self.timeZoneID = timeZoneID; self.allDay = allDay; self.outdoor = outdoor
        self.location = location; self.notes = notes; self.url = url; self.recurrence = recurrence
        self.reminderMinutes = reminderMinutes; self.delivery = delivery; self.enabled = enabled
        self.message = message; self.createdAt = createdAt
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 1024, notes.utf8.count <= 16_384, message.utf8.count <= 4096,
              location.utf8.count <= 2048, url.utf8.count <= 2048,
              TimeZone(identifier: timeZoneID) != nil,
              [start, createdAt].allSatisfy({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) < 32_503_680_000 }),
              ["none", "daily", "weekly", "monthly", "yearly"].contains(recurrence),
              ["system", "speech"].contains(delivery),
              reminderMinutes.map({ (0...525_600).contains($0) }) ?? true else { throw SyncError.invalid }
        if kind == .calendar {
            guard let end, end > start, end.timeIntervalSince(start) <= 366 * 86_400 else { throw SyncError.invalid }
        } else {
            // Current native alarm store has no repeating-alarm representation.
            guard end == nil, recurrence == "none" else { throw SyncError.version }
        }
    }
}

public struct SharedSyncChange: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let key: String
    public let parent: UUID?
    public let record: SharedSyncRecord? // nil is a persistent tombstone
    public let createdAt: Date
}

private struct SyncManifest: Codable, Equatable {
    let format: Int
    let storageID: UUID
}

private struct SyncPackage: Codable {
    let format: Int
    let storageID: UUID
    let deviceID: UUID
    let changes: [SharedSyncChange]
}

private struct SyncState: Codable {
    var format = 1
    var storageID: UUID
    var deviceID = UUID()
    var generation = UUID()
    var heads: [String: SharedSyncChange] = [:]
    var changes: [String: SharedSyncChange] = [:]
    var conflicts: [String: SharedSyncChange] = [:]
    // Last explicitly captured native source. Remote import does not alter this
    // baseline, so stale native records cannot echo imported changes back out.
    var native: [String: SharedSyncRecord] = [:]
}

public struct SharedSyncRow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
}

/// Typed, device-local read model. These are staged records, not OS reservations.
public struct SharedSyncSnapshot: Sendable, Identifiable {
    public var id: UUID { storageID }
    public let storageID: UUID
    public let generation: UUID
    public let heads: [SharedSyncChange] // Includes persistent deletion markers.
    public let conflicts: [SharedSyncChange]
    public let rows: [SharedSyncRow]
}

public struct SharedSyncPlan: Identifiable, Sendable {
    public enum Operation: String, Sendable, CaseIterable {
        case initialize, capture, export, merge, saveAll, loadAll
        public var title: String {
            switch self {
            case .initialize: "저장소 연결·초기화"
            case .capture: "iPhone 목록 백업·변경 수집"
            case .export: "공유 폴더로 내보내기"
            case .merge: "공유 변경 가져오기"
            case .saveAll: "전체 저장하기"
            case .loadAll: "전체 불러오기"
            }
        }
        public var action: SharedProjectAction {
            switch self { case .initialize: .syncInitialize; case .capture: .syncCapture; case .export, .saveAll: .syncExport; case .merge, .loadAll: .syncImport }
        }
    }
    public let id = UUID()
    public let operation: Operation
    public let storageID: UUID
    public let rows: [SharedSyncRow]
    public let expiresAt: Date
    fileprivate let root: URL
    fileprivate let database: URL
    fileprivate let sourceFingerprint: String
    fileprivate let previousGeneration: UUID?
    fileprivate let nextState: Data
    fileprivate let nativeBackup: Data?
    fileprivate let exportData: [Data]
    fileprivate let newManifest: Data?
}

public enum SyncError: LocalizedError {
    case invalid, version, path, changed, limit, database, uninitialized, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid: "손상되었거나 지원하지 않는 데이터입니다. 기존 데이터는 유지합니다."
        case .version: "지원하지 않는 저장소·항목 버전입니다. 업데이트 후 다시 확인해주세요."
        case .path: "폴더 구조·링크·파일 충돌을 확인해주세요. 보호 영역은 일반 파일 명령으로 변경할 수 없습니다."
        case .changed: "검토 후 데이터가 바뀌었거나 승인이 만료되었습니다. 다시 미리보기해주세요."
        case .limit: "수동 동기화 한도를 초과했습니다. 항목 1,000개·이력 5,000개·기기 32개·파일 2,000개(각 4 MiB)·전체 16 MiB까지 지원합니다. DB·백업 크기 제한도 확인해주세요."
        case .database: "로컬 동기화 DB를 확인하지 못했습니다. 원본을 보존하고 중단했습니다."
        case .uninitialized: "저장된 동기화 자료가 없습니다. iPhone에서 전체 저장하기를 먼저 실행하거나 올바른 공유 폴더를 선택해주세요."
        case .cancelled: "작업이 중단되었습니다. 다시 미리보기해 현재 상태를 확인해주세요."
        }
    }
}

/// Manual-only A-stage synchronizer. One engine serializes local DB access.
/// SQLite is private to this device; only immutable, checksum-named packages
/// enter the document provider. No notification/scheduler API is called here.
public final class SharedDataSyncEngine: @unchecked Sendable {
    public static let folders = ["알람/항목", "캘린더/항목", "메모", "시스템/동기화/변경기록",
        "시스템/동기화/수신확인", "시스템/삭제표식", "시스템/충돌", "시스템/복구", "JARVIS 복구함"]
    private let mutex = NSRecursiveLock()
    private var pending: SharedSyncPlan?
    public init() {}

    public func cancel() { mutex.lock(); defer { mutex.unlock() }; pending = nil }

    public func preview(_ operation: SharedSyncPlan.Operation, root: URL, localDirectory: URL,
                        native: [SharedSyncRecord] = [], nativeBackup: Data? = nil,
                        locked: @Sendable () -> Bool, cancelled: @Sendable () -> Bool = { false }) -> ToolExecutionResult<SharedSyncPlan> {
        mutex.lock(); defer { mutex.unlock() }; pending = nil
        return result {
            try check(.syncRead, locked: locked, cancelled: cancelled)
            return try coordinated(root: root, writing: false) { root in
                try validatePrivateDirectory(localDirectory, outside: root)
                let source = try readSource(root)
                guard operation == .initialize || operation == .saveAll || source.manifest != nil else { throw SyncError.uninitialized }
                let manifest = source.manifest ?? SyncManifest(format: 1, storageID: UUID())
                let database = localDirectory.appendingPathComponent(manifest.storageID.uuidString + ".sqlite")
                let previous = try load(database)
                guard previous == nil || previous?.storageID == manifest.storageID else { throw SyncError.database }
                if ![.initialize, .saveAll, .loadAll].contains(operation), previous == nil { throw SyncError.uninitialized }
                var state = previous ?? SyncState(storageID: manifest.storageID)
                var rows: [SharedSyncRow] = []
                var outbound: [Data] = []
                // Prepare every stage without writing. One root/DB/native-bound
                // confirmation applies the combined result; no chained approvals.
                var steps: [SharedSyncPlan.Operation]
                switch operation {
                case .saveAll:
                    guard nativeBackup != nil || native.isEmpty else { throw SyncError.invalid }
                    steps = (nativeBackup == nil ? [] : [.capture]) + [.export]
                case .loadAll: steps = [.merge]
                case .initialize, .capture, .export, .merge: steps = [operation]
                }
                if previous == nil, operation != .initialize { steps.insert(.initialize, at: 0) }
                for step in steps {
                switch step {
                case .initialize:
                    rows = [SharedSyncRow(id: "structure", title: source.manifest == nil ? "새 공용 저장소" : "기존 공용 저장소 연결",
                        detail: Self.folders.joined(separator: "\n"))]
                case .capture:
                    guard native.count <= 1000, Set(native.map(\.key)).count == native.count else { throw SyncError.limit }
                    let current = Dictionary(uniqueKeysWithValues: native.map { ($0.key, $0) })
                    for record in native { try record.validate() }
                    for key in Set(current.keys).union(state.native.keys).sorted() where current[key] != state.native[key] {
                        let record = current[key]
                        let change = SharedSyncChange(id: UUID(), deviceID: state.deviceID, key: key,
                            parent: state.heads[key]?.id, record: record, createdAt: Date())
                        // A native edit against an unapplied remote version must
                        // become a conflict, not silently overwrite the import.
                        let remoteChanged = state.heads[key].map { $0.deviceID != state.deviceID && $0.record != state.native[key] && $0.record != record } ?? false
                        if remoteChanged || state.conflicts.values.contains(where: { $0.key == key }) {
                            state.conflicts[change.id.uuidString] = change
                            state.changes[change.id.uuidString] = change
                            rows.append(row(change, status: "충돌 보류 · 실제 예약 변경 없음"))
                        } else {
                            state.changes[change.id.uuidString] = change; state.heads[key] = change
                            rows.append(row(change, status: record == nil ? "삭제표식 수집" : "로컬 변경 수집"))
                        }
                    }
                    state.native = current
                case .export:
                    var published: [UUID: SharedSyncChange] = [:]
                    for data in source.packages {
                        for change in try decode(SyncPackage.self, data).changes {
                            if let old = published[change.id], old != change { throw SyncError.invalid }
                            published[change.id] = change
                        }
                    }
                    let changes = state.changes.values.filter {
                        $0.deviceID == state.deviceID && state.conflicts[$0.id.uuidString] == nil
                    }.sorted { $0.id.uuidString < $1.id.uuidString }
                    for change in changes {
                        if let old = published[change.id], old != change { throw SyncError.invalid }
                    }
                    let fresh = changes.filter { published[$0.id] == nil }
                    let available = Set(published.keys).union(fresh.map(\.id))
                    guard available.count <= 5000 else { throw SyncError.limit }
                    guard fresh.allSatisfy({ $0.parent.map(available.contains) ?? true }) else { throw SyncError.invalid }
                    // Bound both item count and actual encoded bytes. Incremental
                    // immutable chunks also make an interrupted export resumable.
                    var offset = 0
                    while offset < fresh.count {
                        try check(.syncRead, locked: locked, cancelled: cancelled)
                        var low = 1, high = min(1000, fresh.count - offset), accepted: Data?
                        var length = 0
                        while low <= high {
                            let middle = (low + high) / 2
                            let data = try encode(SyncPackage(format: 1, storageID: state.storageID,
                                deviceID: state.deviceID, changes: Array(fresh[offset..<(offset + middle)])))
                            if data.count <= 4_194_304 { accepted = data; length = middle; low = middle + 1 }
                            else { high = middle - 1 }
                        }
                        guard let accepted else { throw SyncError.limit }
                        outbound.append(accepted); offset += length
                    }
                    let devices = source.deviceIDs.union(fresh.isEmpty ? [] : [state.deviceID])
                    guard devices.count <= 32, source.packages.count + outbound.count <= 2000,
                          (source.packages + outbound).reduce(0, { $0 + $1.count }) <= 16_777_216 else { throw SyncError.limit }
                    if operation == .saveAll {
                        if nativeBackup == nil { rows += fresh.map { row($0, status: "기록 전송 · 상대 기기 수신 확인 아님") } }
                        rows.append(.init(id: "transfer-summary", title: "공유 폴더 저장 검토",
                            detail: "새 변경 \(fresh.count)개 · 파일 \(outbound.count)개. 다른 기기 수신 확인은 아닙니다. 충돌한 변경은 전송하지 않습니다."))
                    } else { rows = fresh.map { row($0, status: "기록 전송 · 상대 기기 수신 확인 아님") } }
                case .merge:
                    var incoming: [String: SharedSyncChange] = [:]
                    for data in source.packages {
                        let package = try decode(SyncPackage.self, data)
                        guard package.format == 1, package.storageID == state.storageID, package.changes.count <= 5000 else { throw SyncError.version }
                        for change in package.changes {
                            try validate(change)
                            guard change.deviceID == package.deviceID else { throw SyncError.invalid }
                            if let existing = incoming[change.id.uuidString], existing != change { throw SyncError.invalid }
                            if let existing = state.changes[change.id.uuidString], existing != change { throw SyncError.invalid }
                            incoming[change.id.uuidString] = change
                        }
                    }
                    guard incoming.count <= 5000 else { throw SyncError.limit }
                    var unseen = incoming.values.filter { state.changes[$0.id.uuidString] == nil }
                    // Causal order, not timestamps or file enumeration order.
                    while !unseen.isEmpty {
                        var progressed = false
                        for change in unseen.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                            if let parent = change.parent, state.changes[parent.uuidString] == nil { continue }
                            if let parent = change.parent, state.changes[parent.uuidString]?.key != change.key { throw SyncError.invalid }
                            state.changes[change.id.uuidString] = change
                            if state.heads[change.key]?.id == change.parent,
                               !state.conflicts.values.contains(where: { $0.key == change.key }) {
                                state.heads[change.key] = change
                                rows.append(row(change, status: change.record == nil ? "삭제표식 병합 · 예약 반영 대기" : "병합 · 예약 반영 대기"))
                            } else {
                                state.conflicts[change.id.uuidString] = change
                                rows.append(row(change, status: "충돌 보류 · 덮어쓰지 않음"))
                            }
                            unseen.removeAll { $0.id == change.id }; progressed = true
                        }
                        if !progressed { throw SyncError.invalid } // Missing parent / cycle: no partial import.
                    }
                case .saveAll, .loadAll: throw SyncError.invalid // Composite stages are expanded above.
                }
                }
                guard state.heads.count <= 1000, state.changes.count <= 5000 else { throw SyncError.limit }
                state.generation = UUID()
                let encodedState = try encode(state)
                guard encodedState.count <= 33_554_432, (nativeBackup?.count ?? 0) <= 8_388_608 else { throw SyncError.limit }
                let plan = SharedSyncPlan(operation: operation, storageID: state.storageID, rows: rows,
                    expiresAt: Date().addingTimeInterval(120), root: root, database: database,
                    sourceFingerprint: source.fingerprint, previousGeneration: previous?.generation,
                    nextState: encodedState, nativeBackup: nativeBackup, exportData: outbound,
                    newManifest: source.manifest == nil ? try encode(manifest) : nil)
                try check(.syncRead, locked: locked, cancelled: cancelled)
                pending = plan
                return plan
            }
        }
    }

    public func commit(_ plan: SharedSyncPlan, confirmed: Bool, locked: @Sendable () -> Bool,
                       cancelled: @Sendable () -> Bool = { false }) -> ToolExecutionResult<String> {
        mutex.lock(); defer { mutex.unlock() }
        switch SafetyPolicyEngine().evaluate(.sharedProject(plan.operation.action), context: .init(
            externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .requireConfirmation(_, _, let prompt): return .needsConfirmation(message: prompt)
        case .block(_, _, let reason): return .failed(message: reason, retryable: false)
        case .allow: break
        }
        var writeAttempted = false
        return result(uncertain: { writeAttempted }) {
            try check(plan.operation.action, confirmed: confirmed, locked: locked, cancelled: cancelled)
            guard pending?.id == plan.id, plan.expiresAt > Date() else { throw SyncError.changed }
            pending = nil // Single use; an uncertain write is never automatically replayed.
            return try coordinated(root: plan.root, writing: true) { root in
                try validatePrivateDirectory(plan.database.deletingLastPathComponent(), outside: root)
                guard try readSource(root).fingerprint == plan.sourceFingerprint,
                      try load(plan.database)?.generation == plan.previousGeneration else { throw SyncError.changed }
                let state = try decode(SyncState.self, plan.nextState)
                func gate() throws { try check(plan.operation.action, confirmed: confirmed, locked: locked, cancelled: cancelled) }
                try gate()
                writeAttempted = true
                if plan.operation == .initialize || plan.newManifest != nil {
                    for path in Self.folders { try makeDirectories(root, path: path, gate: gate) }
                    if let data = plan.newManifest { try writeNew(data, root: root, path: "시스템/저장소정보.json", gate: gate) }
                }
                for data in plan.exportData {
                    guard data.count <= 4_194_304 else { throw SyncError.limit }
                    let path = "시스템/동기화/변경기록/" + state.deviceID.uuidString
                    try makeDirectories(root, path: path, gate: gate)
                    try writeNew(data, root: root, path: path + "/" + SharedProjectFiles.revision(data) + ".json", gate: gate)
                }
                // Backups and the DB are PRIVATE to this device, never in iCloud.
                try gate()
                try FileManager.default.createDirectory(at: plan.database.deletingLastPathComponent(), withIntermediateDirectories: true)
                let backupDirectory = plan.database.deletingLastPathComponent().appendingPathComponent("백업")
                try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                if let old = try load(plan.database) {
                    try encode(old).write(to: backupDirectory.appendingPathComponent(plan.id.uuidString + "-db.json"), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
                }
                if let raw = plan.nativeBackup {
                    guard raw.count <= 8_388_608 else { throw SyncError.limit }
                    try raw.write(to: backupDirectory.appendingPathComponent(plan.id.uuidString + "-iphone.json"), options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
                }
                try gate()
                try save(state, at: plan.database, expected: plan.previousGeneration, gate: gate)
                return "로컬 동기화 DB 반영 완료. " + ([.export, .saveAll].contains(plan.operation)
                    ? "공유 파일을 기록했습니다. 다른 기기 수신은 확인하지 못했습니다."
                    : "실제 알람·일정 알림 예약은 변경하지 않았습니다. 가져온 변경은 예약 반영 대기입니다.")
            }
        }
    }

    public func status(root: URL, localDirectory: URL, locked: @Sendable () -> Bool) -> ToolExecutionResult<[SharedSyncRow]> {
        mutex.lock(); defer { mutex.unlock() }
        return result {
            try check(.syncRead, locked: locked)
            return try coordinated(root: root, writing: false) { root in
                try validatePrivateDirectory(localDirectory, outside: root)
                guard let manifest = try readSource(root).manifest else { throw SyncError.uninitialized }
                guard let state = try load(localDirectory.appendingPathComponent(manifest.storageID.uuidString + ".sqlite")) else { throw SyncError.uninitialized }
                return state.heads.values.sorted { $0.key < $1.key }.map {
                    row($0, status: $0.deviceID == state.deviceID ? "이 기기에서 수집 · 예약 상태 별도" : "가져온 데이터 · 예약 반영 대기")
                } + state.conflicts.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { row($0, status: "충돌 보류 · 해결 기능은 B 단계") }
            }
        }
    }

    /// Does not access a document provider or create a database. A missing share
    /// must not prevent inspection of the last successfully committed local copy.
    public func localStorageIDs(localDirectory: URL, locked: @Sendable () -> Bool,
                                cancelled: @Sendable () -> Bool = { false }) -> ToolExecutionResult<[UUID]> {
        mutex.lock(); defer { mutex.unlock() }
        return result {
            try check(.syncRead, locked: locked, cancelled: cancelled)
            try validatePrivateDirectory(localDirectory)
            guard FileManager.default.fileExists(atPath: localDirectory.path) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: nil)
            guard files.count <= 2000 else { throw SyncError.limit }
            let ids = files.filter { $0.pathExtension == "sqlite" && !$0.lastPathComponent.hasPrefix(".") }
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.uuidString < $1.uuidString }
            guard ids.count <= 100 else { throw SyncError.limit }
            try check(.syncRead, locked: locked, cancelled: cancelled)
            return ids
        }
    }

    public func localSnapshot(storageID: UUID, localDirectory: URL, locked: @Sendable () -> Bool,
                              cancelled: @Sendable () -> Bool = { false }) -> ToolExecutionResult<SharedSyncSnapshot> {
        mutex.lock(); defer { mutex.unlock() }
        return result {
            try check(.syncRead, locked: locked, cancelled: cancelled)
            try validatePrivateDirectory(localDirectory)
            guard let state = try load(localDirectory.appendingPathComponent(storageID.uuidString + ".sqlite")),
                  state.storageID == storageID else { throw SyncError.uninitialized }
            let heads = state.heads.values.sorted { $0.key < $1.key }
            let conflicts = state.conflicts.values.sorted { $0.id.uuidString < $1.id.uuidString }
            let rows = heads.map { row($0, status: $0.deviceID == state.deviceID
                ? "이 기기에서 수집 · 예약 상태 별도" : "가져온 데이터 · 예약 반영 대기") }
                + conflicts.map { row($0, status: "충돌 보류 · 해결 기능은 B 단계") }
            try check(.syncRead, locked: locked, cancelled: cancelled)
            return SharedSyncSnapshot(storageID: storageID, generation: state.generation,
                heads: heads, conflicts: conflicts, rows: rows)
        }
    }

    private func validatePrivateDirectory(_ directory: URL, outside root: URL? = nil) throws {
        guard directory.isFileURL else { throw SyncError.path }
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonical != "/", canonical != NSHomeDirectory() else { throw SyncError.path }
        if let root {
            let shared = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard canonical != shared, !canonical.hasPrefix(shared + "/") else { throw SyncError.path }
        }
        // Permit only the OS's standard /var and /tmp aliases, not application
        // storage or backup directories redirected through a symlink.
        var part = directory.standardizedFileURL
        while part.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: part.path)) != nil {
                let values = try part.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isSymbolicLink == true {
                    guard ["/var", "/tmp"].contains(part.path) else { throw SyncError.path }
                } else if values.isDirectory != true { throw SyncError.path }
            }
            part.deleteLastPathComponent()
        }
        let backup = directory.appendingPathComponent("백업")
        if (try? FileManager.default.attributesOfItem(atPath: backup.path)) != nil {
            let values = try backup.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw SyncError.path }
        }
    }

    private func row(_ change: SharedSyncChange, status: String) -> SharedSyncRow {
        var details = ["\(change.key.hasPrefix("alarm:") ? "알람" : "일정") · \(status)", "항목: \(change.key)"]
        if let r = change.record {
            let style = Date.FormatStyle(date: .abbreviated, time: r.allDay ? .omitted : .shortened,
                timeZone: TimeZone(identifier: r.timeZoneID) ?? .gmt)
            details += ["시작: \(r.start.formatted(style)) · \(r.timeZoneID)",
                "반복: \(r.recurrence) · 활성화: \(r.enabled ? "켜짐" : "꺼짐")"]
            if let end = r.end { details.append("종료: \(end.formatted(style))") }
            if r.kind == .alarm { details += ["알림 방식: \(r.delivery == "system" ? "시스템음" : "TTS")", "안내 내용: \(r.message)"] }
            else {
                details += ["종일: \(r.allDay ? "예" : "아니오") · 야외: \(r.outdoor ? "예" : "아니오")",
                    "알림: \(r.reminderMinutes.map { "\($0)분 전" } ?? "없음")", "장소: \(r.location)", "메모: \(r.notes)", "URL: \(r.url)"]
            }
        }
        return .init(id: change.id.uuidString, title: change.record?.title ?? "삭제 항목", detail: details.joined(separator: "\n"))
    }

    private func validate(_ change: SharedSyncChange) throws {
        let parts = change.key.split(separator: ":")
        guard parts.count == 2, ["alarm", "calendar"].contains(String(parts[0])), UUID(uuidString: String(parts[1])) != nil,
              change.id != change.parent, change.createdAt.timeIntervalSince1970.isFinite else { throw SyncError.invalid }
        if let record = change.record { try record.validate(); guard record.key == change.key else { throw SyncError.invalid } }
    }

    private struct Source {
        let manifest: SyncManifest?
        let packages: [Data]
        let deviceIDs: Set<UUID>
        let fingerprint: String
    }

    private func readSource(_ root: URL) throws -> Source {
        var bytes = Data(); var total = 0; var packages: [Data] = []
        var deviceIDs: Set<UUID> = [], known: [UUID: SharedSyncChange] = [:]
        let manifestURL = root.appendingPathComponent("시스템/저장소정보.json")
        var manifest: SyncManifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try read(root, manifestURL, limit: 4096)
            manifest = try decode(SyncManifest.self, data)
            guard manifest?.format == 1 else { throw SyncError.version }
            bytes.append(data)
            for path in Self.folders {
                let url = root.appendingPathComponent(path)
                try validatePath(root, url)
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SyncError.path }
            }
        } else {
            // Reuse an existing ordinary memo/recovery directory, but never
            // adopt unexplained structured alarm/calendar/system content.
            for path in ["알람", "캘린더", "시스템"] {
                let url = root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    try validatePath(root, url)
                    try validateEmptySkeleton(root, url)
                }
            }
        }
        if manifest != nil {
            let changes = root.appendingPathComponent("시스템/동기화/변경기록")
            let devices = try FileManager.default.contentsOfDirectory(at: changes, includingPropertiesForKeys: nil)
            guard devices.count <= 32 else { throw SyncError.limit }
            var count = 0
            for device in devices.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let deviceID = UUID(uuidString: device.lastPathComponent) else { throw SyncError.path }
                deviceIDs.insert(deviceID)
                try validatePath(root, device)
                let files = try FileManager.default.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)
                for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    count += 1; guard count <= 2000 else { throw SyncError.limit }
                    let data = try read(root, file, limit: 4_194_304)
                    guard file.lastPathComponent == SharedProjectFiles.revision(data) + ".json" else { throw SyncError.invalid }
                    let package = try decode(SyncPackage.self, data)
                    guard package.format == 1, package.storageID == manifest?.storageID else { throw SyncError.version }
                    // Compatibility for bounded v1 files produced by the old
                    // cumulative exporter. New writes use <= 1,000 per chunk.
                    guard package.deviceID.uuidString == device.lastPathComponent, package.changes.count <= 5000 else { throw SyncError.invalid }
                    for change in package.changes {
                        try validate(change); guard change.deviceID == package.deviceID else { throw SyncError.invalid }
                        if let existing = known[change.id], existing != change { throw SyncError.invalid }
                        known[change.id] = change
                    }
                    guard known.count <= 5000 else { throw SyncError.limit }
                    total += data.count; guard total <= 16_777_216 else { throw SyncError.limit }
                    bytes.append(Data((device.lastPathComponent + file.lastPathComponent).utf8)); bytes.append(data)
                    packages.append(data)
                }
            }
        }
        return Source(manifest: manifest, packages: packages, deviceIDs: deviceIDs, fingerprint: SharedProjectFiles.revision(bytes))
    }

    private func validatePath(_ root: URL, _ target: URL) throws {
        try SharedProjectFiles().validate(root: root, target: target, allowMissing: false)
        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: target)?.isEmpty != false else { throw SyncError.changed }
    }
    private func validateEmptySkeleton(_ root: URL, _ directory: URL) throws {
        try validatePath(root, directory)
        let allowed = Set(Self.folders.flatMap { path -> [String] in
            let parts = path.split(separator: "/"); return (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let relative = child.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
                .joined(separator: "/").precomposedStringWithCanonicalMapping
            guard allowed.contains(relative), try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SyncError.path }
            try validateEmptySkeleton(root, child)
        }
    }
    private func read(_ root: URL, _ url: URL, limit: Int) throws -> Data {
        try validatePath(root, url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= limit else { throw SyncError.limit }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SyncError.limit }; return data
    }
    private func makeDirectories(_ root: URL, path: String, gate: () throws -> Void) throws {
        var cursor = root
        for part in path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if !FileManager.default.fileExists(atPath: cursor.path) { try gate(); try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false) }
            try validatePath(root, cursor)
            guard try cursor.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SyncError.path }
        }
    }
    private func writeNew(_ data: Data, root: URL, path: String, gate: () throws -> Void) throws {
        let url = root.appendingPathComponent(path)
        try validatePath(root, url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(root, url, limit: 4_194_304) == data else { throw SyncError.changed }; return
        }
        try gate(); try data.write(to: url, options: [.withoutOverwriting])
        guard try read(root, url, limit: 4_194_304) == data else { throw SyncError.changed }
    }
    private func coordinated<T>(root: URL, writing: Bool, body: (URL) throws -> T) throws -> T {
        guard root.isFileURL, root.standardizedFileURL.path != "/", root.standardizedFileURL.path != NSHomeDirectory(),
              try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true,
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SyncError.path }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var error: NSError?; var output: Result<T, Error>?
        let callback: (URL) -> Void = { url in output = Result { try body(url) } }
        let coordinator = NSFileCoordinator()
        if writing { coordinator.coordinate(writingItemAt: root, options: [], error: &error, byAccessor: callback) }
        else { coordinator.coordinate(readingItemAt: root, options: [], error: &error, byAccessor: callback) }
        if let error { throw error }; guard let output else { throw SyncError.changed }; return try output.get()
    }

    // A single transaction stores the materialized records, immutable local
    // changes, tombstones, conflicts and native baseline together. Disk-full or
    // interrupted COMMIT never leaves a record without its outbound change.
    private func load(_ url: URL) throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else { throw SyncError.database }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; throw SyncError.database }
        defer { sqlite3_close(db) }
        let data = try readState(db)
        let state = try decode(SyncState.self, data)
        guard state.format == 1 else { throw SyncError.version }
        guard state.heads.count <= 1000, state.native.count <= 1000, state.changes.count <= 5000,
              state.conflicts.count <= state.changes.count else { throw SyncError.limit }
        for (id, change) in state.changes {
            try validate(change)
            guard id == change.id.uuidString,
                  change.parent.map({ state.changes[$0.uuidString]?.key == change.key }) ?? true else { throw SyncError.database }
        }
        for (key, head) in state.heads {
            guard key == head.key, state.changes[head.id.uuidString] == head else { throw SyncError.database }
        }
        for (id, conflict) in state.conflicts {
            guard id == conflict.id.uuidString, state.changes[id] == conflict else { throw SyncError.database }
        }
        for (key, record) in state.native {
            try record.validate(); guard key == record.key else { throw SyncError.database }
        }
        return state
    }
    private func readState(_ db: OpaquePointer?) throws -> Data {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM sync_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw SyncError.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw SyncError.database }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= 33_554_432 else { throw SyncError.limit }
        return Data(bytes: bytes, count: count)
    }
    private func save(_ state: SyncState, at url: URL, expected: UUID?, gate: () throws -> Void) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        guard existed == (expected != nil) else { throw SyncError.changed }
        var db: OpaquePointer?
        let working = existed ? url : url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".pending.sqlite")
        guard sqlite3_open_v2(working.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; throw SyncError.database }
        defer {
            sqlite3_close(db)
            if !existed, FileManager.default.fileExists(atPath: working.path) { try? FileManager.default.removeItem(at: working) }
        }
        func sql(_ text: String) throws { guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw SyncError.database } }
        try sql("PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; BEGIN IMMEDIATE;")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        try sql("CREATE TABLE IF NOT EXISTS sync_state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)")
        if let expected { guard try decode(SyncState.self, readState(db)).generation == expected else { throw SyncError.changed } }
        let data = try encode(state); guard data.count <= 33_554_432 else { throw SyncError.limit }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO sync_state(id,payload) VALUES(1,?)", -1, &statement, nil) == SQLITE_OK else { throw SyncError.database }
        defer { sqlite3_finalize(statement) }
        try data.withUnsafeBytes { buffer in
            guard sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw SyncError.database }
        }
        try gate(); try sql("COMMIT"); committed = true
        guard try readState(db) == data else { throw SyncError.database }
        if !existed {
            try gate()
            guard !FileManager.default.fileExists(atPath: url.path) else { throw SyncError.changed }
            try FileManager.default.moveItem(at: working, to: url)
        }
    }

    private func check(_ action: SharedProjectAction, confirmed: Bool = false,
                       locked: @Sendable () -> Bool, cancelled: @Sendable () -> Bool = { false }) throws {
        guard !cancelled() else { throw SyncError.cancelled }
        switch SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .allow: return
        case .block: throw SyncError.cancelled
        case .requireConfirmation: throw SyncError.changed
        }
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    private func result<T>(uncertain: () -> Bool = { false }, _ body: () throws -> T) -> ToolExecutionResult<T> {
        do { return .succeeded(try body()) }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) {
                return .needsPermission(message: "공유 폴더 권한을 다시 선택해주세요. 이미 기록된 변경이 있을 수 있으니 다시 검토해주세요.")
            }
            if uncertain() { return .unverifiable(message: "작업 일부가 기록되었을 수 있어 완료를 확인하지 못했습니다. 기존 데이터·백업을 보존하며 자동 재시도하지 않습니다. 다시 미리보기로 확인해주세요.") }
            return .failed(message: (error as? SyncError)?.localizedDescription ?? "파일·DB를 확인하지 못해 중단했습니다. 기존 원본과 백업을 확인해주세요. 자동 재시도하지 않습니다.", retryable: false)
        }
    }
}
