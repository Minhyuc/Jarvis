import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

@MainActor
protocol CodexCodeTransport: AnyObject {
    var ready: Bool { get }
    var busy: Bool { get }
    var backend: CodexLocalBackend { get }
    var sessionID: UUID? { get }
    func sendCode(_ payload: CodexCodeRequest, expectedSession: UUID, confirmed: Bool,
                  completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void)
    func runNative(_ payload: CodexNativeToolRequest, confirmed: Bool, onOutput: ((String) -> Void)?,
                   completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void)
    func stop()
}
extension CodexLocalStore: CodexCodeTransport {
    func stop() { stop(preservingRecovery: false, cancelAuthentication: true) }
}

@MainActor
final class CodexCodeWorkspaceStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var paths: [String] = []
    @Published private(set) var attachments: [CodexCodeFile] = []
    @Published private(set) var files: [CodexCodeFile] = []
    @Published private(set) var plans: [CodexCodePlan] = []
    @Published private(set) var backups: [CodexCodeBackup] = []
    @Published private(set) var summary = ""
    @Published private(set) var proposal: CodexCodeProposal?
    @Published private(set) var message = "JARVIS 소스가 있는 프로젝트 폴더를 선택하세요."
    @Published private(set) var busy = false
    @Published private(set) var pendingReads: [CodexCodeRead] = []
    @Published private(set) var pendingFiles: [CodexCodeFile] = []
    @Published private(set) var readIssues: [String] = []
    @Published private(set) var permissionID = UUID()
    @Published private(set) var pendingCommand: CodexVerificationCommand?
    @Published private(set) var awaitingResult = false
    @Published var resultDraft = ""
    @Published private(set) var liveOutput = ""
    @Published private(set) var phase = "대기"
    @Published private(set) var activities: [String] = []
    @Published private(set) var taskActive = false
    struct Recovery: Codable {
        let root: String
        let rootIdentity: String
        let instruction: String
        let model: String
        let effort: String
        let date: Date
    }
    @Published private(set) var recovery: Recovery?
    private let recoveryKey: String
    private let recoveryDefaults: UserDefaults?
    var record: ((String, Bool) -> Void)?
    private var taskID = UUID()
    private var readGrant: CodexTaskReadGrant?
    private var commandRequest: CodexNativeToolRequest?
    private var verificationSucceeded = false
    private var verificationRecorded = false
    private var appliedPaths: Set<String> = []
    private var toolResults: [String] = []
    private var instruction = ""
    private var turnModel = ""
    private var turnEffort = ""
    private var rounds = 0
    private var deadline = Date.distantPast
    private var expectedSession: UUID?
    private weak var turnConnection: (any CodexCodeTransport)?
    private var history = AssistantContextManager(maximumRecentTurns: 3, maximumLongTermMemories: 1)
    private var turnContext: [CloudConversationTurn] = []
    private var executor: CodexCodeFiles?
    private var cancellation = SharedProjectCancellation()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private weak var activeConnection: (any CodexCodeTransport)?
    private let backupDirectory: URL
    private var uncertain = false
    private var scopedRoot: URL?
    private let lockState: @Sendable () -> Bool
    private var locked: Bool { lockState() }
    init(projectID: UUID, executor: CodexCodeFiles? = nil, backupDirectory: URL? = nil, recoveryDefaults: UserDefaults? = JarvisStorage.preferences,
         lockState: @escaping @Sendable () -> Bool = { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }) {
        self.recoveryDefaults = recoveryDefaults
        self.recoveryKey = "jarvis.codex.taskRecovery." + projectID.uuidString
        if let data = recoveryDefaults?.data(forKey: recoveryKey), data.count < 16384,
           let saved = try? JSONDecoder().decode(Recovery.self, from: data),
           saved.instruction.utf8.count <= 6000, !CodexCodePolicy.containsSecret(saved.instruction),
           (0...(7 * 86400)).contains(Date().timeIntervalSince(saved.date)) { recovery = saved }
        else if case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.cancel), context: .init()) {
            recoveryDefaults?.removeObject(forKey: recoveryKey)
        }
        self.lockState = lockState
        self.backupDirectory = backupDirectory ?? JarvisStorage.support
            .appendingPathComponent("JARVISCodexCodeBackups", isDirectory: true).appendingPathComponent(projectID.uuidString, isDirectory: true)
        self.executor = executor
        self.root = executor?.root
        if executor != nil { refresh() }
    }
    private func authorize(_ action: CodexLocalAction, confirmed: Bool = false) -> Bool {
        switch SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)) {
        case .allow: return true
        case .requireConfirmation(_, _, let text), .block(_, _, let text): message = text; return false
        }
    }
    private func progress(_ text: String) {
        if taskActive, let root, !instruction.isEmpty, !CodexCodePolicy.containsSecret(instruction) {
            let saved = Recovery(root: root.path, rootIdentity: executor?.identity ?? "", instruction: instruction, model: turnModel, effort: turnEffort, date: Date())
            if let data = try? JSONEncoder().encode(saved) { recoveryDefaults?.set(data, forKey: recoveryKey); recovery = saved }
        } else if text == "작업 완료" { discardRecovery() }
        phase = text
        message = text
        activities = Array((activities + [text]).suffix(40))
    }
    private func resultPreview(_ text: String) -> String {
        let bytes = Data(text.utf8)
        guard bytes.count > 3200 else { return text }
        return String(decoding: bytes.prefix(1800), as: UTF8.self)
            + "\n[…전송 미리보기에서 중간 출력을 생략했습니다. 전체 실시간 출력은 위에서 확인할 수 있습니다…]\n"
            + String(decoding: bytes.suffix(1200), as: UTF8.self)
    }
    func discardRecovery() {
        guard authorize(.cancel) else { return }
        recoveryDefaults?.removeObject(forKey: recoveryKey); recovery = nil
    }
    func resumeRecovery(connection: any CodexCodeTransport) {
        guard let saved = recovery, root?.path == saved.root, executor?.identity == saved.rootIdentity, !locked else {
            message = "중단 당시의 프로젝트 폴더를 다시 연결하세요."; return
        }
        // A fresh task rereads originals and reacquires every approval. No command is replayed.
        _ = request(saved.instruction, model: saved.model, effort: saved.effort, connection: connection)
    }
    func previewDiagnostic(_ location: CodexBuildLocation) -> String? {
        guard let executor, authorize(.codeRead), paths.contains(location.path) else { return nil }
        if case .succeeded(let file) = executor.snapshot(location.path, startLine: max(1, location.line - 4), lineCount: 16, locked: { self.locked }) {
            return file.path + ":" + String(location.line) + "\n\n" + file.text
        }
        return nil
    }
    func agentBackupRoot() -> URL { backupDirectory }
    func agentExecutor() -> CodexCodeFiles? {
        guard !busy, authorize(.codeRead) else { return nil }
        return executor
    }
    func connect(_ url: URL, confirmed: Bool) {
        guard !busy, authorize(.codeConnect, confirmed: confirmed) else { return }
        guard JarvisStorage.permits(url) else { message = "USB 내부 프로젝트만 연결할 수 있습니다."; return }
        let savedRecovery = recovery
        disconnect()
        recovery = savedRecovery
        if let savedRecovery, let data = try? JSONEncoder().encode(savedRecovery) { recoveryDefaults?.set(data, forKey: recoveryKey) }
        guard url.startAccessingSecurityScopedResource() else { message = "선택한 프로젝트의 접근 권한을 확인해주세요."; return }
        do {
            executor = try CodexCodeFiles(root: url, confirmed: confirmed, locked: locked)
            scopedRoot = url; root = executor?.root; uncertain = false; refresh()
        } catch { url.stopAccessingSecurityScopedResource(); message = "프로젝트를 연결하지 못했습니다. 홈 전체나 시스템 폴더 대신 소스 폴더를 선택하세요." }
    }
    @discardableResult
    func refresh() -> Bool {
        guard !busy, let executor, authorize(.codeRead) else { return false }
        switch executor.inventory(locked: { self.locked }) {
        case .succeeded(let value): paths = value
        case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text):
            paths = []; message = text; return false
        case .handedOff:
            paths = []; message = "프로젝트 목록 읽기를 확인하지 못했습니다."; return false
        }
        if case .succeeded(let value) = executor.backups(directory: backupDirectory, locked: { self.locked }) { backups = value }
        message = paths.isEmpty
            ? "선택한 폴더에서 읽을 수 있는 파일을 찾지 못했습니다. 소스가 있는 폴더와 접근 권한을 확인하세요."
            : "읽을 수 있는 파일 \(paths.count)개를 찾았습니다. 파일 목록에서 내용을 확인할 수 있습니다."
        return true
    }
    func attach(_ path: String, line: Int, count: Int) {
        guard !busy, let executor, authorize(.codeRead) else { return }
        if taskActive { stop() }
        let result = executor.snapshot(path, startLine: line, lineCount: count, locked: { self.locked })
        switch result {
        case .succeeded(let file):
            let next = attachments.filter { $0.path != path } + [file]
            guard next.count <= 8, next.reduce(0, { $0 + $1.text.utf8.count }) <= 98304 else { message = "한 요청에 최대 8개 파일·96KiB 코드 범위를 첨부할 수 있습니다."; return }
            attachments = next; plans = []; proposal = nil; summary = ""
            message = CodexCodePolicy.writable(path) ? "선택한 코드 범위를 첨부했습니다." : "보호된 실행·안전 코드는 참고용으로만 첨부합니다. 수정할 수 없습니다."
        case .failed(let text, _), .needsConfirmation(let text), .needsPermission(let text), .unverifiable(let text): message = text
        case .handedOff: message = "파일 읽기를 확인하지 못했습니다."
        }
    }
    func remove(_ path: String) {
        guard !busy, authorize(.codeRead) else { return }
        if taskActive { stop() }
        attachments.removeAll { $0.path == path }; plans = []; proposal = nil
    }
    @discardableResult
    func request(_ instruction: String, model: String, effort: String, connection: any CodexCodeTransport) -> Bool {
        guard !busy, root != nil, connection.ready, !connection.busy, connection.backend == .appServer else {
            message = "프로젝트 폴더와 App Server 연결·로그인 상태를 먼저 확인해주세요."; return false
        }
        guard refresh() else { return false }
        let selected = attachments
        guard selected.allSatisfy({ file in paths.contains(file.path) }) else {
            message = "선택한 파일이 목록에서 사라졌습니다. 파일 목록에서 다시 선택하세요."
            return false
        }
        stop()
        files = selected; pendingReads = []; permissionID = UUID()
        self.instruction = instruction; turnModel = model; turnEffort = effort
        turnContext = history.context(for: instruction, longTermMemories: []).recentTurns.suffix(3).map { CloudConversationTurn(user: $0.userText, assistant: $0.assistantResponse) }
        rounds = 0; deadline = Date().addingTimeInterval(600)
        taskID = UUID(); taskActive = true; activities = []; toolResults = []
        verificationRecorded = false; appliedPaths = []
        progress("프로젝트 분석 중")
        expectedSession = connection.sessionID; turnConnection = connection
        record?(instruction, true)
        continueRequest(connection)
        if busy { attachments = [] }
        return busy
    }
    func recordSteering(_ text: String) {
        let combined = instruction + "\n\n추가 메시지: " + text
        if combined.utf8.count <= 6000 { instruction = combined }
        record?(text, true)
    }
    private func continueRequest(_ connection: any CodexCodeTransport) {
        guard connection.ready, !connection.busy, connection.backend == .appServer else {
            taskActive = false; readGrant = nil; progress("연결 확인 필요")
            message = "선택한 제공자의 연결·로그인 상태를 먼저 확인해주세요."; return
        }
        guard taskActive, rounds < 12, Date() < deadline else {
            taskActive = false; progress("작업 한도 도달"); message = "이번 작업의 12회 요청 또는 10분 제한에 도달했습니다. 결과를 확인한 뒤 새 요청을 보내세요."
            record?(message, false); return
        }
        guard !busy, expectedSession == connection.sessionID,
              let executor, let session = connection.sessionID,
              authorize(.codeDraft, confirmed: true) else { return }
        guard refresh() else {
            taskActive = false; readGrant = nil; progress("프로젝트 확인 실패"); return
        }
        let payload = CodexCodeRequest(model: turnModel, effort: turnEffort, instruction: instruction, files: files, tree: paths, context: turnContext, toolResults: toolResults)
        do { _ = try payload.encodedInput() } catch {
            taskActive = false; readGrant = nil; progress("전송 내용 검증 실패")
            message = "모델·요청 길이·첨부 코드·도구 출력의 크기와 민감정보를 확인해주세요."
            record?(message, false); return
        }
        // The visible send button approves exactly this snapshot. No transcript,
        // root handle, absolute path or credentials enter the helper.
        let stamp = UUID(); generation = stamp; busy = true; plans = []; proposal = nil; summary = ""
        activeConnection = connection; let snapshots = files
        rounds += 1
        progress("Codex가 다음 단계를 판단하는 중")
        message = "승인된 문맥과 실행 결과로 다음 단계를 요청합니다."
        connection.sendCode(payload, expectedSession: session, confirmed: true) { [weak self] result in
            guard let self, self.generation == stamp, self.executor?.session == executor.session, !self.locked else { return }
            self.busy = false; self.activeConnection = nil
            switch result {
            case .succeeded(let reply):
                do {
                    guard self.authorize(.codeRead) else { return }
                    let proposal = try CodexCodeProposal.read(reply.reply ?? "")
                    if let reads = proposal.reads, !reads.isEmpty {
                        guard self.rounds < 12, Date() < self.deadline else {
                            self.taskActive = false; self.progress("작업 한도 도달")
                            self.message = "이번 작업의 요청 횟수 또는 10분 유효 시간이 끝났습니다. 새 요청으로 필요한 파일을 좁혀주세요."
                            self.record?(self.message, false); return
                        }
                        switch executor.previewReads(reads, inventory: self.paths, locked: { self.locked }) {
                        case .succeeded(let batch):
                            self.pendingFiles = batch.files; self.pendingReads = batch.reads; self.readIssues = batch.issues
                        case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text):
                            self.taskActive = false; self.readGrant = nil; self.progress("소스 확인 실패")
                            self.message = text; self.record?(text, false); return
                        case .handedOff:
                            self.taskActive = false; self.readGrant = nil; self.progress("소스 확인 실패")
                            self.message = "로컬 소스 미리보기를 확인하지 못했습니다."; self.record?(self.message, false); return
                        }
                        self.permissionID = UUID()
                        guard !self.pendingFiles.isEmpty else {
                            self.taskActive = false; self.readGrant = nil; self.progress("전송 가능한 소스 없음")
                            self.message = "전송 가능한 소스를 준비하지 못했습니다.\n" + self.readIssues.joined(separator: "\n")
                            self.record?(String(self.message.prefix(1800)), false); return
                        }
                        self.summary = proposal.summary
                        self.record?(proposal.summary, false)
                        self.progress("소스 읽기·전송 승인 대기")
                        self.message = "준비된 코드의 실제 줄 범위와 내용을 확인한 뒤 OpenAI 전송을 승인해주세요. 제외된 파일은 전송하지 않습니다."
                        if self.readGrant?.consume(self.pendingReads, task: self.taskID, locked: self.locked) == true {
                            self.approveReads(self.permissionID)
                        }
                        return
                    }
                    if let command = proposal.commands?.first {
                        let request = CodexNativeToolRequest(operation: .verify, root: executor.root.path, command: command.argv)
                        guard request.rootIdentity == executor.identity else { throw CodexCodeError.changed }
                        _ = try request.encodedInput()
                        self.pendingCommand = command; self.commandRequest = request
                        self.permissionID = UUID(); self.summary = proposal.summary
                        self.progress("검증 명령 승인 대기")
                        self.record?(proposal.summary, false)
                        return
                    }
                    self.plans = try executor.prepare(proposal, files: snapshots, locked: { self.locked })
                    self.proposal = proposal; self.summary = proposal.summary
                    if !self.plans.isEmpty { self.record?(proposal.summary, false) }
                    self.history.record(userText: self.instruction, assistantResponse: proposal.summary, intent: .unknownCommand(text: self.instruction))
                    self.message = self.plans.isEmpty ? "답변을 받았습니다. 파일은 변경하지 않았습니다." : "변경안을 받았습니다. 파일별 변경 전후를 확인하고 적용하세요. 빌드·테스트는 실행하지 않았습니다."
                    self.progress(self.plans.isEmpty ? "완료" : "파일 변경 승인 대기")
                    if self.plans.isEmpty {
                        self.taskActive = false; self.readGrant = nil; self.discardRecovery()
                        let verified = self.verificationRecorded
                            ? (self.verificationSucceeded ? "마지막 검증 명령의 종료 코드가 0입니다." : "마지막 검증은 실패했거나 완료를 확인하지 못했습니다.")
                            : "마지막 파일 변경 이후 검증 실행 결과가 없습니다."
                        self.record?("모델 설명\n" + proposal.summary + "\n\n확인된 실행 결과\n" + "\(self.appliedPaths.count)개 파일의 저장을 확인했습니다. " + verified, false)
                        self.message = self.phase
                    }
                } catch {
                    self.taskActive = false; self.readGrant = nil; self.progress("응답 검증 실패")
                    self.message = "모델의 다음 작업이 허용된 형식·파일 범위·검증 명령을 통과하지 못했습니다. 해당 작업은 실행하지 않았습니다."
                }
            case .failed(let text, _), .needsConfirmation(let text), .needsPermission(let text), .unverifiable(let text):
                self.taskActive = false; self.readGrant = nil; self.progress("작업 실패"); self.message = text
            case .handedOff: self.taskActive = false; self.progress("결과 확인 불가"); self.message = "변경안 수신을 확인하지 못했습니다."
            }
            if self.proposal == nil && self.pendingReads.isEmpty { self.record?(self.message, false) }
        }
    }
    func approveReads(_ id: UUID, forTask: Bool = false) {
        guard id == permissionID else { return }
        guard turnConnection?.busy == false else { return }
        guard taskActive, !busy, !pendingReads.isEmpty, Date() < deadline,
              let connection = turnConnection, connection.sessionID == expectedSession, connection.ready,
              authorize(.codeDraft, confirmed: true) else { stop(); return }
        let reads = pendingReads
        guard pendingFiles.count == reads.count else { stop(); return }
        if forTask { readGrant = CodexTaskReadGrant(task: taskID, ranges: reads, deadline: deadline) }
        files = pendingFiles; pendingFiles = []; pendingReads = []; readIssues = []
        for read in reads { record?("읽는 중 · \(read.path):\(read.startLine) (\(read.lineCount)줄)", false) }
        progress("승인된 소스를 Codex에 전달하는 중")
        continueRequest(connection)
    }
    func approveCommand(_ id: UUID) {
        guard id == permissionID else { return }
        guard turnConnection?.busy == false else { return }
        guard taskActive, !busy, Date() < deadline, !locked,
              let connection = turnConnection, connection.sessionID == expectedSession,
              let command = pendingCommand, let request = commandRequest,
              authorize(.nativeTool, confirmed: true) else { stop(); return }
        do { try command.validate(); _ = try request.encodedInput() }
        catch { stop(); message = "프로젝트나 검증 명령이 바뀌었습니다. 새 요청으로 다시 검토하세요."; return }
        let stamp = generation
        pendingCommand = nil; commandRequest = nil; permissionID = UUID()
        busy = true; activeConnection = connection; liveOutput = ""
        progress("검증 실행 중 · " + command.argv.joined(separator: " "))
        record?("검증 실행 승인 · " + command.argv.joined(separator: " "), false)
        connection.runNative(request, confirmed: true, onOutput: { [weak self] output in
            guard let self, self.generation == stamp, !self.locked else { return }
            self.liveOutput = output
        }) { [weak self] result in
            guard let self, self.generation == stamp, !self.locked else { return }
            self.busy = false; self.activeConnection = nil
            switch result {
            case .succeeded(let value):
                self.verificationRecorded = true
                self.verificationSucceeded = true
                self.resultDraft = self.resultPreview(value.reply ?? "")
            case .failed(let text, _):
                self.verificationRecorded = true
                self.verificationSucceeded = false; self.resultDraft = self.resultPreview(text)
            case .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text):
                self.taskActive = false; self.progress("검증 중단"); self.message = text; return
            case .handedOff:
                self.taskActive = false; self.progress("검증 결과 확인 불가"); return
            }
            self.awaitingResult = true; self.permissionID = UUID()
            self.progress(self.verificationSucceeded ? "검증 성공 · 결과 전송 승인 대기" : "검증 실패 · 결과 전송 승인 대기")
            self.record?(self.phase, false)
        }
    }
    func approveResult(_ id: UUID) {
        guard id == permissionID else { return }
        guard turnConnection?.busy == false else { return }
        guard awaitingResult, taskActive, !busy, !locked, Date() < deadline,
              let connection = turnConnection, connection.sessionID == expectedSession,
              resultDraft.utf8.count <= 3500, !CodexCodePolicy.containsSecret(resultDraft),
              authorize(.codeDraft, confirmed: true) else {
            message = "출력의 민감정보를 제거하고 3,500바이트 이내로 줄여주세요. 작업이 만료되었다면 새 요청이 필요합니다."
            return
        }
        toolResults = Array((toolResults + ["실제 검증 결과: " + (verificationSucceeded ? "종료 코드 0" : "실패 또는 결과 미확인") + "\n사용자 검토 출력:\n" + resultDraft]).suffix(4))
        awaitingResult = false; resultDraft = ""; permissionID = UUID()
        refresh()
        continueRequest(connection)
    }
    func rejectReads() { stop(); files = []; record?("코드 전송 요청을 거절해 작업을 취소했습니다.", false) }
    func apply(_ plan: CodexCodePlan, confirmed: Bool) {
        guard !taskActive || turnConnection?.busy == false else { return }
        guard !busy, !uncertain, let executor, plans.contains(where: { $0.id == plan.id }), authorize(.codeApply, confirmed: confirmed) else { return }
        let directory = backupDirectory
        let lockState = lockState
        runWrite(appliedPlan: plan) { cancellation in
            executor.apply(plan, backupDirectory: directory, confirmed: confirmed, locked: lockState, cancelled: { cancellation.cancelled }).map { _ in "선택한 파일의 저장을 확인했습니다. 다음 검증 단계를 확인합니다." }
        }
    }
    func restore(_ backup: CodexCodeBackup, confirmed: Bool) {
        guard !busy, let executor, backups.contains(where: { $0.id == backup.id }), authorize(.codeRestore, confirmed: confirmed) else { return }
        stop()
        let lockState = lockState
        runWrite { cancellation in
            executor.restore(backup, confirmed: confirmed, locked: lockState, cancelled: { cancellation.cancelled })
        }
    }
    private func runWrite(appliedPlan: CodexCodePlan? = nil, _ operation: @escaping @Sendable (SharedProjectCancellation) -> ToolExecutionResult<String>) {
        busy = true; cancellation = SharedProjectCancellation(); let stamp = generation
        let cancellation = cancellation
        task = Task {
            let result = await Task.detached { operation(cancellation) }.value
            guard generation == stamp else { return }
            busy = false
            if case .succeeded = result, let appliedPlan {
                plans.removeAll { $0.id == appliedPlan.id }; files.removeAll { $0.path == appliedPlan.path }
                if plans.isEmpty { proposal = nil }
                if let executor, case .succeeded(let snapshot) = executor.snapshot(appliedPlan.path, lineCount: 600, locked: { self.locked }, truncateToFit: true) {
                    files = Array((files.filter { $0.path != appliedPlan.path } + [snapshot]).suffix(8))
                    while files.reduce(0, { $0 + $1.text.utf8.count }) > 98304 { files.removeFirst() }
                }
                toolResults = Array((toolResults.filter { !$0.hasPrefix("실제 검증 결과:") }
                    + ["파일 저장을 실제 확인했습니다: " + appliedPlan.path]).suffix(4))
                appliedPaths.insert(appliedPlan.path)
                verificationRecorded = false
                progress("파일 저장 확인 · " + appliedPlan.path)
            } else { plans = []; proposal = nil; files = [] }
            switch result {
            case .succeeded(let text): message = text
            case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text): message = text
            case .unverifiable(let text): uncertain = true; message = text
            case .handedOff: uncertain = true; message = "최종 쓰기 결과를 확인하지 못했습니다."
            }
            if let executor, case .succeeded(let value) = executor.backups(directory: backupDirectory, locked: { self.locked }) { backups = value }
            record?(message, false)
            if taskActive, appliedPlan != nil, case .succeeded = result, plans.isEmpty,
               let connection = turnConnection {
                refresh()
                continueRequest(connection)
            } else if result.status != .succeeded {
                taskActive = false; readGrant = nil; progress("파일 작업 실패")
            }
        }
    }
    func stop() {
        guard authorize(.cancel) else { return }
        discardRecovery()
        generation = UUID(); cancellation.cancel(); task?.cancel(); task = nil
        taskID = UUID(); taskActive = false; readGrant = nil; pendingCommand = nil; commandRequest = nil
        awaitingResult = false; resultDraft = ""; liveOutput = ""; toolResults = []; deadline = .distantPast
        progress("중지됨")
        activeConnection?.stop(); activeConnection = nil; busy = false; plans = []; proposal = nil
        pendingReads = []; pendingFiles = []; readIssues = []; files = []; permissionID = UUID(); turnConnection = nil
        message = "작업을 중지했습니다. 진행 중이던 파일 쓰기는 원본·백업을 다시 확인해주세요. 자동 재시도하지 않습니다."
    }
    func disconnect(preservingRecovery: Bool = false) {
        let saved = preservingRecovery ? recovery : nil
        resetConversation()
        stop(); scopedRoot?.stopAccessingSecurityScopedResource(); scopedRoot = nil; root = nil; executor = nil; files = []; paths = []; backups = []; plans = []
        restoreRecovery(saved)
    }
    private func restoreRecovery(_ saved: Recovery?) {
        if let saved, let data = try? JSONEncoder().encode(saved) { recovery = saved; recoveryDefaults?.set(data, forKey: recoveryKey) }
    }
    func resetConversation(preservingRecovery: Bool = false) {
        let saved = preservingRecovery ? recovery : nil
        stop(); files = []; attachments = []; history = AssistantContextManager(maximumRecentTurns: 3, maximumLongTermMemories: 1); turnContext = []
        restoreRecovery(saved)
    }
}

