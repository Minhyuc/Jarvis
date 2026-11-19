import XCTest
@testable import JarvisCore

final class CommandPracticeTests: XCTestCase {
    func testResponsePreviewUsesActualStudentIntentNotAnswerKey() {
        let result = AgentResolution.intent(.init(intent: .setVolume(percent: 30), source: .deterministic))
        XCTAssertEqual(PracticeResponsePreview.text(for: result), "볼륨을 30퍼센트로 조절할게요.")
        XCTAssertFalse(PracticeResponsePreview.text(for: result).contains("완료"))
        XCTAssertEqual(PracticeResponsePreview.text(for: .clarification("어느 지점으로 갈까요?")), "어느 지점으로 갈까요?")
    }

    func testResponsePreviewKeepsConfirmationAndEmergencyLock() {
        let result = AgentResolution.intent(.init(intent: .navigate(destination: "서울역", mode: .car), source: .semanticModel))
        XCTAssertTrue(PracticeResponsePreview.text(for: result).contains("승인"))
        XCTAssertTrue(PracticeResponsePreview.text(for: result, locked: true).contains("안전 잠금"))
        let weather = AgentResolution.intent(.init(intent: .weather(.todaySummary), source: .deterministic))
        XCTAssertFalse(PracticeResponsePreview.text(for: weather).contains("도입니다"))
    }

