import SwiftUI
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import JarvisCore
import Darwin
import AppKit
#endif

@MainActor
final class SharedProjectStore: ObservableObject {
    static let shared = SharedProjectStore()
    nonisolated static let lockKey = "jarvis.safety.externalActionsLocked"
    @Published private(set) var root: URL?
    @Published private(set) var path = ""
    @Published private(set) var entries: [SharedProjectEntry] = []
    @Published private(set) var document: SharedProjectDocument?
    @Published var draft = ""
    @Published private(set) var busy = false
    @Published var message = "공유할 프로젝트 폴더를 직접 선택해주세요."
    @Published private(set) var audit: [String] = []
    private var work: Task<Void, Never>?
    private var cancellation = SharedProjectCancellation()
    private var generation = UUID()
    private(set) var sessionID = UUID()
    private var prepared: SharedProjectPlan?
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    @Published private(set) var recoveries: [SharedProjectRecovery] = []
    var dirty: Bool { document.map { $0.text != draft } ?? !draft.isEmpty }

    init(startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.startAccess = startAccess; self.stopAccess = stopAccess
    }

    func pause() {
        guard authorize(.cancel) else { return }
        cancellation.cancel(); work?.cancel(); work = nil; generation = UUID(); busy = false; prepared = nil
        // An already committed write is not undone by cancellation.
    }

    func disconnect() {
        guard authorize(.disconnect) else { return }
        pause(); sessionID = UUID(); root = nil; entries = []; document = nil; draft = ""; path = ""; recoveries = []
        message = "폴더 접근을 해제했습니다. 실제 파일은 삭제하지 않았습니다."
    }

    func setLocked(_ locked: Bool, confirmed: Bool = false) {
        guard authorize(locked ? .lock : .unlock, confirmed: confirmed) else { return }
        JarvisStorage.preferences.set(locked, forKey: Self.lockKey)
        if locked { pause(); entries = []; message = "안전 잠금이 켜졌습니다. 초안은 보존되며 파일 작업은 차단됩니다." }
    }

    func discardDraft() { draft = document?.text ?? "" }

    func run(_ action: SharedProjectAction, folder: URL? = nil, target: String = "", confirmed: Bool = false) {
        guard !busy, authorize(action, confirmed: confirmed), let selected = folder ?? root else { return }
        guard JarvisStorage.permits(selected) else { message = "USB 내부 폴더만 사용할 수 있습니다."; return }
        // UI confirmation is bound to this immutable path, text and revision snapshot.
        let text = action == .create ? "" : draft
        let revision = document?.revision
        let startAccess = self.startAccess, stopAccess = self.stopAccess
        let cancellation = SharedProjectCancellation()
        self.cancellation.cancel(); self.cancellation = cancellation
        let epoch = UUID(); generation = epoch; busy = true
        message = "파일 제공자의 응답을 기다리고 있습니다…"
        work = Task { [weak self] in
            let result = await ToolExecutionCoordinator.shared.execute(key: "shared-project-file", timeout: .seconds(20)) {
                await withTaskCancellationHandler {
                  await Task.detached(priority: .userInitiated) {
                    guard startAccess(selected) else {
                        return ToolExecutionResult<SharedProjectOutput>.needsPermission(message: "폴더 접근 권한을 얻지 못했습니다. 시스템 선택창에서 다시 선택해주세요.")
                    }
                    defer { stopAccess(selected) }
                    return SharedProjectFiles().perform(action, root: selected, path: target,
                        text: text, expectedRevision: revision, confirmed: confirmed,
                        locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) },
                        cancelled: { Task.isCancelled }, cancellation: cancellation)
                  }.value
                } onCancel: { cancellation.cancel() }
            }
            guard let self, self.generation == epoch else { return }
            self.busy = false; self.work = nil
            guard !Task.isCancelled, !cancellation.cancelled,
                  !JarvisStorage.preferences.bool(forKey: Self.lockKey) else { return }
            switch result {
            case .succeeded(let value):
                switch action {
                case .connect:
                    self.sessionID = UUID(); self.prepared = nil; self.recoveries = []
                    self.root = selected; self.path = ""; self.entries = []; self.document = nil; self.draft = ""
                    self.message = "폴더 접근을 허용했습니다. 목록 불러오기를 눌러주세요."
                case .browse:
                    self.path = target; self.entries = value.entries
                    self.message = value.truncated ? "목록은 처음 500개 항목까지만 확인했습니다." : "목록을 불러왔습니다."
                case .read, .save, .create:
                    self.document = value.document; self.draft = value.document?.text ?? ""
                    self.message = action == .read ? "파일을 열었습니다." : "이 기기에 저장하고 내용을 확인했습니다. iCloud의 다른 기기 반영은 아직 확인하지 못했습니다."
                case .inspect, .createFolder, .move, .remove, .disconnect, .cancel, .lock, .unlock,
                     .syncRead, .syncInitialize, .syncCapture, .syncExport, .syncImport: break
                }
                self.record("공유 프로젝트 작업: 기기 내 확인 완료")
            case .handedOff: self.message = "파일 제공자에게 요청을 전달했습니다."
            case .needsPermission(let message), .needsConfirmation(let message), .failed(let message, _), .unverifiable(let message):
                self.message = message; self.record("공유 프로젝트 작업: 확인 필요 또는 실패")
            }
        }
    }

    func cancelProposal() { prepared = nil }

    func prepare(_ request: SharedProjectRequest) async -> ToolExecutionResult<SharedProjectPlan> {
        prepared = nil
        guard root != nil else { return .needsPermission(message: "먼저 개발 공간에서 공유할 폴더를 선택하고 접근을 허용해주세요.") }
        guard !dirty else { return .failed(message: "편집 중인 초안을 먼저 저장하거나 변경 취소해주세요.", retryable: false) }
        guard SharedProjectFiles.validPath(request.path),
              !SharedProjectFiles.protectedPath(request.path), !SharedProjectFiles.protectedPath(request.destination),
              request.path != SharedProjectFiles.recoveryFolder,
              request.destination.isEmpty || SharedProjectFiles.validPath(request.destination),
              ![.note, .update].contains(request.operation) || (request.path.lowercased().hasSuffix(".txt") && request.text.utf8.count <= 4096 && !request.text.isEmpty)
        else { return .failed(message: "정확한 상대 경로와 메모 내용을 확인해주세요. 허용 폴더 밖이나 복구함 자체는 변경할 수 없습니다.", retryable: false) }
        let rootSession = sessionID
        var revision: String?
        if [.update, .move, .remove].contains(request.operation) {
            let result = await operation(request.operation == .update ? .read : .inspect, target: request.path)
            switch result {
            case .succeeded(let output): revision = request.operation == .update ? output.document?.revision : output.itemRevision
            case .needsPermission(let m): return .needsPermission(message: m)
            case .needsConfirmation(let m): return .needsConfirmation(message: m)
            case .failed(let m, _), .unverifiable(let m): return .failed(message: m, retryable: false)
            case .handedOff: return .unverifiable(message: "원본을 확인하지 못했습니다.")
            }
        }
        guard !Task.isCancelled, rootSession == sessionID, let root,
              !JarvisStorage.preferences.bool(forKey: Self.lockKey) else { return .failed(message: "작업 준비가 취소되었습니다.", retryable: false) }
        let plan = SharedProjectPlan(sessionID: sessionID, rootName: root.lastPathComponent, request: request, revision: revision)
        prepared = plan
        return .succeeded(plan)
    }

    func commit(_ plan: SharedProjectPlan, confirmed: Bool = false) async -> ToolExecutionResult<String> {
        guard confirmed, authorize(plan.request.action, confirmed: confirmed), !dirty else {
            return .needsConfirmation(message: "경로와 내용을 확인해 승인해주세요. 편집 중인 초안은 먼저 저장해주세요.")
        }
        guard prepared == plan, plan.sessionID == sessionID, plan.expiresAt > Date() else {
            return .failed(message: "승인 대상이 만료·취소되었거나 폴더가 변경되었습니다. 다시 요청해주세요.", retryable: false)
        }
        prepared = nil // Consume once, before any await; no automatic mutation retries.
        let result = await operation(plan.request.action, target: plan.request.path, text: plan.request.text,
            revision: plan.revision, destination: plan.request.destination, confirmed: true)
        switch result {
        case .succeeded(let output):
            if let recovery = output.recovery { recoveries.insert(recovery, at: 0) }
            if plan.request.operation == .move { recoveries.removeAll { $0.recoveryPath == plan.request.path } }
            document = nil; draft = ""; entries = []
            if plan.request.operation == .move || plan.request.operation == .remove { path = "" }
            message = "지정한 위치의 작업을 기기에서 확인했습니다. 목록을 새로고침해주세요. 다른 기기 동기화는 아직 확인하지 못했습니다."
            if output.recovery != nil { message = "대상을 JARVIS 복구함으로 이동했습니다. 영구 삭제하지 않았습니다. 목록을 새로고침해주세요." }
            return .succeeded(message)
        case .needsPermission(let m): return .needsPermission(message: m)
        case .needsConfirmation(let m): return .needsConfirmation(message: m)
        case .failed(let m, let retry): return .failed(message: m, retryable: retry)
        case .unverifiable(let m): return .unverifiable(message: m)
        case .handedOff: return .unverifiable(message: "파일 제공자의 실행 결과를 확인하지 못했습니다.")
        }
    }

    private func operation(_ action: SharedProjectAction, target: String, text: String = "", revision: String? = nil,
                           destination: String = "", confirmed: Bool = false) async -> ToolExecutionResult<SharedProjectOutput> {
        guard !busy, let root, authorize(action, confirmed: confirmed) else {
            return .failed(message: busy ? "다른 파일 작업이 진행 중입니다." : message, retryable: false)
        }
        let epoch = UUID(); generation = epoch; busy = true
        let token = SharedProjectCancellation(); cancellation = token
        let startAccess = self.startAccess, stopAccess = self.stopAccess
        defer { if generation == epoch { busy = false } }
        return await withTaskCancellationHandler {
            let result = await ToolExecutionCoordinator.shared.execute(key: "shared-project-file", timeout: .seconds(20)) {
                await withTaskCancellationHandler {
                    await Task.detached {
                        guard startAccess(root) else { return ToolExecutionResult<SharedProjectOutput>.needsPermission(message: "공유 폴더를 다시 선택해 접근 권한을 허용해주세요.") }
                        defer { stopAccess(root) }
                        return SharedProjectFiles().perform(action, root: root, path: target, text: text,
                            expectedRevision: revision, confirmed: confirmed, destination: destination,
                            locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }, cancellation: token)
                    }.value
                } onCancel: { token.cancel() }
            }
            guard generation == epoch, !Task.isCancelled, !token.cancelled,
                  !JarvisStorage.preferences.bool(forKey: Self.lockKey) else { return .unverifiable(message: "작업이 중단되었습니다. 이미 전달한 변경은 파일을 다시 확인해주세요.") }
            record("공유 프로젝트 명령: " + result.status.rawValue)
            return result
        } onCancel: { token.cancel() }
    }

    private func authorize(_ action: SharedProjectAction, confirmed: Bool = false) -> Bool {
        switch SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(
            externalActionsLocked: JarvisStorage.preferences.bool(forKey: Self.lockKey), wasExplicitlyConfirmed: confirmed)) {
        case .allow(let risk, let name):
            record("\(name): 허용")
            #if os(iOS)
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .authorized)
            #endif
            return true
        case .block(_, _, let reason): message = reason; record("공유 프로젝트 작업: 차단"); return false
        case .requireConfirmation(_, _, let prompt): message = prompt; record("공유 프로젝트 작업: 확인 필요"); return false
        }
    }
    private func record(_ event: String) { audit.insert(event, at: 0); audit = Array(audit.prefix(30)) }
}

