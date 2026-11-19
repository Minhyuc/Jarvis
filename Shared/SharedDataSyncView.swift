import SwiftUI
#if os(macOS)
import JarvisCore
#endif

/// Feature pages have canonical parents. Switching siblings replaces this
/// single selection; it never appends another NavigationStack destination.
enum WorkspacePage: String, CaseIterable, Hashable, Sendable {
    case database, transfer, openAI, learning, practice, review, memories
    case chat, settings, development, alarms, calendar, handsFree
    case iCloudProject, multiAgent
    enum Parent: Equatable, Sendable { case home, development, sharedProject, settings }
    var parent: Parent {
        switch self {
        case .database, .transfer: .sharedProject
        case .iCloudProject, .multiAgent: .development
        case .openAI, .learning, .practice, .review, .memories: .settings
        case .chat, .settings, .development, .alarms, .calendar, .handsFree: .home
        }
    }
}

@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published private(set) var page: WorkspacePage
    let parent: WorkspacePage.Parent
    init(_ page: WorkspacePage) { self.page = page; parent = page.parent }
    @discardableResult func select(_ page: WorkspacePage) -> Bool {
        guard page.parent == parent else { return false }
        self.page = page
        return true
    }
}

private struct WorkspaceNavigationKey: EnvironmentKey {
    static let defaultValue: WorkspaceNavigation? = nil
}
extension EnvironmentValues {
    var workspaceNavigation: WorkspaceNavigation? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
}

/// Only feature-level cross-links use this button. Record/detail links retain
/// normal child navigation so Back still returns to their actual parent.
struct WorkspaceSiblingLink: View {
    let title: String
    let page: WorkspacePage
    @Environment(\.workspaceNavigation) private var navigation
    init(_ title: String, page: WorkspacePage) { self.title = title; self.page = page }
    var body: some View {
        Button { navigation?.select(page) } label: {
            HStack { Text(title); Spacer(); Image(systemName: "chevron.right").font(.caption) }
        }
        .disabled(navigation?.parent != page.parent)
        .accessibilityIdentifier("workspace.open." + page.rawValue)
    }
}

/// Exactly one destination below the iCloud project, on both iPhone and Mac.
struct SharedDataWorkspaceView: View {
    @StateObject private var navigation: WorkspaceNavigation
    @ObservedObject private var project = SharedProjectStore.shared
    init(initial: WorkspacePage) {
        precondition(initial.parent == .sharedProject)
        _navigation = StateObject(wrappedValue: WorkspaceNavigation(initial))
    }
    init(navigation: WorkspaceNavigation) {
        precondition(navigation.parent == .sharedProject)
        _navigation = StateObject(wrappedValue: navigation)
    }
    var body: some View {
        Group {
            switch navigation.page {
            case .database: SharedDataLocalView()
            case .transfer:
                if let root = project.root { SharedDataSyncView(root: root).id(root) }
                else { Text("공유 폴더 연결이 해제되었습니다. 뒤로 가서 iCloud 공유 프로젝트에서 폴더를 선택해주세요.").padding().navigationTitle("저장·불러오기") }
            case .openAI, .learning, .practice, .review, .memories,
                 .chat, .settings, .development, .alarms, .calendar, .handsFree,
                 .iCloudProject, .multiAgent: EmptyView()
            }
        }
        .id(navigation.page)
        .environment(\.workspaceNavigation, navigation)
    }
}

/// Separate from general file tools. Opening a folder grants no import consent.
struct SharedDataSyncView: View {
    let root: URL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var engine = SharedDataSyncEngine()
    @State private var token = SharedProjectCancellation()
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var plan: SharedSyncPlan?
    @State private var rows: [SharedSyncRow] = []
    @State private var message = "전체 저장하기 또는 전체 불러오기를 선택하세요. 처음 연결하는 DB 준비도 한 번의 검토·승인에 포함됩니다."
    @State private var epoch = UUID()
    @State private var nativeFingerprint: String?