struct CodexCodeWorkspace: View {
    @StateObject private var store: CodexCodeWorkspaceStore
    @ObservedObject var connection: CodexLocalStore
    let model: String
    let effort: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var picking = false
    @State private var candidate: URL?
    @State private var confirmConnect = false
    @State private var search = ""
    @State private var selectedPath: String?
    @State private var startLine = 1
    @State private var lineCount = 200
    @State private var instruction = ""
    @State private var applying: CodexCodePlan?
    @State private var restoring: CodexCodeBackup?
    init(projectID: UUID, connection: CodexLocalStore, model: String, effort: String) {
        _store = StateObject(wrappedValue: CodexCodeWorkspaceStore(projectID: projectID))
        self.connection = connection; self.model = model; self.effort = effort
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Codex · 프로젝트 코드 수정").font(.title2.bold()); Spacer()
                if store.busy { ProgressView().controlSize(.small); Button("중지") { store.stop() } }
                Button("닫기") { dismiss() }
            }
            HStack {
                Button("프로젝트 폴더 선택") { picking = true }.disabled(store.busy || locked)
                Text(store.root?.path ?? "JARVIS 프로젝트 폴더를 선택하세요").font(.caption).textSelection(.enabled).privacySensitive()
            }
            Text("선택한 코드 범위와 상대 파일 목록만 전송합니다. 안전 정책·인증·실행기·빌드 설정은 보호합니다. 원본 반영은 파일별 승인이 필요하며 빌드·셸은 자동 실행하지 않습니다.").font(.caption).foregroundStyle(.secondary)
            Text("모델: \(model) · 추론: \(effort)").font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("파일 이름 검색", text: $search)
                    List(selection: $selectedPath) {
                        ForEach(store.paths.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { path in
                            Text(path).font(.caption.monospaced()).tag(path)
                        }
                    }
                    HStack { Text("시작 줄"); TextField("1", value: $startLine, format: .number).frame(width: 65) }
                    Stepper("코드 \(lineCount)줄", value: $lineCount, in: 20...600, step: 20)
                    Button("선택 범위 첨부") { if let selectedPath { store.attach(selectedPath, line: startLine, count: lineCount) } }
                        .disabled(selectedPath == nil || store.busy || locked)
                }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.attachments, id: \.path) { file in
                            DisclosureGroup("\(file.path) · \(file.startLine)줄부터 · \(file.text.utf8.count)B") {
                                Text(file.text).font(.caption.monospaced()).textSelection(.enabled)
                                Button("첨부 해제") { store.remove(file.path) }.disabled(store.busy)
                            }
                        }
                        Text("수정 요청").font(.headline)
                        CodexComposerEditor(text: $instruction, submit: {
                            store.request(instruction, model: model, effort: effort, connection: connection)
                        }, placeholder: "예: 선택한 캘린더 화면의 날짜 글자 크기를 키워줘")
                        .frame(height: 84).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                        .disabled(store.busy || locked)
                        Text("Enter 전송 · Shift+Enter 줄바꿈").font(.caption).foregroundStyle(.secondary)
                        Button("선택 코드 전송·변경안 요청") { store.request(instruction, model: model, effort: effort, connection: connection) }
                            .disabled(store.attachments.isEmpty || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || connection.busy || !connection.ready || connection.backend != .appServer || locked)
                        if connection.backend != .appServer || !connection.ready { Text("연결 설정에서 App Server와 로그인 상태를 먼저 확인하세요.").font(.caption).foregroundStyle(.orange) }
                        Text(store.message).font(.callout).textSelection(.enabled)
                        if !store.summary.isEmpty { Text(store.summary).font(.headline) }
                        ForEach(store.plans) { plan in
                            GroupBox(plan.path) {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array((store.proposal?.edits.filter { $0.path == plan.path } ?? []).enumerated()), id: \.offset) { _, edit in
                                        Text(edit.old == nil ? "새 파일" : "변경 전").font(.caption.bold())
                                        if let old = edit.old { Text(old).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.red) }
                                        Text("변경 후").font(.caption.bold())
                                        Text(edit.new).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.green)
                                    }
                                    Button("이 파일 적용") { applying = plan }.disabled(store.busy || locked)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !store.backups.isEmpty {
                            Text("이 프로젝트의 백업").font(.headline)
                            ForEach(store.backups.prefix(20)) { backup in
                                DisclosureGroup("\(backup.path) · \(backup.created.formatted(date: .abbreviated, time: .shortened))") {
                                    Text("현재 파일이 적용 직후 내용과 같을 때만 복구합니다. 변경됐으면 덮어쓰지 않습니다.").font(.caption)
                                    Text(backup.before ?? "원래 없던 파일입니다. 복구하면 생성한 파일을 제거합니다.").font(.caption.monospaced()).textSelection(.enabled)
                                    Button("이 백업으로 복구") { restoring = backup }.disabled(store.busy || locked)
                                }
                            }
                        }
                    }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 500)
            }
        }.padding(20).frame(minWidth: 940, idealWidth: 1060, minHeight: 680, idealHeight: 760)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { candidate = url; confirmConnect = true }
        }
        .alert("코드 프로젝트를 연결할까요?", isPresented: $confirmConnect) {
            Button("취소", role: .cancel) { candidate = nil }
            Button("선택 폴더 연결") { if let candidate { store.connect(candidate, confirmed: true) }; candidate = nil }
        } message: { Text("선택 폴더의 소스를 조회하고, 직접 첨부·전송한 코드만 Codex에 제공합니다. 검토 후 승인한 파일만 변경합니다.\n\(candidate?.path ?? "")") }
        .alert("이 파일의 변경을 적용할까요?", isPresented: Binding(get: { applying != nil }, set: { if !$0 { applying = nil } })) {
            Button("취소", role: .cancel) { applying = nil }
            Button("검토한 파일 적용") { if let applying { store.apply(applying, confirmed: true) }; applying = nil }
        } message: { Text("\(applying?.path ?? "")\n앱 내부에 원본 백업을 보존하고 현재 파일을 다시 확인합니다. 빌드·실행은 수행하지 않습니다.") }
        .alert("선택한 백업으로 복구할까요?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("취소", role: .cancel) { restoring = nil }
            Button("검토한 백업 복구") { if let restoring { store.restore(restoring, confirmed: true) }; restoring = nil }
        } message: { Text(restoring?.path ?? "") }
        .onChange(of: locked) { _, value in if value { applying = nil; restoring = nil; candidate = nil; store.disconnect() } }
        .onDisappear { store.disconnect() }
    }
}

