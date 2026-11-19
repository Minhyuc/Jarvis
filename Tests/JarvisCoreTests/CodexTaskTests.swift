import XCTest
@testable import JarvisCore

final class CodexTaskTests: XCTestCase {
    func testModelCanProposeVerificationButCannotProposeShellOrMixedMutations() throws {
        let valid = #"{"summary":"검증","edits":[],"reads":[],"commands":[{"argv":["swift","test"],"purpose":"회귀 확인"}]}"#
        XCTAssertEqual(try CodexCodeProposal.read(valid).commands?.first?.argv, ["swift", "test"])
        let shell = valid.replacingOccurrences(of: #""swift","test""#, with: #""/bin/sh","-c","rm -rf .""#)
        XCTAssertThrowsError(try CodexCodeProposal.read(shell))
        let mixed = valid.replacingOccurrences(of: #""edits":[]"#, with: #""edits":[{"path":"View.swift","old":"a","new":"b"}]"#)
        XCTAssertThrowsError(try CodexCodeProposal.read(mixed))
        XCTAssertThrowsError(try CodexVerificationCommand(argv: ["swift", "test", "--scratch-path", "/Users"], purpose: "검증").validate())
        XCTAssertThrowsError(try CodexVerificationCommand(argv: ["xcodebuild", "-project", "../Other.xcodeproj", "-scheme", "App", "build"], purpose: "검증").validate())
    }
    func testTaskReadApprovalIsBoundedByRangeTaskExpiryLockAndUseCount() {
        let task = UUID(), now = Date()
        let approved = CodexCodeRead(path: "View.swift", startLine: 10, lineCount: 20)
        var grant = CodexTaskReadGrant(task: task, ranges: [approved], deadline: now.addingTimeInterval(60))
        XCTAssertFalse(grant.consume([approved], task: UUID(), now: now, locked: false))
        XCTAssertFalse(grant.consume([approved], task: task, now: now, locked: true))
        XCTAssertFalse(grant.consume([approved], task: task, now: now.addingTimeInterval(61), locked: false))
        XCTAssertFalse(grant.consume([.init(path: "Other.swift", startLine: 10, lineCount: 20)], task: task, now: now, locked: false))
        XCTAssertFalse(grant.consume([.init(path: "View.swift", startLine: 1, lineCount: 600)], task: task, now: now, locked: false))
        for _ in 0..<8 {
            XCTAssertTrue(grant.consume([.init(path: "View.swift", startLine: 12, lineCount: 5)], task: task, now: now, locked: false))
        }
        XCTAssertFalse(grant.consume([approved], task: task, now: now, locked: false))
    }
    func testToolEvidenceIsBoundedAndNeverSilentlySendsKnownSecrets() throws {
        let valid = CodexCodeRequest(model: "test-model", effort: "low", instruction: "결과 설명", files: [], tree: [],
                                     toolResults: ["실제 종료 코드 0"])
        XCTAssertTrue(try valid.encodedInput().contains("toolResults"))
        let oversized = CodexCodeRequest(model: "test-model", effort: "low", instruction: "결과 설명", files: [], tree: [],
                                         toolResults: [String(repeating: "x", count: 4097)])
        XCTAssertThrowsError(try oversized.encodedInput())
        let secret = CodexCodeRequest(model: "test-model", effort: "low", instruction: "결과 설명", files: [], tree: [],
                                      toolResults: ["sk-" + String(repeating: "a", count: 32)])
        XCTAssertThrowsError(try secret.encodedInput())
    }
}
