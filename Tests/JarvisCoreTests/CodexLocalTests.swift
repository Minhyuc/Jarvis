import XCTest
@testable import JarvisCore

final class CodexLocalTests: XCTestCase {
    func testChatImageIsScopedToAppServerAndRequiresSelectionUnderPolicy() throws {
        let connection = try CodexLocalConnection.read(data())
        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        let chat = try CodexChatRequest(model: "test-model", message: "이미지 설명", messages: [],
                                       conversationID: UUID(), image: image)
        XCTAssertThrowsError(try connection.request(.chat, id: UUID(), chat: chat))
        let request = try connection.request(.chat, id: UUID(), chat: chat, backend: .appServer)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["imageJPEG"], image.base64EncodedString())
        XCTAssertNil(body["path"])
        XCTAssertThrowsError(try CodexChatRequest(model: "test-model", message: "이미지 설명", messages: [],
                                                 image: Data([1, 2, 3, 4])))
        let intent = AssistantIntent.codexLocal(.chatImageRead)
        let policy = SafetyPolicyEngine()
        guard case .requireConfirmation = policy.evaluate(intent, context: .init()),
              case .allow = policy.evaluate(intent, context: .init(wasExplicitlyConfirmed: true)),
              case .block = policy.evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
            return XCTFail("Image selection must be explicit and respect the emergency lock")
        }
    }

    func testSteeringRequiresExplicitConsentAndLockTakesPrecedence() {
        let intent = AssistantIntent.codexLocal(.steer)
        let policy = SafetyPolicyEngine()
        guard case .requireConfirmation = policy.evaluate(intent, context: .init()) else {
            return XCTFail("Expected explicit confirmation")
        }
        guard case .allow = policy.evaluate(intent, context: .init(wasExplicitlyConfirmed: true)) else {
            return XCTFail("Expected approved steering")
        }
        guard case .block = policy.evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
            return XCTFail("Expected emergency lock to block steering")
        }
        XCTAssertTrue(CodexTurnInput.valid("테스트도 포함해줘"))
        XCTAssertFalse(CodexTurnInput.valid("  "))
        XCTAssertFalse(CodexTurnInput.valid(String(repeating: "가", count: 601)))
    }
    func testQuotaValidationAndReadOnlySafety() throws {
        let connection = try CodexLocalConnection.read(JSONSerialization.data(withJSONObject: ["format": 1, "port": 54321, "sessionID": UUID().uuidString, "token": String(repeating: "a", count: 64)]))
        let id = UUID()
        var object: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString, "requestID": id.uuidString, "status": "succeeded", "protocolVersion": 3, "backend": "appServer",
            "quota": ["checkedAt": 1790000000, "primary": ["usedPercent": 26, "windowDurationMins": 300, "resetsAt": 1900000000]]]
        func parse() throws -> CodexLocalReply { try .validated(JSONSerialization.data(withJSONObject: object), connection: connection, id: id, action: .usage, backend: .appServer) }
        XCTAssertEqual(try parse().quota?.primary?.remaining, 74)
        object["quota"] = ["checkedAt": 1790000000, "primary": ["usedPercent": 101]]
        XCTAssertThrowsError(try parse())
        object.removeValue(forKey: "quota")
        XCTAssertNil(try parse().quota)
        XCTAssertEqual(try connection.request(.usage, id: id, backend: .appServer).url?.path, "/usage")
        guard case .allow(let risk, _) = SafetyPolicyEngine().evaluate(.codexLocal(.usage), context: .init()) else { return XCTFail() }
        XCTAssertEqual(risk, .informational)
        guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(.usage), context: .init(externalActionsLocked: true)) else { return XCTFail() }
    }
    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["format": 1, "port": 53421, "sessionID": UUID().uuidString,
                                   "token": String(repeating: "a", count: 64)]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testDescriptorIsStrictLocalBoundedAndRedacted() throws {
        let value = try CodexLocalConnection.read(data())
        let request = try value.request(.probe, id: UUID())
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.path, "/probe")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["requestID", "sessionID", "prompt"])
        XCTAssertEqual(body["prompt"], CodexLocalProbe.text)
        XCTAssertFalse(value.description.contains(String(repeating: "a", count: 64)))
        for changes: [String: Any] in [["port": 80], ["port": 65536], ["format": 2], ["token": "bad"],
            ["host": "example.com"], ["endpoint": "http://example.com"], ["prompt": "run"], ["apiKey": "fake"]] {
            XCTAssertThrowsError(try CodexLocalConnection.read(data(changes)))
        }
        XCTAssertThrowsError(try CodexLocalConnection.read(Data(repeating: 0, count: 4097)))
        XCTAssertThrowsError(try value.request(.configure, id: UUID()))
        XCTAssertThrowsError(try value.request(.serviceStart, id: UUID()))
        XCTAssertThrowsError(try value.request(.serviceStop, id: UUID()))
    }
    func testLocalProbeAndConnectionAlwaysNeedApprovalAndLockWins() {
        for action in [CodexLocalAction.configure, .serviceStart, .loginStart, .logout, .probe, .chat, .workspaceDelete, .codeConnect, .codeDraft, .codeApply, .codeRestore] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init()) else { return XCTFail() }
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(wasExplicitlyConfirmed: true)) else { return XCTFail() }
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail() }
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(origin: .proactiveSuggestion, wasExplicitlyConfirmed: true)) else { return XCTFail() }
        }
        for action in [CodexLocalAction.status, .models, .workspaceRead, .workspaceEdit, .selectBackend, .configureRecovery, .loginPoll, .diagnostics, .codeRead] {
            guard case .block = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: true)) else { return XCTFail() }
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init()) else { return XCTFail() }
        }
        for action in [CodexLocalAction.cancel, .disconnect, .serviceStop, .loginCancel] {
            guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: true)) else { return XCTFail() }
        }
        XCTAssertNil(SemanticCapabilityID(rawValue: "codexLocal"))
    }
    func testRepliesMustMatchCurrentConnectionAndRequestAndBeBounded() throws {
        let connection = try CodexLocalConnection.read(data()), request = UUID()
        var object: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString,
            "requestID": request.uuidString, "status": "succeeded", "reply": "가상 응답"]
        func parse() throws -> CodexLocalReply {
            try .validated(JSONSerialization.data(withJSONObject: object), connection: connection, id: request, action: .probe)
        }
        XCTAssertEqual(try parse().reply, "가상 응답")
        object["sessionID"] = UUID().uuidString; XCTAssertThrowsError(try parse())
        object["sessionID"] = connection.sessionID.uuidString
        object["requestID"] = UUID().uuidString; XCTAssertThrowsError(try parse())
        object["requestID"] = request.uuidString
        object["reply"] = ""; XCTAssertThrowsError(try parse())
        object["reply"] = String(repeating: "x", count: 8193); XCTAssertThrowsError(try parse())
        object["reply"] = "가상 응답"; object["status"] = "unknown"; XCTAssertThrowsError(try parse())
    }
    func testClientDoesNotSendUnapprovedLockedOrCancelledRequests() async throws {
        let client = CodexLocalClient(), connection = try CodexLocalConnection.read(data())
        let no = await client.perform(.probe, connection: connection, id: UUID(), locked: { false })
        XCTAssertEqual(no.status, .needsConfirmation)
        let blocked = await client.perform(.probe, connection: connection, id: UUID(), confirmed: true, locked: { true })
        XCTAssertEqual(blocked.status, .failed)
        let chat = try CodexChatRequest(model: "test-model", message: "테스트", messages: [])
        let unapprovedChat = await client.perform(.chat, connection: connection, id: UUID(), chat: chat, locked: { false })
        XCTAssertEqual(unapprovedChat.status, .needsConfirmation)
        let lockedChat = await client.perform(.chat, connection: connection, id: UUID(), confirmed: true, chat: chat, locked: { true })
        XCTAssertEqual(lockedChat.status, .failed)
        let invalidNative = await client.perform(.chat, connection: connection, id: UUID(), confirmed: true, chat: chat, backend: .appServer, locked: { false })
        XCTAssertEqual(invalidNative.status, .failed)
        let task = Task {
            await Task.yield()
            return await client.perform(.status, connection: connection, id: UUID(), locked: { false })
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.status, .failed)
    }

    func testChatRequestHasNarrowSchemaAndOnlySuccessfulLocalConversationPairs() throws {
        let messages: [CodexChatMessage] = [
            .init(role: .user, text: "내 별명은 파랑"), .init(role: .assistant, text: "알겠습니다"),
            .init(role: .user, text: "전송 실패한 비밀", state: .interrupted),
            .init(role: .notice, text: "실패"), .init(role: .assistant, text: "짝이 없는 답변"),
            .init(role: .user, text: "대기중인 입력", state: .pending)]
        let chat = try CodexChatRequest(model: "test-model", message: "내 별명이 뭐야?", messages: messages)
        let decoded = try JSONDecoder().decode(CodexChatRequest.Input.self, from: Data(chat.input.utf8))
        XCTAssertEqual(decoded.turns.count, 1)
        XCTAssertEqual(decoded.turns[0].user, "내 별명은 파랑")
        XCTAssertFalse(chat.input.contains("비밀")); XCTAssertFalse(chat.input.contains("대기중"))
        let fresh = try CodexChatRequest(model: "other-model", message: "질문", messages: [])
        XCTAssertFalse(fresh.input.contains("파랑"))
        let connection = try CodexLocalConnection.read(data())
        let request = try connection.request(.chat, id: UUID(), chat: chat)
        XCTAssertEqual(request.url?.path, "/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["requestID", "sessionID", "model", "input", "effort"])
        XCTAssertEqual(body["effort"], "low")
        XCTAssertEqual(body["model"], "test-model")
        XCTAssertThrowsError(try connection.request(.chat, id: UUID()))
        XCTAssertThrowsError(try connection.request(.status, id: UUID(), chat: chat))
        for invalid in ["", "--model", "../secret", "model name", "model\ncommand"] {
            XCTAssertThrowsError(try CodexChatRequest(model: invalid, message: "질문", messages: []))
        }
        XCTAssertThrowsError(try CodexChatRequest(model: "test", message: " ", messages: []))
        XCTAssertThrowsError(try CodexChatRequest(model: "test", message: String(repeating: "가", count: 2001), messages: []))
    }

    func testChatContextAndWorkspaceStorageAreBoundedAndInterruptedRequestsDoNotResume() throws {
        var messages: [CodexChatMessage] = []
        for index in 0..<20 {
            messages += [.init(role: .user, text: "질문 \(index)" + String(repeating: "가", count: 1000)),
                         .init(role: .assistant, text: String(repeating: "나", count: 2000))]
        }
        let chat = try CodexChatRequest(model: "test-model", message: "그럼 자세히", messages: messages)
        XCTAssertLessThanOrEqual(chat.input.utf8.count, 24_576)
        let payload = try JSONDecoder().decode(CodexChatRequest.Input.self, from: Data(chat.input.utf8))
        XCTAssertLessThanOrEqual(payload.turns.count, 6)
        var workspace = CodexChatWorkspace(), project = CodexChatProject(name: "프로젝트")
        var thread = CodexChatThread(model: "test-model")
        thread.messages = [.init(role: .user, text: "대기", state: .pending)]
        project.threads = [thread]; workspace.projects = [project]
        let recovered = try CodexChatWorkspace.read(workspace.encoded())
        XCTAssertEqual(recovered.projects[0].threads[0].messages[0].state, .interrupted)
        workspace.projects[0].threads.append(thread)
        XCTAssertThrowsError(try workspace.encoded())
        workspace.projects = Array(repeating: project, count: 21)
        XCTAssertThrowsError(try workspace.encoded())
        XCTAssertThrowsError(try CodexChatWorkspace.read(Data(repeating: 0, count: 8_388_609)))
    }

    func testModelCatalogRejectsInvalidOrDuplicateIDsAndChatNeedsNonemptyReply() throws {
        let connection = try CodexLocalConnection.read(data()), id = UUID()
        var object: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString,
            "requestID": id.uuidString, "status": "succeeded", "models": [["id": "test-model", "name": "Test"]]]
        func parse(_ action: CodexLocalAction = .models) throws -> CodexLocalReply {
            try .validated(JSONSerialization.data(withJSONObject: object), connection: connection, id: id, action: action)
        }
        XCTAssertEqual(try parse().models?.first?.id, "test-model")
        XCTAssertThrowsError(try parse(.chat))
        object["models"] = [["id": "bad value", "name": "Test"]]
        XCTAssertThrowsError(try parse())
        object["models"] = Array(repeating: ["id": "test-model", "name": "Test"], count: 2)
        XCTAssertThrowsError(try parse())
    }

    func testReasoningSelectionSurvivesEncodingAndOldWorkspaceStillLoads() throws {
        let request = try CodexChatRequest(model: "test-model", message: "질문", messages: [], effort: "high")
        let connection = try CodexLocalConnection.read(data())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: connection.request(.chat, id: UUID(), chat: request).httpBody!) as? [String: String])
        XCTAssertEqual(body["effort"], "high")
        XCTAssertThrowsError(try CodexChatRequest(model: "test-model", message: "질문", messages: [], effort: "high\"; run"))
        let old: [String: Any] = ["version": 1, "projects": [["id": UUID().uuidString, "name": "기존 프로젝트", "threads": [["id": UUID().uuidString, "title": "기존 대화", "model": "test-model", "messages": []]]]]]
        var workspace = try CodexChatWorkspace.read(JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(workspace.preferredModel); XCTAssertNil(workspace.projects[0].threads[0].effort)
        workspace.preferredModel = "test-model"; workspace.preferredEffort = "high"
        workspace.projects[0].threads[0].effort = "high"
        let recovered = try CodexChatWorkspace.read(workspace.encoded())
        XCTAssertEqual(recovered.preferredEffort, "high")
        XCTAssertEqual(recovered.projects[0].threads[0].effort, "high")
        workspace.preferredEffort = "unknown"; XCTAssertThrowsError(try workspace.encoded())
    }
    func testRecommendedModelsAreAvailableWithoutHelperAndMergeMetadataWithoutDuplicates() {
        let base = CodexLocalModel.catalog(merging: [])
        XCTAssertEqual(base.count, 8)
        XCTAssertEqual(base.first?.name, "GPT-6.1 Sol")
        XCTAssertTrue(base.allSatisfy { CodexLocalModel.validID($0.id) })
        let result = CodexLocalModel.catalog(merging: [
            .init(id: "gpt-6.1-sol", name: "CLI display", reasoningEfforts: ["low", "high"]),
            .init(id: "custom-model", name: "Custom"), .init(id: "custom-model", name: "Duplicate"),
            .init(id: "--bad", name: "Invalid")])
        XCTAssertEqual(result.first?.name, "GPT-6.1 Sol")
        XCTAssertEqual(result.first?.reasoningEfforts, ["low", "high"])
        XCTAssertEqual(result.filter { $0.id == "custom-model" }.count, 1)
        XCTAssertFalse(result.contains { $0.id == "--bad" })
        XCTAssertLessThanOrEqual(CodexLocalModel.catalog(merging: (0..<100).map { .init(id: "model-\($0)", name: "Model") }).count, 40)
    }
    func testOldHelperLoginCannotAuthorizeChatAndLocalRejectionsAreNotUnknownExecution() throws {
        let connection = try CodexLocalConnection.read(data()), id = UUID()
        var object: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString,
                                  "requestID": id.uuidString, "status": "succeeded"]
        func reply() throws -> CodexLocalReply {
            try .validated(JSONSerialization.data(withJSONObject: object), connection: connection, id: id, action: .status)
        }
        XCTAssertTrue(try reply().requiresUpdate(for: .status))
        XCTAssertTrue(try reply().requiresUpdate(for: .chat))
        XCTAssertFalse(try reply().requiresUpdate(for: .cancel))
        object["protocolVersion"] = 1; XCTAssertTrue(try reply().requiresUpdate(for: .status))
        object["protocolVersion"] = 2; XCTAssertFalse(try reply().requiresUpdate(for: .status))
        object["protocolVersion"] = 3; object["backend"] = "cli"
        XCTAssertFalse(try reply().requiresUpdate(for: .status))
        object["protocolVersion"] = 4; XCTAssertTrue(try reply().requiresUpdate(for: .status))
        for code in [400, 401, 403, 404, 405] {
            let result = try XCTUnwrap(CodexLocalClient.rejection(for: code))
            XCTAssertNotEqual(result.status, .unverifiable)
            XCTAssertNotEqual(result.status, .succeeded)
        }
        XCTAssertNil(CodexLocalClient.rejection(for: 200))
        XCTAssertNil(CodexLocalClient.rejection(for: 500))
    }
    func testAppServerRequestsAreExplicitlyScopedAndBackendCannotSilentlyChange() throws {
        let connection = try CodexLocalConnection.read(data()), id = UUID(), conversation = UUID()
        let payload = try CodexChatRequest(model: "test-model", message: "질문", messages: [], conversationID: conversation)
        let request = try connection.request(.chat, id: id, chat: payload, backend: .appServer)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
        XCTAssertEqual(body["backend"], "appServer")
        XCTAssertEqual(body["conversationID"], conversation.uuidString)
        XCTAssertNil(body["cwd"]); XCTAssertNil(body["method"])
        XCTAssertThrowsError(try connection.request(.chat, id: id, chat: CodexChatRequest(model: "test-model", message: "질문", messages: []), backend: .appServer))
        let object: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString, "requestID": id.uuidString,
            "status": "succeeded", "reply": "답변", "protocolVersion": 3, "backend": "appServer"]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let reply = try CodexLocalReply.validated(bytes, connection: connection, id: id, action: .chat, backend: .appServer)
        XCTAssertFalse(reply.requiresUpdate(for: .chat, backend: .appServer))
        XCTAssertThrowsError(try CodexLocalReply.validated(bytes, connection: connection, id: id, action: .chat, backend: .cli))
    }
}