/// Entry-only hub. Opening it does not grant file access or start an agent.
struct DevelopmentHubView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("사용할 작업 공간을 선택하세요.").foregroundStyle(.secondary)
                NavigationLink {
                    DevelopmentWorkspaceView(initial: .iCloudProject)
                } label: {
                    entrance(JarvisStorage.portable ? "USB 공유 프로젝트" : "iCloud 공유 프로젝트", icon: "icloud", description: "공유 폴더·파일 관리와 알람·일정 DB 저장·불러오기")
                }
                .accessibilityIdentifier("development.icloud")
                NavigationLink {
                    DevelopmentWorkspaceView(initial: .multiAgent)
                } label: {
                    entrance("멀티 에이전트", icon: "person.3", description: "에이전트 협업 기능을 위한 별도 공간 · 준비 중")
                }
                .accessibilityIdentifier("development.multi-agent")
            }.padding()
        }
        .buttonStyle(.plain)
        .navigationTitle("개발 공간")
    }
    private func entrance(_ title: String, icon: String, description: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title).foregroundStyle(.tint).frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// The two development areas are siblings. DB/transfer remain children of
/// the iCloud project and cannot accidentally navigate into agent execution.
struct DevelopmentWorkspaceView: View {
    @StateObject private var navigation: WorkspaceNavigation
    init(initial: WorkspacePage) {
        precondition(initial.parent == .development)
        _navigation = StateObject(wrappedValue: WorkspaceNavigation(initial))
    }
    init(navigation: WorkspaceNavigation) {
        precondition(navigation.parent == .development)
        _navigation = StateObject(wrappedValue: navigation)
    }
    var body: some View {
        Group {
            switch navigation.page {
            case .iCloudProject: SharedProjectView()
            case .multiAgent: MultiAgentWorkspaceView()
            case .database, .transfer, .openAI, .learning, .practice, .review, .memories,
                 .chat, .settings, .development, .alarms, .calendar, .handsFree: EmptyView()
            }
        }
        .id(navigation.page)
        .environment(\.workspaceNavigation, navigation)
    }
}

struct MultiAgentWorkspaceView: View {
    var body: some View {
        #if os(macOS)
        CodexWorkspaceView()
            .navigationTitle("멀티 에이전트")
            .accessibilityIdentifier("development.multi-agent.space")
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("멀티 에이전트 전용 공간", systemImage: "person.3").font(.title2.bold())
                Text("Codex 로컬 연결은 Mac의 JARVIS에서 사용할 수 있습니다. iPhone 원격 연결은 아직 제공하지 않습니다.")
                Text("현재는 Codex 단일 연결 테스트 단계입니다. 역할별 에이전트 협업과 코드 수정·검증·실행은 아직 연결하지 않았습니다.")
                Text("이 화면에 들어오는 것만으로 API를 호출하거나 공유 파일을 읽고 수정하지 않습니다. iCloud 공유 프로젝트와 별도 공간이며 실행 권한도 자동으로 부여하지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("멀티 에이전트")
        .accessibilityIdentifier("development.multi-agent.space")
        #endif
    }
}

#if os(macOS)
@MainActor
final class CodexLocalStore: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var message = "연결 설정에서 보조 서비스 시작·자동 연결을 누르세요. 기존 수동 연결도 사용할 수 있습니다."
    @Published private(set) var reply = ""
    @Published private(set) var audit: [String] = []
    @Published private(set) var models: [CodexLocalModel] = CodexLocalModel.recommended
    @Published private(set) var usesServerModelCatalog = false
    @Published private(set) var quota: CodexQuota?
    @Published private(set) var quotaMessage = "잔여 사용량 확인 전"
    @Published private(set) var backend: CodexLocalBackend
    @Published private(set) var serviceBusy = false
    @Published private(set) var serviceRunning = false
    @Published private(set) var loginPending = false
    @Published private(set) var accountPlan: CodexAccountPlan?
    @Published private(set) var accountCheckedAt: Date?
    @Published private(set) var loginMessage = "전용 App Server 로그인은 Codex에서 관리합니다."
    @Published private(set) var diagnostics: CodexLocalDiagnostics?
    @Published private(set) var lastDurationMS: Int?
    @Published private(set) var reconnecting = false
    @Published private(set) var automaticRecovery = true
    private let managedService: any CodexServiceTransport
    private let recoveryDelay: Duration
    private var recoveryBudget: CodexServiceRecoveryBudget?
    private var recoveryTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private let preferences: UserDefaults
    private var serviceGeneration = UUID()
    private var connection: CodexLocalConnection?
    private let client = CodexLocalClient()
    private var agentLease: UUID?
    private var work: Task<Void, Never>?
    private var activeRequest: UUID?
    @Published private(set) var activeGeneration: UUID?
    @Published private(set) var partialReply = ""
    @Published private(set) var steering = false
    private var steeringWork: Task<Void, Never>?
    private var partialObserver: ((String) -> Void)?

