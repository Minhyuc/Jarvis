import XCTest
@testable import Jarvis

@MainActor
final class CommandPracticeTests: XCTestCase {
    private struct BriefingStudent: SemanticIntentResolving {
        func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? {
            .init(capabilityID: .fullBriefing, confidence: 1)
        }
    }

    func testFullBriefingTranscriptIncludesCalendarBodyAndEmptyFailureBranches() async {
        let result = AgentResolution.intent(.init(intent: .fullBriefing, source: .deterministic))
        let filled = await PracticeTranscriptSimulation.render(result, scenario: 0, locked: false)
        XCTAssertEqual(filled.steps.count, 2)
        XCTAssertTrue(filled.steps[1].text.contains("프로젝트 회의"))
        XCTAssertTrue(filled.steps[1].text.contains("공원 산책"))
        XCTAssertTrue(filled.steps[1].text.contains("80%"))
        XCTAssertTrue(filled.steps[1].text.contains("이상입니다"))
        let empty = await PracticeTranscriptSimulation.render(result, scenario: 1, locked: false)
        XCTAssertTrue(empty.steps[1].text.contains("오늘 예정된 일정은 없습니다"))
        let failed = await PracticeTranscriptSimulation.render(result, scenario: 2, locked: false)
        XCTAssertTrue(failed.steps[1].text.contains("날씨"))
        XCTAssertTrue(failed.steps[1].text.contains("프로젝트 회의"))
        XCTAssertFalse(failed.steps[1].text.contains("현재 기온은"))
    }

    func testWeatherTranscriptIncludesAdviceAndCalendarIncludesEventDetails() async {
        let weather = await PracticeTranscriptSimulation.render(.intent(.init(intent: .weather(.todaySummary), source: .deterministic)), scenario: 0, locked: false)
        XCTAssertTrue(weather.steps.contains { $0.stage == .result && $0.text.contains("8도") })
        XCTAssertTrue(weather.steps.contains { $0.stage == .suggestion && $0.text.contains("우산") })
        let calendar = await PracticeTranscriptSimulation.render(.intent(.init(intent: .calendar(.nextEvent), source: .deterministic)), scenario: 0, locked: false)
        XCTAssertTrue(calendar.steps.contains { $0.text.contains("다음 일정은") && $0.text.contains("프로젝트 회의") })
    }

    func testTranscriptStopsAtConfirmationOrLockAndMockHandoffIsHonest() async {
        let intent = AssistantIntent.navigate(destination: "서울역", mode: .car)
        let confirmation = await PracticeTranscriptSimulation.render(.intent(.init(intent: intent, source: .semanticModel)), scenario: 0, locked: false)
        XCTAssertEqual(confirmation.steps.count, 1)
        XCTAssertEqual(confirmation.steps[0].stage, .confirmation)
        let locked = await PracticeTranscriptSimulation.render(.intent(.init(intent: intent, source: .deterministic)), scenario: 0, locked: true)
        XCTAssertEqual(locked.steps.count, 1)
        XCTAssertTrue(locked.steps[0].text.contains("안전 잠금"))
        let handoff = await PracticeTranscriptSimulation.render(.intent(.init(intent: .playYouTube(query: "별빛 노래"), source: .deterministic)), scenario: 0, locked: false)
        XCTAssertTrue(handoff.scenario.contains("실제 일정·날씨·기기 상태가 아닙니다"))
        XCTAssertTrue(handoff.steps.last!.text.contains("실제 재생 여부는 확인할 수 없습니다"))
    }