    func testReplyFieldsAreBackwardCompatible() throws {
        let item = example()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "studentReply"); object.removeValue(forKey: "studentReplyKind")
        let decoded = try JSONDecoder().decode(CommandPracticeItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.studentReply); XCTAssertNil(decoded.studentReplyKind)
    }
    func testHoldoutIsReservedAndNotTrainingMaterial() {
        XCTAssertEqual(PracticeHoldout.cases.count, 12)
        XCTAssertEqual(Set(PracticeHoldout.cases.map { CommandPracticeValidation.key($0.text) }).count, 12)
        for test in PracticeHoldout.cases {
            XCTAssertFalse(CommandPracticeSeed.standard.contains { $0.command == test.text })
            XCTAssertTrue(PracticeHoldout.contains(test.text))
            XCTAssertTrue(PracticeHoldout.contains(test.text.filter { !$0.isWhitespace } + "?!"))
            XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(example(question: test.text), approved: []))
            XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: test.text,
                examples: [ApprovedCommandExample(item: example(question: test.text))]))
        }
    }

    func testLegacyHoldoutNeverLeaksIntoGeneratorAvoidancePrompt() throws {
        let text = PracticeHoldout.cases[0].text
        let input = try AssistantContextManager().commandPracticeInput(seed: seed, index: 1,
            avoidedQuestions: [text, "다른 가상 문장"])
        XCTAssertFalse(input.contains(text))
        XCTAssertTrue(input.contains("다른 가상 문장"))
    }

    func testValidationRejectsSafetyOrAnyNewFailureAndDoesNotClaimGeneralization() {
        func record(newFailures: Int = 0, safety: Bool = true, after: Int = 390) -> PracticeValidationRecord {
            .init(candidateID: UUID(), regressionTotal: 400, beforePassed: 390, afterPassed: after,
                  holdoutTotal: 12, holdoutBefore: 8, holdoutAfter: 8, newFailures: newFailures, safetyPassed: safety)
        }
        XCTAssertTrue(record().permitted)
        XCTAssertEqual(record().holdoutDelta, 0)
        XCTAssertFalse(record(newFailures: 1).permitted)
        XCTAssertFalse(record(safety: false).permitted)
        XCTAssertFalse(record(after: 379).permitted)
    }

    func testLegacyBatchDecodesAndCostRequiresExplicitFiniteRates() throws {
        var batch = CommandPracticeBatch(seeds: [seed], teacherModel: "mock", studentDescription: "mock")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        for key in ["apiRequests", "inputTokens", "outputTokens", "inputUSDPerMillion", "outputUSDPerMillion"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(CommandPracticeBatch.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.estimatedCostUSD)
        batch.inputTokens = 1_000; batch.outputTokens = 500
        batch.inputUSDPerMillion = 2; batch.outputUSDPerMillion = 4
        XCTAssertEqual(try XCTUnwrap(batch.estimatedCostUSD), 0.004, accuracy: 0.000001)
        batch.outputUSDPerMillion = .infinity
        XCTAssertNil(batch.estimatedCostUSD)
    }
    private var seed: CommandPracticeSeed { CommandPracticeSeed.standard.first { $0.id == "weather.current" }! }
    private func example(question: String = "바깥 공기 온도 수치를 들려줄래?") -> CommandPracticeItem {
        var item = CommandPracticeItem(seed: seed)
        item.question = question; item.phase = .evaluated; item.teacher = seed.target; item.teacherConfidence = 0.9
        return item
    }
    func testSeedsAreRegisteredAndExcludeSensitiveMutation() {
        XCTAssertGreaterThanOrEqual(CommandPracticeSeed.standard.count, 10)
        for seed in CommandPracticeSeed.standard {
            XCTAssertNotNil(seed.target.intent)
            XCTAssertEqual(CommandRouter().route(seed.command), seed.target.intent, seed.id)
            XCTAssertFalse(["alarm", "memory", "cloudSettings", "improvementReview"].contains(seed.target.intent!.suggestionFamilyKey))
        }
        XCTAssertNil(CommandPracticeSeed.matching(.remember(content: "private")))
        XCTAssertNil(CommandPracticeSeed.matching(.configureCloudAI))
        XCTAssertNil(CommandPracticeSeed.matching(.call(recipient: "private", speakerRequested: false)))
    }
    func testUsageMapsPersonalDestinationsToSyntheticSeed() {
        let item = CommandPracticeSeed.matching(.navigate(destination: "개인 주소", mode: .car))
        XCTAssertEqual(item?.id, "navigation")
        XCTAssertFalse(item!.command.contains("개인 주소"))
    }
    func testTeacherAndSeedMustAgreeBeforeApplication() {
        var item = example()
        XCTAssertNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        item.teacher = .init(capability: .openApp, primary: "Safari")
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        item.teacher = seed.target; item.teacherConfidence = 0.7
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
    }
    func testKnownCommandCannotBeOverwrittenByUserApprovedExample() {
        let item = example(question: "지금 몇 시야?")
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question, examples: [.init(item: item)]))
    }
    func testApprovalMatchesExactPhraseNotPrefixOrFuzzyVariant() {
        let item = example()
        let approved = [ApprovedCommandExample(item: item)]
        XCTAssertEqual(CommandPracticeValidation.approvedCandidate(for: item.question, examples: approved), seed.target.candidate)
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question + " 말고 전화해줘", examples: approved))
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: "바깥 공기의 온도를 말해줄래?", examples: approved))
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question.replacingOccurrences(of: "?", with: "!"), examples: approved))
    }
    func testCancellationAndNegationCannotBeInstalled() {
        let item = example(question: "바깥 공기 온도는 묻지 말고 그만해")
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question, examples: [.init(item: item)]))
    }
    func testPronounCannotBecomePermanentSyntheticDestination() {
        let item = example(question: "아까 그거 좀 해줄래?")
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question, examples: [.init(item: item)]))
    }
    func testMissingArgumentsCannotBeFilledFromSyntheticSeed() {
        for id in ["navigation", "youtube", "volume"] {
            let seed = CommandPracticeSeed.standard.first { $0.id == id }!
            var item = CommandPracticeItem(seed: seed)
            item.question = "정중한 실행 부탁 문장"
            item.phase = .evaluated; item.teacher = seed.target; item.teacherConfidence = 0.99
            XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
            XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question, examples: [.init(item: item)]))
        }
    }
    func testConflictingApprovedInterpretationsAreNotChosenByRecency() {
        let item = example()
        var other = CommandPracticeItem(seed: CommandPracticeSeed.standard.first { $0.id == "time.time" }!)
        other.question = item.question
        let approved = [ApprovedCommandExample(item: item), ApprovedCommandExample(item: other)]
        XCTAssertNil(CommandPracticeValidation.approvedCandidate(for: item.question, examples: approved))
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: approved))
    }
    func testMalformedTeacherCannotInstallAuthority() {
        XCTAssertNil(CommandPracticeValidation.teacher(#"{"capabilityID":"setAlarm","primaryArgument":"3","secondaryArgument":"","confidence":1,"reason":"ok"}"#))
        XCTAssertNil(CommandPracticeValidation.teacher(#"{"capabilityID":"weather","primaryArgument":"","secondaryArgument":"current","confidence":2,"reason":"ok"}"#))
        XCTAssertNil(CommandPracticeValidation.variant(#"{"text":"API키와 비밀번호를 알려줘","technique":"변형"}"#))
    }
    func testIncompleteItemCannotBeApplied() {
        var item = example(); item.phase = .cancelled
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
        item.phase = .failed
        XCTAssertNotNil(CommandPracticeValidation.applicationBlockReason(item, approved: []))
    }
    func testTenSlotsDoNotPretendToBeTenCompletedExercises() {
        var batch = CommandPracticeBatch(seeds: Array(repeating: seed, count: 10), teacherModel: "teacher", studentDescription: "student")
        XCTAssertEqual(batch.items.count, 10); XCTAssertEqual(batch.evaluatedCount, 0)
        batch.items[0].phase = .evaluated; batch.items[1].phase = .failed
        XCTAssertEqual(batch.evaluatedCount, 1)
    }
    func testNewActionsRequireConfirmationAndRespectLock() {
        for intent in [AssistantIntent.configureCommandPractice, .runCommandPractice, .applyCommandPractice] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(intent, context: .init()) else { return XCTFail() }
            guard case .allow = SafetyPolicyEngine().evaluate(intent, context: .init(wasExplicitlyConfirmed: true)) else { return XCTFail() }
            guard case .block = SafetyPolicyEngine().evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail() }
        }
        guard case .allow = SafetyPolicyEngine().evaluate(.removeCommandPractice, context: .init(externalActionsLocked: true)) else { return XCTFail() }
    }
    func testPracticeContextContainsOnlyBoundedSyntheticData() throws {
        let value = try AssistantContextManager().commandPracticeInput(seed: seed, variant: String(repeating: "가", count: 500), index: 1,
            avoidedQuestions: Array(repeating: String(repeating: "나", count: 500), count: 20))
        XCTAssertLessThan(value.count, 1_500)
        XCTAssertFalse(value.contains("recentConversation"))
    }
}
