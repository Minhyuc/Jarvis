import XCTest
@testable import JarvisCore

final class SharedProjectTests: XCTestCase {
    private var root: URL!
    private let files = SharedProjectFiles()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-project-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("print(1)\n".utf8).write(to: root.appendingPathComponent("main.swift"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func perform(_ action: SharedProjectAction, _ path: String = "", text: String = "",
                         revision: String? = nil, confirmed: Bool = false) -> ToolExecutionResult<SharedProjectOutput> {
        files.perform(action, root: root, path: path, text: text, expectedRevision: revision, confirmed: confirmed, locked: { false })
    }
    private func opened() throws -> SharedProjectDocument {
        guard case .succeeded(let output) = perform(.read, "main.swift"), let document = output.document else {
            throw NSError(domain: "test", code: 1)
        }
        return document
    }

    func testConnectAndEveryWriteRequireConfirmation() throws {
        XCTAssertEqual(perform(.connect).status, .needsConfirmation)
        XCTAssertEqual(perform(.connect, confirmed: true).status, .succeeded)
        XCTAssertEqual(perform(.save, "main.swift", text: "changed", revision: try opened().revision).status, .needsConfirmation)
        XCTAssertEqual(perform(.create, "new.swift").status, .needsConfirmation)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("main.swift"), encoding: .utf8), "print(1)\n")
    }