struct CodexProjectFilePicker: View {
    @ObservedObject var store: CodexCodeWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: String?
    @State private var startLine = 1
    @State private var lineCount = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("프로젝트 파일").font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
            }
            TextField("경로 검색", text: $search)
            List(selection: $selected) {
                ForEach(store.paths.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { path in
                    Text(path).font(.caption.monospaced()).tag(path)
                }
            }.frame(minHeight: 150, maxHeight: 210)
            HStack {
                Text("시작 줄")
                TextField("1", value: $startLine, format: .number).frame(width: 64)
                Stepper("\(lineCount)줄", value: $lineCount, in: 20...600, step: 20)
                Spacer()
                Button("범위 미리보기·첨부") {
                    if let selected { store.attach(selected, line: startLine, count: lineCount) }
                }.disabled(selected == nil || startLine < 1 || store.busy)
            }
            ScrollView {
                ForEach(store.attachments, id: \.path) { file in
                    DisclosureGroup("\(file.path) · \(file.startLine)줄부터") {
                        Text(file.text).font(.caption.monospaced()).textSelection(.enabled)
                        Button("첨부 해제") { store.remove(file.path) }
                    }
                }
            }.frame(maxHeight: 160)
            Text(store.message).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 550)
    }
}

@MainActor
protocol CodexAgentTransport: AnyObject {
    var ready: Bool { get }
    var busy: Bool { get }
    var backend: CodexLocalBackend { get }
    var sessionID: UUID? { get }
    func reserveAgent(_ lease: UUID) -> Bool
    func releaseAgent(_ lease: UUID)
    func stopAgent(_ lease: UUID)
    func agentCall(_ action: CodexLocalAction, input: String, lease: UUID, confirmed: Bool) async -> ToolExecutionResult<CodexLocalReply>
    func agentVerify(_ payload: CodexNativeToolRequest, lease: UUID, output: @escaping @MainActor (String) -> Void) async -> ToolExecutionResult<CodexLocalReply>
    func agentSearch(_ query: String, lease: UUID) async -> ToolExecutionResult<String>
}
extension CodexAgentTransport {
    func agentSearch(_ query: String, lease: UUID) async -> ToolExecutionResult<String> { .needsPermission(message: "검색 연결이 필요합니다.") }
}
extension CodexLocalStore: CodexAgentTransport {}