    private var localDirectory: URL {
        JarvisStorage.support
            .appendingPathComponent("JARVIS/SharedSync", isDirectory: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("알람·일정 저장·불러오기").font(.title2.bold())
                Text("대상: \(root.lastPathComponent)").font(.headline)
                Text("이 기기의 로컬 SQLite DB와 공유 폴더 사이에서 데이터를 교환합니다. 기존 알람·캘린더와 실제 알림 예약은 그대로 유지합니다. 가져온 자료는 예약 반영 대기입니다.")
                Text("전체 저장하기: iPhone의 현재 알람·일정을 DB에 수집하고 공유 폴더에 기록합니다. 전체 불러오기: 공유 기록을 로컬 DB에 안전하게 병합합니다. TXT 파일·폴더는 이 DB의 저장 대상이 아닙니다. 자동 저장은 아닙니다.").font(.callout)
                #if os(macOS)
                Text("Mac의 전체 저장하기는 이 기기의 동기화 DB를 기준으로 합니다. iPhone 원본을 직접 읽지 않으므로 먼저 iPhone에서 전체 저장하기를 실행하세요.").font(.caption)
                #endif
                ForEach([SharedSyncPlan.Operation.saveAll, .loadAll], id: \.rawValue) { operation in
                    Button(operation.title) { preview(operation) }.disabled(busy || locked)
                }
                WorkspaceSiblingLink("DB 조회", page: .database).disabled(busy || locked)
                if busy {
                    ProgressView()
                    Button("중지") { stop() }
                }
                Text(message).font(.callout).accessibilityIdentifier("sharedSyncStatus")
                ForEach(rows) { row in
                    VStack(alignment: .leading) {
                        Text(row.title).font(.headline)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                    }.privacySensitive()
                    Divider()
                }
                DisclosureGroup("보호·백업·제한 안내") {
                    Text("알람·캘린더·시스템 폴더는 일반 파일 명령으로 변경할 수 없습니다. API 키·OS 예약 식별자·승인·안전 잠금은 공유하지 않습니다. 가져온 텍스트는 실행 지시가 아닙니다. 충돌은 보류하고 원본을 유지합니다. 로컬 DB 변경 전 이전 상태와 iPhone 수집 원본을 기기 내부 백업에 보관합니다. 백업 복구·충돌 해결 UI는 B 단계입니다. 항목 스냅샷·수신확인 폴더는 향후 단계용이며 A는 변경기록으로 교환합니다. 자동 동기화·실제 예약 연결은 아직 하지 않습니다.")
                    Text("수동 수집 시 현재 시간대를 최초 이전 기준으로 기록합니다. 기존 캘린더에는 시간대·반복 회차 예외 정보가 없으므로 새로 만들어내지 않습니다. 폴더 권한은 이번 앱 실행 동안만 유지합니다. iCloud 전달·다운로드는 지연될 수 있으며 로컬 저장만으로 다른 기기 수신을 보장하지 않습니다.")
                    Text("로컬 DB·백업 위치: \(localDirectory.path)").textSelection(.enabled).privacySensitive()
                }.font(.caption)
            }.padding()
        }
        .navigationTitle("저장·불러오기")
        .sheet(item: $plan) { proposed in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(proposed.operation.title).font(.title2.bold())
                        Text("폴더: \(root.lastPathComponent)\n저장소 ID: \(proposed.storageID.uuidString)")
                        Text("\(proposed.rows.count)개 검토 항목 · 승인 유효시간 2분")
                        if proposed.rows.isEmpty { Text("새 변경이 없습니다. 기존 내용을 덮어쓰지 않습니다.") }
                        ForEach(proposed.rows) { row in
                            VStack(alignment: .leading) { Text(row.title).bold(); Text(row.detail).font(.caption) }
                            Divider()
                        }
                        Text("공유할 제목·장소·메모가 포함될 수 있습니다. 지정한 폴더의 접근자에게 전달될 수 있으므로 확인해주세요. 실제 알람·일정 예약은 변경하지 않습니다.")
                        Button("표시한 작업 승인·적용") { commit(proposed) }.disabled(busy || locked)
                    }.padding().privacySensitive()
                }
                .navigationTitle("동기화 변경 확인")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") {
                    plan = nil; token.cancel(); engine.cancel(); message = "검토를 취소했습니다. 해당 변경은 적용하지 않았습니다."
                } } }
            }.interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onChange(of: locked) { _, value in if value { stop() } }
        .onDisappear { stop() }
    }

    private func nativeInput() throws -> (records: [SharedSyncRecord], backup: Data?) {
        #if os(iOS)
        let alarms = AlarmStore.shared, calendar = JarvisCalendarStore.shared
        try alarms.ensureWritable(); try calendar.ensureWritable()
        guard calendar.notificationIssue == nil else {
            throw LocalDataError.blocked("일정 알림 예약 상태의 확인이 필요해 수집을 보류했습니다. 캘린더 관리에서 알림 재예약 상태를 먼저 확인해주세요. 기존 일정은 유지됩니다.")
        }
        let zone = TimeZone.current.identifier
        let records = alarms.alarms.map {
            SharedSyncRecord(id: $0.id, kind: .alarm, title: $0.effectiveLabel, start: $0.date,
                timeZoneID: zone, delivery: $0.delivery == .system ? "system" : "speech",
                enabled: $0.isEnabled, message: $0.message, createdAt: $0.createdAt)
        } + calendar.events.map {
            SharedSyncRecord(id: $0.id, kind: .calendar, title: $0.title, start: $0.startDate, end: $0.endDate,
                timeZoneID: zone, allDay: $0.isAllDay, outdoor: $0.isOutdoor, location: $0.location,
                notes: $0.notes, url: $0.urlString, recurrence: $0.recurrence.rawValue,
                reminderMinutes: $0.reminderMinutesBefore, createdAt: $0.createdAt)
        }
        struct NativeBackup: Encodable {
            let alarms: [JarvisAlarmRecord]
            let calendar: [JarvisCalendarEvent]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (records, try encoder.encode(NativeBackup(alarms: alarms.alarms, calendar: calendar.events)))
        #else
        return ([], nil)
        #endif
    }

    private func preview(_ operation: SharedSyncPlan.Operation) {
        guard !busy, !locked else { return }
        guard case .allow = SafetyPolicyEngine().evaluate(.sharedProject(.syncRead), context: .init(externalActionsLocked: locked)) else { return }
        do {
            let input = [.capture, .saveAll].contains(operation) ? try nativeInput() : (records: [], backup: nil as Data?)
            nativeFingerprint = input.backup.map { SharedProjectFiles.revision($0) }
            run(action: .syncRead) { engine, token in
                engine.preview(operation, root: root, localDirectory: localDirectory, native: input.records,
                    nativeBackup: input.backup, locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) },
                    cancelled: { token.cancelled })
            } completed: { result in
                switch result {
                case .succeeded(let value):
                    plan = value
                    message = input.backup != nil
                        ? "iPhone 원본: 알람 \(input.records.filter { $0.kind == .alarm }.count)개 · 일정 \(input.records.filter { $0.kind == .calendar }.count)개. 준비·전송 안내를 포함한 검토 항목 \(value.rows.count)개를 확인하고 승인해야 DB에 반영됩니다."
                        : "대상 저장소와 변경 내용을 확인하고 한 번 승인해주세요. 실제 iPhone 목록·알림 예약은 변경하지 않습니다."
                default: message = failure(result)
                }
            }
        } catch { message = "iPhone 원본 데이터를 확인하지 못했습니다. " + error.localizedDescription }
    }

    private func commit(_ proposed: SharedSyncPlan) {
        guard SharedProjectStore.shared.root?.standardizedFileURL == root.standardizedFileURL else {
            plan = nil; token.cancel(); message = "연결된 폴더가 변경되었습니다. 새 폴더에서 다시 검토해주세요."; return
        }
        #if os(iOS)
        if [.capture, .saveAll].contains(proposed.operation) {
            do {
                guard let expected = nativeFingerprint, let current = try nativeInput().backup,
                      expected == SharedProjectFiles.revision(current) else { throw SyncError.changed }
            } catch { plan = nil; token.cancel(); message = SyncError.changed.localizedDescription; return }
        }
        #endif
        plan = nil
        run(action: proposed.operation.action, confirmed: true) { engine, token in
            engine.commit(proposed, confirmed: true,
                locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }, cancelled: { token.cancelled })
        } completed: { result in
            switch result { case .succeeded(let value): message = value; rows = proposed.rows; default: message = failure(result) }
        }
    }

    private func run<T: Sendable>(action: SharedProjectAction, confirmed: Bool = false,
                                  _ operation: @escaping @Sendable (SharedDataSyncEngine, SharedProjectCancellation) -> ToolExecutionResult<T>,
                                  completed: @escaping (ToolExecutionResult<T>) -> Void) {
        guard !busy, !locked else { return }
        switch SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)) {
        case .allow(let risk, let name):
            #if os(iOS)
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .authorized)
            #endif
            break
        case .requireConfirmation(_, _, let prompt): message = prompt; return
        case .block(_, _, let reason): message = reason; return
        }
        let token = SharedProjectCancellation(); self.token.cancel(); self.token = token
        let stamp = UUID(); epoch = stamp; busy = true
        let engine = engine
        task = Task {
            let result = await ToolExecutionCoordinator.shared.execute(key: "shared-data-sync", timeout: .seconds(30)) {
                await withTaskCancellationHandler {
                    await Task.detached {
                        guard root.startAccessingSecurityScopedResource() else { return ToolExecutionResult<T>.needsPermission(message: "공유 폴더를 다시 선택해주세요.") }
                        defer { root.stopAccessingSecurityScopedResource() }
                        return operation(engine, token)
                    }.value
                } onCancel: { token.cancel() }
            }
            guard epoch == stamp else { return }; busy = false
            guard !token.cancelled, !Task.isCancelled, !locked else { return }
            completed(result)
        }
    }
    private func stop() {
        token.cancel(); task?.cancel(); task = nil; epoch = UUID(); busy = false; plan = nil
        message = "동기화 검토를 중단했습니다. 이미 기록된 변경은 되돌리지 않으므로 다시 확인해주세요."
    }
    private func failure<T>(_ result: ToolExecutionResult<T>) -> String {
        switch result {
        case .needsPermission(let m), .needsConfirmation(let m), .failed(let m, _), .unverifiable(let m): m
        case .handedOff: "결과를 확인하지 못했습니다."
        case .succeeded: "완료"
        }
    }
}