    func testPracticeStoresFullStudentTranscriptEvenWhenStudentIsWrong() async {
        let (_, cloud, _, defaults) = setup()
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: BriefingStudent(), locked: { false })
        await store.run(confirmed: true)
        let item = store.batches[0].items[0]
        XCTAssertEqual(item.studentMatched, false)
        XCTAssertEqual(item.studentReplyKind, .simulatedTranscript)
        XCTAssertEqual(item.studentTranscript?.count, 2)
        XCTAssertTrue(item.studentReply?.contains("프로젝트 회의") == true)
        let reloaded = CommandPracticeStore(defaults: defaults, cloud: cloud, student: BriefingStudent(), locked: { false })
        XCTAssertEqual(reloaded.batches[0].items[0].studentTranscript, item.studentTranscript)
    }
    private actor SlowHoldoutStudent: SemanticIntentResolving {
        func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? {
            if PracticeHoldout.contains(text) { try await Task.sleep(for: .milliseconds(150)) }
            return nil
        }
    }

    func testCancelDuringIndependentValidationCannotPublishLateExample() async throws {
        let (_, cloud, _, defaults) = setup()
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: SlowHoldoutStudent(), locked: { false })
        await store.run(confirmed: true)
        let batch = store.batches[0]
        let work = Task { await store.apply(batchID: batch.id, itemID: batch.items[0].id, confirmed: true) }
        let deadline = Date().addingTimeInterval(3)
        while !store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.busy)
        store.cancel()
        await work.value
        XCTAssertTrue(store.approved.isEmpty)
        XCTAssertEqual(store.batches[0].items[0].decision, .pending)
    }

    func testPersonalScopeAndCostSettingsRequireExplicitPolicyApproval() async {
        let (_, cloud, teacher, defaults) = setup()
        defaults.removeObject(forKey: "jarvis.command-practice.v1.personal-review-scope-2026-10")
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: { false })
        await store.run(confirmed: true)
        XCTAssertTrue(store.batches.isEmpty)
        store.configure(counting: false, use: true, confirmed: false, inputRate: "2", outputRate: "4")
        XCTAssertFalse(store.personalUseAcknowledged); XCTAssertEqual(store.configuredInputRate, "")
        let calls = await teacher.calls; XCTAssertEqual(calls, 0)
        store.configure(counting: false, use: true, confirmed: true, inputRate: "2", outputRate: "nan")
        XCTAssertTrue(store.personalUseAcknowledged)
        XCTAssertEqual(store.configuredInputRate, "2"); XCTAssertEqual(store.configuredOutputRate, "")
    }
    private actor RegressingStudent: SemanticIntentResolving {
        let text: String
        let target: PracticeInterpretation
        var calls = 0
        init(text: String, target: PracticeInterpretation) { self.text = text; self.target = target }
        func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? {
            guard text == self.text else { return nil }
            calls += 1
            return calls == 1 ? target.candidate : .init(capabilityID: .time, secondaryArgument: "date", confidence: 1)
        }
    }

    func testApplyRecordsIndependentEvaluationWithoutAdditionalTeacherCalls() async {
        let (store, _, teacher, defaults) = setup()
        defaults.set("2", forKey: "jarvis.command-practice.v1.input-rate")
        defaults.set("4", forKey: "jarvis.command-practice.v1.output-rate")
        await store.run(confirmed: true)
        let batch = store.batches[0]
        XCTAssertEqual(batch.apiRequests, 20)
        XCTAssertEqual(batch.inputTokens, 100); XCTAssertEqual(batch.outputTokens, 100)
        XCTAssertEqual(batch.estimatedCostUSD ?? -1, 0.0006, accuracy: 0.000001)
        await store.apply(batchID: batch.id, itemID: batch.items[0].id, confirmed: true)
        XCTAssertEqual(store.validations.count, 1)
        XCTAssertTrue(store.validations[0].permitted)
        XCTAssertEqual(store.validations[0].holdoutDelta, 0)
        XCTAssertEqual(store.validations[0].observations?.count, 12)
        let calls = await teacher.calls; XCTAssertEqual(calls, 20)
    }

    func testNewHoldoutFailureHoldsApplicationEvenWithUserApproval() async throws {
        let (_, cloud, _, defaults) = setup()
        let test = try XCTUnwrap(PracticeHoldout.cases.first { value in
            switch CommandRouter().route(value.text) { case .generalConversation, .unknownCommand: return value.target.capability != .time; default: return false }
        })
        let student = RegressingStudent(text: test.text, target: test.target)
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: student, locked: { false })
        await store.run(confirmed: true)
        let batch = store.batches[0]
        await store.apply(batchID: batch.id, itemID: batch.items[0].id, confirmed: true)
        XCTAssertTrue(store.approved.isEmpty)
        XCTAssertEqual(store.batches[0].items[0].decision, .pending)
        XCTAssertFalse(try XCTUnwrap(store.validations.last).permitted)
        XCTAssertGreaterThan(try XCTUnwrap(store.validations.last).newFailures, 0)
    }

    func testVersionRestoreNeedsApprovalAndDeleteAllPreventsResurrection() async throws {
        let (store, cloud, _, defaults) = setup()
        await store.run(confirmed: true)
        let batch = store.batches[0]
        await store.apply(batchID: batch.id, itemID: batch.items[0].id, confirmed: true)
        await store.apply(batchID: batch.id, itemID: batch.items[1].id, confirmed: true)
        let revision = try XCTUnwrap(store.revisions.first { $0.examples.count == 1 })
        await store.restore(revision.id, confirmed: false)
        XCTAssertEqual(store.approved.count, 2)
        await store.restore(revision.id, confirmed: true)
        XCTAssertEqual(store.approved.count, 1)
        XCTAssertNil(store.candidate(for: batch.items[1].question))
        let reloaded = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: { false })
        XCTAssertEqual(reloaded.approved.count, 1); XCTAssertFalse(reloaded.revisions.isEmpty)
        reloaded.deleteAll()
        await reloaded.restore(revision.id, confirmed: true)
        XCTAssertTrue(reloaded.approved.isEmpty); XCTAssertTrue(reloaded.revisions.isEmpty)
    }
    private final class Credentials: OpenAICredentialStoring {
        var value = ""; func load() -> String { value }
        func save(_ key: String) -> Bool { value = key; return true }
        func delete() -> Bool { value = ""; return true }
    }
    private actor Teacher: OpenAIResponding {
        var calls = 0
        var generated = 0
        let delay: Bool
        let invalidAt: Int?
        let disagrees: Bool
        init(delay: Bool = false, invalidAt: Int? = nil, disagrees: Bool = false) {
            self.delay = delay; self.invalidAt = invalidAt; self.disagrees = disagrees
        }
        func generate(apiKey: String, instructions: String, input: String, maximumOutputTokens: Int) async throws -> OpenAITextResponse {
            calls += 1
            if delay { try await Task.sleep(for: .milliseconds(200)) }
            let envelope = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
            let object: [String: Any]
            if envelope["questionToReview"] == nil {
                generated += 1
                if generated == invalidAt { return .init(text: "유효하지 않은 JSON", inputTokens: 2, outputTokens: 2) }
                object = ["text": "테스트용 정중한 요청 문구 \(generated)", "technique": "합성 구어체"]
            } else {
                object = ["capabilityID": disagrees ? "unknown" : envelope["expectedCapability"]!,
                          "primaryArgument": envelope["primaryArgument"]!, "secondaryArgument": envelope["secondaryArgument"]!,
                          "confidence": disagrees ? 0.4 : 0.95, "reason": "독립 검토한 테스트 교정 제안"]
            }
            return .init(text: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), inputTokens: 5, outputTokens: 5)
        }
    }
    private func setup(teacher: Teacher = Teacher(), locked: @escaping () -> Bool = { false }) -> (CommandPracticeStore, OpenAIIntegrationStore, Teacher, UserDefaults) {
        let defaults = UserDefaults(suiteName: "jarvis.practice.tests.\(UUID())")!
        let cloud = OpenAIIntegrationStore(defaults: defaults, credentials: Credentials(), transport: teacher, isLocked: { false }, audit: { _, _, _ in })
        var config = OpenAIConfiguration(); config.enabled = true; config.dailyRequestLimit = 100
        _ = cloud.apply(config, key: "test-key", confirmed: true)
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: locked)
        store.configure(counting: true, use: false, confirmed: true)
        store.observe(.time(.currentTime))
        return (store, cloud, teacher, defaults)
    }

    func testTenExercisesKeepBothConclusionsAndDoNotAutoApply() async {
        let (store, cloud, teacher, _) = setup()
        await store.run(confirmed: true)
        XCTAssertEqual(store.batches.count, 1)
        XCTAssertEqual(store.batches[0].items.count, 10)
        XCTAssertEqual(store.batches[0].evaluatedCount, 10)
        XCTAssertTrue(store.approved.isEmpty)
        XCTAssertEqual(store.pendingCount, 10)
        XCTAssertTrue(store.batches[0].items.allSatisfy { !$0.studentConclusion.isEmpty && $0.teacher != nil && $0.decision == .pending })
        XCTAssertTrue(store.batches[0].items.allSatisfy { $0.studentReply?.isEmpty == false && $0.studentReplyKind != nil })
        let calls = await teacher.calls; XCTAssertEqual(calls, 20)
        XCTAssertEqual(cloud.observedResults.conversationResponses, 0)
    }

    func testApplyActuallyChangesFallbackAndDiscardNeverInstalls() async {
        let (store, cloud, _, _) = setup()
        await store.run(confirmed: true)
        let batch = store.batches[0], item = batch.items[0], rejected = batch.items[1]
        XCTAssertNil(store.candidate(for: item.question))
        await store.apply(batchID: batch.id, itemID: item.id, confirmed: false)
        XCTAssertTrue(store.approved.isEmpty)
        await store.apply(batchID: batch.id, itemID: item.id, confirmed: true)
        XCTAssertEqual(store.approved.count, 1); XCTAssertEqual(store.pendingCount, 9)
        XCTAssertEqual(store.candidate(for: item.question)?.capabilityID, .time)
        store.reject(batchID: batch.id, itemID: rejected.id)
        XCTAssertEqual(store.pendingCount, 8); XCTAssertNil(store.candidate(for: rejected.question))
        _ = cloud.disable()
        let resolver = ReviewedPracticeAIClient(base: MockAIClient(), store: store)
        let result = await AgentOrchestrator().resolve(item.question, previousIntent: nil,
            context: .init(summary: nil, recentUserTexts: []), semanticResolver: resolver)
        XCTAssertEqual(result, .intent(.init(intent: .time(.currentTime), source: .semanticModel)))
        store.revoke(item.id)
        XCTAssertNil(store.candidate(for: item.question))
    }

    func testNaturalReplyPersistsAndDoesNotAddTeacherRequests() async {
        let (store, cloud, teacher, defaults) = setup()
        await store.run(confirmed: true)
        let item = store.batches[0].items[0]
        XCTAssertNotNil(item.studentReply)
        XCTAssertNotEqual(item.studentReply, item.studentConclusion)
        let reloaded = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: { false })
        XCTAssertEqual(reloaded.batches[0].items[0].studentReply, item.studentReply)
        let calls = await teacher.calls; XCTAssertEqual(calls, 20)
        XCTAssertTrue(store.approved.isEmpty)
    }

    func testThirtyUndecidedResultsBlockNextRunUntilTenSlotsAreFreed() async {
        let (store, _, teacher, _) = setup()
        for _ in 0..<3 { await store.run(confirmed: true) }
        XCTAssertEqual(store.pendingCount, 30)
        let before = await teacher.calls
        await store.run(confirmed: true)
        let after = await teacher.calls; XCTAssertEqual(before, after)
        XCTAssertEqual(store.batches.count, 3)
        let batch = store.batches[0]
        store.reject(batchID: batch.id, itemID: batch.items[0].id)
        XCTAssertEqual(store.availableSlots, 1)
        for item in batch.items.dropFirst() { await store.apply(batchID: batch.id, itemID: item.id, confirmed: true) }
        XCTAssertEqual(store.availableSlots, 10)
        await store.run(confirmed: true)
        XCTAssertEqual(store.batches.count, 4); XCTAssertEqual(store.pendingCount, 30)
    }

    func testFailedExerciseIsVisibleAndUsesSlotUntilDiscarded() async {
        let (store, _, _, _) = setup(teacher: Teacher(invalidAt: 3))
        await store.run(confirmed: true)
        let batch = store.batches[0], failed = batch.items[2]
        XCTAssertEqual(failed.phase, .failed); XCTAssertNotNil(failed.failureReason)
        XCTAssertEqual(batch.evaluatedCount, 9); XCTAssertEqual(store.pendingCount, 10)
        XCTAssertNotNil(store.blockReason(for: failed))
        await store.apply(batchID: batch.id, itemID: failed.id, confirmed: true)
        XCTAssertTrue(store.approved.isEmpty)
        store.reject(batchID: batch.id, itemID: failed.id)
        XCTAssertEqual(store.pendingCount, 9)
        XCTAssertEqual(store.batches[0].items[2].phase, .failed)
        XCTAssertEqual(store.batches[0].items[2].decision, .rejected)
    }

    func testCancellationRetainsTenInspectableSlotsAndDoesNotResume() async throws {
        let (store, cloud, _, defaults) = setup(teacher: Teacher(delay: true))
        store.start(confirmed: true)
        let deadline = Date().addingTimeInterval(3)
        while !store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        store.cancel()
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.busy); XCTAssertEqual(store.pendingCount, 10)
        XCTAssertTrue(store.batches[0].items.allSatisfy { $0.phase == .cancelled })
        let reloaded = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: { false })
        XCTAssertEqual(reloaded.pendingCount, 10); XCTAssertFalse(reloaded.busy)
    }

    func testTeacherDisagreementCanBeInspectedButCannotBeApplied() async {
        let (store, _, _, _) = setup(teacher: Teacher(disagrees: true))
        await store.run(confirmed: true)
        let batch = store.batches[0], item = batch.items[0]
        XCTAssertEqual(item.teacher?.capability, .unknown)
        XCTAssertNotNil(store.blockReason(for: item))
        await store.apply(batchID: batch.id, itemID: item.id, confirmed: true)
        XCTAssertTrue(store.approved.isEmpty); XCTAssertEqual(store.pendingCount, 10)
    }

    func testDisabledCloudConsentAndDailyLimitsNeverStartPaidPractice() async {
        let (store, cloud, teacher, _) = setup()
        await store.run(confirmed: false)
        XCTAssertTrue(store.batches.isEmpty)
        _ = cloud.disable()
        await store.run(confirmed: true)
        XCTAssertTrue(store.batches.isEmpty)
        var config = cloud.configuration; config.enabled = true; config.dailyRequestLimit = 10
        _ = cloud.apply(config, key: nil, confirmed: true)
        await store.run(confirmed: true)
        let calls = await teacher.calls; XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.batches.isEmpty)
    }

    func testEmergencyLockPreventsPracticeAndApplicationButAllowsDiscard() async {
        var locked = false
        let (store, _, _, _) = setup(locked: { locked })
        await store.run(confirmed: true)
        let batch = store.batches[0], item = batch.items[0]
        locked = true
        await store.run(confirmed: true)
        XCTAssertEqual(store.batches.count, 1)
        await store.apply(batchID: batch.id, itemID: item.id, confirmed: true)
        XCTAssertTrue(store.approved.isEmpty)
        store.reject(batchID: batch.id, itemID: item.id)
        XCTAssertEqual(store.pendingCount, 9)
    }

    func testUsageCountersNeverStoreRealDestinationOrUtterance() {
        let (store, _, _, defaults) = setup()
        store.observe(.navigate(destination: "비공개 우리집 주소", mode: .car))
        let data = defaults.data(forKey: "jarvis.command-practice.v1.counts")!
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("비공개")); XCTAssertTrue(text.contains("navigation"))
        XCTAssertEqual(store.selectedSeeds().count, 10)
    }

    func testHistoryPruningNeverDeletesUndecidedFailedResult() throws {
        let (_, cloud, _, defaults) = setup()
        let seed = CommandPracticeSeed.standard.first { $0.id == "time.time" }!
        var pending = CommandPracticeBatch(seeds: Array(repeating: seed, count: 10), teacherModel: "test", studentDescription: "test")
        pending.finishedAt = Date()
        for i in pending.items.indices { pending.items[i].phase = .failed; pending.items[i].decision = .rejected }
        pending.items[0].decision = .pending
        let reviewed = (0..<12).map { _ -> CommandPracticeBatch in
            var batch = CommandPracticeBatch(seeds: Array(repeating: seed, count: 10), teacherModel: "test", studentDescription: "test")
            batch.finishedAt = Date()
            for i in batch.items.indices { batch.items[i].phase = .failed; batch.items[i].decision = .rejected }
            return batch
        }
        defaults.set(try JSONEncoder().encode([pending] + reviewed), forKey: "jarvis.command-practice.v1.batches")
        let store = CommandPracticeStore(defaults: defaults, cloud: cloud, student: MockAIClient(), locked: { false })
        let last = reviewed.last!
        store.reject(batchID: last.id, itemID: last.items[0].id)
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(store.batches.count, 11)
        XCTAssertEqual(store.batches.first?.id, pending.id)
        XCTAssertEqual(store.batches.first?.items[0].phase, .failed)
    }

    func testApprovedExampleWorksThroughViewModelWithoutExecutingTrainingTools() async throws {
        let (store, _, _, _) = setup()
        await store.run(confirmed: true)
        let batch = store.batches[0], item = batch.items[0]
        await store.apply(batchID: batch.id, itemID: item.id, confirmed: true)
        let client = ReviewedPracticeAIClient(base: MockAIClient(), store: store)
        let model = AssistantViewModel(aiClient: client, speechOutputEnabled: false)
        model.textInput = item.question; model.submitText()
        let deadline = Date().addingTimeInterval(3)
        while model.messages.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.response.contains("현재 시각"))
        XCTAssertEqual(model.messages.count, 2)
    }
}