@MainActor
final class CodexAgentWorkspaceStore: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var phase = "프로젝트 작업 대기"
    @Published private(set) var snapshot: CodexAgentSnapshot?
    @Published private(set) var pending: CodexAgentCall?
    @Published private(set) var preview = ""
    @Published private(set) var output = ""
    @Published private(set) var capability = "미확인"
    @Published private(set) var verifiedFacts: [String] = []
    @Published private(set) var canApprove = false
    @Published private(set) var sending = false
    @Published private(set) var awaitingOutput = false
    @Published private(set) var steering = false
    @Published var outputDraft = ""
    var record: ((String, Bool) -> Void)?
    var completed: ((String, String) -> Void)?
    private var profile = CodexAgentProfile()
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?
    private var lease: UUID?
    private var session: UUID?
    private var executor: CodexCodeFiles?
    private weak var transport: (any CodexAgentTransport)?
    private var files: [CodexCodeFile] = []
    private var preparedFile: CodexCodeFile?
    private var preparedPlan: CodexCodePlan?
    private var readGrant: CodexTaskReadGrant?
    private var bytesShared = 0
    private var resolvedApprovals: Set<UUID> = []
    private var verificationSucceeded = false
    private let agentBackupDirectory: URL?
    private var sessionBackupDirectory: URL?
    private var callDeadline = Date.distantPast
    private var deadline = ContinuousClock.now
    private let lockState: @Sendable () -> Bool
    init(backupDirectory: URL? = nil, lockState: @escaping @Sendable () -> Bool = { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }) {
        self.lockState = lockState; self.agentBackupDirectory = backupDirectory
    }
    private func allowed(_ intent: AssistantIntent, confirmed: Bool = false) -> Bool {
        if case .allow = SafetyPolicyEngine().evaluate(intent, context: .init(origin: .modelProposed, externalActionsLocked: lockState(), wasExplicitlyConfirmed: confirmed)) { return true }
        return false
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func text(_ result: ToolExecutionResult<CodexLocalReply>) throws -> String {
        if case .succeeded(let value) = result, let reply = value.reply { return reply }
        throw CodexLocalError.unavailable
    }
    @discardableResult
    func start(_ message: String, model: String, effort: String, executor: CodexCodeFiles, context: [CloudConversationTurn] = [], backupDirectory: URL? = nil, conversationID: UUID? = nil, resumeTurn: String? = nil, forkSource: UUID? = nil, forkTurn: String? = nil,
               profile: CodexAgentProfile = .init(), connection: any CodexAgentTransport) -> Bool {
        guard !running, connection.ready, !connection.busy, connection.backend == .appServer,
              allowed(.codexLocal(.agentStart), confirmed: true), CodexLocalModel.validID(model),
              CodexLocalModel.effortValues.contains(effort), !message.isEmpty, message.utf8.count <= 6000,
              !CodexCodePolicy.containsSecret(message), context.count <= 3,
              context.allSatisfy({ $0.user.utf8.count <= 6000 && $0.assistant.utf8.count <= 8192 && !CodexCodePolicy.containsSecret($0.user + $0.assistant) }) else { return false }
        guard let profileBytes = try? profile.encoded() else { phase = "확장 설정을 확인해주세요."; return false }
        self.profile = profile
        let identifier = UUID()
        guard connection.reserveAgent(identifier) else { return false }
        self.lease = identifier; session = connection.sessionID; transport = connection; self.executor = executor
        sessionBackupDirectory = backupDirectory ?? agentBackupDirectory
        generation = UUID(); let stamp = generation
        running = true; phase = "Codex 지원 기능 확인 중"; pending = nil; snapshot = nil; preview = ""; output = ""; files = []
        bytesShared = 0; verifiedFacts = []; resolvedApprovals = []; readGrant = nil; deadline = .now.advanced(by: .seconds(600))
        record?(message, true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let caps = try self.text(await connection.agentCall(.agentPoll, input: "{\"capabilities\":true}", lease: identifier, confirmed: false))
                guard let capabilities = try JSONSerialization.jsonObject(with: Data(caps.utf8)) as? [String: Any],
                      capabilities["supported"] as? Bool == true,
                      capabilities["agentVersion"] as? Int == 2,
                      Set(capabilities["tools"] as? [String] ?? []) == CapabilityRegistry.codexAgentTools else {
                    throw CodexLocalError.unavailable
                }
                guard self.valid(stamp) else { return }
                self.capability = (capabilities["runtime"] as? String ?? "Codex") + " · 호스트 도구 10종 · 실험적 API"
                self.phase = "프로젝트 작업 세션 시작 중"
                var request: [String: Any] = ["jobID": identifier.uuidString, "root": executor.root.path, "rootIdentity": executor.identity,
                    "model": model, "effort": effort, "message": message,
                    "turns": context.map { ["user": $0.user, "assistant": $0.assistant] }, "conversationID": (conversationID ?? identifier).uuidString,
                    "binding": SharedProjectFiles.revision(profileBytes)]
                if let resumeTurn { request["resumeTurn"] = resumeTurn }
                if let forkSource, let forkTurn { request["forkSource"] = forkSource.uuidString; request["forkTurn"] = forkTurn }
                let input = try self.json(request)
                _ = try self.text(await connection.agentCall(.agentStart, input: input, lease: identifier, confirmed: true))
                while self.valid(stamp) {
                    let reply = try self.text(await connection.agentCall(.agentPoll, input: try self.json(["jobID": identifier.uuidString]), lease: identifier, confirmed: false))
                    guard self.valid(stamp) else { return }
                    let snapshot = try CodexAgentSnapshot.read(reply)
                    guard snapshot.jobID == identifier else { throw CodexLocalError.invalid }
                    self.snapshot = snapshot
                    if ["completed", "failed", "cancelled"].contains(snapshot.state) {
                        self.pending = nil; self.canApprove = false
                        self.phase = snapshot.state == "completed" ? "Codex 작업 응답 완료" : snapshot.state == "cancelled" ? "취소됨" : "작업 실패·미완료"
                        if !snapshot.reply.isEmpty {
                            if snapshot.state == "completed", let turn = snapshot.turnID, let completed = self.completed { completed(String(snapshot.reply.prefix(1800)), turn) }
                            else { self.record?(String(snapshot.reply.prefix(1800)), false) }
                        }
                        if snapshot.state != "completed" { self.record?(self.phase + ". 자동 재실행하지 않습니다.", false) }
                        self.finish(identifier); return
                    }
                    if let call = snapshot.pending, !self.resolvedApprovals.contains(call.approvalID), call.approvalID != self.pending?.approvalID, !self.sending, !self.awaitingOutput {
                        self.prepare(call)
                        if call.tool == "jarvis_project_read", let fields = try? call.validatedArguments(),
                           let path = fields["path"] as? String, let start = fields["startLine"] as? Int, let count = fields["lineCount"] as? Int,
                           self.canApprove, self.readGrant?.consume([CodexCodeRead(path: path, startLine: start, lineCount: count)], task: identifier, locked: self.lockState()) == true {
                            self.approve(call.approvalID)
                        }
                    }
                    if self.pending == nil { self.phase = "Codex가 프로젝트 작업 중" }
                    try await Task.sleep(for: .milliseconds(300))
                }
                if self.generation == stamp { self.stop() }
            } catch {
                guard self.generation == stamp else { return }
                self.phase = "작업 연결·지원 기능을 확인하지 못했습니다. 자동 재시도하지 않습니다."
                self.record?(self.phase, false); self.stop(keepPhase: true)
            }
        }
        return true
    }
    private func valid(_ stamp: UUID) -> Bool {
        !Task.isCancelled && generation == stamp && running && !lockState() && transport?.sessionID == session && ContinuousClock.now < deadline
    }
    private func prepare(_ call: CodexAgentCall) {
        pending = call; preparedFile = nil; preparedPlan = nil; canApprove = false
        callDeadline = Date(timeIntervalSince1970: call.expiresAt - 10)
        phase = ["jarvis_project_list": "프로젝트 목록 공유 승인 대기", "jarvis_project_read": "소스 읽기·공유 승인 대기", "jarvis_project_edit": "파일 변경 승인 대기", "jarvis_project_verify": "검증 실행 승인 대기"][call.tool] ?? "도구 실행·공유 승인 대기"
        do {
            guard let executor, Date() < callDeadline, allowed(.codexLocal(.codeRead)), let fields = try? call.validatedArguments() else { throw CodexLocalError.invalid }
            switch call.tool {
            case "jarvis_project_list":
                guard case .succeeded(let paths) = executor.inventory(locked: lockState) else { throw CodexLocalError.invalid }
                preview = paths.joined(separator: "\n")
            case "jarvis_project_read":
                guard case .succeeded(let file) = executor.snapshot(fields["path"] as! String, startLine: fields["startLine"] as! Int,
                    lineCount: fields["lineCount"] as! Int, locked: lockState, maximumBytes: 24000, truncateToFit: true),
                      bytesShared + file.text.utf8.count <= 98304, files.contains(where: { $0.path == file.path }) || files.count < 8 else { throw CodexLocalError.invalid }
                preparedFile = file; preview = file.path + ":" + String(file.startLine) + "\n" + file.text
            case "jarvis_project_edit":
                if let old = fields["old"] as? String {
                    guard files.contains(where: { $0.path == fields["path"] as? String && $0.text.contains(old) }) else { throw CodexLocalError.invalid }
                }
                let proposal = try CodexCodeProposal.read(try json(["summary": "Codex 호스트 도구 변경", "edits": [fields]]))
                guard let plan = try executor.prepare(proposal, files: files, locked: lockState).first else { throw CodexLocalError.invalid }
                preparedPlan = plan
                preview = plan.path + "\n\n변경 전:\n" + (fields["old"] as? String ?? "새 파일") + "\n\n변경 후:\n" + (fields["new"] as! String)
            case "jarvis_extension_list":
                preview = try json(["extensions": profile.extensions.map { ["id": $0.id.uuidString, "name": $0.name, "allowedTools": $0.allowedTools] as [String: Any] }])
            case "jarvis_skill_list":
                preview = try json(["skills": profile.skills.map { ["id": $0.id.uuidString, "name": $0.document.name, "truncated": $0.document.truncated] as [String: Any] }])
            case "jarvis_skill_read":
                guard let item = profile.skills.first(where: { $0.id.uuidString.lowercased() == (fields["skillID"] as! String).lowercased() }) else { throw CodexLocalError.invalid }
                preview = "검토한 스킬 참고 자료 · " + item.document.name + "\n" + item.document.text
            case "jarvis_extension_call", "jarvis_extension_inspect":
                guard let item = profile.extensions.first(where: { $0.id.uuidString.lowercased() == (fields["extensionID"] as! String).lowercased() }),
                      (call.tool == "jarvis_extension_inspect" || item.allowedTools.contains(fields["tool"] as! String)) else { throw CodexLocalError.invalid }
                let request = CodexNativeToolRequest(operation: call.tool == "jarvis_extension_inspect" ? .mcpList : .mcpCall, root: executor.root.path, server: item.server, tool: fields["tool"] as? String, arguments: fields["arguments"] as? String)
                guard request.rootIdentity == executor.identity else { throw CodexLocalError.invalid }
                preview = try request.encodedInput()
            case "jarvis_web_search":
                guard profile.webSearchEnabled else { throw CodexLocalError.invalid }
                preview = "Tavily 인터넷 검색 · 외부 서비스에 검색어 전송\n" + (fields["query"] as! String)
            case "jarvis_project_verify":
                preview = (fields["argv"] as! [String]).joined(separator: " ") + "\n" + (fields["purpose"] as! String)
            default: throw CodexLocalError.invalid
            }
            canApprove = true
        } catch { preview = "이 도구 요청은 경로·원본·비밀정보·지원 범위 또는 유효 시간 검사에 통과하지 못했습니다. 거절할 수 있습니다." }
    }
    func approve(_ approvalID: UUID, forTask: Bool = false) {
        guard !sending, !awaitingOutput, canApprove, let call = pending, call.approvalID == approvalID,
              let identifier = lease, let connection = transport, let executor,
              Date() < callDeadline, allowed(call.intent, confirmed: true) else { return }
        let stamp = generation
        let file = preparedFile, plan = preparedPlan
        canApprove = false; sending = true
        responseTask = Task {
            do {
                let current = try CodexAgentSnapshot.read(try text(await connection.agentCall(.agentPoll,
                    input: try json(["jobID": identifier.uuidString]), lease: identifier, confirmed: false)))
                guard valid(stamp), Date() < callDeadline, current.pending?.approvalID == approvalID else { throw CodexLocalError.invalid }
                let fields = try call.validatedArguments()
                var shared = ""
                switch call.tool {
                case "jarvis_project_list", "jarvis_extension_list", "jarvis_skill_list", "jarvis_skill_read": shared = preview
                case "jarvis_project_read":
                    guard let file, case .succeeded(let now) = executor.snapshot(file.path, startLine: file.startLine,
                        lineCount: fields["lineCount"] as! Int, locked: lockState, maximumBytes: 24000, truncateToFit: true),
                          file.revision == now.revision, now.text == file.text else { throw CodexLocalError.invalid }
                    shared = preview; files = files.filter { $0.path != file.path } + [file]; bytesShared += file.text.utf8.count
                    if forTask {
                        readGrant = CodexTaskReadGrant(task: identifier,
                            ranges: [CodexCodeRead(path: file.path, startLine: fields["startLine"] as! Int, lineCount: fields["lineCount"] as! Int)], deadline: min(callDeadline, Date().addingTimeInterval(600)))
                    }
                case "jarvis_project_edit":
                    guard let plan else { throw CodexLocalError.invalid }
                    let backup = sessionBackupDirectory ?? JarvisStorage.support
                        .appendingPathComponent("JARVISCodexCodeBackups/Agent-" + executor.session.uuidString)
                    let cancellation = { !self.valid(stamp) || Date() >= self.callDeadline }
                    guard case .succeeded = executor.apply(plan, backupDirectory: backup, confirmed: true, locked: lockState, cancelled: cancellation) else { throw CodexLocalError.invalid }
                    verifiedFacts.append("파일 저장·백업 확인 · " + plan.path)
                    shared = "Verified saved file: " + plan.path + ". A local backup was created. No test has run yet."
                    files.removeAll { $0.path == plan.path }
                case "jarvis_web_search":
                    let result = await connection.agentSearch(fields["query"] as! String, lease: identifier)
                    guard valid(stamp) else { return }
                    verificationSucceeded = false
                    switch result {
                    case .succeeded(let value): output = value; verificationSucceeded = true
                    case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message): output = message
                    case .handedOff: output = "검색 완료를 확인하지 못했습니다."
                    }
                    outputDraft = String(decoding: Data(output.utf8).prefix(16000), as: UTF8.self)
                    awaitingOutput = true; sending = false; phase = "검색 결과·출처 공유 검토 대기"; return
                case "jarvis_extension_call", "jarvis_extension_inspect":
                    guard let item = profile.extensions.first(where: { $0.id.uuidString.lowercased() == (fields["extensionID"] as! String).lowercased() }), (call.tool == "jarvis_extension_inspect" || item.allowedTools.contains(fields["tool"] as! String)) else { throw CodexLocalError.invalid }
                    let request = CodexNativeToolRequest(operation: call.tool == "jarvis_extension_inspect" ? .mcpList : .mcpCall, root: executor.root.path, server: item.server, tool: fields["tool"] as? String, arguments: fields["arguments"] as? String)
                    guard request.rootIdentity == executor.identity else { throw CodexLocalError.invalid }
                    let result = await connection.agentVerify(request, lease: identifier) { [weak self] text in self?.output = text }
                    guard valid(stamp) else { return }
                    verificationSucceeded = false
                    switch result {
                    case .succeeded(let value):
                        output = value.reply ?? "결과 없음"; verificationSucceeded = true
                        if call.tool == "jarvis_extension_inspect" {
                            guard let value = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                                  let tools = value["tools"] as? [String: Any] else { throw CodexLocalError.invalid }
                            output = try json(["tools": tools.filter { item.allowedTools.contains($0.key) }, "allowedTools": item.allowedTools])
                        }
                    case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message): output = message + "\n추가 인증·입력이 필요하면 작업을 취소하고 도구 연결 설정에서 확인해주세요. 자동 재시도하지 않습니다."
                    case .handedOff: output = "MCP 결과를 확인하지 못했습니다."
                    }
                    outputDraft = String(decoding: Data(output.utf8).prefix(16000), as: UTF8.self)
                    awaitingOutput = true; sending = false; phase = "MCP 결과 공유 검토 대기"; return
                case "jarvis_project_verify":
                    let request = CodexNativeToolRequest(operation: .verify, root: executor.root.path, command: fields["argv"] as? [String])
                    guard request.rootIdentity == executor.identity else { throw CodexLocalError.invalid }
                    _ = try request.encodedInput()
                    phase = "검증 명령 실행 중"
                    let result = await connection.agentVerify(request, lease: identifier) { [weak self] text in self?.output = text }
                    guard valid(stamp) else { return }
                    verificationSucceeded = false
                    switch result {
                    case .succeeded(let value):
                        output = value.reply ?? "검증 결과 없음"
                        if let fields = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] { verificationSucceeded = fields["exitCode"] as? Int == 0 }
                    case .failed(let reason, _), .needsPermission(let reason), .needsConfirmation(let reason), .unverifiable(let reason): output = "검증 완료를 확인하지 못했습니다: " + reason + "\n" + output
                    case .handedOff: output = "검증 완료를 확인하지 못했습니다."
                    }
                    verifiedFacts.append(verificationSucceeded ? "검증 명령 종료 코드 0 확인" : "검증 실패 또는 완료 미확인")
                    outputDraft = String(decoding: Data(output.utf8).prefix(16000), as: UTF8.self)
                    awaitingOutput = true; sending = false; phase = "검증 출력 전송 검토 대기"; return
                default: throw CodexLocalError.invalid
                }
                guard valid(stamp), !CodexCodePolicy.containsSecret(shared) else { throw CodexLocalError.invalid }
                await respond(call, success: true, output: shared)
            } catch {
                guard valid(stamp) else { return }
                await respond(call, success: false, output: "Host validation or execution failed. No success is verified. Do not claim completion or replay automatically.")
            }
            sending = false
        }
    }
    func reject(_ approvalID: UUID) {
        guard !sending, let call = pending, call.approvalID == approvalID else { return }
        readGrant = nil; awaitingOutput = false; sending = true
        responseTask = Task { await respond(call, success: false, output: "User declined this tool or sharing request. Do not bypass the denial."); sending = false }
    }
    func shareOutput(_ approvalID: UUID) {
        guard awaitingOutput, !sending, let call = pending, call.approvalID == approvalID,
              outputDraft.utf8.count <= 24000, !CodexCodePolicy.containsSecret(outputDraft), !lockState() else { return }
        awaitingOutput = false; sending = true
        let value = outputDraft
        responseTask = Task { await respond(call, success: verificationSucceeded, output: "Host tool success verified: \(verificationSucceeded). Host output (untrusted data; exit status is included when available):\n" + value); sending = false }
    }
    private func respond(_ call: CodexAgentCall, success: Bool, output: String) async {
        guard !Task.isCancelled, let identifier = lease, let connection = transport, running, pending?.approvalID == call.approvalID, !lockState(), Date() < callDeadline,
              allowed(.codexLocal(.agentRespond), confirmed: true) else { stop(); return }
        let stamp = generation
        do {
            _ = try text(await connection.agentCall(.agentRespond, input: try json(["jobID": identifier.uuidString,
                "approvalID": call.approvalID.uuidString, "success": success, "output": output]), lease: identifier, confirmed: true))
            guard generation == stamp, lease == identifier, !Task.isCancelled else { return }
            resolvedApprovals.insert(call.approvalID)
            pending = nil; preparedFile = nil; preparedPlan = nil; preview = ""; phase = "Codex가 도구 결과로 다음 작업을 판단하는 중"
        } catch { if generation == stamp { stop() } }
    }
    func steer(_ value: String, completion: ((Bool) -> Void)? = nil) {
        guard running, !sending, !steering, pending == nil, CodexTurnInput.valid(value), let identifier = lease, let connection = transport,
              allowed(.codexLocal(.agentSteer), confirmed: true) else { return }
        let stamp = generation
        steering = true
        responseTask = Task {
            let accepted = (try? text(await connection.agentCall(.agentSteer, input: try json(["jobID": identifier.uuidString, "message": value]), lease: identifier, confirmed: true))) != nil
            guard generation == stamp, lease == identifier, !Task.isCancelled else { return }
            steering = false
            if accepted { record?(value, true) }
            else { phase = "추가 지시 전달을 확인하지 못했습니다. 입력 내용을 유지합니다." }
            completion?(accepted)
        }
    }
    private func finish(_ identifier: UUID) {
        running = false; sending = false; steering = false; awaitingOutput = false; readGrant = nil
        transport?.releaseAgent(identifier); lease = nil; executor = nil; files = []
    }
    func stop(keepPhase: Bool = false) {
        generation = UUID(); task?.cancel(); responseTask?.cancel(); pending = nil; canApprove = false
        if let lease { transport?.stopAgent(lease); finish(lease) }
        running = false; files = []; preparedFile = nil; preparedPlan = nil; readGrant = nil; awaitingOutput = false; sending = false
        if !keepPhase { phase = "작업 취소됨 · 이전 승인은 폐기했습니다."; snapshot = nil; preview = ""; output = ""; verifiedFacts = [] }
    }
}

