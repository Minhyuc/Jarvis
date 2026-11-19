import XCTest
@testable import JarvisCore

final class CodexChatImportTests: XCTestCase {
    func testImportSelectsActiveTextBranchAndDoesNotUseItAsPromptContext() throws {
        let export = #"""
        [{
          "id":"example", "title":"가져온 대화", "current_node":"reply",
          "mapping":{
            "system":{"parent":null,"message":{"author":{"role":"system"},"content":{"content_type":"text","parts":["private system"]}}},
            "user":{"parent":"system","message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["old user text"]}}},
            "hidden":{"parent":"user","message":{"author":{"role":"assistant"},"metadata":{"is_visually_hidden_from_conversation":true},"content":{"content_type":"text","parts":["private analysis"]}}},
            "reply":{"parent":"hidden","message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["old assistant text"]}}},
            "alternate":{"parent":"user","message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["other branch"]}}}
          }
        }]
        """#
        let preview = try CodexChatImport.read(Data(export.utf8))
        let thread = try XCTUnwrap(preview.threads.first)
        XCTAssertEqual(thread.messages.map(\.text), ["old user text", "old assistant text"])
        XCTAssertTrue(thread.messages.allSatisfy { $0.imported == true })
        XCTAssertEqual(thread.importFingerprint?.utf8.count, 64)
        let draft = try CodexChatRequest(model: "test-model", message: "new input", messages: thread.messages)
        XCTAssertFalse(draft.input.contains("old user text"))
        XCTAssertFalse(draft.input.contains("old assistant text"))
    }

    func testMalformedOrCyclicBranchesAreExcluded() throws {
        let input = #"[{"id":"cycle","current_node":"a","mapping":{"a":{"parent":"b"},"b":{"parent":"a"}}},{"id":"missing","current_node":"a","mapping":{}}]"#
        let preview = try CodexChatImport.read(Data(input.utf8))
        XCTAssertTrue(preview.threads.isEmpty)
        XCTAssertEqual(preview.omittedCount, 2)
        XCTAssertThrowsError(try CodexChatImport.read(Data("{}".utf8)))
    }

    func testImportRequiresExplicitConfirmationAndHonorsLock() {
        let policy = SafetyPolicyEngine()
        let intent = AssistantIntent.codexLocal(.workspaceImport)
        guard case .requireConfirmation = policy.evaluate(intent, context: .init()),
              case .allow = policy.evaluate(intent, context: .init(wasExplicitlyConfirmed: true)),
              case .block = policy.evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
            return XCTFail("Import must be approved and blocked when locked")
        }
    }
}