    var canSteer: Bool { activeGeneration != nil && canSteerGeneration && backend == .appServer && !locked }
    private var canSteerGeneration = false

    func steer(_ text: String, completion: @escaping (Bool, String) -> Void) {
        guard canSteer, !steering, let target = activeGeneration, let connection,
              CodexTurnInput.valid(text), authorize(.steer, confirmed: true) else { return }
        let stamp = epoch
        steering = true
        steeringWork = Task {
            let result = await client.perform(.steer, connection: connection, id: UUID(), confirmed: true,
                backend: .appServer, steering: .init(target: target, text: text),
                locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) })
            guard !Task.isCancelled, !locked else { return }
            steering = false
            steeringWork = nil
            guard epoch == stamp || activeGeneration == nil else { return }
            switch result {
            case .succeeded: completion(true, "현재 작업에 추가 메시지를 전달했습니다.")
            case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text): completion(false, text)
            case .handedOff: completion(false, "추가 메시지 전달을 확인하지 못했습니다.")
            }
        }
    }
    private var epoch = UUID()
    private var completion: ((ToolExecutionResult<CodexLocalReply>) -> Void)?
    var sessionID: UUID? { connection?.sessionID }
    private var locked: Bool { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }

    init(preferences: UserDefaults = JarvisStorage.preferences, service: (any CodexServiceTransport)? = nil, recoveryDelay: Duration = .seconds(2)) {
        self.preferences = preferences
        managedService = service ?? CodexManagedService()
        self.recoveryDelay = recoveryDelay
        backend = JarvisStorage.portable ? .appServer : (CodexLocalBackend(rawValue: preferences.string(forKey: "jarvis.codex.backend") ?? "cli") ?? .cli)
        automaticRecovery = preferences.object(forKey: "jarvis.codex.recovery") == nil ? true : preferences.bool(forKey: "jarvis.codex.recovery")
        // Only display preferences survive relaunch; no connection, login URL,
        // repair lease or user approval is restored or executed automatically.
    }

    private func authorize(_ action: CodexLocalAction, confirmed: Bool = false) -> Bool {
        switch SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(
            externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)) {
        case .allow(_, let name):
            audit = Array((audit + [name + " · 허용(완료 아님)"]).suffix(30)); return true
        case .block(_, let name, let reason):
            audit = Array((audit + [name + " · 차단"]).suffix(30)); message = reason; return false
        case .requireConfirmation(_, let name, let prompt):
            audit = Array((audit + [name + " · 승인 필요"]).suffix(30)); message = prompt; return false
        }
    }
    func startService(confirmed: Bool) {
        guard !serviceBusy, !busy, authorize(.serviceStart, confirmed: confirmed) else { return }
        disconnect()
        if automaticRecovery, let build = managedService.installedBuild {
            recoveryBudget = .init(now: Date(), backend: backend, build: build)
        }
        beginService()
    }
    private func beginService() {
        let stamp = UUID(); serviceGeneration = stamp; serviceBusy = true
        message = "앱에 포함된 보조 서비스를 시작합니다…"
        managedService.onDisconnect = { [weak self] in
            guard let self, self.serviceGeneration == stamp else { return }
            self.stop(preservingRecovery: true)
            self.connection = nil; self.connected = false; self.serviceRunning = false
            self.scheduleRecovery()
        }
        managedService.start { [weak self] data, error in
            guard let self, self.serviceGeneration == stamp else { return }
            self.serviceBusy = false
            self.reconnecting = false
            guard !self.locked, let data,
                  let connection = try? CodexLocalConnection.read(data) else {
                self.managedService.stop(); self.serviceRunning = false
                self.message = self.locked ? "안전 잠금으로 서비스 시작을 취소했습니다." : (error ?? "서비스 인증 정보를 확인하지 못했습니다.")
                self.scheduleRecovery()
                return
            }
            self.connection = connection; self.connected = true; self.serviceRunning = true
            self.status() // Login check only; never a model probe or chat replay.
        }
    }
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        guard !locked, let build = managedService.installedBuild,
              (recoveryBudget?.remaining ?? 0) > 0 else {
            reconnecting = false
            message = "보조 서비스 연결을 확인하지 못했습니다. 시작·자동 연결로 다시 연결하세요. 중단된 질문은 재전송하지 않습니다."
            return
        }
        reconnecting = true
        let stamp = serviceGeneration, targetBackend = backend
        message = "승인된 범위에서 연결만 복구합니다. 질문은 다시 보내지 않습니다."
        recoveryTask = Task { [weak self] in
            guard let delay = self?.recoveryDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.serviceGeneration == stamp else { return }
            guard !self.locked, self.backend == targetBackend, self.managedService.installedBuild == build else {
                self.revokeRecovery()
                self.message = "빌드·연결 방식·잠금 상태가 변경돼 자동 복구를 중단했습니다. 다시 연결을 승인해주세요."
                return
            }
            guard self.recoveryBudget?.claim(now: Date(), backend: targetBackend, build: build, locked: self.locked) == true,
                  self.authorize(.serviceStart, confirmed: true) else {
                self.reconnecting = false
                self.message = "연결 복구 승인 범위가 만료되거나 변경됐습니다. 시작·자동 연결로 다시 승인해주세요."
                return
            }
            self.beginService()
        }
    }
    private func revokeRecovery() {
        recoveryBudget = nil; recoveryTask?.cancel(); recoveryTask = nil; reconnecting = false
    }
    func setAutomaticRecovery(_ enabled: Bool) {
        guard authorize(.configureRecovery) else { return }
        automaticRecovery = enabled
        preferences.set(enabled, forKey: "jarvis.codex.recovery")
        if !enabled { revokeRecovery() }
    }
    func stopService() {
        guard authorize(.serviceStop) else { return }
        serviceGeneration = UUID(); serviceBusy = false
        disconnect()
        message = "전용 보조 서비스에 중지를 요청하고 연결을 해제했습니다. 기존 수동 CLI 프로그램과 Codex 로그인은 유지됩니다."
    }
    func configure(_ url: URL, confirmed: Bool) {
        if JarvisStorage.portable { message = "USB 전용 모드에서는 앱 내장 App Server 서비스를 시작해주세요."; return }
        guard authorize(.configure, confirmed: confirmed) else { return }
        disconnect()
        do {
            guard url.lastPathComponent == "JARVISCodexLocal.json",
                  !["Mobile Documents", "CloudStorage", "CloudDocs"].contains(where: url.path.contains),
                  url.startAccessingSecurityScopedResource() else { throw CodexLocalError.invalid }
            defer { url.stopAccessingSecurityScopedResource() }
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  (values[.referenceCount] as? NSNumber)?.intValue == 1,
                  ((values[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CodexLocalError.invalid }
            guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            connection = try CodexLocalConnection.read(handle.read(upToCount: 4097) ?? Data())
            connected = true
            message = "연결 정보를 메모리에 불러왔습니다. 아직 보조 프로그램·로그인을 확인한 것은 아닙니다. 로그인 상태 확인을 눌러주세요."
        } catch { message = "개인 로컬 연결 파일을 확인하지 못했습니다. 보조 프로그램이 만든 원본 파일을 다시 선택하세요. 토큰은 표시하거나 iCloud에 저장하지 않습니다." }
    }
    func status() {
        guard !busy, !loginPending else { return }
        run(.status, confirmed: false)
    }
    func inspectConnection() { run(.diagnostics, confirmed: false) }
    func becameActive() {
        guard connected, !busy, !locked, !serviceBusy else { return }
        if loginPending { run(.loginPoll, confirmed: false) } else { status() }
    }
    func login(confirmed: Bool, expectedSession: UUID?) {
        guard expectedSession != nil, expectedSession == sessionID, backend == .appServer, connected, !busy, !loginPending else { return }
        run(.loginStart, confirmed: confirmed)
    }
    func logout(confirmed: Bool, expectedSession: UUID?) {
        guard expectedSession != nil, expectedSession == sessionID, backend == .appServer, connected, !busy else { return }
        run(.logout, confirmed: confirmed)
    }
    func cancelLogin() {
        guard authorize(.loginCancel) else { return }
        stop(cancelAuthentication: false)
        if connected { run(.loginCancel, confirmed: false) }
    }
    private func waitForLogin() {
        loginTask?.cancel()
        let session = sessionID
        loginTask = Task { [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.sessionID == session, self.loginPending, !self.locked else { return }
                if !self.busy { self.run(.loginPoll, confirmed: false) }
            }
            guard !Task.isCancelled, let self, self.loginPending else { return }
            self.cancelLogin()
            self.loginMessage = "로그인 대기 시간이 만료됐습니다. 다시 로그인해주세요."
        }
    }
    func selectBackend(_ value: CodexLocalBackend) {
        if JarvisStorage.portable && value == .cli { message = "USB 전용 모드는 전용 App Server를 사용합니다."; return }
        guard value != backend, authorize(.selectBackend) else { return }
        stop(); backend = value; ready = false; quota = nil; quotaMessage = "잔여 사용량 확인 전"
        models = CodexLocalModel.recommended
        usesServerModelCatalog = false
        preferences.set(value.rawValue, forKey: "jarvis.codex.backend")
        message = "\(value.title) 연결을 선택했습니다. 로그인 상태를 확인하세요. 이전 요청을 다른 방식으로 자동 전송하지 않습니다."
    }
    func refreshModels() { run(.models, confirmed: false) }
    func refreshUsage() {
        guard connected, !busy else { return }
        quota = nil; quotaMessage = "잔여 사용량 확인 중"
        run(.usage, confirmed: false)
    }
    func send(_ payload: CodexChatRequest, expectedSession: UUID, confirmed: Bool = false, completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void) {
        guard ready, !busy, connection?.sessionID == expectedSession else {
            completion(.failed(message: "연결 상태가 바뀌었습니다. 로그인 상태를 다시 확인하세요.", retryable: false)); return
        }
        run(.chat, confirmed: confirmed, chat: payload, completion: completion)
    }
    func reserveAgent(_ lease: UUID) -> Bool {
        guard ready, !busy, backend == .appServer, agentLease == nil, !locked else { return false }
        agentLease = lease; busy = true; return true
    }
    func releaseAgent(_ lease: UUID) {
        guard agentLease == lease else { return }
        agentLease = nil; busy = false
    }
    func agentCall(_ action: CodexLocalAction, input: String, lease: UUID, confirmed: Bool) async -> ToolExecutionResult<CodexLocalReply> {
        guard agentLease == lease, let connection, backend == .appServer else { return .failed(message: "Codex 작업 연결이 변경됐습니다.", retryable: false) }
        return await client.perform(action, connection: connection, id: UUID(), confirmed: confirmed,
            backend: .appServer, agentInput: input, locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) })
    }
    func agentVerify(_ payload: CodexNativeToolRequest, lease: UUID, output: @escaping @MainActor (String) -> Void) async -> ToolExecutionResult<CodexLocalReply> {
        guard agentLease == lease, let connection else { return .failed(message: "작업 연결이 변경됐습니다.", retryable: false) }
        return await client.perform(.nativeTool, connection: connection, id: UUID(), confirmed: true, backend: .appServer,
            onPartial: { text in await output(text) }, native: payload,
            locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) })
    }
    func agentSearch(_ query: String, lease: UUID) async -> ToolExecutionResult<String> {
        guard agentLease == lease, !locked, case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.nativeTool),
            context: .init(origin: .modelProposed, externalActionsLocked: locked, wasExplicitlyConfirmed: true)) else {
            return .failed(message: "검색 승인이 만료됐습니다.", retryable: false)
        }
        do {
            let result = try await WebSearchService().search(query: query)
            guard agentLease == lease, !locked, !Task.isCancelled else { return .failed(message: "검색을 취소했습니다.", retryable: false) }
            let sources = result.sources.prefix(5).filter { $0.url.user == nil && $0.url.password == nil }.map { String($0.title.prefix(200)) + " · " + String($0.url.absoluteString.prefix(2000)) }
            return .succeeded(String(decoding: Data((result.text + "\n\n출처:\n" + sources.joined(separator: "\n")).utf8).prefix(16000), as: UTF8.self))
        } catch { return .failed(message: (error as? LocalizedError)?.errorDescription ?? "검색 연결을 확인해주세요.", retryable: false) }
    }
    func stopAgent(_ lease: UUID) {
        guard agentLease == lease else { return }
        if let connection {
            let client = client
            let input = "{\"jobID\":\"" + lease.uuidString + "\"}"
            Task { _ = await client.perform(.agentStop, connection: connection, id: UUID(), backend: .appServer, agentInput: input, locked: { false }) }
        }
        releaseAgent(lease)
    }
    func sendCode(_ payload: CodexCodeRequest, expectedSession: UUID, confirmed: Bool, completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void) {
        guard ready, !busy, backend == .appServer, connection?.sessionID == expectedSession else {
            completion(.failed(message: "App Server 연결·로그인 상태를 확인해주세요.", retryable: false)); return
        }
        run(.codeDraft, confirmed: confirmed, code: payload, completion: completion)
    }
    func runNative(_ payload: CodexNativeToolRequest, confirmed: Bool, onOutput: ((String) -> Void)? = nil,
                   completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void) {
        guard ready, backend == .appServer else {
            completion(.needsPermission(message: "App Server에 연결하고 로그인 상태를 확인하세요."))
            return
        }
        run(.nativeTool, confirmed: confirmed, native: payload, onOutput: onOutput, completion: completion)
    }
    func probe(confirmed: Bool, expectedSession: UUID?) {
        guard ready, expectedSession != nil, connection?.sessionID == expectedSession else {
            message = "연결 상태가 바뀌었습니다. 로그인부터 다시 확인해주세요."; return
        }
        run(.probe, confirmed: confirmed)
    }
    private func run(_ action: CodexLocalAction, confirmed: Bool, chat: CodexChatRequest? = nil, code: CodexCodeRequest? = nil, native: CodexNativeToolRequest? = nil, onOutput: ((String) -> Void)? = nil,
                     completion: ((ToolExecutionResult<CodexLocalReply>) -> Void)? = nil) {
        guard !busy, (!steering || action == .usage), authorize(action, confirmed: confirmed), let connection else {
            completion?(.failed(message: "요청이 허용되지 않았습니다.", retryable: false)); return
        }
        if serviceRunning && !managedService.matchesInstalledBuild {
            disconnect(); message = "앱 또는 내장 서비스가 업데이트됐습니다. 시작·자동 연결로 새 빌드에 연결하세요. 로그인과 대화 기록은 유지됩니다."
            completion?(.failed(message: message, retryable: false)); return
        }
        if [.status, .loginStart, .logout].contains(action) { clearAccountStatus() }
        self.completion = completion
        partialObserver = onOutput
        let backend = backend
        let request = UUID(), stamp = UUID()
        canSteerGeneration = [.chat, .codeDraft].contains(action)
        activeRequest = request; activeGeneration = [.chat, .codeDraft, .probe, .nativeTool].contains(action) ? request : nil; epoch = stamp; busy = true; reply = ""
        message = [.probe, .chat, .codeDraft].contains(action) ? "Codex 응답을 기다립니다…" : "로컬 연결 정보를 확인합니다…"
        partialReply = ""
        let onPartial: (@Sendable (String) async -> Void)?
        if [.chat, .nativeTool].contains(action) && backend == .appServer {
            onPartial = { [weak self] text in
                await self?.showPartialReply(text, request: request, epoch: stamp)
            }
        } else {
            onPartial = nil
        }
        let started = ContinuousClock.now
        work = Task {
            let client = client
            let result = await ToolExecutionCoordinator.shared.execute(key: "codex-local", timeout: .seconds([.probe, .chat, .codeDraft, .nativeTool].contains(action) ? (backend == .appServer ? 130 : 90) : (backend == .appServer ? 50 : 25))) {
                await withTaskCancellationHandler {
                    await client.perform(action, connection: connection, id: request, confirmed: confirmed, chat: chat, backend: backend, code: code, onPartial: onPartial, native: native,
                        locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) })
                } onCancel: {
                    Task { _ = await client.perform(.cancel, connection: connection, id: request, backend: backend, locked: { false }) }
                }
            }
            guard epoch == stamp, !Task.isCancelled, action == .loginCancel || !locked else { return }
            busy = false; activeRequest = nil; activeGeneration = nil; partialReply = ""; partialObserver = nil; work = nil
            let duration = started.duration(to: .now).components
            lastDurationMS = max(0, Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000))
            switch result {
            case .succeeded(let value):
                if action == .status && backend == .appServer {
                    accountPlan = value.accountPlan
                    accountCheckedAt = Date()
                }
                if [.status, .probe, .chat, .codeDraft].contains(action) && !loginPending { ready = true }
                if action == .loginStart {
                    ready = false; loginPending = true
                    guard let text = value.authURL, let url = CodexLoginURL.validated(text) else {
                        cancelLogin(); return
                    }
                    if NSWorkspace.shared.open(url) {
                        message = "브라우저 로그인을 기다립니다. 질문은 전송하지 않았습니다."
                        loginMessage = "브라우저에서 로그인을 완료해주세요. 최대 3분 동안 확인합니다."
                        waitForLogin()
                    } else {
                        cancelLogin(); loginMessage = "브라우저를 열지 못했습니다. 다시 시도해주세요."
                    }
                } else if action == .loginPoll {
                    if value.loginState == "completed" {
                        loginPending = false; loginTask?.cancel(); loginTask = nil; ready = true
                        loginMessage = "전용 App Server의 ChatGPT 로그인을 확인했습니다."
                    } else if value.loginState != "pending" {
                        loginPending = false; loginTask?.cancel(); loginTask = nil; ready = false
                        loginMessage = value.loginState == "expired" ? "로그인 대기 시간이 만료됐습니다." : "로그인이 완료되지 않았습니다. 다시 로그인해주세요."
                    }
                } else if [.logout, .loginCancel].contains(action) {
                    loginPending = false; loginTask?.cancel(); loginTask = nil; ready = false
                    loginMessage = action == .logout ? "전용 App Server 로그아웃을 확인했습니다. 기존 CLI 계정은 유지됩니다." : "로그인 대기를 중지했습니다. 계정 상태는 다시 확인할 수 있습니다."
                } else if action == .diagnostics {
                    diagnostics = value.diagnostics
                    message = value.diagnostics == nil ? "진단 기능을 지원하려면 보조 서비스를 다시 시작하세요." : "연결 진단을 확인했습니다. 모델 질문은 보내지 않았습니다."
                } else if action == .codeDraft {
                    message = "코드 작업 응답을 수신했습니다. 파일 변경은 적용 승인 후 진행됩니다."
                } else if action == .usage {
                    quota = value.quota
                    quotaMessage = value.quota == nil ? (backend == .cli ? "App Server 연결에서 잔여 사용량을 조회할 수 있습니다." : "서버가 사용량 정보를 제공하지 않았습니다.") : "계정 한도 기준 · 모델별 잔여 토큰 수가 아닙니다."
                } else if action == .models {
                    if backend == .appServer, let available = value.models, !available.isEmpty {
                        models = available
                        usesServerModelCatalog = true
                        message = "App Server가 제공한 모델과 추론 수준을 표시합니다."
                    } else {
                        models = CodexLocalModel.catalog(merging: value.models ?? [])
                        usesServerModelCatalog = false
                        message = "추천 모델과 최근 Codex 모델 목록을 표시합니다. 계정에서의 실제 사용 가능 여부는 응답 요청 때 확인됩니다."
                    }
                } else if [.probe, .chat].contains(action) {
                    reply = value.reply ?? ""
                    message = "Codex 응답을 수신했습니다. 아래는 검증되지 않은 모델 텍스트이며 실행 지시로 사용하지 않습니다."
                } else if action == .nativeTool {
                    message = "도구 실행 결과를 확인했습니다."
                } else {
                    message = "\(backend.title) 연결과 ChatGPT 로그인 상태를 확인했습니다."
                    if action == .status { loginMessage = "\(backend.title)의 ChatGPT 로그인을 확인했습니다." }
                }
            case .failed(let text, _) where action == .nativeTool:
                // A test's nonzero exit is an operation failure, while the
                // authenticated App Server connection can remain usable.
                message = text
            case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text):
                if action == .usage { quota = nil; quotaMessage = "잔여 사용량 확인 불가" }
                else { message = text; if action != .models { ready = false } }
                if [.loginStart, .loginPoll, .logout].contains(action) {
                    loginTask?.cancel(); loginTask = nil; loginPending = false; loginMessage = text
                    let client = client
                    Task { _ = await client.perform(.loginCancel, connection: connection, id: UUID(), backend: .appServer, locked: { false }) }
                }
            case .handedOff: message = "완료를 확인하지 못했습니다."; ready = false
            }
            let callback = self.completion; self.completion = nil; callback?(result)
            if action == .status, case .succeeded = result { refreshModels() }
            if action == .loginPoll, ready, !loginPending { status() }
            if [.models, .chat].contains(action), !busy { refreshUsage() }
        }
    }
    private func clearAccountStatus() {
        accountPlan = nil; accountCheckedAt = nil
    }

    private func showPartialReply(_ text: String, request: UUID, epoch stamp: UUID) {
        guard epoch == stamp, activeGeneration == request, !locked else { return }
        partialReply = text
        partialObserver?(text)
    }

    func stop(preservingRecovery: Bool = false, cancelAuthentication: Bool = true) {
        guard authorize(.cancel) else { return }
        if let lease = agentLease { stopAgent(lease) }
        if !preservingRecovery { revokeRecovery() }
        loginTask?.cancel(); loginTask = nil
        if cancelAuthentication, loginPending, let connection {
            let client = client
            Task { _ = await client.perform(.loginCancel, connection: connection, id: UUID(), backend: .appServer, locked: { false }) }
        }
        loginPending = false
        if let connection, let activeRequest {
            let client = client
            let backend = backend
            Task { _ = await client.perform(.cancel, connection: connection, id: activeRequest, backend: backend, locked: { false }) }
        }
        clearAccountStatus()
        steeringWork?.cancel(); steeringWork = nil; steering = false; activeGeneration = nil; partialReply = ""; partialObserver = nil
        epoch = UUID(); work?.cancel(); work = nil; activeRequest = nil; busy = false; ready = false; reply = ""
        let callback = completion; completion = nil
        callback?(.failed(message: "요청을 중단했습니다. 자동으로 다시 전송하지 않습니다.", retryable: false))
        message = "로컬 요청을 중단했습니다. 다시 요청하려면 로그인 상태를 재확인하세요."
    }
    func disconnect() {
        guard authorize(.disconnect) else { return }
        serviceGeneration = UUID(); serviceBusy = false
        managedService.stop(); serviceRunning = false
        stop(); connection = nil; connected = false; ready = false; reply = ""; quota = nil; quotaMessage = "잔여 사용량 확인 전"
        message = "JARVIS의 연결 정보를 지웠습니다. Codex 계정에서 로그아웃하거나 다른 작업을 중단한 것은 아닙니다."
    }
}