struct CodexAgentPanel: View {
    @ObservedObject var store: CodexAgentWorkspaceStore
    var manageConnections: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if store.running { ProgressView().controlSize(.small) }
                Text(store.phase).font(.headline)
                Spacer()
                if store.running { Button("작업 취소") { store.stop() } }
            }
            Text(store.capability).font(.caption).foregroundStyle(.secondary)
            if !store.verifiedFacts.isEmpty {
                DisclosureGroup("기기에서 확인한 실행 결과") {
                    ForEach(Array(store.verifiedFacts.enumerated()), id: \.offset) { _, fact in Text(fact).font(.caption).textSelection(.enabled) }
                }
            }
            if let snapshot = store.snapshot {
                if let mode = snapshot.sessionMode {
                    Text(["new":"새 작업 세션", "resumed":"저장된 작업 세션 재개", "forked":"확인된 작업에서 분기", "reconstructed":"제한된 문맥으로 새 세션 구성"][mode] ?? "작업 세션 확인").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("작업 과정 · " + String(snapshot.events.count)) {
                    ForEach(snapshot.events, id: \.sequence) { event in Text(event.text).font(.caption).textSelection(.enabled) }
                }
                if store.running, !snapshot.reply.isEmpty { CodexMessageText(text: snapshot.reply) }
            }
            if let call = store.pending {
                GroupBox(store.awaitingOutput ? "도구 결과 전송 검토" : "Codex 도구 승인 · " + call.tool) {
                    VStack(alignment: .leading, spacing: 10) {
                        if call.tool == "jarvis_project_verify" {
                            Text("프로젝트 코드를 실행하는 검증입니다. Mac에서 읽을 수 있는 정보가 출력에 포함될 수 있으므로 실행 내용과 결과 전송을 각각 확인하세요.").font(.caption)
                        }
                        if store.awaitingOutput, call.tool.hasPrefix("jarvis_extension"), let manageConnections {
                            Button("작업 취소 후 도구 인증·연결 설정 열기") { store.stop(); manageConnections() }
                        }
                        if store.awaitingOutput {
                            TextEditor(text: $store.outputDraft).font(.body.monospaced()).frame(height: 180)
                            Text("개인정보를 지우고 전송하세요. 원본 출력은 아래에서 확인할 수 있습니다.").font(.caption)
                        } else {
                            ScrollView { CodexMessageText(text: store.preview) }.frame(maxHeight: 240)
                        }
                        HStack {
                            Button("허용 안 함") { store.reject(call.approvalID) }.disabled(store.sending)
                            Spacer()
                            if store.awaitingOutput {
                                Button("이 출력 전송") { store.shareOutput(call.approvalID) }.disabled(store.sending)
                            } else {
                                if call.tool == "jarvis_project_read" {
                                    Button("같은 읽기 범위 · 이 작업 동안 허용") { store.approve(call.approvalID, forTask: true) }.disabled(!store.canApprove || store.sending)
                                }
                                Button("이번만 허용") { store.approve(call.approvalID) }.disabled(!store.canApprove || store.sending)
                            }
                        }
                        Text("작업·프로젝트·요청에 묶인 승인입니다. 변경과 명령은 매번 확인하며 취소·잠금 시 폐기합니다.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !store.output.isEmpty {
                DisclosureGroup("실행 출력") { ScrollView { CodexMessageText(text: store.output) }.frame(maxHeight: 220) }
            }
        }
    }
}

struct CodexAgentExtensionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jarvis.codex.agentProfile") private var stored = Data()
    @AppStorage("jarvis.codex.mcpConnections") private var connections = Data()
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var profile = CodexAgentProfile()
    @State private var candidates: [String: CodexNativeToolRequest.Server] = [:]
    @State private var selected = ""
    @State private var tools = ""
    @State private var key = ""
    @State private var message = ""
    @State private var loaded = false
    @State private var confirmSave = false
    @State private var confirmKey = false
    @State private var confirmReset = false
    private func approved() -> Bool {
        if case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.agentConfigureExtensions), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: true)) { return true }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex 작업 확장·스킬·검색").font(.title2.bold())
            Text("선택한 전용 저장소에 설정을 보관합니다. 모델은 등록한 도구만 제안하며 실제 실행과 결과 공유는 채팅에서 각각 확인합니다.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("MCP · 플러그인 도구 연결") {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("기존 도구 창에서 저장한 연결 또는 신뢰하는 플러그인의 .mcp.json을 선택하세요. 허용할 도구 이름은 실제 목록에서 확인한 이름을 쉼표로 구분해 입력합니다.").font(.caption)
                            HStack {
                                Picker("연결", selection: $selected) {
                                    Text("연결 선택").tag("")
                                    ForEach(candidates.keys.sorted(), id: \.self) { Text($0).tag($0) }
                                }
                                Button(".mcp.json 가져오기…") { chooseMCP() }
                            }
                            TextField("허용할 MCP 도구 이름 · 예: search, fetch", text: $tools)
                            Button("검토 목록에 추가") {
                                guard let server = candidates[selected] else { return }
                                let names = tools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                                var next = profile
                                next.extensions.append(.init(name: selected, server: server, allowedTools: names))
                                do { _ = try next.encoded(); profile = next; tools = ""; message = "저장 전에 연결 프로그램·URL·허용 도구를 확인하세요." }
                                catch { message = "최대 8개 연결·각 20개 도구이며 자격 증명을 인자에 넣을 수 없습니다." }
                            }.disabled(selected.isEmpty || tools.isEmpty)
                            ForEach(profile.extensions) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text(item.name).bold(); Spacer(); Button("제외") { profile.extensions.removeAll { $0.id == item.id } } }
                                    Text(item.server.url ?? (item.server.command + " " + item.server.args.joined(separator: " "))).font(.caption).textSelection(.enabled)
                                    Text(item.allowedTools.joined(separator: ", ")).font(.caption.monospaced())
                                }.padding(.vertical, 5)
                            }
                            Text("OAuth 로그인·플러그인 설치/제거는 기존 ‘셸·MCP·플러그인 도구 실행’ 창에서 관리합니다. 인증이 필요한 작업은 로그인 후 새로 요청하세요. 훅·스크립트는 자동 실행하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("검토한 스킬 참고 자료") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("스킬 Markdown 파일 선택…") { chooseSkill() }
                            ForEach(profile.skills) { skill in
                                DisclosureGroup(skill.document.name) {
                                    ScrollView { Text(skill.document.text).font(.caption.monospaced()).textSelection(.enabled) }.frame(maxHeight: 140)
                                    if skill.document.truncated { Text("용량 제한으로 일부만 포함됐습니다.").font(.caption).foregroundStyle(.orange) }
                                    Button("이 스킬 제외") { profile.skills.removeAll { $0.id == skill.id } }
                                }
                            }
                            Text("최대 4개·각 16KiB입니다. 파일을 검토해 저장하고, Codex가 내용을 읽을 때 공유를 다시 승인합니다. 스킬은 안전 정책이나 실행 권한을 변경하지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("인터넷 검색 · Tavily") {
                        VStack(alignment: .leading, spacing: 9) {
                            Toggle("Codex가 인터넷 검색을 제안할 수 있도록 허용", isOn: $profile.webSearchEnabled)
                            SecureField("이 Mac에서 사용할 Tavily API 키", text: $key)
                            Button("검색 키 저장 / 빈 값이면 삭제") { confirmKey = true }
                            Text("키는 기기 Keychain에만 보관합니다. 프로필·Codex·공유 폴더에 키를 넣지 않습니다. 검색어와 결과 공유는 실행할 때마다 확인하며 제공자 사용 한도가 적용됩니다.").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.disabled(locked || !loaded)
            }
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("닫기") { dismiss() }
                if !loaded { Button("손상된 설정 초기화…") { confirmReset = true } }
                Spacer()
                Button("검토한 설정 저장") { confirmSave = true }.disabled(locked || !loaded)
            }
        }.padding(22).frame(width: 740, height: 720)
            .onAppear {
                candidates = (try? JSONDecoder().decode([String: CodexNativeToolRequest.Server].self, from: connections)) ?? [:]
                do { profile = try CodexAgentProfile.read(stored); loaded = true }
                catch { message = "저장된 확장 설정이 손상되거나 지원 범위를 벗어났습니다. 기존 설정을 자동 덮어쓰지 않습니다." }
            }
            .onChange(of: locked) { _, value in if value { key = ""; confirmSave = false; confirmKey = false } }
            .alert("검토한 확장 설정을 저장할까요?", isPresented: $confirmSave) {
                Button("취소", role: .cancel) {}
                Button("저장") {
                    guard approved() else { return }
                    do { stored = try profile.encoded(); message = "설정을 저장했습니다. 다음 작업에 적용하며 실행 승인은 저장하지 않습니다." }
                    catch { message = "프로그램·인자·허용 도구·스킬 내용을 확인해주세요." }
                }
            } message: { Text("MCP 연결과 허용 도구, 표시된 스킬 내용, 검색 사용 설정을 이 Mac에 저장합니다. 자격 증명은 포함하지 않습니다.") }
            .alert("검색 자격 증명을 변경할까요?", isPresented: $confirmKey) {
                Button("취소", role: .cancel) { key = "" }
                Button("이 Mac의 검색 키 변경") {
                    guard approved(), key.utf8.count <= 1024 else { return }
                    message = WebSearchAPIKeyStore.save(key) ? "Keychain의 검색 키 설정을 변경했습니다." : "Keychain 설정을 변경하지 못했습니다."
                    key = ""
                }
            } message: { Text("입력한 키를 이 Mac의 JARVIS 검색 기능에 사용합니다. 빈 값은 기존 키 삭제입니다.") }
            .alert("확장 설정을 초기화할까요?", isPresented: $confirmReset) {
                Button("취소", role: .cancel) {}
                Button("초기화", role: .destructive) { if approved() { stored = Data(); profile = .init(); loaded = true } }
            } message: { Text("연결·스킬 설정만 지우며 Keychain 키와 서비스 측 OAuth 권한은 유지됩니다.") }
    }
    private func chooseMCP() {
        guard !locked else { return }
        let panel = NSOpenPanel(); if JarvisStorage.portable { panel.directoryURL = JarvisStorage.store?.root }; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, JarvisStorage.permits(url),
              case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.attachmentRead), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: true)) else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 65537) ?? Data()
            let servers = try CodexNativeToolRequest.pluginServers(data)
            candidates.merge(servers) { _, selected in selected }; selected = servers.keys.sorted().first ?? ""
            message = "가져온 연결은 검토 목록에 추가하고 저장해야 적용됩니다."
        } catch { message = "MCP 정의를 읽지 못했습니다. env·인증 헤더·훅을 포함한 설정은 가져올 수 없습니다." }
    }
    private func chooseSkill() {
        guard !locked, profile.skills.count < 4 else { return }
        let panel = NSOpenPanel(); if JarvisStorage.portable { panel.directoryURL = JarvisStorage.store?.root }; panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try CodexDocumentReader.read(url, confirmed: true, locked: locked)
            profile.skills.append(.init(document: document)); message = "스킬 내용을 펼쳐 검토한 후 저장하세요."
        } catch { message = "스킬 파일의 UTF-8 형식·용량·비밀정보를 확인해주세요." }
    }
}

