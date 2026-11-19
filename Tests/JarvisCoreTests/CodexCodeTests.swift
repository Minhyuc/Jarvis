import XCTest
@testable import JarvisCore

final class CodexCodeTests: XCTestCase {
    private var directory: URL!
    private var root: URL!
    private var backups: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-code-test-" + UUID().uuidString)
        root = directory.appendingPathComponent("Project"); backups = directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "let title = \"안녕 🌏\"\nlet count = 1\n".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func engine() throws -> CodexCodeFiles { try CodexCodeFiles(root: root, confirmed: true) }
    private func snapshot(_ e: CodexCodeFiles, path: String = "View.swift", line: Int = 1, count: Int = 200) throws -> CodexCodeFile {
        guard case .succeeded(let file) = e.snapshot(path, startLine: line, lineCount: count, locked: { false }) else { throw CodexCodeError.invalid }
        return file
    }
    private func proposal(path: String = "View.swift", old: String? = "let count = 1", new: String = "let count = 2") throws -> CodexCodeProposal {
        let object: [String: Any] = ["summary": "합성 변경", "edits": [["path": path, "old": old as Any? ?? NSNull(), "new": new]]]
        return try .read(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    func testInventoryRejectsReplacementProjectInsteadOfReturningItsFiles() throws {
        let connected = try engine()
        guard case .succeeded(let original) = connected.inventory(locked: { false }) else {
            return XCTFail("Original folder should be readable")
        }
        XCTAssertEqual(original, ["View.swift"])
        try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try "replacement".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        guard case .failed = connected.inventory(locked: { false }) else {
            return XCTFail("Listing a replacement folder requires a fresh connection")
        }
    }

    func testProjectMetadataIsReadableWithoutExpandingWriteAccess() {
        XCTAssertTrue(CodexCodePolicy.readable("Makefile"))
        XCTAssertTrue(CodexCodePolicy.readable("앱/App.xcodeproj/project.pbxproj"))
        XCTAssertFalse(CodexCodePolicy.writable("앱/App.xcodeproj/project.pbxproj"))
        XCTAssertFalse(CodexCodePolicy.readable(".git/README"))
        XCTAssertFalse(CodexCodePolicy.readable("시스템/README"))
    }
    func testApplyAndPersistedRestoreVerifyExactUnicodeAndDirtyFileContent() throws {
        let e = try engine(), file = try snapshot(e), plan = try XCTUnwrap(e.prepare(proposal(), files: [file]).first)
        guard case .succeeded(let backup) = e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }) else { return XCTFail("apply") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), file.fullText.replacingOccurrences(of: "count = 1", with: "count = 2"))
        XCTAssertEqual(e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }).status, .failed)
        let reopened = try engine()
        guard case .succeeded(let records) = reopened.backups(directory: backups, locked: { false }) else { return XCTFail() }
        XCTAssertEqual(records.map(\.id), [backup.id])
        XCTAssertEqual(reopened.restore(records[0], confirmed: true, locked: { false }).status, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), file.fullText)
    }
    func testApprovalLockAndCancelNeverWriteOrCreateBackup() throws {
        let e = try engine(), file = try snapshot(e), plan = try XCTUnwrap(e.prepare(proposal(), files: [file]).first)
        XCTAssertEqual(e.apply(plan, backupDirectory: backups, confirmed: false, locked: { false }).status, .needsConfirmation)
        XCTAssertEqual(e.apply(plan, backupDirectory: backups, confirmed: true, locked: { true }).status, .failed)
        XCTAssertEqual(e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }, cancelled: { true }).status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), file.fullText)
        XCTAssertEqual(e.snapshot("View.swift", locked: { true }).status, .failed)
    }
    func testConcurrentExternalEditAndStaleBackupCannotOverwriteNewWork() throws {
        let e = try engine(), file = try snapshot(e), plan = try XCTUnwrap(e.prepare(proposal(), files: [file]).first)
        try "user edit".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }).status, .failed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), "user edit")
        try file.fullText.write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        guard case .succeeded(let backup) = e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }) else { return XCTFail() }
        try "later edit".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(e.restore(backup, confirmed: true, locked: { false }).status, .failed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), "later edit")
    }
    func testNewFileNoOverwriteAndUndoOnlyItsOwnContent() throws {
        let e = try engine(), plan = try XCTUnwrap(e.prepare(proposal(path: "NewView.swift", old: nil, new: "let newValue = 1\n"), files: []).first)
        guard case .succeeded(let backup) = e.apply(plan, backupDirectory: backups, confirmed: true, locked: { false }) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("NewView.swift").path))
        XCTAssertEqual(e.restore(backup, confirmed: false, locked: { false }).status, .needsConfirmation)
        XCTAssertEqual(e.restore(backup, confirmed: true, locked: { false }).status, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NewView.swift").path))
    }
    func testTraversalSymlinkHardlinkAndProtectedFilesAreRejected() throws {
        let e = try engine()
        let outside = directory.appendingPathComponent("Outside.swift")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.swift"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: outside, to: root.appendingPathComponent("Hard.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: directory)
        for path in ["../Outside.swift", "Link.swift", "Hard.swift", "Linked/Outside.swift", "/tmp/Outside.swift"] {
            XCTAssertNotEqual(e.snapshot(path, locked: { false }).status, .succeeded)
        }
        for path in ["AGENTS.md", "Sources/JarvisCore/SafetyPolicy.swift", "JarvisMac/CodexCodeWorkspace.swift", "Tools/new.py", "Package.swift", "config.json", "알람/foo.swift", "View\u{202e}.swift"] {
            XCTAssertThrowsError(try proposal(path: path))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
    }
    func testOnlyVisibleCodeRangesAreSentAndMayBeChanged() throws {
        let e = try engine(), file = try snapshot(e, line: 2, count: 1)
        let request = CodexCodeRequest(model: "test-model", effort: "low", instruction: "카운트 변경", files: [file], tree: ["View.swift"])
        let input = try request.encodedInput()
        XCTAssertTrue(input.contains("let count")); XCTAssertFalse(input.contains("안녕")); XCTAssertFalse(input.contains(root.path))
        XCTAssertThrowsError(try e.prepare(proposal(old: "let title = \"안녕 🌏\""), files: [file]))
        XCTAssertThrowsError(try e.prepare(proposal(), files: [file], locked: { true }))
        let connection = try CodexLocalConnection.read(JSONSerialization.data(withJSONObject: ["format": 1, "port": 54321, "sessionID": UUID().uuidString, "token": String(repeating: "a", count: 64)]))
        XCTAssertThrowsError(try connection.request(.codeDraft, id: UUID(), code: request))
        let wire = try connection.request(.codeDraft, id: UUID(), backend: .appServer, code: request)
        XCTAssertEqual(wire.url?.path, "/codeDraft")
        XCTAssertFalse(String(decoding: wire.httpBody!, as: UTF8.self).contains(root.path))
    }
    func testAmbiguousAndOverlappingEditsAndExpiredPlansAreRejected() throws {
        let e = try engine()
        try "let n = 1\nlet n = 1\n".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try e.prepare(proposal(old: "let n = 1"), files: [try snapshot(e)]))
        try "let n = 1\n".write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        let object: [String: Any] = ["summary": "overlap", "edits": [["path": "View.swift", "old": "let n = 1", "new": "let n = 2"], ["path": "View.swift", "old": "n = 1", "new": "n = 3"]]]
        let parsed = try CodexCodeProposal.read(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        XCTAssertThrowsError(try e.prepare(parsed, files: [try snapshot(e)]))
        let expired = try XCTUnwrap(e.prepare(proposal(old: "let n = 1"), files: [try snapshot(e)], now: Date().addingTimeInterval(-601)).first)
        XCTAssertEqual(e.apply(expired, backupDirectory: backups, confirmed: true, locked: { false }).status, .failed)
    }
    func testSecretFileAndUnknownProposalKeysNeverEnterWire() throws {
        let e = try engine()
        try ("let value = \"sk-" + String(repeating: "A", count: 40) + "\"").write(to: root.appendingPathComponent("View.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(e.snapshot("View.swift", locked: { false }).status, .failed)
        XCTAssertThrowsError(try CodexCodeProposal.read("{\"summary\":\"x\",\"edits\":[],\"command\":\"anything\"}"))
    }
    func testLockAtCommitAndReconnectCannotReusePlan() throws {
        let e = try engine(), file = try snapshot(e), plan = try XCTUnwrap(e.prepare(proposal(), files: [file]).first)
        var checks = 0
        let result = e.apply(plan, backupDirectory: backups, confirmed: true, locked: { checks += 1; return checks >= 3 })
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("View.swift"), encoding: .utf8), file.fullText)
        XCTAssertEqual(try engine().apply(plan, backupDirectory: backups, confirmed: true, locked: { false }).status, .failed)
    }
    func testCodeResponseRequiresNewNarrowProtocolAndNoGeneralChatReuse() throws {
        let connection = try CodexLocalConnection.read(JSONSerialization.data(withJSONObject: ["format": 1, "port": 54321, "sessionID": UUID().uuidString, "token": String(repeating: "a", count: 64)]))
        let id = UUID()
        var value: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString, "requestID": id.uuidString, "status": "succeeded", "backend": "appServer", "protocolVersion": 3,
            "reply": "{\"summary\":\"x\",\"edits\":[{\"path\":\"View.swift\",\"old\":\"let count = 1\",\"new\":\"let count = 2\"}]}"]
        func parsed() throws -> CodexLocalReply { try .validated(JSONSerialization.data(withJSONObject: value), connection: connection, id: id, action: .codeDraft, backend: .appServer) }
        XCTAssertTrue(try parsed().requiresUpdate(for: .codeDraft, backend: .appServer))
        value["codeVersion"] = 1
        XCTAssertTrue(try parsed().requiresUpdate(for: .codeDraft, backend: .appServer))
        value["codeVersion"] = 2
        XCTAssertTrue(try parsed().requiresUpdate(for: .codeDraft, backend: .appServer))
        value["codeVersion"] = 3
        XCTAssertFalse(try parsed().requiresUpdate(for: .codeDraft, backend: .appServer))
    }
    func testConversationalReadRequestsAreBoundedDataAndCannotWrite() throws {
        let input = try CodexCodeRequest(model: "test-model", effort: "low", instruction: "화면을 고쳐줘", files: [], tree: ["View.swift"]).encodedInput()
        XCTAssertFalse(input.contains("let count"))
        let request = "{\"summary\":\"화면 소스를 확인하겠습니다.\",\"edits\":[],\"reads\":[{\"path\":\"View.swift\",\"startLine\":1,\"lineCount\":40}]}"
        let parsed = try CodexCodeProposal.read(request)
        XCTAssertEqual(parsed.reads?.first?.path, "View.swift")
        XCTAssertTrue(try engine().prepare(parsed, files: []).isEmpty)
        for invalid in [request.replacingOccurrences(of: "View.swift", with: "../Outside.swift"), request.replacingOccurrences(of: "\"lineCount\":40", with: "\"lineCount\":601"), request.replacingOccurrences(of: "\"startLine\":1", with: "\"startLine\":0")] {
            XCTAssertThrowsError(try CodexCodeProposal.read(invalid))
        }
        let discussion = try CodexCodeProposal.read("{\"summary\":\"먼저 요구사항을 확인하겠습니다.\",\"edits\":[],\"reads\":[]}")
        XCTAssertTrue(discussion.edits.isEmpty)
        XCTAssertThrowsError(try engine().prepare(proposal(), files: []))
    }
    func testCodingTranscriptNeverLeaksIntoOrdinaryChatContext() throws {
        var user = CodexChatMessage(role: .user, text: "private source request")
        var assistant = CodexChatMessage(role: .assistant, text: "private source response")
        user.coding = true; assistant.coding = true
        let request = try CodexChatRequest(model: "test-model", message: "안녕", messages: [user, assistant], effort: "low", conversationID: UUID())
        XCTAssertFalse(request.input.contains("private source"))
    }
    func testReadPreviewShortensLongRangesWithoutIncreasingByteLimits() throws {
        let text = (0..<600).map { "let value\($0) = \"" + String(repeating: "가", count: 40) + "\"" }.joined(separator: "\n")
        try text.write(to: root.appendingPathComponent("Large.swift"), atomically: true, encoding: .utf8)
        let e = try engine()
        XCTAssertEqual(e.snapshot("Large.swift", lineCount: 600, locked: { false }).status, .failed)
        guard case .succeeded(let batch) = e.previewReads([.init(path: "Large.swift", startLine: 1, lineCount: 600)], inventory: ["Large.swift"], locked: { false }) else { return XCTFail() }
        let file = try XCTUnwrap(batch.files.first), read = try XCTUnwrap(batch.reads.first)
        XCTAssertLessThanOrEqual(file.text.utf8.count, 32768)
        XCTAssertLessThan(read.lineCount, 600)
        XCTAssertEqual(read.lineCount, file.text.components(separatedBy: "\n").count)
        XCTAssertTrue(text.hasPrefix(file.text)); XCTAssertFalse(batch.issues.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Large.swift"), encoding: .utf8), text)
    }
    func testReadPreviewKeepsValidFilesWhenAnotherFileIsBlockedOrMissing() throws {
        try ("sk-" + String(repeating: "A", count: 40)).write(to: root.appendingPathComponent("AccessValue.swift"), atomically: true, encoding: .utf8)
        try Data([0, 255]).write(to: root.appendingPathComponent("Image.png"))
        let requests: [CodexCodeRead] = [.init(path: "AccessValue.swift", startLine: 1, lineCount: 50), .init(path: "Missing.swift", startLine: 1, lineCount: 50), .init(path: "Image.png", startLine: 1, lineCount: 50), .init(path: "View.swift", startLine: 1, lineCount: 50)]
        guard case .succeeded(let batch) = try engine().previewReads(requests, inventory: ["AccessValue.swift", "Image.png", "View.swift"], locked: { false }) else { return XCTFail() }
        XCTAssertEqual(batch.files.map(\.path), ["View.swift"])
        XCTAssertTrue(batch.issues.contains { $0.contains("비밀 키") })
        XCTAssertFalse(batch.issues.joined().contains(String(repeating: "A", count: 40)))
        XCTAssertFalse(batch.files.map(\.text).joined().contains("sk-"))
    }
    func testReadPreviewTotalBudgetCancellationLockAndInvalidRange() throws {
        let e = try engine(), paths = (1...4).map { "Part\($0).swift" }
        for path in paths { try Array(repeating: String(repeating: "x", count: 99), count: 300).joined(separator: "\n").write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let requests = paths.map { CodexCodeRead(path: $0, startLine: 1, lineCount: 300) }
        guard case .succeeded(let batch) = e.previewReads(requests, inventory: paths, locked: { false }) else { return XCTFail() }
        XCTAssertLessThanOrEqual(batch.files.reduce(0, { $0 + $1.text.utf8.count }), 98304)
        XCTAssertEqual(batch.files.count, 4)
        XCTAssertLessThan(batch.reads.last!.lineCount, 300)
        XCTAssertEqual(e.previewReads(requests, inventory: paths, locked: { true }).status, .failed)
        XCTAssertEqual(e.previewReads(requests, inventory: paths, locked: { false }, cancelled: { true }).status, .failed)
        guard case .failed(let reason, _) = e.snapshot("View.swift", startLine: 9999, locked: { false }) else { return XCTFail() }
        XCTAssertTrue(reason.contains("줄 범위"))
    }
}
