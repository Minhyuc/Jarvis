import XCTest
@testable import JarvisCore

final class PersonalAssistantProgressTests: XCTestCase {
    func testSemanticSupplementUsesRegistryAndRouterFirst() async {
        let failures = await EvaluationRunner().runSemantic(CommandEvaluationCorpus.semanticSupplement)
        XCTAssertEqual(failures, [])
    }
    private func place(_ id: String, name: String, open: Bool? = nil, date: Date = Date()) -> NearbyPlace {
        .init(id: id, name: name, address: "테스트 주소", latitude: 37.5, longitude: 127.0,
              sourceLatitude: 37.4, sourceLongitude: 127.0, distance: 300, openNow: open, observedAt: date)
    }

    func testNearbyRoutingAndExplicitMode() {
        XCTAssertEqual(CommandRouter().route("근처에 마트가 어떤 게 있어?"), .nearbyPlaces(category: .market, navigate: false, mode: nil))
        XCTAssertEqual(CommandRouter().route("근처 약국으로 자가용 안내해줘"), .nearbyPlaces(category: .pharmacy, navigate: true, mode: .car))
        XCTAssertEqual(CommandRouter().route("주변 주차장 찾아줘"), .nearbyPlaces(category: .parking, navigate: false, mode: nil))
    }

    func testFiveTurnPlacesWorkflowPreservesIdentityAndCoordinates() {
        let a = place("a", name: "A마트 서초점"), b = place("b", name: "B마트 잠실점")
        var dialogue = NearbyPlaceDialogue(category: .market, candidates: [a, b])
        let resolver = NearbyPlaceFollowUpResolver()
        XCTAssertEqual(resolver.resolve("두 번째 마트 영업 중이야?", dialogue: dialogue), .details(b))
        dialogue.selectedID = b.id
        XCTAssertEqual(resolver.resolve("거기는 어디 있어?", dialogue: dialogue), .details(b))
        XCTAssertEqual(resolver.resolve("거기로 안내해줘", dialogue: dialogue), .navigate(b, nil))
        XCTAssertEqual(resolver.resolve("자가용으로", dialogue: dialogue), .navigate(b, .car))
        XCTAssertEqual(b.navigationCandidate.longitude, 127.0)
    }

