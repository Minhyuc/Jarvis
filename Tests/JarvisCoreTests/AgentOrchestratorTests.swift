import XCTest
@testable import JarvisCore

final class AgentOrchestratorTests: XCTestCase {
    private struct StubResolver: SemanticIntentResolving {
        let candidate: SemanticIntentCandidate?

        func interpretCommand(
            _ text: String,
            capabilities: String,
            context: SemanticResolutionContext
        ) async throws -> SemanticIntentCandidate? {
            candidate
        }
    }

    func testKnownCommandUsesDeterministicRouter() async {
        let orchestrator = AgentOrchestrator()
        let result = await orchestrator.resolve(
            "볼륨 30퍼센트로 해줘",
            previousIntent: nil,
            context: .init(summary: nil, recentUserTexts: []),
            semanticResolver: StubResolver(candidate: nil)
        )

        XCTAssertEqual(
            result,
            .intent(.init(intent: .setVolume(percent: 30), source: .deterministic))
        )
    }

    func testSemanticCandidateCanResolveUnknownNaturalExpression() async {
        let candidate = SemanticIntentCandidate(
            capabilityID: .playYouTube,
            primaryArgument: "아이유 밤편지",
            confidence: 0.94
        )
        let result = await AgentOrchestrator().resolve(
            "아이유 밤편지 영상으로 부탁할게",
            previousIntent: nil,
            context: .init(summary: nil, recentUserTexts: []),
            semanticResolver: StubResolver(candidate: candidate)
        )

        XCTAssertEqual(
            result,
            .intent(.init(
                intent: .playYouTube(query: "아이유 밤편지"),
                source: .semanticModel
            ))
        )
    }

    func testLowConfidenceCandidateDoesNotExecuteTool() async {
        let candidate = SemanticIntentCandidate(
            capabilityID: .call,
            primaryArgument: "홍길동",
            confidence: 0.51
        )
        let result = await AgentOrchestrator().resolve(
            "그 사람에게 해줘",
            previousIntent: nil,
            context: .init(summary: nil, recentUserTexts: []),
            semanticResolver: StubResolver(candidate: candidate)
        )

        guard case .intent(let resolution) = result else {
            return XCTFail("낮은 확신의 도구 후보는 실행되면 안 됩니다.")
        }
        XCTAssertEqual(resolution.source, .deterministic)
        XCTAssertNotEqual(resolution.intent, .call(recipient: "홍길동", speakerRequested: false))
    }

    func testMissingRequiredArgumentRequestsClarification() async {
        let candidate = SemanticIntentCandidate(
            capabilityID: .navigate,
            confidence: 0.95
        )
        let result = await AgentOrchestrator().resolve(
            "길 좀 안내해줘",
            previousIntent: nil,
            context: .init(summary: nil, recentUserTexts: []),
            semanticResolver: StubResolver(candidate: candidate)
        )

        XCTAssertEqual(result, .clarification("어디까지 길 안내를 시작할까요?"))
    }

    func testSemanticNavigationNormalizesDestinationAndUsesTransitDefault() {
        let registry = CapabilityRegistry()
        XCTAssertEqual(
            registry.resolve(
                .init(
                    capabilityID: .navigate,
                    primaryArgument: "강남역 역으로 안내 부탁해",
                    confidence: 1
                ),
                originalText: "강남역으로 안내해줘"
            ),
            .intent(.navigate(destination: "강남역", mode: .publicTransit))
        )
    }

    func testRegistryClampsVolumeAndRejectsUnregisteredCapability() {
        let registry = CapabilityRegistry()
        XCTAssertEqual(
            registry.resolve(
                .init(capabilityID: .setVolume, primaryArgument: "150", confidence: 1),
                originalText: "볼륨 최대로"
            ),
            .intent(.setVolume(percent: 100))
        )

        let restricted = CapabilityRegistry(descriptors: [
            .init(id: .conversation, summary: "대화")
        ])
        XCTAssertEqual(
            restricted.resolve(
                .init(capabilityID: .call, primaryArgument: "홍길동", confidence: 1),
                originalText: "전화"
            ),
            .unavailable
        )
    }
}