struct CodexAgentHistoryPanel: View {
    struct Row: Identifiable { let id: UUID; let archived: Bool; let pending: Bool; let updated: Double }
    @Environment(\.dismiss) private var dismiss
    let root: URL
    @ObservedObject var connection: CodexLocalStore
    let names: [UUID: String]
    let changed: (UUID, String) -> Void
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var rows: [Row] = []
    @State private var message = ""
    @State private var detail = ""
    @State private var loading = false
    @State private var selection: Row?
    @State private var nextCursor: String?
    @State private var detailCursor: String?
    @State private var detailRow: Row?
    @State private var operation = ""
    @State private var confirmation = false
    @State private var lease: UUID?
    @State private var work: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex 작업 세션·이력 관리").font(.title2.bold())
            Text("현재 프로젝트 폴더와 일치하는 JARVIS 전용 세션입니다. 공식 앱 계정 전체의 대화 동기화와는 별개입니다.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(names[row.id] ?? "이전 JARVIS 대화").font(.headline)
                                Text((row.archived ? "보관됨" : "활성") + (row.pending ? " · 이전 작업 또는 관리 결과 미확인" : " · 마지막 결과 확인됨")).font(.caption).foregroundStyle(row.pending ? .orange : .secondary)
                                Text(Date(timeIntervalSince1970: row.updated).formatted()).font(.caption2)
                                HStack {
                                    Button("이력 확인") { run("read", row: row, change: false) }
                                    Button(row.archived ? "복원" : "보관") { ask(row.archived ? "unarchive" : "archive", row) }
                                    Button("대화 압축") { ask("compact", row) }.disabled(row.pending || row.archived)
                                    Button("영구 삭제", role: .destructive) { ask("delete", row) }
                                    if row.pending { Button("연결 메타데이터 지우기") { ask("forget", row) } }
                                }.disabled(loading || locked)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(minHeight: 210)
            if let cursor = nextCursor { Button("이전 세션 더 보기") { run("list", row: nil, change: false, cursor: cursor) }.disabled(loading || locked) }
            if !detail.isEmpty { ScrollView { Text(detail).textSelection(.enabled).font(.caption) }.frame(maxHeight: 170) }
            if let cursor = detailCursor, let row = detailRow { Button("이 대화의 이전 작업 더 보기") { run("read", row: row, change: false, cursor: cursor) }.disabled(loading || locked) }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack { Button("닫기") { dismiss() }; Spacer(); if loading { ProgressView().controlSize(.small) }; Button("새로 고침") { run("list", row: nil, change: false) }.disabled(loading || locked) }
        }.padding(22).frame(width: 760, height: 650)
            .onAppear { run("list", row: nil, change: false) }
            .onDisappear { work?.cancel(); if let lease { connection.stopAgent(lease) } }
            .onChange(of: locked) { _, value in if value { work?.cancel(); if let lease { connection.stopAgent(lease) }; loading = false } }
            .alert("선택한 세션을 변경할까요?", isPresented: $confirmation) {
                Button("취소", role: .cancel) {}
                Button(operation == "delete" ? "영구 삭제" : "이 작업 실행", role: operation == "delete" ? .destructive : nil) { run(operation, row: selection, change: true) }
            } message: {
                Text((selection.flatMap { names[$0.id] } ?? "선택한 대화") + "\n작업: " + operation + "\n압축은 OpenAI 서비스를 사용합니다. 영구 삭제는 Codex 세션과 관련 하위 작업을 지울 수 있으며 되돌릴 수 없습니다. JARVIS 채팅창의 로컬 대화는 유지합니다. 메타데이터 지우기는 Codex 원본 기록을 삭제하지 않습니다.")
            }
    }
    private func ask(_ value: String, _ row: Row) { operation = value; selection = row; confirmation = true }
    private func run(_ value: String, row: Row?, change: Bool, cursor: String? = nil) {
        guard !loading, !locked, connection.ready, connection.backend == .appServer else { return }
        let current = UUID()
        guard connection.reserveAgent(current) else { return }
        lease = current; loading = true
        work = Task {
            defer { connection.releaseAgent(current); if lease == current { lease = nil; loading = false } }
            do {
                guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.codeRead), context: .init(externalActionsLocked: locked)),
                      let identity = CodexNativeToolRequest(operation: .gitStatus, root: root.path, command: []).rootIdentity else { throw CodexLocalError.invalid }
                var input: [String: Any] = ["operation":value,"root":root.path,"rootIdentity":identity,"jobID":current.uuidString]
                if let row { input["conversationID"] = row.id.uuidString }
                if let cursor { input["cursor"] = cursor }
                let payload = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
                let result = await connection.agentCall(change ? .agentHistoryChange : .agentHistoryRead, input: payload, lease: current, confirmed: change)
                guard !Task.isCancelled, !locked, lease == current, case .succeeded(let reply) = result,
                      let text = reply.reply, let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CodexLocalError.unavailable }
                if value == "list", let items = object["sessions"] as? [[String: Any]] {
                    let loaded = items.compactMap { item -> Row? in
                        guard let raw = item["conversationID"] as? String, let id = UUID(uuidString: raw),
                              let archived = item["archived"] as? Bool, let pending = item["pending"] as? Bool, let updated = item["updated"] as? Double else { return nil }
                        return Row(id: id, archived: archived, pending: pending, updated: updated)
                    }
                    rows = cursor == nil ? loaded : rows + loaded.filter { value in !rows.contains(where: { $0.id == value.id }) }
                    nextCursor = object["nextCursor"] as? String
                    message = rows.isEmpty ? "이 프로젝트의 저장된 작업 세션이 없습니다." : "프로젝트 작업 세션을 확인했습니다."
                } else if value == "read", let items = object["messages"] as? [[String: Any]] {
                    let page = items.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    detail = String((cursor == nil ? page : detail + "\n\n" + page).suffix(16000)); detailRow = row
                    detailCursor = object["nextCursor"] as? String
                    message = "최근 네이티브 작업 요약을 읽었습니다. 전체 사용자 대화는 JARVIS 채팅창에서 확인하세요."
                } else if object["verified"] as? Bool == true, let row {
                    changed(row.id, value); message = "세션 관리 결과를 확인했습니다. 새로 고침으로 상태를 확인할 수 있습니다."
                    if value == "delete" || value == "forget" { rows.removeAll { $0.id == row.id } }
                } else { throw CodexLocalError.invalid }
            } catch { if !Task.isCancelled { message = "세션 관리 결과를 확인하지 못했습니다. 자동 재시도하지 않습니다. 기존 기록과 로그인 상태를 확인하세요." } }
        }
    }
}