struct CodexLocalPanel: View {
    @ObservedObject var store: CodexLocalStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var picking = false
    @State private var selected: URL?
    @State private var confirmingConnection = false
    @State private var confirmingProbe = false
    @State private var confirmingService = false
    @State private var confirmingLogin = false
    @State private var confirmingLogout = false
    @State private var approvedSession: UUID?
    var body: some View {
        GroupBox("Codex · 개인용 Mac 로컬 연결") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("연결 방식", selection: Binding(get: { store.backend }, set: { store.selectBackend($0) })) {
                    ForEach(CodexLocalBackend.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).disabled(store.busy || locked)
                Text("보조 프로그램은 이 Mac의 127.0.0.1에서만 연결됩니다. 답변 생성은 선택 제공자의 인터넷 서비스와 계정 한도를 사용합니다.")
                HStack {
                    Button("보조 서비스 시작·자동 연결") { confirmingService = true }
                        .disabled(store.busy || store.serviceBusy || locked)
                    Button("보조 서비스 중지") { store.stopService() }
                        .disabled(!store.serviceRunning && !store.serviceBusy && !store.reconnecting)
                    if store.serviceBusy { ProgressView().controlSize(.small) }
                }
                Toggle("연결 끊김 자동 복구 (승인 후 10분·최대 2회)", isOn: Binding(
                    get: { store.automaticRecovery }, set: { store.setAutomaticRecovery($0) }))
                    .disabled(locked || store.serviceBusy)
                if store.reconnecting { Text("연결 복구 대기 중 · 질문 재전송 없음").font(.caption) }
                Text(store.serviceRunning ? "내장 서비스 실행 중 · 인증 연결됨" : "내장 서비스 중지됨")
                    .font(.caption).foregroundStyle(.secondary)
                Text("터미널·연결 파일 선택 없이 시작합니다. 이 Mac에 Python 3과 Codex가 설치되어 있어야 합니다. 앱 종료·연결 해제 시 전용 서비스도 중지되며, 로그인 시 자동 실행은 등록하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.backend == .appServer {
                    Text("App Server · 텍스트 연결 단계\n별도의 설정·로그인 저장소를 사용합니다. 기존 CLI는 그대로 유지됩니다. 파일·명령 실행은 연결하지 않았습니다.").font(.callout)
                    HStack {
                        Button("ChatGPT 로그인") { approvedSession = store.sessionID; confirmingLogin = true }
                            .disabled(!store.connected || store.busy || store.loginPending || locked)
                        Button("전용 계정 로그아웃") { approvedSession = store.sessionID; confirmingLogout = true }
                            .disabled(!store.connected || store.busy || store.loginPending || locked)
                        if store.loginPending { Button("로그인 취소") { store.cancelLogin() } }
                    }
                    Text(store.loginMessage).font(.caption).foregroundStyle(.secondary)
                    if let checked = store.accountCheckedAt {
                        LabeledContent("ChatGPT 플랜", value: store.accountPlan?.title ?? "확인 불가")
                        LabeledContent("최근 확인", value: checked.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("로그인 정보는 Codex가 전용 저장소에 보관합니다. 브라우저로 이동해도 로그인 대기는 유지하며, 취소·연결 해제·3분 만료 시 종료합니다.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("CLI는 기존 Mac 로그인을 사용합니다. 로그인이 필요하면 터미널에서 codex login을 실행하세요.").font(.callout)
                }
                Text("기존 수동 연결도 사용할 수 있습니다: 보조 프로그램 실행 → 연결 파일 선택 → 로그인 상태 확인").font(.caption)
                Button("수동 연결 파일 선택") { picking = true }.disabled(store.busy || store.serviceBusy || locked)
                Button(store.backend == .appServer ? "계정 상태 새로 고침" : "로그인 상태 확인") { store.status() }.disabled(!store.connected || store.busy || locked)
                Button("최근 모델 목록 불러오기") { store.refreshModels() }.disabled(!store.connected || store.busy || store.loginPending || locked)
                Button("연결 진단 확인") { store.inspectConnection() }.disabled(!store.connected || store.busy || store.loginPending || locked)
                if let diagnostics = store.diagnostics {
                    Text("보조 프로그램 \(diagnostics.helperBuild) · Python \(String(diagnostics.pythonMajor)).\(String(diagnostics.pythonMinor)) · 처리 요청 \(String(diagnostics.requests))개 · \(diagnostics.managed ? "내장 서비스" : "수동 연결")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let latency = store.lastDurationMS {
                    Text("최근 요청 응답까지 \(String(latency))ms · 모델 추론 시간만을 의미하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Codex 응답 테스트 · 고정 질문 1회") {
                    approvedSession = store.sessionID; confirmingProbe = true
                }.disabled(!store.ready || store.busy || locked)
                if store.busy { ProgressView(); Button("요청 중지") { store.stop() } }
                if store.connected { Button("JARVIS 연결 해제") { store.disconnect() } }
                Text(store.message).font(.callout)
                if !store.reply.isEmpty { Text(store.reply).textSelection(.enabled).privacySensitive() }
                DisclosureGroup("이 화면의 실행 검토 기록") {
                    ForEach(Array(store.audit.enumerated()), id: \.offset) { _, entry in Text(entry).font(.caption) }
                }
                Text("수동 연결 파일은 iCloud·공유 프로젝트에 복사하지 마세요. 내장 서비스는 시작 버튼으로 다시 연결할 수 있습니다. 대화는 별도 채팅 화면에서 전송하며 셸·파일 도구는 제공하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .alert("전용 보조 서비스를 시작할까요?", isPresented: $confirmingService) {
            Button("취소", role: .cancel) {}
            Button("서비스 시작·연결 승인") { store.startService(confirmed: true) }
        } message: {
            Text("앱에 포함된 서비스가 이 Mac의 Python·Codex를 실행합니다. 자동 복구를 켰다면 같은 빌드·연결 방식에서 10분 동안 최대 2회 연결 복구만 허용합니다. 질문·파일·셸 실행은 승인하지 않습니다.")
        }
        .alert("전용 App Server에 로그인할까요?", isPresented: $confirmingLogin) {
            Button("취소", role: .cancel) { approvedSession = nil }
            Button("브라우저 로그인") { store.login(confirmed: true, expectedSession: approvedSession); approvedSession = nil }
        } message: { Text("공식 인증 페이지를 브라우저로 엽니다. JARVIS는 비밀번호·로그인 토큰을 읽지 않습니다. 기존 CLI 계정은 변경하지 않습니다.") }
        .alert("전용 계정에서 로그아웃할까요?", isPresented: $confirmingLogout) {
            Button("취소", role: .cancel) { approvedSession = nil }
            Button("전용 계정 로그아웃", role: .destructive) { store.logout(confirmed: true, expectedSession: approvedSession); approvedSession = nil }
        } message: { Text("JARVIS 전용 App Server의 로그인만 해제합니다. 로컬 대화 기록·기존 CLI·Codex 앱 계정은 유지됩니다.") }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let first = urls.first { selected = first; confirmingConnection = true }
        }
        .alert("Codex 로컬 연결을 허용할까요?", isPresented: $confirmingConnection) {
            Button("취소", role: .cancel) { selected = nil }
            Button("선택한 파일 연결 승인") { if let selected { store.configure(selected, confirmed: true) }; selected = nil }
        } message: { Text("선택한 JARVISCodexLocal.json의 연결 정보로 이 Mac의 로컬 보조 프로그램에만 연결합니다. 아직 질문을 전송하거나 파일·셸 권한을 부여하지 않습니다.") }
        .alert("Codex 테스트 질문 한 번을 보낼까요?", isPresented: $confirmingProbe) {
            Button("취소", role: .cancel) { approvedSession = nil }
            Button("고정 질문 전송") { store.probe(confirmed: true, expectedSession: approvedSession); approvedSession = nil }
        } message: { Text("고정된 연결 테스트 문장만 Codex로 전송합니다. 공유 파일·기존 대화·코드·개인정보는 첨부하지 않습니다. 자동 재시도하지 않습니다.") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.becameActive() }
            else {
                if store.serviceBusy { store.stopService() }
                if store.busy && !store.loginPending { store.stop() }
                confirmingService = false; confirmingProbe = false; confirmingLogin = false; confirmingLogout = false; approvedSession = nil
            }
        }
        .onChange(of: locked) { _, value in if value { store.stopService(); confirmingService = false; confirmingProbe = false; confirmingLogin = false; confirmingLogout = false; approvedSession = nil } }
    }
}
#endif

struct SharedProjectView: View {
    @StateObject private var store = SharedProjectStore.shared
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosing = false
    @State private var candidate: URL?
    @State private var confirmFolder = false
    @State private var confirmSave = false
    @State private var confirmDisconnect = false
    @State private var confirmDiscard = false
    @State private var confirmUnlock = false
    @State private var creating = false
    @State private var filename = ""
    @State private var createTarget: String?
    @State private var commandText = ""
    @State private var proposedPlan: SharedProjectPlan?
    @State private var composeKind: SharedProjectRequest.Operation?
    @State private var selectedEntry: SharedProjectEntry?
    @State private var manageDestination = ""
    @State private var showManage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(JarvisStorage.portable ? "USB 공유 프로젝트" : "iCloud 공유 프로젝트").font(.title2.bold())
                Text("양쪽 기기에서 같은 iCloud Drive 폴더를 선택하세요. IP·서버 연결은 필요 없습니다. 이 앱은 파일을 AI로 전송하거나 코드를 실행하지 않습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("프로젝트 폴더 선택", systemImage: "folder.badge.plus") { choosing = true }
                        .disabled(store.busy || store.dirty || locked)
                    Spacer()
                    Button(locked ? "안전 잠금 해제" : "안전 잠금", systemImage: locked ? "lock.fill" : "lock.open") {
                        if locked { confirmUnlock = true } else { store.setLocked(true) }
                    }
                }
                NavigationLink("이 기기의 동기화 DB 보기 (오프라인)", destination: SharedDataWorkspaceView(initial: .database))
                    .disabled(store.busy || locked)
                if let root = store.root {
                    NavigationLink("알람·캘린더 저장·불러오기", destination: SharedDataWorkspaceView(initial: .transfer))
                        .disabled(store.busy || store.dirty || locked)
                    Text("허용 폴더: \(root.lastPathComponent)").font(.headline)
                    DisclosureGroup("연결된 실제 폴더 위치 확인") {
                        Text(root.path).font(.caption).textSelection(.enabled).privacySensitive()
                    }
                    Text(store.path.isEmpty ? "프로젝트 최상위" : store.path).font(.caption).textSelection(.enabled)
                    Text("작업 위치: \(root.lastPathComponent)/\(store.path)").font(.callout.bold())
                    HStack {
                        Button("새 폴더") { composeKind = .folder }
                        Button("새 메모") { composeKind = .note }
                    }.disabled(store.busy || store.dirty || locked)
                    TextField("예: 공유 폴더의 메모 폴더 만들어줘", text: $commandText, axis: .vertical)
                        .textFieldStyle(.roundedBorder).disabled(store.busy || locked)
                    Button("명령 확인") { stageTextCommand() }.disabled(store.busy || store.dirty || locked)
                    DisclosureGroup("명령 예시 · 경로는 공유 폴더 기준") {
                        Text("공유 폴더의 \"메모\" 폴더 만들어줘\n공유 폴더의 \"메모/장보기.txt\" 메모 만들어줘 내용: 우유와 달걀\n공유 폴더의 \"메모/장보기.txt\" 메모 수정해줘 내용: 우유 두 개\n공유 폴더의 \"메모/장보기.txt\" 파일을 \"기록/장보기.txt\"로 옮겨줘\n공유 폴더의 \"메모/장보기.txt\" 파일 삭제해줘")
                            .font(.caption).textSelection(.enabled)
                    }
                    HStack {
                        Button("목록 새로고침") { store.run(.browse, target: store.path) }
                        if !store.path.isEmpty {
                            Button("상위 폴더") { store.run(.browse, target: (store.path as NSString).deletingLastPathComponent) }
                        }
                        Button("새 파일") { filename = ""; creating = true }
                        Button("연결 해제", role: .destructive) { confirmDisconnect = true }
                    }.disabled(store.busy || store.dirty || locked)
                    ForEach(store.entries) { entry in
                      HStack {
                        Button {
                            store.run(entry.directory ? .browse : .read, target: entry.path)
                        } label: {
                            Label(URL(fileURLWithPath: entry.path).lastPathComponent,
                                systemImage: entry.directory ? "folder" : "doc.text")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }.disabled(store.busy || store.dirty || locked)
                        Button("관리") { selectedEntry = entry; manageDestination = entry.path; showManage = true }
                            .disabled(store.busy || store.dirty || locked || SharedProjectFiles.protectedPath(entry.path))
                      }
                    }
                    if !store.recoveries.isEmpty {
                        DisclosureGroup("이번 연결에서 삭제한 항목 복구") {
                            ForEach(store.recoveries) { recovery in
                                Button("\(recovery.originalPath) 원래 위치로 복구") {
                                    stage(.init(.move, path: recovery.recoveryPath, destination: recovery.originalPath))
                                }.disabled(store.busy || store.dirty || locked)
                            }
                        }
                    }
                }
                if let document = store.document {
                    Divider()
                    Text(document.path).font(.headline).textSelection(.enabled)
                    Text(store.dirty ? "저장하지 않은 변경 있음 · 다른 파일을 열기 전에 저장 또는 변경 취소" : "원본과 동일")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.draft).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300).border(Color.secondary.opacity(0.3))
                        .disabled(store.busy || locked).privacySensitive()
                    HStack {
                        Button("변경 비교·저장") { createTarget = nil; confirmSave = true }
                            .disabled(!store.dirty || store.busy || locked)
                        Button("변경 취소") { confirmDiscard = true }.disabled(!store.dirty || store.busy)
                    }
                }
                if store.busy { ProgressView(); Button("작업 중지") { store.pause() } }
                Text(store.message).font(.callout).accessibilityIdentifier("sharedProjectStatus")
                DisclosureGroup("사용 범위와 동기화 안내") {
                    Text("권한은 이번 실행 동안만 유지하며 다시 실행하면 폴더를 선택합니다. 로컬 폴더를 선택하면 iCloud로 공유되지 않습니다. UTF-8 코드·텍스트(256 KiB 이하)만 지원합니다. 숨김·링크·일부 민감 이름 파일은 제외하지만 비밀정보 완전 탐지 기능은 아닙니다. API 키는 넣지 마세요. 동시 수정은 원본 해시·파일 제공자의 충돌 버전을 검사하지만 오프라인 기기 간 충돌을 완전히 막지는 못합니다. 별도 Git 백업을 유지하세요. 잠금은 이 기기에만 적용됩니다.")
                        .font(.caption)
                }
                DisclosureGroup("최근 실행 기록 (내용·경로 제외)") {
                    ForEach(Array(store.audit.enumerated()), id: \.offset) { _, event in Text(event).font(.caption) }
                }
            }.padding()
        }
        .navigationTitle(JarvisStorage.portable ? "USB 공유 프로젝트" : "iCloud 공유 프로젝트")
        .sheet(item: $composeKind) { kind in
            SharedProjectComposeView(kind: kind, base: store.path) { request in
                composeKind = nil; stage(request)
            }
        }
        .sheet(item: $proposedPlan) { plan in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(plan.confirmation).textSelection(.enabled)
                        Text("공유 폴더 밖은 접근하지 않습니다. 승인 후에도 원본이 바뀌면 실행하지 않습니다.")
                        Button("이 경로의 작업 승인") {
                            proposedPlan = nil
                            Task { display(await store.commit(plan, confirmed: true)) }
                        }.disabled(locked || store.busy)
                    }.padding()
                }.navigationTitle("경로·내용 확인")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { store.cancelProposal(); proposedPlan = nil } } }
            }.privacySensitive().interactiveDismissDisabled()
        }
        .sheet(isPresented: $showManage) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("원본: \(store.root?.lastPathComponent ?? "")/\(selectedEntry?.path ?? "")").textSelection(.enabled)
                    TextField("이동할 전체 상대 경로", text: $manageDestination).textFieldStyle(.roundedBorder)
                    Button("이동·이름 변경 확인") {
                        if let selectedEntry { showManage = false; stage(.init(.move, path: selectedEntry.path, destination: manageDestination)) }
                    }
                    Button("삭제 대상 확인 (복구함 이동)", role: .destructive) {
                        if let selectedEntry { showManage = false; stage(.init(.remove, path: selectedEntry.path)) }
                    }
                    Text("기존 대상은 덮어쓰지 않습니다. 비어 있지 않은 폴더는 포함 항목을 검사하며 숨김·링크·지원하지 않는 항목이 있으면 이동을 차단합니다.").font(.caption)
                    Spacer()
                }.padding().navigationTitle("항목 관리")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { showManage = false } } }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): candidate = url; confirmFolder = true
            case .failure: store.message = "폴더를 선택하지 못했습니다. 기존 연결은 변경하지 않았습니다."
            }
        }
        .alert("폴더 접근을 허용할까요?", isPresented: $confirmFolder) {
            Button("취소", role: .cancel) { candidate = nil }
            Button("읽기·승인 후 쓰기 허용") {
                if let candidate { store.run(.connect, folder: candidate, confirmed: true) }
                candidate = nil
            }
        } message: { Text("\(candidate?.lastPathComponent ?? "선택한 폴더")의 코드·텍스트에만 접근합니다. 자동 실행·외부 AI 전송은 하지 않습니다.") }
        .sheet(isPresented: $confirmSave) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(createTarget ?? store.document?.path ?? "").font(.headline)
                        if createTarget == nil {
                            Text("변경 전").font(.headline)
                            Text(store.document?.text ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Text("저장할 내용").font(.headline)
                        Text(createTarget == nil ? store.draft : "(빈 파일)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Text("이 파일의 변경을 저장합니다. iCloud 동기화 후 다른 기기에도 반영될 수 있습니다.")
                        Button("이 파일 저장 승인") {
                            if let createTarget { store.run(.create, target: createTarget, confirmed: true) }
                            else if let document = store.document { store.run(.save, target: document.path, confirmed: true) }
                            confirmSave = false
                        }.disabled(locked)
                    }.padding()
                }
                .navigationTitle("저장 확인")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { confirmSave = false } } }
            }.privacySensitive()
        }
        .alert("새 UTF-8 파일", isPresented: $creating) {
            TextField("예: main.swift", text: $filename)
            Button("취소", role: .cancel) {}
            Button("내용 확인") {
                let path = store.path.isEmpty ? filename : store.path + "/" + filename
                guard !filename.contains("/"), SharedProjectFiles.editablePath(path) else {
                    store.message = "숨김·민감 이름이 아닌 지원 코드 파일명을 입력해주세요."; return
                }
                createTarget = path; confirmSave = true
            }
        } message: { Text("빈 파일을 생성한 뒤 열어서 편집합니다. 기존 파일은 덮어쓰지 않습니다.") }
        .alert("변경을 취소할까요?", isPresented: $confirmDiscard) {
            Button("유지", role: .cancel) {}
            Button("변경 취소", role: .destructive) { store.discardDraft() }
        }
        .alert("폴더 접근을 해제할까요?", isPresented: $confirmDisconnect) {
            Button("유지", role: .cancel) {}
            Button("해제", role: .destructive) { store.disconnect() }
        }
        .alert("안전 잠금 해제", isPresented: $confirmUnlock) {
            Button("취소", role: .cancel) {}
            Button("이 기기 잠금 해제") { store.setLocked(false, confirmed: true) }
        }
        .onChange(of: locked) { _, value in if value { store.pause() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.pause(); candidate = nil; confirmFolder = false; confirmSave = false; proposedPlan = nil
            }
        }
        .onDisappear { store.pause() }
    }

    private func stageTextCommand() {
        guard case .projectWorkflow(.prepare(let request)) = CommandRouter().route(commandText) else {
            store.message = "대상 경로와 할 일을 명확히 말씀해주세요. 예: 공유 폴더의 \"메모\" 폴더 만들어줘. 메모는 TXT 경로와 내용: 이 필요합니다."; return
        }
        stage(request)
    }
    private func stage(_ request: SharedProjectRequest) {
        Task {
            switch await store.prepare(request) {
            case .succeeded(let plan): proposedPlan = plan
            case .needsPermission(let m), .needsConfirmation(let m), .failed(let m, _), .unverifiable(let m): store.message = m
            case .handedOff: store.message = "실제 원본을 확인하지 못했습니다."
            }
        }
    }
    private func display(_ result: ToolExecutionResult<String>) {
        switch result {
        case .succeeded(let m), .handedOff(let m), .needsPermission(let m), .needsConfirmation(let m), .failed(let m, _), .unverifiable(let m): store.message = m
        }
    }
}

private struct SharedProjectComposeView: View {
    let kind: SharedProjectRequest.Operation
    let base: String
    let submit: (SharedProjectRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                Text("생성 위치: 공유 폴더/\(base)")
                TextField(kind == .folder ? "폴더 이름" : "메모 이름 (예: 장보기)", text: $name)
                if kind == .note { TextEditor(text: $text).frame(minHeight: 180) }
                Button("경로·내용 확인") {
                    let leaf = kind == .note && !name.lowercased().hasSuffix(".txt") ? name + ".txt" : name
                    submit(.init(kind, path: base.isEmpty ? leaf : base + "/" + leaf, text: text))
                }.disabled(name.isEmpty || name.contains("/") || !SharedProjectFiles.validPath(name) || (kind == .note && text.isEmpty))
            }.navigationTitle(kind == .folder ? "새 폴더" : "새 메모")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }
}