/// No shared-folder grant is needed to inspect an already committed local DB.
/// Deliberately read-only: importing, recovery and scheduling are separate actions.
struct SharedDataLocalView: View {
    @ObservedObject private var project = SharedProjectStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var engine = SharedDataSyncEngine()
    @State private var token = SharedProjectCancellation()
    @State private var task: Task<Void, Never>?
    @State private var epoch = UUID()
    @State private var busy = false
    @State private var stores: [UUID] = []
    @State private var snapshot: SharedSyncSnapshot?
    @State private var checkedAt: Date?
    @State private var message = "목록을 새로고침하면 이 기기에 저장된 DB를 확인합니다."
    private var directory: URL {
        JarvisStorage.support
            .appendingPathComponent("JARVIS/SharedSync", isDirectory: true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("공유 폴더 연결 없이 마지막 로컬 사본을 조회합니다. 최신 원격 데이터나 실제 알림 예약 상태를 확인한 것은 아닙니다.")
                Text("이 DB는 일반 파일 목록이 아닌 알람·일정의 수동 복사본입니다. 캘린더에 등록한 일정이 안 보이면 iPhone에서 전체 저장하기를 실행하세요.").font(.callout)
                if project.root != nil {
                    WorkspaceSiblingLink("전체 저장·불러오기 화면 열기", page: .transfer).disabled(busy || locked)
                } else {
                    Text("수집하려면 개발 공간에서 공유 폴더를 먼저 선택하세요. 로컬 DB 조회에는 폴더 연결이 필요 없습니다.").font(.caption)
                }
                Button("저장소 목록 새로고침") {
                    snapshot = nil; checkedAt = nil
                    run { engine, token in engine.localStorageIDs(localDirectory: directory,
                        locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }, cancelled: { token.cancelled })
                    } completed: { stores = $0; message = stores.isEmpty ? "저장된 로컬 DB가 없습니다." : "조회할 저장소 ID를 선택하세요." }
                }.disabled(busy || locked)
                ForEach(stores, id: \.self) { id in
                    Button(id.uuidString) {
                        snapshot = nil; checkedAt = nil
                        run { engine, token in engine.localSnapshot(storageID: id, localDirectory: directory,
                            locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }, cancelled: { token.cancelled })
                        } completed: { snapshot = $0; checkedAt = Date(); message = "로컬 사본 조회 완료 · 공유 데이터 갱신 여부 미확인" }
                    }.font(.caption).disabled(busy || locked)
                }
                if busy { ProgressView(); Button("중지") { stop() } }
                Text(message).font(.callout)
                if let checkedAt { Text("로컬 조회 시각: \(checkedAt.formatted())").font(.caption) }
                if let snapshot {
                    Text("알람 \(snapshot.heads.filter { $0.record?.kind == .alarm }.count)개 · 일정 \(snapshot.heads.filter { $0.record?.kind == .calendar }.count)개 · 삭제표식 \(snapshot.heads.filter { $0.record == nil }.count)개 · 충돌 \(snapshot.conflicts.count)개")
                    if snapshot.heads.isEmpty { Text("저장된 항목이 없습니다. iPhone에서 전체 저장하기를 하거나 공유 기록이 있다면 전체 불러오기를 실행해주세요.").font(.callout) }
                    ForEach(snapshot.rows) { row in
                        VStack(alignment: .leading) {
                            Text(row.title).font(.headline)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        }.privacySensitive()
                        Divider()
                    }
                }
            }.padding()
        }
        .navigationTitle("로컬 동기화 DB")
        .onChange(of: locked) { _, value in if value { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }

    private func run<T: Sendable>(_ operation: @escaping @Sendable (SharedDataSyncEngine, SharedProjectCancellation) -> ToolExecutionResult<T>,
                                  completed: @escaping (T) -> Void) {
        guard !busy, !locked else { return }
        switch SafetyPolicyEngine().evaluate(.sharedProject(.syncRead), context: .init(externalActionsLocked: locked)) {
        case .allow(let risk, let name):
            #if os(iOS)
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .authorized)
            #endif
            break
        case .block(_, _, let reason): message = reason; return
        case .requireConfirmation(_, _, let prompt): message = prompt; return
        }
        let token = SharedProjectCancellation(); self.token.cancel(); self.token = token
        let stamp = UUID(); epoch = stamp; busy = true
        let engine = engine
        task = Task {
            let result = await ToolExecutionCoordinator.shared.execute(key: "shared-data-local-read", timeout: .seconds(30)) {
                await withTaskCancellationHandler {
                    await Task.detached { operation(engine, token) }.value
                } onCancel: { token.cancel() }
            }
            guard epoch == stamp else { return }; busy = false
            guard !token.cancelled, !Task.isCancelled, !locked else { return }
            switch result {
            case .succeeded(let value): completed(value)
            case .failed(let reason, _), .needsPermission(let reason), .needsConfirmation(let reason), .unverifiable(let reason): message = reason
            case .handedOff: message = "로컬 조회 결과를 확인하지 못했습니다."
            }
        }
    }
    private func stop() {
        token.cancel(); task?.cancel(); task = nil; epoch = UUID(); busy = false
        snapshot = nil; checkedAt = nil; stores = []
        message = "로컬 DB 조회를 중단했습니다. 저장된 데이터는 변경하지 않았습니다."
    }
}