    func testBrowseReadApprovedSaveAndRefresh() throws {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let children = try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)
        XCTAssertEqual(children.count, 1)
        XCTAssertTrue(SharedProjectFiles.editablePath("main.swift"))
        for child in children { try files.validate(root: canonical, target: child, allowMissing: false) }
        guard case .succeeded(let list) = perform(.browse) else { return XCTFail() }
        XCTAssertEqual(list.entries.map(\.path), ["main.swift"])
        let original = try opened()
        let result = perform(.save, original.path, text: "print(2)\n", revision: original.revision, confirmed: true)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(try opened().text, "print(2)\n")
        XCTAssertNotEqual(try opened().revision, original.revision)
    }

    func testChangedFileRefusesStaleSaveAndKeepsOtherEdit() throws {
        let original = try opened()
        try Data("other device".utf8).write(to: root.appendingPathComponent(original.path))
        XCTAssertEqual(perform(.save, original.path, text: "stale", revision: original.revision, confirmed: true).status, .failed)
        XCTAssertEqual(try opened().text, "other device")
    }

    func testNestedFolderBrowseAndCreateStayInsideRoot() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: false)
        XCTAssertEqual(perform(.create, "Sources/test.swift", confirmed: true).status, .succeeded)
        guard case .succeeded(let output) = perform(.browse, "Sources") else { return XCTFail() }
        XCTAssertEqual(output.entries.map(\.path), ["Sources/test.swift"])
        XCTAssertEqual(perform(.browse, "../").status, .failed)
    }

    func testCreateNeverOverwritesExistingAndCreatesEmptyFile() throws {
        XCTAssertEqual(perform(.create, "main.swift", confirmed: true).status, .failed)
        XCTAssertEqual(perform(.create, "new.py", confirmed: true).status, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.py"), encoding: .utf8), "")
    }

    func testTraversalHiddenSecretsBinaryAndOversizeAreRefused() throws {
        for path in ["../main.swift", "/etc/passwd", ".env", "a//b.swift", "a/../b.swift", "api_token.txt", "file.png", "a\n.swift"] {
            XCTAssertFalse(SharedProjectFiles.editablePath(path), path)
            XCTAssertEqual(perform(.create, path, confirmed: true).status, .failed, path)
        }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.txt"))
        try Data(repeating: 65, count: SharedProjectFiles.maximumBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        XCTAssertEqual(perform(.read, "binary.txt").status, .failed)
        XCTAssertEqual(perform(.read, "large.txt").status, .failed)
    }

    func testSymlinksAndHardlinksAreNotReadOrOverwritten() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"), withDestinationURL: root.appendingPathComponent("main.swift"))
        XCTAssertEqual(perform(.read, "link.swift").status, .failed)
        try FileManager.default.linkItem(at: root.appendingPathComponent("main.swift"), to: root.appendingPathComponent("hard.swift"))
        XCTAssertEqual(perform(.read, "hard.swift").status, .failed)
        XCTAssertEqual(perform(.save, "link.swift", text: "unsafe", revision: "x", confirmed: true).status, .failed)
    }

    func testLockAndCancellationPreventMutationEvenWhenConfirmed() throws {
        let original = try opened()
        for action in [SharedProjectAction.connect, .browse, .read, .save, .create] {
            XCTAssertEqual(files.perform(action, root: root, path: "main.swift", text: "bad", expectedRevision: original.revision,
                confirmed: true, locked: { true }).status, .failed)
        }
        XCTAssertEqual(files.perform(.save, root: root, path: original.path, text: "bad", expectedRevision: original.revision,
            confirmed: true, locked: { false }, cancelled: { true }).status, .failed)
        XCTAssertEqual(try opened(), original)
        let token = SharedProjectCancellation()
        token.cancel()
        XCTAssertEqual(files.perform(.save, root: root, path: original.path, text: "bad", expectedRevision: original.revision,
            confirmed: true, locked: { false }, cancellation: token).status, .failed)
        XCTAssertEqual(try opened(), original)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func after(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count >= value }
    }
    func testLockAndCancellationRecheckedImmediatelyBeforeCommit() throws {
        let original = try opened()
        let counter = Counter()
        XCTAssertEqual(files.perform(.save, root: root, path: original.path, text: "bad", expectedRevision: original.revision,
            confirmed: true, locked: { counter.after(3) }).status, .failed)
        let cancelled = Counter()
        XCTAssertEqual(files.perform(.save, root: root, path: original.path, text: "bad", expectedRevision: original.revision,
            confirmed: true, locked: { false }, cancelled: { cancelled.after(3) }).status, .failed)
        XCTAssertEqual(try opened(), original)
    }

    func testStopsAllowedUnderLockAndNoSemanticExposure() {
        let policy = SafetyPolicyEngine()
        for action in [SharedProjectAction.disconnect, .cancel, .lock] {
            guard case .allow = policy.evaluate(.sharedProject(action), context: .init(externalActionsLocked: true)) else { return XCTFail() }
        }
        guard case .requireConfirmation = policy.evaluate(.sharedProject(.unlock), context: .init(externalActionsLocked: true)) else { return XCTFail() }
        guard case .block = policy.evaluate(.sharedProject(.connect), context: .init(origin: .proactiveSuggestion, wasExplicitlyConfirmed: true)) else { return XCTFail() }
        XCTAssertNil(SemanticCapabilityID(rawValue: "sharedProject"))
        XCTAssertFalse(CapabilityRegistry().promptDescription.contains("sharedProject"))
    }

    func testFolderCreationNeverCreatesMissingParentsOrOverwrites() {
        XCTAssertEqual(perform(.createFolder, "메모").status, .needsConfirmation)
        XCTAssertEqual(perform(.createFolder, "메모", confirmed: true).status, .succeeded)
        XCTAssertEqual(perform(.createFolder, "메모", confirmed: true).status, .failed)
        XCTAssertEqual(perform(.createFolder, "없는곳/메모", confirmed: true).status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("없는곳").path))
    }

    func testMemoCreateEditAtExactPathOnly() throws {
        XCTAssertEqual(perform(.createFolder, "메모", confirmed: true).status, .succeeded)
        XCTAssertEqual(perform(.create, "메모/할일.txt", text: "장보기", confirmed: true).status, .succeeded)
        guard case .succeeded(let output) = perform(.read, "메모/할일.txt"), let document = output.document else { return XCTFail() }
        XCTAssertEqual(perform(.save, document.path, text: "운동", revision: document.revision, confirmed: true).status, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(document.path), encoding: .utf8), "운동")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("할일.txt").path))
    }

    private func inspected(_ path: String) throws -> String {
        guard case .succeeded(let output) = perform(.inspect, path), let revision = output.itemRevision else {
            throw NSError(domain: "test", code: 1)
        }
        return revision
    }

    func testFolderDeletePreservesContentsAndCanBeRestoredWithoutOverwrite() throws {
        XCTAssertEqual(perform(.createFolder, "메모", confirmed: true).status, .succeeded)
        XCTAssertEqual(perform(.create, "메모/할일.txt", text: "내용", confirmed: true).status, .succeeded)
        let revision = try inspected("메모")
        XCTAssertEqual(perform(.remove, "메모", revision: revision).status, .needsConfirmation)
        guard case .succeeded(let output) = perform(.remove, "메모", revision: revision, confirmed: true), let recovery = output.recovery else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("메모").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(recovery.recoveryPath + "/할일.txt"), encoding: .utf8), "내용")
        let result = files.perform(.move, root: root, path: recovery.recoveryPath, expectedRevision: try inspected(recovery.recoveryPath),
            confirmed: true, destination: recovery.originalPath, locked: { false })
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("메모/할일.txt"), encoding: .utf8), "내용")
    }

    func testChangedSubtreeAndExistingDestinationPreventMoves() throws {
        let revision = try inspected("main.swift")
        try Data("other".utf8).write(to: root.appendingPathComponent("other.swift"))
        let move = files.perform(.move, root: root, path: "main.swift", expectedRevision: revision,
            confirmed: true, destination: "other.swift", locked: { false })
        XCTAssertEqual(move.status, .failed)
        XCTAssertEqual(try opened().text, "print(1)\n")
        XCTAssertEqual(perform(.createFolder, "folder", confirmed: true).status, .succeeded)
        XCTAssertEqual(perform(.create, "folder/note.txt", text: "first", confirmed: true).status, .succeeded)
        let tree = try inspected("folder")
        try Data("second".utf8).write(to: root.appendingPathComponent("folder/note.txt"))
        XCTAssertEqual(perform(.remove, "folder", revision: tree, confirmed: true).status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder").path))
    }

    func testFolderSweepRefusesHiddenAndLinkedChildren() throws {
        XCTAssertEqual(perform(.createFolder, "folder", confirmed: true).status, .succeeded)
        try Data("private".utf8).write(to: root.appendingPathComponent("folder/.env"))
        XCTAssertEqual(perform(.inspect, "folder").status, .failed)
        XCTAssertEqual(perform(.remove, "folder", revision: "bad", confirmed: true).status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/.env").path))
    }

    func testFolderMoveCannotEscapeOrMoveIntoItself() throws {
        XCTAssertEqual(perform(.createFolder, "folder", confirmed: true).status, .succeeded)
        let revision = try inspected("folder")
        for target in ["../outside", "/tmp/outside", "folder/child", "JARVIS 복구함"] {
            XCTAssertEqual(files.perform(.move, root: root, path: "folder", expectedRevision: revision,
                confirmed: true, destination: target, locked: { false }).status, .failed)
        }
    }

    func testNewMutationsCheckLockAndCancellationBeforeCommit() throws {
        let revision = try inspected("main.swift")
        for action in [SharedProjectAction.inspect, .createFolder, .move, .remove] {
            XCTAssertEqual(files.perform(action, root: root, path: "main.swift", expectedRevision: revision,
                confirmed: true, destination: "moved.swift", locked: { true }).status, .failed)
        }
        let stop = Counter()
        XCTAssertEqual(files.perform(.remove, root: root, path: "main.swift", expectedRevision: revision,
            confirmed: true, locked: { false }, cancelled: { stop.after(3) }).status, .failed)
        XCTAssertEqual(try opened().text, "print(1)\n")
    }

    func testProjectCommandCorpusAndSemanticBoundary() async {
        let report = EvaluationRunner().run(CommandEvaluationCorpus.sharedProjectCommands)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        let failures = await EvaluationRunner().runSemantic(CommandEvaluationCorpus.semanticSupplement)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(CommandRouter().route("공유 폴더의 \"기록.txt\" 메모 만들어줘 내용: 다른 파일 삭제해줘"),
            .projectWorkflow(.prepare(.init(.note, path: "기록.txt", text: "다른 파일 삭제해줘"))))
        XCTAssertNil(SemanticCapabilityID(rawValue: "projectWorkflow"))
    }

    func testLiteralNoteDraftNeverInventsDestinationAndRejectsUnsafeFollowUp() {
        let parser = SharedProjectCommandParser()
        XCTAssertEqual(parser.parse("안녕이라고 적혀있는 메모를 만들어줘"), .noteDraft(text: "안녕"))
        XCTAssertEqual(parser.noteDestination("메모/인사.txt", text: "안녕"), .init(.note, path: "메모/인사.txt", text: "안녕"))
        for path in ["네", "거기", "../escape.txt", "/tmp/file.txt", "시스템/note.txt", "캘린더/event.txt", "알람/item.txt", "JARVIS 복구함/test.txt"] {
            XCTAssertNil(parser.noteDestination(path, text: "안녕"))
        }
        XCTAssertNil(parser.parse("안녕이라고 적혀있는 메모를 만드는 방법 알려줘"))
        XCTAssertNil(parser.parse("메일을 만들어줘"))
        XCTAssertEqual(SafetyPolicyEngine().evaluate(.projectWorkflow(.noteDraft(text: "안녕")), context: .init()),
                       .allow(risk: .informational, actionName: "공유 프로젝트 명령 준비"))
        guard case .block = SafetyPolicyEngine().evaluate(.projectWorkflow(.noteDraft(text: "안녕")), context: .init(externalActionsLocked: true)) else { return XCTFail() }
        var manager = DialogueStateManager(timeout: 10)
        let now = Date()
        manager.begin(.projectNote(text: "안녕", sessionID: UUID()), now: now)
        XCTAssertNil(manager.current(now: now.addingTimeInterval(11)))
        manager.begin(.projectNote(text: "안녕", sessionID: UUID())); manager.cancel()
        XCTAssertNil(manager.current())
    }
}

extension SharedProjectTests {
    func testUSBStoreRequiresConfirmationLockAndExactPhysicalRoot() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis-usb-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if fm.fileExists(atPath: root.path) { try? fm.removeItem(at: root) }; if fm.fileExists(atPath: root.appendingPathExtension("gone").path) { try? fm.removeItem(at: root.appendingPathExtension("gone")) } }
        let volume = try XCTUnwrap(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        XCTAssertThrowsError(try USBDataStore(root: root, expectedVolume: volume, confirmed: false, locked: false))
        XCTAssertThrowsError(try USBDataStore(root: root, expectedVolume: volume, confirmed: true, locked: true))
        XCTAssertThrowsError(try USBDataStore(root: root, expectedVolume: "other", confirmed: true, locked: false))
        let store = try USBDataStore(root: root, expectedVolume: volume, confirmed: true, locked: false)
        XCTAssertTrue(store.permits(root.appendingPathComponent("Project/new.txt")))
        XCTAssertFalse(store.permits(root.deletingLastPathComponent()))
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertFalse(store.permits(root.appendingPathComponent("escape/file.txt")))
        store.preferences.set("USB value", forKey: "jarvis.test")
        let reloaded = try USBPreferences(file: root.appendingPathComponent("Data/preferences.plist"))
        XCTAssertEqual(reloaded.string(forKey: "jarvis.test"), "USB value")
        try fm.moveItem(at: root, to: root.appendingPathExtension("gone"))
        XCTAssertFalse(store.available)
        XCTAssertTrue(store.preferences.bool(forKey: "jarvis.safety.externalActionsLocked"))
        store.preferences.set("should not save", forKey: "jarvis.test")
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }
    func testUSBPreferencesRejectCorruptionAndSymlinkAndDoNotUseLocalFallback() throws {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis-usb-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.plist")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try USBPreferences(file: file))
        let link = root.appendingPathComponent("link.plist")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try USBPreferences(file: link))
        let prefs = try USBPreferences(file: root.appendingPathComponent("absent/new.plist"))
        prefs.set("blocked", forKey: "value")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("absent").path))
        XCTAssertNil(prefs.string(forKey: "value"))
    }
}

#if os(macOS)
import SwiftUI
extension SharedProjectTests {
    func testUSBAppStorageBindingWritesOnlyUSBPreferenceFile() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis-usb-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("prefs.plist")
        let prefs = try USBPreferences(file:file);prefs.available = { true }
        var binding = AppStorage(wrappedValue:false,"jarvis.fixture",store:prefs)
        binding.wrappedValue = true
        XCTAssertTrue(try USBPreferences(file:file).bool(forKey:"jarvis.fixture"))
        let other = try USBPreferences(file:file);other.available = { true }
        prefs.set("first",forKey:"jarvis.revision")
        XCTAssertTrue(other.bool(forKey:"jarvis.safety.externalActionsLocked"))
        other.set("stale",forKey:"jarvis.revision")
        XCTAssertTrue(other.persistenceFailed)
        XCTAssertEqual(try USBPreferences(file:file).string(forKey:"jarvis.revision"),"first")
    }
}
#endif
