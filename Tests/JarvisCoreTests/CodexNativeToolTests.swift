import XCTest
@testable import JarvisCore

final class CodexNativeToolTests: XCTestCase {
    func testEveryInvocationRequiresFreshConfirmationAndLockWins() {
        let policy = SafetyPolicyEngine()
        guard case .requireConfirmation = policy.evaluate(.codexLocal(.nativeTool), context: .init()) else {
            return XCTFail("Native execution must require confirmation")
        }
        guard case .allow = policy.evaluate(.codexLocal(.nativeTool), context: .init(wasExplicitlyConfirmed: true)) else {
            return XCTFail("Explicit execution approval was rejected")
        }
        guard case .block = policy.evaluate(.codexLocal(.nativeTool), context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
            return XCTFail("Lock must override approval")
        }
    }
    func testCommandAndMCPHaveDisjointValidatedSchemas() throws {
        try CodexNativeToolRequest(operation: .command, root: "/tmp/project", command: ["/usr/bin/git", "status"]).validate()
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .command, root: "/", command: ["pwd"]).validate())
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .command, root: "/tmp/project", command: []).validate())
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .command, root: "/tmp/project", command: ["pwd"], tool: "arbitrary").validate())
        let server = CodexNativeToolRequest.Server(command: "/usr/bin/python3", args: ["server.py"])
        try CodexNativeToolRequest(operation: .mcpCall, root: "/tmp/project", server: server, tool: "echo", arguments: "{\"text\":\"hello\"}").validate()
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .mcpCall, root: "/tmp/project", server: server, tool: "echo", arguments: "[]").validate())
    }
    func testPluginManifestCannotSilentlyImportCredentialsOrHooks() throws {
        let manifest = Data(#"{"mcpServers":{"example":{"command":"python3","args":["server.py"]}}}"#.utf8)
        XCTAssertEqual(try CodexNativeToolRequest.pluginServers(manifest)["example"]?.args, ["server.py"])
        XCTAssertThrowsError(try CodexNativeToolRequest.pluginServers(Data(#"{"mcpServers":{"bad":{"command":"python3","env":{"TOKEN":"secret"}}}}"#.utf8)))
        XCTAssertThrowsError(try CodexNativeToolRequest.pluginServers(Data(#"{"mcpServers":{"bad":{"command":"python3","args":"bad"}}}"#.utf8)))
    }
    func testReplacedProjectCannotReuseReviewedExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CodexNativeToolRequest(operation: .command, root: root.path, command: ["/usr/bin/printf", ""])
        XCTAssertNoThrow(try request.encodedInput())
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try request.encodedInput())
    }
    func testUnconfirmedAndLockedClientsNeverReachNativeTransport() async throws {
        let descriptor: [String: Any] = ["format": 1, "port": 54321,
            "sessionID": UUID().uuidString, "token": String(repeating: "a", count: 64)]
        let connection = try CodexLocalConnection.read(JSONSerialization.data(withJSONObject: descriptor))
        let request = CodexNativeToolRequest(operation: .command, root: "/tmp/project", command: ["pwd"])
        let client = CodexLocalClient()
        let unconfirmed = await client.perform(.nativeTool, connection: connection, id: UUID(),
                                               backend: .appServer, native: request, locked: { false })
        guard case .needsConfirmation = unconfirmed else { return XCTFail("Unconfirmed tool reached transport") }
        let locked = await client.perform(.nativeTool, connection: connection, id: UUID(), confirmed: true,
                                          backend: .appServer, native: request, locked: { true })
        guard case .failed = locked else { return XCTFail("Lock failed to stop transport") }
        XCTAssertThrowsError(try connection.request(.nativeTool, id: UUID(), native: request))
    }
}

extension CodexNativeToolTests {
    func testHTTPMCPAndPluginSelectorsAreBounded() throws {
        try CodexNativeToolRequest(operation: .mcpLogin, root: "/tmp/project", server: .init(url: "https://example.com/mcp")).validate()
        for url in ["http://example.com/mcp", "https://user:secret@example.com/mcp", "https://example.com/?token=x"] {
            XCTAssertThrowsError(try CodexNativeToolRequest(operation: .mcpList, root: "/tmp/project", server: .init(url: url)).validate())
        }
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .mcpLogin, root: "/tmp/project", server: .init(command: "python3")).validate())
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .gitDiff, root: "/tmp/project", command: ["../secret"]).validate())
        XCTAssertThrowsError(try CodexNativeToolRequest(operation: .pluginAdd, root: "/tmp/project", command: ["bad;command"]).validate())
        let manifest = Data(#"{"mcpServers":{"remote":{"url":"https://example.com/mcp","type":"http"}}}"#.utf8)
        XCTAssertEqual(try CodexNativeToolRequest.pluginServers(manifest)["remote"]?.url, "https://example.com/mcp")
    }
    func testDiagnosticsOnlyLinkInventoryFiles() {
        let output = "/tmp/project/View.swift:12:4: error: invalid\nView.swift:12: warning\n../secret:4: error\nhttps://bad.example:8: error\nOther.swift:9: error"
        let locations = CodexBuildLocation.parse(output, paths: ["View.swift"], root: "/tmp/project")
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.path, "View.swift")
        XCTAssertEqual(locations.first?.line, 12)
    }
    func testDocumentsImagesAndExportRespectPolicyAndBounds() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let file = CodexChatDocument(name: "안내.txt", text: "내용")
        let request = try CodexChatRequest(model: "test-model", message: "설명해줘", messages: [], images: [jpeg, jpeg], documents: [file])
        XCTAssertEqual(request.images.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(CodexChatRequest.Input.self, from: Data(request.input.utf8)).documents, [file])
        XCTAssertThrowsError(try CodexChatRequest(model: "test-model", message: "요약", messages: [], images: Array(repeating: jpeg, count: 5)))
        XCTAssertThrowsError(try CodexChatRequest(model: "test-model", message: "요약", messages: [], documents: Array(repeating: file, count: 5)))
        XCTAssertThrowsError(try CodexChatDocument(name: "bad.txt", text: String(repeating: "a", count: 16385)).validate())
        for action in [CodexLocalAction.attachmentRead, .workspaceExport] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init()) else { return XCTFail("Missing confirmation") }
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(wasExplicitlyConfirmed: true)) else { return XCTFail("Approval rejected") }
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail("Lock bypassed") }
        }
    }
}

