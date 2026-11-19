import XCTest
@testable import JarvisCore

final class EvaluationV2Tests: XCTestCase {
    func testRealisticCorpusContainsThreeHundredDistinctUtterances() {
        let cases = CommandEvaluationCorpus.realisticV2

        XCTAssertGreaterThanOrEqual(cases.count, 300)
        XCTAssertLessThanOrEqual(cases.count, 500)
        XCTAssertEqual(Set(cases.map(\.input)).count, cases.count)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        for tag in EvaluationTag.allCases {
            XCTAssertTrue(cases.contains { $0.tags.contains(tag) }, "Missing coverage for \(tag)")
        }
        for category in RoutingEvaluationCategory.allCases {
            XCTAssertTrue(cases.contains { $0.category == category }, "Missing coverage for \(category)")
        }
    }

    func testRealisticCorpusMeetsAccuracyAndSafetyGates() {
        let report = EvaluationRunner().runV2(
            CommandEvaluationCorpus.realisticV2,
            requiredPassRate: CommandEvaluationCorpus.minimumPassRate
        )

        XCTAssertGreaterThanOrEqual(report.passRate, 0.95, failureSummary(report))
        XCTAssertEqual(report.dangerousMisfireCount, 0, failureSummary(report))
        let speech = report.tagResults.first { $0.tag == .speechRecognitionVariation }
        XCTAssertNotNil(speech)
        XCTAssertGreaterThanOrEqual(speech?.passRate ?? 0, 0.90)
        XCTAssertGreaterThanOrEqual(report.speechVariationPassRate, 0.90)
        XCTAssertEqual(report.ambiguousGuessCount, 0)
        XCTAssertGreaterThanOrEqual(report.totalDurationMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(report.slowestCaseMilliseconds, 0)
        let ambiguousFailures = report.failures.filter {
            $0.type == .ambiguousCommandGuessed
        }
        XCTAssertTrue(ambiguousFailures.isEmpty, failureSummary(report))
    }

    func testStrictGateFailsWhenSpeechVariationOrAmbiguityRegresses() {
        let cases = [
            EvaluationCaseV2(
                id: "speech-regression",
                category: .media,
                input: "유투부 재생",
                expectedIntent: .identifySong,
                tags: [.speechRecognitionVariation],
                inputOrigin: .anonymizedSpeechTranscript
            ),
            EvaluationCaseV2(
                id: "ambiguous-regression",
                category: .safety,
                input: "카카오톡 열어줘",
                expectedIntent: .unknownCommand(text: "카카오톡 열어줘"),
                expectedBehavior: .askForClarification,
                riskLevel: .high,
                tags: [.ambiguous]
            )
        ]

        let report = EvaluationRunner().runV2(cases, requiredPassRate: 0)

        XCTAssertFalse(report.passed)
        XCTAssertLessThan(report.speechVariationPassRate, 0.90)
        XCTAssertEqual(report.ambiguousGuessCount, 1)
    }

    func testFailureTypesDistinguishArgumentsSpeechAmbiguityAndDanger() {
        let cases: [EvaluationCaseV2] = [
            .init(
                id: "argument",
                category: .media,
                input: "유튜브에서 체념 틀어줘",
                expectedIntent: .playYouTube(query: "밤편지")
            ),
            .init(
                id: "speech",
                category: .media,
                input: "유투브에서 체념 틀어줘",
                expectedIntent: .playYouTube(query: "밤편지"),
                tags: [.speechRecognitionVariation]
            ),
            .init(
                id: "ambiguous",
                category: .safety,
                input: "카카오톡 열어줘",
                expectedIntent: .unknownCommand(text: "카카오톡 열어줘"),
                expectedBehavior: .askForClarification,
                riskLevel: .high,
                tags: [.ambiguous]
            ),
            .init(
                id: "danger",
                category: .communication,
                input: "카카오톡 열어줘",
                expectedIntent: .call(recipient: "엄마", speakerRequested: false),
                riskLevel: .high,
                tags: [.safetyCritical]
            )
        ]

        let failures = EvaluationRunner().runV2(cases).failures
        XCTAssertEqual(failures.first { $0.caseID == "argument" }?.type, .argumentExtraction)
        XCTAssertEqual(failures.first { $0.caseID == "speech" }?.type, .speechRecognitionVariation)
        XCTAssertEqual(failures.first { $0.caseID == "ambiguous" }?.type, .ambiguousCommandGuessed)
        XCTAssertEqual(failures.first { $0.caseID == "danger" }?.type, .dangerousCommandMisfire)
    }

    func testSnapshotComparisonFindsNewAndResolvedFailures() {
        let baselineReport = EvaluationReportV2(
            totalCount: 10,
            passedCount: 9,
            requiredPassRate: 0.95,
            categoryResults: [],
            tagResults: [],
            failures: [failure(id: "old")]
        )
        let currentReport = EvaluationReportV2(
            totalCount: 10,
            passedCount: 9,
            requiredPassRate: 0.95,
            categoryResults: [],
            tagResults: [],
            failures: [failure(id: "new")]
        )
        let comparison = EvaluationComparison(
            baseline: EvaluationSnapshot(report: baselineReport, corpusVersion: "old"),
            current: EvaluationSnapshot(report: currentReport, corpusVersion: "new")
        )

        XCTAssertEqual(comparison.newFailureCaseIDs, ["new"])
        XCTAssertEqual(comparison.resolvedFailureCaseIDs, ["old"])
        XCTAssertTrue(comparison.hasRegression)
    }

    func testEvaluationHistoryKeepsNewestTwentySnapshots() {
        let report = EvaluationReportV2(
            totalCount: 10,
            passedCount: 10,
            requiredPassRate: 0.95,
            categoryResults: [],
            tagResults: [],
            failures: []
        )
        var history = EvaluationHistory()
        for index in 0..<25 {
            history.append(EvaluationSnapshot(
                report: report,
                corpusVersion: "v\(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
            ))
        }

        XCTAssertEqual(history.snapshots.count, 20)
        XCTAssertEqual(history.snapshots.first?.corpusVersion, "v5")
        XCTAssertEqual(history.latest?.corpusVersion, "v24")
    }

    func testFiftyMultiTurnScenariosMeetGate() {
        let scenarios = ConversationScenarioCorpus.standard
        let report = ConversationScenarioRunner().run(scenarios)

        XCTAssertEqual(scenarios.count, 50)
        XCTAssertTrue(scenarios.allSatisfy { (3...5).contains($0.turns.count) })
        XCTAssertGreaterThanOrEqual(report.passRate, 0.95, scenarioFailureSummary(report))
    }

    func testFiftyDialogueStateScenariosCoverReplacementCancellationExpiryAndRetries() {
        let scenarios = DialogueStateScenarioCorpus.standard
        let report = DialogueStateScenarioRunner().run(scenarios)

        XCTAssertEqual(scenarios.count, 50)
        XCTAssertTrue(scenarios.allSatisfy { (3...5).contains($0.steps.count) })
        XCTAssertEqual(report.passRate, 1, String(describing: report.failures))
    }

    private func failure(id: String) -> EvaluationFailureV2 {
        EvaluationFailureV2(
            caseID: id,
            category: .conversation,
            input: id,
            expected: .assistantCapabilities,
            actual: .generalConversation(text: id),
            type: .intentClassification
        )
    }

    private func failureSummary(_ report: EvaluationReportV2) -> String {
        report.failures.map {
            "\($0.caseID): \($0.input) [\($0.type.rawValue)] expected=\($0.expected) actual=\($0.actual)"
        }.joined(separator: "\n")
    }

    private func scenarioFailureSummary(_ report: ConversationScenarioReport) -> String {
        report.failures.map {
            "\($0.scenarioID)#\($0.turnIndex + 1): \($0.input)"
        }.joined(separator: "\n")
    }
}