    func testNoSelectionDoesNotGuessFirstPlace() {
        let dialogue = NearbyPlaceDialogue(category: .market, candidates: [place("a", name: "A마트"), place("b", name: "B마트")])
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("거기로 안내해줘", dialogue: dialogue), .ambiguous)
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("두 번째 대신 세 번째로 안내해줘", dialogue: dialogue), .ambiguous)
    }

    func testUnknownAndStaleHoursAreNotAsserted() {
        XCTAssertTrue(place("a", name: "A").hoursDescription().contains("확인하지 못"))
        XCTAssertTrue(place("a", name: "A", open: true, date: Date(timeIntervalSinceNow: -301)).hoursDescription().contains("확인하지 못"))
        XCTAssertTrue(place("a", name: "A", open: false).hoursDescription().contains("영업 종료"))
    }

    func testNearbyDialogueRefinementCannotExtendExpiry() {
        let now = Date()
        var state = DialogueStateManager(timeout: 120)
        var value = NearbyPlaceDialogue(category: .market, candidates: [place("a", name: "A")])
        state.begin(.nearbyPlaces(value), now: now)
        _ = state.registerRetry(now: now.addingTimeInterval(10))
        value.selectedID = "a"
        state.updateNearbyPlaces(value, now: now.addingTimeInterval(119))
        XCTAssertEqual(state.current(now: now.addingTimeInterval(119))?.retryCount, 1)
        XCTAssertNil(state.current(now: now.addingTimeInterval(121)))
    }

    func testNewTopicCannotUsePreviousPlace() {
        let value = NearbyPlaceDialogue(category: .market, candidates: [place("a", name: "A마트")], selectedID: "a")
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("서울역으로 자가용 안내해줘", dialogue: value), .unrelated)
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("지금 몇 시야?", dialogue: value), .unrelated)
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("A마트 부산점으로 자가용 안내해줘", dialogue: value), .unrelated)
    }

    func testUniqueBrandCanReferToSearchedBranchButDuplicatesAsk() {
        let a = place("a", name: "A마트 서초점")
        let one = NearbyPlaceDialogue(category: .market, candidates: [a])
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("A마트로 자가용 안내해줘", dialogue: one), .navigate(a, .car))
        let two = NearbyPlaceDialogue(category: .market, candidates: [a, place("b", name: "A마트 잠실점")])
        XCTAssertEqual(NearbyPlaceFollowUpResolver().resolve("A마트로 자가용 안내해줘", dialogue: two), .ambiguous)
    }

    func testCloudCandidateRejectsUnknownAuthorityAndInvalidConfidence() {
        XCTAssertNil(SemanticCandidateDecoder().decode(#"{"capabilityID":"setAlarm","primaryArgument":"3분","secondaryArgument":"","confidence":1}"#))
        XCTAssertNil(SemanticCandidateDecoder().decode(#"{"capabilityID":"call","primaryArgument":"누군가","secondaryArgument":"","confidence":2}"#))
        XCTAssertEqual(SemanticCandidateDecoder().decode(#"{"capabilityID":"nearbyPlaces","primaryArgument":"market","secondaryArgument":"search","confidence":0.9}"#)?.capabilityID, .nearbyPlaces)
    }

    func testLearningPrivacyAndEmergencyLock() {
        let policy = SafetyPolicyEngine()
        for intent in [AssistantIntent.configureImprovementCollection, .assistImprovementData, .runResponseEvaluation] {
            guard case .requireConfirmation = policy.evaluate(intent, context: .init()) else { return XCTFail("explicit consent required") }
            guard case .block = policy.evaluate(intent, context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail("lock must win") }
            guard case .allow = policy.evaluate(intent, context: .init(wasExplicitlyConfirmed: true)) else { return XCTFail("confirmed operation") }
        }
        guard case .allow = policy.evaluate(.deleteImprovementData, context: .init(externalActionsLocked: true)) else { return XCTFail("privacy deletion remains available") }
        guard case .requireConfirmation = policy.evaluate(.navigate(destination: "검증된 장소", mode: .car), context: .init(origin: .modelProposed)) else { return XCTFail("model must not execute navigation") }
    }

    func testActualAnswerRunnerDoesNotPretendToGradeFacts() async throws {
        let run = try await LiveResponseEvaluationRunner().run([.init(id: "water", turns: ["물?"], rubric: "H2O", requiredTerms: ["H2O"])], model: "test", promptVersion: "v1") { _, _ in "H2O입니다." }
        XCTAssertTrue(run.observations[0].automaticChecksPassed)
        XCTAssertEqual(run.reviewedCount, 0)
        XCTAssertTrue(run.passedIDs.isEmpty)
        XCTAssertNil(run.changes(from: run))
    }

    func testReviewedComparisonShowsBothImprovementAndRegression() {
        var one = ResponseQualityObservation(id: "1", turns: ["a"], answers: ["a"], rubric: "a", automaticChecksPassed: true)
        var two = ResponseQualityObservation(id: "2", turns: ["b"], answers: ["b"], rubric: "b", automaticChecksPassed: true)
        one.ratings = Dictionary(uniqueKeysWithValues: ResponseQualityDimension.allCases.map { ($0, 2) })
        two.ratings = Dictionary(uniqueKeysWithValues: ResponseQualityDimension.allCases.map { ($0, 0) })
        let baseline = ResponseQualityRun(model: "a", promptVersion: "v1", observations: [one, two])
        one.ratings[.accuracy] = 0; two.ratings = Dictionary(uniqueKeysWithValues: ResponseQualityDimension.allCases.map { ($0, 2) })
        let latest = ResponseQualityRun(model: "b", promptVersion: "v2", observations: [one, two])
        XCTAssertEqual(latest.changes(from: baseline)?.improved, ["2"])
        XCTAssertEqual(latest.changes(from: baseline)?.regressed, ["1"])
        let changed = ResponseQualityRun(model: "b", promptVersion: "v2", suiteVersion: "different", observations: [one, two])
        XCTAssertNil(changed.changes(from: baseline))
    }

    func testCorrectionEvidenceRequiresReviewAndRetest() {
        var sample = ImprovementExample(question: "q", previousAnswer: "wrong", correction: "그게 아니라")
        sample.assistedAt = Date(); sample.assistedAnswer = "model suggestion"
        XCTAssertFalse(sample.verifiedImprovement)
        sample.approvedAt = Date(); sample.approvedAnswer = "reviewed"
        sample.retestedAt = Date(); sample.retestAnswer = "retested"
        XCTAssertFalse(sample.verifiedImprovement)
        sample.verifiedAt = Date()
        XCTAssertTrue(sample.verifiedImprovement)
    }
}

final class PersonalWorkflowCoreTests: XCTestCase {
    func testCalendarMutationsRouteBeforeReadAndAlarm() {
        XCTAssertEqual(CommandRouter().route("내일 오후 3시 회의 일정 등록해줘"),
            .calendarWorkflow(.draft(.init(title: "회의", time: .atTime(hour: 3, minute: 0, period: .pm, day: .tomorrow)))))
        XCTAssertEqual(CommandRouter().route("회의 일정을 내일 오후 4시로 옮겨줘"),
            .calendarWorkflow(.draft(.init(operation: .move, title: "회의", time: .atTime(hour: 4, minute: 0, period: .pm, day: .tomorrow)))))
        XCTAssertEqual(CommandRouter().route("회의 일정 취소해줘"), .calendarWorkflow(.draft(.init(operation: .delete, title: "회의"))))
        XCTAssertEqual(CommandRouter().route("내일 일정 알려줘"), .calendarWorkflow(.day(offset: 1)))
        XCTAssertEqual(CommandRouter().route("내일 외출 준비 도와줘"), .prepareOuting(dayOffset: 1))
    }

    func testCalendarClarifiesDayThenPeriodAndPinsDate() {
        let parser = CalendarWorkflowParser()
        var draft = CalendarEventDraft(title: "회의", time: .atTime(hour: 3, minute: 0, period: nil, day: .automatic))
        XCTAssertTrue(parser.clarification(for: draft)!.contains("어느 날"))
        draft = parser.refining(draft, with: "내일")
        XCTAssertTrue(parser.clarification(for: draft)!.contains("오전"))
        draft = parser.refining(draft, with: "오후")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let now = calendar.date(from: .init(year: 2026, month: 10, day: 16, hour: 16))!
        let date = parser.date(for: draft, now: now, calendar: calendar)!
        XCTAssertEqual(calendar.component(.day, from: date), 17)
        XCTAssertEqual(calendar.component(.hour, from: date), 15)
        let past = CalendarEventDraft(title: "회의", time: .atTime(hour: 3, minute: 0, period: .pm, day: .today))
        XCTAssertNil(parser.date(for: past, now: now, calendar: calendar))
    }

    func testCalendarDraftKeepsOriginalExpiryAndRetryBudget() {
        let start = Date(timeIntervalSince1970: 100)
        var manager = DialogueStateManager(timeout: 30, maximumRetries: 1)
        manager.begin(.calendarDraft(.init(title: "회의")), now: start)
        _ = manager.registerRetry(now: start.addingTimeInterval(5))
        manager.updateCalendarDraft(.init(title: "수정"), now: start.addingTimeInterval(10))
        XCTAssertEqual(manager.current(now: start.addingTimeInterval(20))?.retryCount, 1)
        XCTAssertNil(manager.current(now: start.addingTimeInterval(31)))
    }

    func testSuggestionRiskTiersCannotBeBypassedByConfirmation() {
        let policy = SafetyPolicyEngine()
        let low = AssistantIntent.setAlarm(request: .afterMinutes(10), label: "준비", message: nil, delivery: .jarvisVoice)
        guard case .allow = policy.evaluate(low, context: .init(origin: .proactiveSuggestion)) else { return XCTFail() }
        guard case .requireConfirmation = policy.evaluate(.navigate(destination: "서울역", mode: .car), context: .init(origin: .proactiveSuggestion)) else { return XCTFail() }
        for confirmed in [false, true] {
            guard case .block = policy.evaluate(.cancelAlarm(.all), context: .init(origin: .proactiveSuggestion, wasExplicitlyConfirmed: confirmed)) else { return XCTFail() }
        }
        guard case .requireConfirmation = policy.evaluate(.remember(content: "선호"), context: .init(origin: .proactiveSuggestion)) else { return XCTFail() }
        guard case .block = policy.evaluate(low, context: .init(origin: .proactiveSuggestion, externalActionsLocked: true)) else { return XCTFail() }
        guard case .allow = policy.evaluate(.pauseMedia, context: .init(origin: .proactiveSuggestion, externalActionsLocked: true)) else { return XCTFail() }
        guard case .requireConfirmation = policy.evaluate(.cancelAlarm(.all), context: .init()) else { return XCTFail() }
    }

    func testWeatherAdviceUsesFactsForRainColdDropAndRange() {
        let now = Date()
        let suggestion = WeatherAdviceEngine().suggestion(for: .init(high: 14, low: 3, rainProbability: 70, yesterdayHigh: 22, observedAt: now), now: now)!
        XCTAssertTrue(suggestion.title.contains("우산"))
        XCTAssertTrue(suggestion.title.contains("8도"))
        XCTAssertTrue(suggestion.title.contains("일교차"))
        XCTAssertTrue(suggestion.reason.contains("70%"))
        XCTAssertNil(suggestion.proposedIntent)
        XCTAssertEqual(suggestion.observedAt, now)
    }

    func testWeatherAdviceDoesNotInventTemperatureDropOrUseStaleData() {
        let now = Date(), engine = WeatherAdviceEngine()
        let cold = engine.suggestion(for: .init(high: 12, low: 4, rainProbability: 0, observedAt: now), now: now)!
        XCTAssertFalse(cold.title.contains("전날"))
        XCTAssertTrue(cold.title.contains("외투"))
        XCTAssertNil(engine.suggestion(for: .init(high: 22, low: 18, rainProbability: 0, observedAt: now), now: now))
        XCTAssertNil(engine.suggestion(for: .init(high: 12, low: 4, rainProbability: 80, observedAt: now.addingTimeInterval(-1_801)), now: now))
        XCTAssertNil(engine.suggestion(for: .init(high: .nan, low: 4, rainProbability: 80, observedAt: now), now: now))
        XCTAssertNil(engine.suggestion(for: .init(high: 12, low: 4, rainProbability: 80, observedAt: now.addingTimeInterval(1)), now: now))
    }

    func testPlanBudgetStopsAtStepLimitTimeoutAndClockRollback() {
        let now = Date()
        var budget = BoundedPlanBudget(now: now)
        XCTAssertTrue(budget.takeStep(now: now)); XCTAssertTrue(budget.takeStep(now: now)); XCTAssertTrue(budget.takeStep(now: now))
        XCTAssertFalse(budget.takeStep(now: now))
        var timeout = BoundedPlanBudget(now: now)
        XCTAssertFalse(timeout.takeStep(now: now.addingTimeInterval(26)))
        XCTAssertFalse(timeout.takeStep(now: now.addingTimeInterval(-1)))
    }
}