extension CodexNativeToolTests {
    private func agentCall(_ name: String, _ arguments: [String: Any]) throws -> CodexAgentCall {
        let value: [String: Any] = ["approvalID": UUID().uuidString, "callID": "call", "threadID": "thread", "turnID": "turn", "tool": name,
                                  "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self), "expiresAt": Date().timeIntervalSince1970 + 120]
        return try JSONDecoder().decode(CodexAgentCall.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testAgentHostToolSchemasRejectPolicyEditsShellTraversalAndBooleans() throws {
        XCTAssertEqual(CapabilityRegistry.codexAgentTools.count, 10)
        XCTAssertNoThrow(try agentCall("jarvis_project_read", ["path":"View.swift", "startLine":1, "lineCount":20]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_project_read", ["path":"../secret.txt", "startLine":1, "lineCount":20]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_project_read", ["path":"View.swift", "startLine":true, "lineCount":20]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_project_edit", ["path":"SafetyPolicy.swift", "old":"a", "new":"b"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_project_verify", ["argv":["sh","-c","touch example"], "purpose":"run"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("native_shell", [:]).validatedArguments())
    }
    func testAgentControlSafetyAndStopUnderLock() {
        for action in [CodexLocalAction.agentStart, .agentRespond, .agentSteer] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init()) else { return XCTFail("Missing approval") }
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(wasExplicitlyConfirmed: true)) else { return XCTFail("Approved action denied") }
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail("Lock bypass") }
        }
        guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.agentStop), context: .init(externalActionsLocked: true)) else { return XCTFail("Stop blocked") }
    }
    func testAgentSnapshotsRejectCrossTurnApprovalAndDuplicateEvents() throws {
        let call = try agentCall("jarvis_project_list", [:])
        let pending: [String: Any] = ["approvalID":call.approvalID.uuidString, "callID":"call", "threadID":"thread", "turnID":"wrong", "tool":call.tool, "arguments":"{}", "expiresAt":Date().timeIntervalSince1970 + 120]
        var object: [String:Any] = ["agentVersion":1, "jobID":UUID().uuidString, "state":"awaitingApproval", "threadID":"thread", "turnID":"turn", "reply":"", "pending":pending, "events":[]]
        func decode(_ object: [String:Any]) throws -> CodexAgentSnapshot { try CodexAgentSnapshot.read(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
        XCTAssertThrowsError(try decode(object))
        object["pending"] = NSNull(); object["state"] = "running"
        XCTAssertNoThrow(try decode(object))
        object["events"] = [["sequence":1,"kind":"started","text":"start"], ["sequence":1,"kind":"started","text":"duplicate"]]
        XCTAssertThrowsError(try decode(object))
    }
}

extension CodexNativeToolTests {
    func testAgentProfileRoundtripAndCredentialBoundaries() throws {
        var profile = CodexAgentProfile()
        profile.extensions = [.init(name:"검색 서버",server:.init(url:"https://example.com/mcp"),allowedTools:["search"])]
        profile.skills = [.init(document:.init(name:"SKILL.md",text:"검토한 참고 자료"))]
        profile.webSearchEnabled = true
        let data = try profile.encoded()
        XCTAssertEqual(try CodexAgentProfile.read(data),profile)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("apiKey"))
        profile.extensions[0].server = .init(command:"server",args:["--token","do-not-store"])
        XCTAssertThrowsError(try profile.encoded())
        profile.extensions = []
        profile.skills[0].document = .init(name:"SKILL.md",text:"tvly-" + String(repeating:"x",count:24))
        XCTAssertThrowsError(try profile.encoded())
    }
    func testExtensionToolsRejectUnknownIDsAndArbitraryArguments() throws {
        XCTAssertNoThrow(try agentCall("jarvis_extension_list",[:]).validatedArguments())
        XCTAssertNoThrow(try agentCall("jarvis_extension_inspect",["extensionID":UUID().uuidString]).validatedArguments())
        XCTAssertNoThrow(try agentCall("jarvis_extension_call",["extensionID":UUID().uuidString,"tool":"search","arguments":"{\"query\":\"test\"}"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_extension_call",["extensionID":"../other","tool":"search","arguments":"{}"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_extension_call",["extensionID":UUID().uuidString,"tool":"search","arguments":"[]"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_skill_read",["skillID":"invalid"]).validatedArguments())
        XCTAssertThrowsError(try agentCall("jarvis_web_search",["query":String(repeating:"x",count:2001)]).validatedArguments())
    }
    func testHistoryAndExtensionConfigurationRequireSpecificApprovalAndRespectLock() {
        for action in [CodexLocalAction.agentHistoryChange,.agentConfigureExtensions] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(.codexLocal(action),context:.init()) else { return XCTFail("Missing approval") }
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action),context:.init(wasExplicitlyConfirmed:true)) else { return XCTFail("Approval rejected") }
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action),context:.init(externalActionsLocked:true,wasExplicitlyConfirmed:true)) else { return XCTFail("Lock bypass") }
        }
    }
    func testAgentSessionMetadataIsOptionalAndBoundedForLegacyWorkspaces() throws {
        var workspace = CodexChatWorkspace()
        var project = CodexChatProject(name:"Project")
        var thread = CodexChatThread(title:"Chat",model:"test-model")
        project.threads = [thread]; workspace.projects = [project]
        let data = try workspace.encoded()
        XCTAssertNil(try JSONDecoder().decode(CodexChatWorkspace.self,from:data).projects[0].threads[0].agentTurnID)
        thread.agentTurnID = String(repeating:"a",count:129);workspace.projects[0].threads = [thread]
        XCTAssertThrowsError(try workspace.encoded())
    }
}
