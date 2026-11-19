import XCTest
@testable import Jarvis

@MainActor
final class OpenAIIntegrationTests: XCTestCase {
    private final class Credentials: OpenAICredentialStoring {
        var value = ""
        func load() -> String { value }
        func save(_ key: String) -> Bool { value = key; return true }
        func delete() -> Bool { value = ""; return true }
    }

    private actor Transport: OpenAIResponding {
        var calls = 0
        let delay: Bool
        let failure: OpenAIServiceError?
        let ignoresCancellation: Bool
        init(delay: Bool = false, failure: OpenAIServiceError? = nil, ignoresCancellation: Bool = false) {
            self.delay = delay; self.failure = failure; self.ignoresCancellation = ignoresCancellation
        }
        func generate(apiKey: String, instructions: String, input: String, maximumOutputTokens: Int) async throws -> OpenAITextResponse {
            calls += 1
            if delay {
                if ignoresCancellation { try? await Task.sleep(for: .seconds(20)) }
                else { try await Task.sleep(for: .seconds(20)) }
            }
            if let failure { throw failure }
            return .init(text: "API 테스트 답변입니다.", inputTokens: 12, outputTokens: 7)
        }
    }

    private func makeStore(transport: Transport, credentials: Credentials, locked: @escaping () -> Bool = { false }) -> OpenAIIntegrationStore {
        let defaults = UserDefaults(suiteName: "jarvis.tests.openai.\(UUID().uuidString)")!
        return OpenAIIntegrationStore(defaults: defaults, credentials: credentials, transport: transport, isLocked: locked, audit: { _, _, _ in })
    }

    func testDisabledModeMakesNoAPIRequest() async throws {
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: Credentials())
        let client = OpenAIHybridAIClient(local: MockAIClient(), store: store)
        let answer = try await client.reply(to: "안녕", context: nil)
        XCTAssertTrue(answer.contains("안녕하세요"))
        let count = await transport.calls
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.usage.requests, 0)
    }

    func testKeyAndEnableRequireSpecificConfirmation() {
        let credentials = Credentials()
        let store = makeStore(transport: Transport(), credentials: credentials)
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        let result = store.apply(configuration, key: "test-placeholder", confirmed: false)
        XCTAssertEqual(result.status, .needsConfirmation)
        XCTAssertEqual(credentials.value, "")
        XCTAssertFalse(store.configuration.enabled)
    }

    func testSuccessfulRequestCountsUsageAndPurposeWithoutClaimingTraining() async throws {
        let credentials = Credentials()
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: credentials)
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let result = try await store.generate(instructions: "테스트", input: "{}", purpose: .searchSummary)
        XCTAssertEqual(result.text, "API 테스트 답변입니다.")
        XCTAssertEqual(store.usage.inputTokens, 12)
        XCTAssertEqual(store.usage.outputTokens, 7)
        XCTAssertEqual(store.observedResults.searchSummaries, 1)
        XCTAssertEqual(store.observedResults.conversationResponses, 0)
    }

    func testDailyLimitPreventsSecondNetworkRequest() async throws {
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        configuration.dailyRequestLimit = 1
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        _ = try await store.generate(instructions: "테스트", input: "{}")
        do {
            _ = try await store.generate(instructions: "테스트", input: "{}")
            XCTFail("Daily limit must block transport")
        } catch {
            XCTAssertEqual(error as? OpenAIServiceError, .dailyLimit)
        }
        let count = await transport.calls
        XCTAssertEqual(count, 1)
    }

    func testDisableCancelsInFlightRequestAndDoesNotRecordSuccess() async throws {
        let transport = Transport(delay: true, ignoresCancellation: true)
        let store = makeStore(transport: transport, credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let task = Task { try await store.generate(instructions: "테스트", input: "{}") }
        for _ in 0..<1_000 {
            if await transport.calls > 0 { break }
            await Task.yield()
        }
        XCTAssertTrue(store.disable().accepted)
        do {
            _ = try await task.value
            XCTFail("Disabled request must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(store.configuration.enabled)
        XCTAssertEqual(store.observedResults.conversationResponses, 0)
        XCTAssertEqual(store.usage.outputTokens, 0)
    }

    func testEmergencyLockBlocksCloudButStillAllowsDisableAndKeyRemoval() async throws {
        var locked = false
        let credentials = Credentials()
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: credentials, locked: { locked })
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        locked = true
        do {
            _ = try await store.generate(instructions: "테스트", input: "{}")
            XCTFail("Emergency lock must block cloud transfer")
        } catch {
            XCTAssertEqual(error as? OpenAIServiceError, .disabled)
        }
        XCTAssertFalse(store.apply(configuration, key: nil, confirmed: true).accepted)
        XCTAssertTrue(store.disable(removeKey: true).accepted)
        XCTAssertEqual(credentials.value, "")
        let count = await transport.calls
        XCTAssertEqual(count, 0)
    }

    func testDeterministicViewModelCommandBypassesAPIWhenEnabled() async throws {
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let client = OpenAIHybridAIClient(local: MockAIClient(), store: store)
        let model = AssistantViewModel(aiClient: client, speechOutputEnabled: false)
        model.textInput = "지금 몇 시야?"
        model.submitText()
        for _ in 0..<1_000 {
            if model.messages.count == 2 { break }
            await Task.yield()
        }
        XCTAssertTrue(model.response.contains("시각"))
        let count = await transport.calls
        XCTAssertEqual(count, 0)
    }

    func testEnabledGeneralConversationUsesAPIThroughViewModel() async throws {
        let transport = Transport()
        let store = makeStore(transport: transport, credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let model = AssistantViewModel(aiClient: OpenAIHybridAIClient(local: MockAIClient(), store: store), speechOutputEnabled: false)
        model.textInput = "하늘이 파란 이유를 설명해줘"
        model.submitText()
        let deadline = Date().addingTimeInterval(5)
        while model.messages.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.response, "API 테스트 답변입니다.")
        XCTAssertEqual(store.observedResults.conversationResponses, 1)
        let count = await transport.calls
        XCTAssertEqual(count, 1)
    }

    func testAuthenticationFailureFallsBackLocallyAndShowsReason() async throws {
        let store = makeStore(transport: Transport(failure: .unauthorized), credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let client = OpenAIHybridAIClient(local: MockAIClient(), store: store)
        let answer = try await client.reply(to: "안녕", context: nil)
        XCTAssertTrue(answer.contains("안녕하세요"))
        XCTAssertTrue(store.status.contains("API 키"))
        XCTAssertEqual(store.observedResults.failedRequests, 1)
        XCTAssertEqual(store.observedResults.conversationResponses, 0)
    }

    func testExplicitRefusalIsNotRetriedWithLocalModel() async throws {
        let store = makeStore(transport: Transport(failure: .refused), credentials: Credentials())
        var configuration = OpenAIConfiguration()
        configuration.enabled = true
        XCTAssertTrue(store.apply(configuration, key: "test-placeholder", confirmed: true).accepted)
        let client = OpenAIHybridAIClient(local: MockAIClient(), store: store)
        let answer = try await client.reply(to: "안녕", context: nil)
        XCTAssertEqual(answer, "그 요청에 대한 답변을 제공할 수 없습니다.")
        XCTAssertFalse(store.status.contains("기기에서 처리"))
    }
}
