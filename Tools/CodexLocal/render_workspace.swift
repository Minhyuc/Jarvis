// Local visual QA only. Compile with the Mac UI sources and JarvisCore objects.
// Uses synthetic, read-only state; never reads or writes the user's workspace.
import AppKit
import SwiftUI
import JarvisCore
import PDFKit

@MainActor
private final class ScriptedCodeTransport: CodexCodeTransport {
    var ready = true
    var busy = false
    let backend = CodexLocalBackend.appServer
    let sessionID: UUID? = UUID()
    var scripts: [String] = []
    var requests: [CodexCodeRequest] = []
    var executions = 0
    var executionFails = false
    private func reply(_ text: String) -> CodexLocalReply {
        let object: [String: Any] = ["format": 1, "sessionID": sessionID!.uuidString,
            "requestID": UUID().uuidString, "status": "succeeded", "reply": text,
            "protocolVersion": 3, "backend": "appServer", "codeVersion": 3, "nativeVersion": 1]
        return try! JSONDecoder().decode(CodexLocalReply.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func sendCode(_ payload: CodexCodeRequest, expectedSession: UUID, confirmed: Bool,
                  completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void) {
        precondition(expectedSession == sessionID && confirmed)
        precondition((try? payload.encodedInput()) != nil)
        requests.append(payload)
        precondition(!scripts.isEmpty, "Conversation requested an unexpected model step")
        let value = reply(scripts.removeFirst())
        DispatchQueue.main.async { completion(.succeeded(value)) }
    }
    func runNative(_ payload: CodexNativeToolRequest, confirmed: Bool, onOutput: ((String) -> Void)?,
                   completion: @escaping (ToolExecutionResult<CodexLocalReply>) -> Void) {
        precondition(confirmed && payload.operation == .verify && payload.command == ["swift", "test"])
        precondition((try? payload.encodedInput()) != nil)
        executions += 1
        let value = reply(#"{"exitCode":0,"stdout":"Synthetic tests passed","stderr":""}"#)
        DispatchQueue.main.async {
            onOutput?("Synthetic test output while running\n")
            completion(self.executionFails ? .failed(message: "Synthetic exit code 1", retryable: false) : .succeeded(value))
        }
    }
    func stop() {}
}

@MainActor
private final class FailingCodexService: CodexServiceTransport {
    var onDisconnect: (() -> Void)?
    var installedBuild: String? = "synthetic-build"
    var matchesInstalledBuild: Bool { false }
    var starts = 0
    func start(completion: @escaping (Data?, String?) -> Void) {
        starts += 1; completion(nil, "합성 연결 실패")
    }
    func stop() {}
}

@MainActor
private final class ScriptedAgentTransport: CodexAgentTransport {
    var ready = true
    var busy = false
    var backend = CodexLocalBackend.appServer
    var sessionID: UUID? = UUID()
    var lease: UUID?
    var position = 0
    var executions = 0
    var answers: [[String:Any]] = []
    var approvalIDs = [UUID(), UUID(), UUID()]
    var executionFails = false
    var extensionScript: [(String, [String:Any])] = []
    var nativeRequests: [CodexNativeToolRequest] = []
    var searches = 0
    func reserveAgent(_ lease: UUID) -> Bool { guard !busy else { return false }; self.lease = lease; busy = true; return true }
    func releaseAgent(_ lease: UUID) { if self.lease == lease { self.lease = nil; busy = false } }
    func stopAgent(_ lease: UUID) { releaseAgent(lease) }
    private func result(_ value: [String:Any]) throws -> ToolExecutionResult<CodexLocalReply> {
        let response: [String:Any] = ["format":1,"sessionID":sessionID!.uuidString,"requestID":UUID().uuidString,"status":"succeeded",
            "agentVersion":2,"reply":String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)]
        return .succeeded(try JSONDecoder().decode(CodexLocalReply.self,from:JSONSerialization.data(withJSONObject:response)))
    }
    private func snapshot() throws -> ToolExecutionResult<CodexLocalReply> {
        let names = extensionScript.isEmpty ? ["jarvis_project_read","jarvis_project_edit","jarvis_project_verify"] : extensionScript.map { $0.0 }
        let fields: [[String:Any]] = extensionScript.isEmpty ? [["path":"View.swift","startLine":1,"lineCount":20],
            ["path":"View.swift","old":"let n = 1","new":"let n = 2"], ["argv":["swift","test"],"purpose":"검증"]]
            : extensionScript.map { $0.1 }
        while approvalIDs.count < names.count { approvalIDs.append(UUID()) }
        var response: [String:Any] = ["agentVersion":2,"jobID":lease!.uuidString,"state":position < names.count ? "awaitingApproval":"completed",
             "threadID":"agent-thread","turnID":"agent-turn","reply":position < names.count ? "":"합성 Codex 작업 완료", "events":[]]
        if position < names.count {
            response["pending"] = ["approvalID":approvalIDs[position].uuidString,"callID":"call-"+String(position),"threadID":"agent-thread","turnID":"agent-turn",
                "tool":names[position],"arguments":String(decoding:try JSONSerialization.data(withJSONObject:fields[position]),as:UTF8.self),"expiresAt":Date().timeIntervalSince1970+120] as [String:Any]
        }
        return try result(response)
    }
    func agentCall(_ action: CodexLocalAction, input: String, lease: UUID, confirmed: Bool) async -> ToolExecutionResult<CodexLocalReply> {
        guard self.lease == lease else { return .failed(message:"revoked",retryable:false) }
        do {
            let fields = try JSONSerialization.jsonObject(with:Data(input.utf8)) as! [String:Any]
            if action == .agentPoll, fields["capabilities"] as? Bool == true {
                return try result(["agentVersion":2,"supported":true,"runtime":"Synthetic Codex","tools":Array(CapabilityRegistry.codexAgentTools)])
            }
            if action == .agentRespond {
                precondition(confirmed && fields["approvalID"] as? String == approvalIDs[position].uuidString)
                answers.append(fields); position += 1
            }
            return try snapshot()
        } catch { return .failed(message:"invalid fixture",retryable:false) }
    }
    func agentVerify(_ payload: CodexNativeToolRequest, lease: UUID, output: @escaping @MainActor (String) -> Void) async -> ToolExecutionResult<CodexLocalReply> {
        if !extensionScript.isEmpty {
            precondition(self.lease == lease && [.mcpList,.mcpCall].contains(payload.operation))
            nativeRequests.append(payload)
            return try! result(payload.operation == .mcpList ? ["tools":["search":["description":"Synthetic search"],"forbidden":["description":"Must not share"]]] : ["result":"Synthetic MCP result"])
        }
        precondition(self.lease == lease && payload.operation == .verify && payload.command == ["swift","test"])
        executions += 1; output(executionFails ? "Synthetic test failure" : "Synthetic tests passed")
        if executionFails { return .failed(message:"Synthetic verification failed", retryable:false) }
        return try! result(["exitCode":0,"stdout":"Synthetic tests passed","stderr":""])
    }
    func agentSearch(_ query: String, lease: UUID) async -> ToolExecutionResult<String> {
        precondition(self.lease == lease); searches += 1
        return .succeeded("Synthetic search result\n출처: https://example.com/source")
    }
}

@main
struct RenderCodexWorkspace {
    @MainActor static func checkCodingConversation(in scratch: URL) throws {
        let root = scratch.appendingPathComponent("TaskProject")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("View.swift")
        try "let count = 1\n".write(to: source, atomically: true, encoding: .utf8)
        let executor = try CodexCodeFiles(root: root, confirmed: true)
        let store = CodexCodeWorkspaceStore(projectID: UUID(), executor: executor,
                                           backupDirectory: scratch.appendingPathComponent("TaskBackups"), lockState: { false })
        let transport = ScriptedCodeTransport()
        let verify = #"{"summary":"테스트를 실행해 확인하겠습니다.","edits":[],"reads":[],"commands":[{"argv":["swift","test"],"purpose":"변경 검증"}]}"#
        transport.scripts = [
            #"{"summary":"필요한 소스를 확인하겠습니다.","edits":[],"reads":[{"path":"View.swift","startLine":1,"lineCount":20}],"commands":[]}"#,
            #"{"summary":"같은 승인 범위를 다시 확인하겠습니다.","edits":[],"reads":[{"path":"View.swift","startLine":1,"lineCount":20}],"commands":[]}"#,
            #"{"summary":"값을 수정하겠습니다.","edits":[{"path":"View.swift","old":"let count = 1","new":"let count = 2"}],"reads":[],"commands":[]}"#,
            verify,
            #"{"summary":"파일 저장과 합성 테스트 결과를 확인했습니다.","edits":[],"reads":[],"commands":[]}"#
        ]
        func pump(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "Coding conversation did not reach the expected stage: " + store.phase + " / " + store.message)
        }
        precondition(store.request("값을 수정하고 테스트해줘", model: "test-model", effort: "low", connection: transport))
        pump { !store.pendingReads.isEmpty }
        let firstApproval = store.permissionID
        store.approveReads(UUID())
        precondition(!store.pendingReads.isEmpty, "Stale approval changed current task")
        store.approveReads(firstApproval, forTask: true)
        pump { !store.plans.isEmpty }
        let plan = store.plans[0]
        store.apply(plan, confirmed: false)
        let original = try String(contentsOf: source, encoding: .utf8)
        precondition(original == "let count = 1\n")
        store.apply(plan, confirmed: true)
        pump { store.pendingCommand != nil }
        var previewState = CodexChatWorkspace()
        var previewProject = CodexChatProject(name: "합성 검증 프로젝트")
        var previewThread = CodexChatThread(title: "코드 수정 후 테스트", model: "test-model")
        previewThread.messages = [.init(role: .user, text: "값을 수정하고 테스트해줘")]
        previewProject.threads = [previewThread]
        previewState.projects = [previewProject]
        let preview = NSHostingView(rootView: CodexWorkspaceView(preview: previewState, codeStore: store)
            .frame(width: 1180, height: 900).environment(\.colorScheme, .dark))
        preview.frame = NSRect(x: 0, y: 0, width: 1180, height: 900)
        let previewWindow = NSWindow(contentRect: preview.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.contentView = preview
        preview.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jarvis-codex-task-approval.png"))
        }
        let changed = try String(contentsOf: source, encoding: .utf8)
        precondition(changed == "let count = 2\n")
        precondition(transport.executions == 0, "Command executed before its own approval")
        store.approveCommand(UUID())
        precondition(transport.executions == 0)
        store.approveCommand(store.permissionID)
        pump { store.awaitingResult }
        precondition(transport.requests.count == 4, "Tool output was transmitted without review")
        precondition(store.liveOutput.contains("while running"))
        store.approveResult(store.permissionID)
        pump { !store.taskActive && store.phase == "완료" }
        precondition(transport.requests.count == 5 && transport.executions == 1)
        precondition(transport.requests.last!.toolResults.contains(where: { $0.contains("종료 코드 0") }))
        precondition(store.backups.count == 1, "Write backup was not retained")
        transport.executionFails = true
        transport.scripts = [verify, #"{"summary":"실패한 테스트 출력을 설명하겠습니다.","edits":[],"reads":[],"commands":[]}"#]
        precondition(store.request("실패 결과도 설명해줘", model: "test-model", effort: "low", connection: transport))
        pump { store.pendingCommand != nil }
        store.approveCommand(store.permissionID)
        pump { store.awaitingResult }
        precondition(transport.executions == 2)
        store.approveResult(store.permissionID)
        pump { !store.taskActive && store.phase == "완료" }
        precondition(transport.requests.last!.toolResults.contains(where: { $0.contains("실패 또는 결과 미확인") }))
        transport.scripts = [verify]
        precondition(store.request("테스트를 다시 제안해줘", model: "test-model", effort: "low", connection: transport))
        pump { store.pendingCommand != nil }
        let stale = store.permissionID
        store.rejectReads()
        store.approveCommand(stale)
        precondition(transport.executions == 2 && !store.taskActive)
        transport.scripts = [verify]
        precondition(store.request("새 검증 작업", model: "test-model", effort: "low", connection: transport))
        pump { store.pendingCommand != nil }
        store.approveCommand(stale)
        precondition(store.taskActive && store.pendingCommand != nil && transport.executions == 2)
        store.rejectReads()
        store.disconnect()
        print("PASS: conversation -> scoped reads -> approved real file write -> separately approved verification -> reviewed output -> final answer; stale approvals and rejection never execute")
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-workspace-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let previewSuite = "jarvis-agent-extension-preview-" + UUID().uuidString
        let previewDefaults = UserDefaults(suiteName: previewSuite)!
        defer { previewDefaults.removePersistentDomain(forName: previewSuite) }
        let extensionPreview = NSHostingView(rootView: CodexAgentExtensionsPanel().defaultAppStorage(previewDefaults).environment(\.colorScheme,.dark))
        extensionPreview.frame = NSRect(x:0,y:0,width:740,height:720)
        let extensionWindow = NSWindow(contentRect:extensionPreview.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        extensionWindow.appearance = NSAppearance(named:.darkAqua);extensionWindow.contentView = extensionPreview
        extensionPreview.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        if let bitmap = extensionPreview.bitmapImageRepForCachingDisplay(in:extensionPreview.bounds) {
            extensionPreview.cacheDisplay(in:extensionPreview.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/jarvis-agent-extensions.png"))
        }
        extensionWindow.orderOut(nil)
        try checkCodingConversation(in: scratch)
        do {
            let root = scratch.appendingPathComponent("AgentProject")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("View.swift")
            try "let n = 1\n".write(to: source, atomically: true, encoding: .utf8)
            let executor = try CodexCodeFiles(root: root, confirmed: true)
            let agent = CodexAgentWorkspaceStore(backupDirectory: scratch.appendingPathComponent("AgentBackups"), lockState: { false })
            let connection = ScriptedAgentTransport()
            func pump(_ condition: () -> Bool) {
                let limit = Date().addingTimeInterval(10)
                while !condition() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                precondition(condition(), "Agent did not reach expected stage: " + agent.phase)
            }
            precondition(agent.start("수정하고 검증", model: "test-model", effort: "low", executor: executor, connection: connection))
            pump { agent.pending?.tool == "jarvis_project_read" && agent.canApprove }
            agent.approve(UUID()); precondition(connection.answers.isEmpty)
            agent.approve(agent.pending!.approvalID)
            pump { agent.pending?.tool == "jarvis_project_edit" && agent.canApprove }
            let agentHost = NSHostingView(rootView: CodexAgentPanel(store: agent).padding(20).environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
            agentHost.frame = NSRect(x: 0, y: 0, width: 820, height: 520)
            let agentWindow = NSWindow(contentRect: agentHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            agentWindow.appearance = NSAppearance(named: .darkAqua)
            agentWindow.contentView = agentHost; agentHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let bitmap = agentHost.bitmapImageRepForCachingDisplay(in: agentHost.bounds) {
                agentHost.cacheDisplay(in: agentHost.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/jarvis-agent-approval.png"))
            }
            agentWindow.orderOut(nil)
            let beforeAgentEdit = try String(contentsOf: source, encoding: .utf8)
            precondition(beforeAgentEdit == "let n = 1\n")
            agent.approve(agent.pending!.approvalID)
            pump { agent.pending?.tool == "jarvis_project_verify" && agent.canApprove }
            let afterAgentEdit = try String(contentsOf: source, encoding: .utf8)
            precondition(afterAgentEdit == "let n = 2\n")
            precondition(connection.executions == 0)
            agent.approve(agent.pending!.approvalID)
            pump { agent.awaitingOutput }
            precondition(connection.executions == 1 && connection.answers.count == 2)
            agent.shareOutput(agent.pending!.approvalID)
            pump { !agent.running }
            precondition(connection.answers.count == 3 && connection.answers.allSatisfy { $0["success"] as? Bool == true })
            precondition(!connection.busy)
            precondition(executor.backups(directory: scratch.appendingPathComponent("AgentBackups"), locked: { false }).status == .succeeded)
            let cancelled = CodexAgentWorkspaceStore(lockState: { false })
            let second = ScriptedAgentTransport()
            precondition(cancelled.start("확인", model: "test-model", effort: "low", executor: executor, connection: second))
            pump { cancelled.pending != nil }
            let stale = cancelled.pending!.approvalID
            cancelled.stop(); cancelled.approve(stale)
            precondition(second.answers.isEmpty && !second.busy && cancelled.pending == nil)
            let lock = SharedProjectCancellation()
            let lockedAgent = CodexAgentWorkspaceStore(lockState: { lock.cancelled })
            let lockedConnection = ScriptedAgentTransport()
            precondition(lockedAgent.start("읽기", model: "test-model", effort: "low", executor: executor, connection: lockedConnection))
            pump { lockedAgent.pending != nil }
            let lockedApproval = lockedAgent.pending!.approvalID
            lock.cancel(); lockedAgent.approve(lockedApproval)
            pump { !lockedAgent.running }
            precondition(lockedConnection.answers.isEmpty && !lockedConnection.busy)
            try "let n = 1\n".write(to: source, atomically: true, encoding: .utf8)
            let failed = CodexAgentWorkspaceStore(backupDirectory: scratch.appendingPathComponent("FailedAgentBackups"), lockState: { false })
            let failureTransport = ScriptedAgentTransport(); failureTransport.executionFails = true
            precondition(failed.start("실패 검사", model: "test-model", effort: "low", executor: executor, connection: failureTransport))
            pump { failed.pending?.tool == "jarvis_project_read" && failed.canApprove }
            failed.approve(failed.pending!.approvalID)
            pump { failed.pending?.tool == "jarvis_project_edit" && failed.canApprove }
            failed.approve(failed.pending!.approvalID)
            pump { failed.pending?.tool == "jarvis_project_verify" && failed.canApprove }
            failed.approve(failed.pending!.approvalID)
            pump { failed.awaitingOutput }
            failed.shareOutput(failed.pending!.approvalID)
            pump { !failed.running }
            precondition(failureTransport.answers.last?["success"] as? Bool == false)
            precondition(failed.verifiedFacts.last?.contains("미확인") == true)
            print("PASS: native host-tool read -> approved actual edit/backup -> verification -> output sharing -> final; stale approval, cancellation, emergency lock and failed-verification honesty")
            var profile = CodexAgentProfile()
            let server = CodexAgentExtension(name:"Synthetic",server:.init(url:"https://example.com/mcp"),allowedTools:["search"])
            let skill = CodexAgentSkill(document:.init(name:"SKILL.md",text:"Synthetic reviewed guidance"))
            profile.extensions = [server]; profile.skills = [skill]; profile.webSearchEnabled = true
            let extensions = ScriptedAgentTransport()
            extensions.extensionScript = [
                ("jarvis_extension_list",[:]), ("jarvis_skill_read",["skillID":skill.id.uuidString]),
                ("jarvis_extension_inspect",["extensionID":server.id.uuidString]),
                ("jarvis_extension_call",["extensionID":server.id.uuidString,"tool":"search","arguments":"{\"query\":\"sample\"}"]),
                ("jarvis_web_search",["query":"sample query"])]
            let extensionAgent = CodexAgentWorkspaceStore(lockState:{ false })
            var acknowledged: String?
            extensionAgent.completed = { _, turn in acknowledged = turn }
            precondition(extensionAgent.start("확장 도구 사용",model:"test-model",effort:"low",executor:executor,profile:profile,connection:extensions))
            profile.extensions = []; profile.skills = []; profile.webSearchEnabled = false
            for index in 0..<5 {
                pump { extensionAgent.pending?.tool == extensions.extensionScript[index].0 && extensionAgent.canApprove }
                precondition(extensions.nativeRequests.count == max(0,min(2,index-2)))
                precondition(extensions.searches == 0)
                extensionAgent.approve(UUID()); precondition(!extensionAgent.sending)
                extensionAgent.approve(extensionAgent.pending!.approvalID)
                if index >= 2 {
                    pump { extensionAgent.awaitingOutput }
                    precondition(extensions.answers.count == index, "Tool output shared before approval")
                    if index == 2 { precondition(!extensionAgent.outputDraft.contains("forbidden")) }
                    extensionAgent.shareOutput(extensionAgent.pending!.approvalID)
                }
            }
            pump { !extensionAgent.running }
            precondition(acknowledged == "agent-turn" && extensions.nativeRequests.count == 2 && extensions.searches == 1)
            precondition(extensions.answers.allSatisfy { $0["success"] as? Bool == true })
            for (tool,fields) in [("jarvis_extension_call",["extensionID":UUID().uuidString,"tool":"search","arguments":"{}"]), ("jarvis_web_search",["query":"disabled search"])] {
                let denied = ScriptedAgentTransport(); denied.extensionScript = [(tool,fields)]
                let deniedAgent = CodexAgentWorkspaceStore(lockState:{ false })
                precondition(deniedAgent.start("검사",model:"test-model",effort:"low",executor:executor,connection:denied))
                pump { deniedAgent.pending != nil }
                precondition(!deniedAgent.canApprove)
                deniedAgent.approve(deniedAgent.pending!.approvalID)
                precondition(denied.nativeRequests.isEmpty && denied.searches == 0 && denied.answers.isEmpty)
                deniedAgent.reject(deniedAgent.pending!.approvalID)
                pump { !deniedAgent.running }
                precondition(denied.answers.first?["success"] as? Bool == false)
            }
            print("PASS: pinned MCP/skill/search profile, filtered schema discovery, per-call execution and output approval, native completion acknowledgment, unknown extension and disabled search rejected")
        }
        do {
        let pdfData = try CodexResponseExporter.data("JARVIS 한국어 응답\n일정을 확인했습니다.", format: "pdf")
        precondition(PDFDocument(data: pdfData)?.pageCount == 1)
        let pdfURL = scratch.appendingPathComponent("response.pdf")
        precondition(CodexResponseExporter.save(pdfData, to: pdfURL, confirmed: false, locked: { false }).status == .needsConfirmation)
        precondition(!FileManager.default.fileExists(atPath: pdfURL.path))
        precondition(CodexResponseExporter.save(pdfData, to: pdfURL, confirmed: true, locked: { true }).status == .failed)
        precondition(CodexResponseExporter.save(pdfData, to: pdfURL, confirmed: true, locked: { false }).status == .succeeded)
        let document = try CodexDocumentReader.read(pdfURL, confirmed: true, locked: false)
        precondition(document.text.contains("한국어") && document.text.contains("일정을"))
        do { _ = try CodexDocumentReader.read(pdfURL, confirmed: false, locked: false); preconditionFailure("Unapproved attachment read") } catch {}
        let textURL = scratch.appendingPathComponent("long.txt")
        try String(repeating: "a", count: 17000).write(to: textURL, atomically: true, encoding: .utf8)
        let shortened = try CodexDocumentReader.read(textURL, confirmed: true, locked: false)
        precondition(shortened.truncated && shortened.text.utf8.count <= 16384)
        let recoveryRoot = scratch.appendingPathComponent("recovery-project")
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        try "let n = 1\n".write(to: recoveryRoot.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        let recoveryExecutor = try CodexCodeFiles(root: recoveryRoot, confirmed: true)
        let suite = "jarvis-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = UUID()
        let recoveryStore = CodexCodeWorkspaceStore(projectID: project, executor: recoveryExecutor, recoveryDefaults: defaults, lockState: { false })
        let recoveryTransport = ScriptedCodeTransport()
        recoveryTransport.scripts = [#"{"summary":"소스 확인","edits":[],"reads":[{"path":"View.swift","startLine":1,"lineCount":10}]}"#]
        precondition(recoveryStore.request("코드 확인", model: "test-model", effort: "low", connection: recoveryTransport))
        let restored = CodexCodeWorkspaceStore(projectID: project, executor: recoveryExecutor, recoveryDefaults: defaults, lockState: { false })
        precondition(restored.recovery?.instruction == "코드 확인" && !restored.taskActive && restored.pendingReads.isEmpty)
        restored.disconnect(preservingRecovery: true)
        precondition(restored.recovery != nil)
        restored.stop()
        precondition(restored.recovery == nil)
        print("PASS: PDF Korean roundtrip, explicit save/read approval, truncation and metadata-only task recovery")
        }
        let file = scratch.appendingPathComponent("workspace.json")
        let first = CodexChatWorkspaceStore(storageURL: file)
        first.createProject("Project A"); first.createThread(model: "test-model")
        precondition(first.data.projects.count == 1 && first.thread?.model == "test-model", "Create and save failed")
        let other = CodexChatWorkspaceStore(storageURL: file)
        precondition(other.data == first.data, "Reopen did not preserve workspace")
        first.model("another-model")
        other.rename(other.threadID!, name: "Stale change")
        precondition(other.message.contains("저장하지 못했습니다"), "Stale window was not blocked")
        other.reload()
        precondition(other.thread?.model == "another-model" && other.thread?.title == "새 대화", "Conflict overwrote stored data")
        let projectID = first.projectID!
        first.delete(projectID, confirmed: false)
        precondition(first.data.projects.count == 1, "Unconfirmed deletion allowed")
        first.delete(projectID, confirmed: true)
        precondition(first.data.projects.isEmpty, "Confirmed deletion failed")
        first.model("general-model", effort: "high")
        precondition(first.thread == nil && first.selectedModel == "general-model", "Cannot choose model before a conversation")
        let plan = first.prepare("바로 입력한 메시지", session: UUID())
        precondition(plan != nil && first.data.projects.count == 1 && first.data.projects[0].name == "일반 대화", "Typing did not create general conversation")
        precondition(plan?.payload.model == "general-model" && plan?.payload.effort == "high", "General conversation lost selected settings")
        first.createGeneralThread()
        precondition(first.data.projects.count == 1 && first.data.projects[0].threads.count == 2, "New chat did not reuse general project")
        first.createProject("별도 프로젝트"); first.createThread(model: "other-model")
        first.createGeneralThread()
        precondition(first.data.projects.first(where: { $0.id == first.projectID })?.name == "일반 대화", "Top-level new chat stayed in custom project")
        let reopened = CodexChatWorkspaceStore(storageURL: file)
        precondition(reopened.data.projects.count == 2 && reopened.selectedEffort == "high", "General conversation settings did not persist")
        print("PASS: automatic general chat, reusable general project, model-before-chat, reasoning and legacy storage")
        print("PASS: Mac workspace create, model selection, reopen, conflict protection, deletion approval")
        let imageURL = scratch.appendingPathComponent("sample.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<16 {
            for x in 0..<16 { bitmap.setColor(.systemBlue, atX: x, y: y) }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let imageJPEG = try first.readChatImage(imageURL)
        precondition(imageJPEG.starts(with: [0xff, 0xd8]) && NSImage(data: imageJPEG)?.isValid == true,
                     "Selected PNG was not re-encoded as a usable JPEG")
        let imagePlan = first.prepare("Describe the image", session: UUID(), image: imageJPEG)
        precondition(imagePlan?.payload.image == imageJPEG, "Image was not included in the selected draft")
        print("PASS: selected PNG becomes a bounded JPEG in the chat draft")

        let exported = #"""
        [{"id":"synthetic-import","title":"Imported","current_node":"later","mapping":{
          "first":{"parent":null,"message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["Question"]}}},
          "answer":{"parent":"first","message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["Answer"]}}},
          "later":{"parent":"answer","message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["Later question"]}}}
        }}]
        """#
        let importFile = scratch.appendingPathComponent("import-test.json")
        let importStore = CodexChatWorkspaceStore(storageURL: importFile)
        let preview = try CodexChatImport.read(Data(exported.utf8))
        let selected = Set(preview.threads.map(\.id))
        precondition(!importStore.importChatGPT(preview, selected: selected, confirmed: false))
        precondition(importStore.importChatGPT(preview, selected: selected, confirmed: true))
        precondition(!importStore.importChatGPT(preview, selected: selected, confirmed: true))
        let original = importStore.thread!
        precondition(importStore.branchConversation(after: original.messages[1].id))
        let branch = importStore.thread!
        precondition(branch.id != original.id && branch.messages.map(\.text) == ["Question", "Answer"])
        precondition(Set(branch.messages.map(\.id)).isDisjoint(with: original.messages.map(\.id)))
        let reopenedImport = CodexChatWorkspaceStore(storageURL: importFile)
        precondition(reopenedImport.data.projects[0].threads == [original, branch])
        print("PASS: approved selective import, duplicate protection and durable independent branching")
        let scoped = CodexChatWorkspaceStore(storageURL: scratch.appendingPathComponent("project-folders.json"))
        scoped.createProject("폴더 프로젝트 A")
        let folderProject = scoped.projectID!
        let folderRequest = scoped.prepareFolderSelection(projectID: folderProject, model: "test-model")!
        precondition(scoped.data.projects.count == 1 && scoped.projectID == folderProject && scoped.thread != nil,
                     "Folder selection escaped the empty custom project")
        scoped.createThread(model: "test-model")
        let retainedThread = scoped.threadID!
        let renewedRequest = scoped.prepareFolderSelection(projectID: folderProject, model: "test-model")!
        precondition(scoped.threadID == retainedThread && renewedRequest != folderRequest, "Folder selection lost current thread or reused a request")
        scoped.createProject("폴더 프로젝트 B"); scoped.createThread(model: "test-model")
        let otherProject = scoped.projectID!, otherThread = scoped.threadID!
        let otherRequest = scoped.prepareFolderSelection(projectID: otherProject, model: "test-model")!
        precondition(!scoped.acceptsFolderSelection(folderRequest) && scoped.acceptsFolderSelection(otherRequest),
                     "Stale folder request survived a project change")
        precondition(scoped.prepareFolderSelection(projectID: UUID(), model: "test-model") == nil, "Unknown project accepted folder selection")
        scoped.delete(retainedThread, confirmed: false)
        precondition(scoped.data.projects.flatMap(\.threads).contains { $0.id == retainedThread }, "Unconfirmed thread deletion succeeded")
        scoped.delete(retainedThread, confirmed: true)
        precondition(!scoped.data.projects.flatMap(\.threads).contains { $0.id == retainedThread }
                     && scoped.threadID == otherThread, "Thread deletion affected a sibling selection")
        let afterDeletion = CodexChatWorkspaceStore(storageURL: scratch.appendingPathComponent("project-folders.json"))
        precondition(!afterDeletion.data.projects.flatMap(\.threads).contains { $0.id == retainedThread }, "Deleted thread returned on reopen")
        scoped.delete(otherProject, confirmed: true)
        precondition(!scoped.acceptsFolderSelection(otherRequest), "Deleted project kept folder selection authority")
        print("PASS: project-scoped folder selection, fresh request identity, stale/deleted project rejection and confirmed durable thread deletion")
        let codingThread = first.threadID!
        first.recordCode("화면 제목을 고쳐줘", user: true, threadID: codingThread)
        first.recordCode("필요한 소스 범위를 확인하겠습니다.", user: false, threadID: codingThread)
        let codeReopen = CodexChatWorkspaceStore(storageURL: file)
        codeReopen.projectID = first.projectID; codeReopen.threadID = codingThread
        precondition(codeReopen.thread?.messages.suffix(2).allSatisfy { $0.coding == true } == true, "Code transcript lost isolation marker")
        let ordinary = try CodexChatRequest(model: "general-model", message: "안녕", messages: codeReopen.thread!.messages, effort: "low", conversationID: codingThread)
        precondition(!ordinary.input.contains("소스 범위"), "Coding transcript entered ordinary chat context")
        print("PASS: conversational coding transcript persists and is excluded from ordinary chat prompts")
        codeReopen.recordAgentCompletion("완료 답변",turn:"acknowledged-turn",threadID:codingThread)
        let agentReopen = CodexChatWorkspaceStore(storageURL:file)
        agentReopen.projectID = first.projectID;agentReopen.threadID = codingThread
        precondition(agentReopen.thread?.agentTurnID == "acknowledged-turn")
        precondition(agentReopen.branchConversation(after:agentReopen.thread!.messages.last!.id))
        precondition(agentReopen.thread?.agentForkSource == codingThread && agentReopen.thread?.agentForkTurn == "acknowledged-turn")
        agentReopen.clearAgentSession(codingThread)
        precondition(agentReopen.thread?.agentForkSource == nil && agentReopen.thread?.agentForkTurn == nil)
        precondition(agentReopen.thread?.messages.last?.text == "완료 답변")
        print("PASS: native turn acknowledgment and fork pins persist atomically; session removal clears references without deleting local messages")
        let defaultsName = "jarvis.codex-ui-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let disconnected = CodexLocalStore(preferences: defaults)
        let failingService = FailingCodexService()
        let lifecycle = CodexLocalStore(preferences: defaults, service: failingService, recoveryDelay: .milliseconds(10))
        lifecycle.startService(confirmed: false)
        precondition(failingService.starts == 0, "Unapproved start reached service")
        lifecycle.startService(confirmed: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(failingService.starts == 3 && !lifecycle.reconnecting && !lifecycle.serviceRunning,
                     "Transport repairs were not bounded to two retries")
        lifecycle.startService(confirmed: true); lifecycle.stopService()
        let stoppedCount = failingService.starts
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(failingService.starts == stoppedCount && !lifecycle.reconnecting, "Stop failed to revoke pending repair")
        lifecycle.startService(confirmed: true)
        failingService.installedBuild = "updated-build"
        let beforeUpdate = failingService.starts
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(failingService.starts == beforeUpdate && !lifecycle.reconnecting,
                     "Update reused an old repair authorization")
        lifecycle.disconnect()
        print("PASS: two bounded transport repairs, approval, cancellation and update revocation without network/model calls")
        disconnected.startService(confirmed: false)
        precondition(!disconnected.serviceBusy && !disconnected.serviceRunning && !disconnected.connected,
                     "Service started without action-specific approval")
        disconnected.stopService()
        precondition(!disconnected.serviceBusy && !disconnected.serviceRunning,
                     "Stop did not cancel service state")
        disconnected.selectBackend(.appServer)
        disconnected.login(confirmed: true, expectedSession: UUID())
        disconnected.logout(confirmed: true, expectedSession: UUID())
        precondition(!disconnected.loginPending && !disconnected.busy && !disconnected.connected,
                     "Stale login/logout approval reached a transport")
        disconnected.setAutomaticRecovery(false)
        precondition(!disconnected.automaticRecovery && !disconnected.reconnecting, "Recovery opt-out failed")
        let restoredConnection = CodexLocalStore(preferences: defaults)
        precondition(restoredConnection.backend == .appServer && !restoredConnection.automaticRecovery
                     && !restoredConnection.connected && !restoredConnection.serviceRunning && !restoredConnection.loginPending,
                     "Relaunch either lost preferences or silently restored execution consent")
        disconnected.selectBackend(.cli)
        precondition(!disconnected.connected && disconnected.models.count == 8, "Disconnected model choices are empty")
        disconnected.refreshModels(); disconnected.disconnect()
        precondition(disconnected.models.count == 8, "Refresh or disconnect erased model choices")
        disconnected.selectBackend(.appServer)
        precondition(disconnected.backend == .appServer && !disconnected.ready && !disconnected.connected,
                     "Selecting App Server reused CLI authorization or connection readiness")
        disconnected.selectBackend(.cli)
        precondition(disconnected.backend == .cli && !disconnected.ready, "CLI fallback was not explicit")
        print("PASS: recommended model list exists before connection and survives refresh/disconnect")
        var state = CodexChatWorkspace()
        var project = CodexChatProject(name: "JARVIS 개발")
        var thread = CodexChatThread(title: "캘린더 개선 계획", model: "선택한 모델")
        thread.messages = [
            .init(role: .user, text: "캘린더 검색 화면을 더 편하게 만들려면 어떻게 하면 좋을까?"),
            .init(role: .assistant, text: "검색 결과에서 날짜와 시간을 함께 보여주고, 지난 일정과 앞으로의 일정을 나눠보세요.\n\n일정을 누르면 해당 날짜로 이동하고, 수정은 별도 버튼으로 제공하면 탐색과 편집을 구분할 수 있습니다.", model: "선택한 모델")]
        project.threads = [thread, CodexChatThread(title: "음성 응답 점검")]
        var ideas = CodexChatProject(name: "개인 아이디어")
        ideas.threads = [CodexChatThread(title: "다음 업데이트")]
        state.projects = [project, ideas]
        let view = CodexWorkspaceView(preview: state).frame(width: 1180, height: 800).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func message(in view: NSView, matching text: String) -> NSTextView? {
            if let body = view as? NSTextView, body.string == text { return body }
            for child in view.subviews {
                if let body = message(in: child, matching: text) { return body }
            }
            return nil
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for item in thread.messages {
            guard let body = message(in: host, matching: item.text) else { throw CodexLocalError.invalid }
            precondition(body.isSelectable && !body.isEditable && body.acceptsFirstResponder)
            let source = item.text as NSString
            let selection = NSRange(location: 0, length: source.length / 2)
            body.setSelectedRange(selection)
            precondition(body.selectedRange() == selection, "Native text selection did not stick")
            precondition(body.writeSelection(to: pasteboard, types: body.writablePasteboardTypes),
                         "Native copy did not export plain text")
            precondition(pasteboard.string(forType: .string) == source.substring(with: selection))
            precondition(body.string == item.text, "Copy changed the message")
        }
        print("PASS: native user and assistant messages copy only the selected text")
        func editor(in view: NSView) -> CodexComposerTextView? {
            if let input = view as? CodexComposerTextView { return input }
            for child in view.subviews { if let found = editor(in: child) { return found } }
            return nil
        }
        guard let input = editor(in: host) else { throw CodexLocalError.invalid }
        let sample = "첫 번째 줄\n두 번째 줄"
        input.insertText(sample, replacementRange: NSRange(location: 0, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(input.string == sample && input.selectedRange().location == (sample as NSString).length,
                     "Multiline edit lost text or moved insertion point after redraw")
        var submissions = 0
        input.submit = { submissions += 1 }
        func key(_ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false, code: UInt16 = 36) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "\r",
                             charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: code)!
        }
        input.keyDown(with: key(.shift))
        precondition(submissions == 0 && input.string == sample + "\n", "Shift+Return submitted instead of inserting newline")
        input.keyDown(with: key())
        precondition(submissions == 1 && input.string == sample + "\n", "Return did not submit, or inserted newline")
        input.keyDown(with: key(repeatKey: true))
        precondition(submissions == 1, "Held Return submitted repeatedly")
        input.keyDown(with: key(code: 76))
        precondition(submissions == 2, "Keypad Enter did not submit")
        input.setMarkedText("입력중", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(input.hasMarkedText(), "IME test did not create composition")
        input.keyDown(with: key())
        precondition(submissions == 2, "Return during IME composition submitted a message")
        input.unmarkText()
        print("PASS: Return submit, Shift+Return newline, repeat suppression, keypad Enter and IME composition")
        input.selectAll(nil); input.delete(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(input.string.isEmpty, "Clearing input failed")
        print("PASS: native multiline editor binding, insertion point and clear-to-placeholder")
        if let live = try? String(contentsOfFile: "/tmp/jarvis-code-live-proposal.json", encoding: .utf8) {
            let codeRoot = scratch.appendingPathComponent("CodeProject")
            try FileManager.default.createDirectory(at: codeRoot, withIntermediateDirectories: true)
            try "let count = 1\n".write(to: codeRoot.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
            let executor = try CodexCodeFiles(root: codeRoot, confirmed: true)
            guard case .succeeded(let snapshot) = executor.snapshot("View.swift", locked: { false }) else { throw CodexCodeError.invalid }
            let proposal = try CodexCodeProposal.read(live)
            guard let plan = try executor.prepare(proposal, files: [snapshot]).first,
                  case .succeeded(let backup) = executor.apply(plan, backupDirectory: scratch.appendingPathComponent("CodeBackups"), confirmed: true, locked: { false }) else { throw CodexCodeError.invalid }
            let changed = try String(contentsOf: codeRoot.appendingPathComponent("View.swift"), encoding: .utf8)
            precondition(changed.contains("2"), "Native proposal did not reach source file")
            precondition(executor.restore(backup, confirmed: true, locked: { false }).status == .succeeded, "Native proposal undo failed")
            print("PASS: real model proposal -> deterministic Swift validation -> temporary source write -> verified backup undo")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CodexLocalError.invalid }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.representation(using: .png, properties: [:]) else { throw CodexLocalError.invalid }
        try image.write(to: URL(fileURLWithPath: "/tmp/jarvis-codex-workspace.png"))
        let panel = CodexModelSelectionPanel(models: CodexLocalModel.recommended, selected: "gpt-6.1-sol", busy: false, canRefresh: false,
                                             choose: { _ in }, refresh: {}, manual: {}).environment(\.colorScheme, .dark)
        let menuHost = NSHostingView(rootView: panel)
        menuHost.frame = NSRect(x: 0, y: 0, width: 332, height: 490)
        let menuWindow = NSWindow(contentRect: menuHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        menuWindow.contentView = menuHost; menuHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let menuBitmap = menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds) else { throw CodexLocalError.invalid }
        menuHost.cacheDisplay(in: menuHost.bounds, to: menuBitmap)
        guard let menuImage = menuBitmap.representation(using: .png, properties: [:]) else { throw CodexLocalError.invalid }
        try menuImage.write(to: URL(fileURLWithPath: "/tmp/jarvis-codex-model-menu.png"))
        let codeView = CodexCodeWorkspace(projectID: UUID(), connection: disconnected, model: "gpt-6.1-sol", effort: "low")
            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor))
        let codeHost = NSHostingView(rootView: codeView)
        codeHost.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
        let codeWindow = NSWindow(contentRect: codeHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        codeWindow.appearance = NSAppearance(named: .darkAqua)
        codeWindow.contentView = codeHost; codeHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let codeBitmap = codeHost.bitmapImageRepForCachingDisplay(in: codeHost.bounds) else { throw CodexCodeError.invalid }
        codeHost.cacheDisplay(in: codeHost.bounds, to: codeBitmap)
        guard let codeImage = codeBitmap.representation(using: .png, properties: [:]) else { throw CodexCodeError.invalid }
        try codeImage.write(to: URL(fileURLWithPath: "/tmp/jarvis-code-editor.png"))
    }
}
