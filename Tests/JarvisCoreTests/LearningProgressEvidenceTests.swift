import XCTest
@testable import JarvisCore

final class LearningProgressEvidenceTests: XCTestCase {
    private func snapshot(passed: Int, version: String = "same", at: Double, failures: [String] = []) -> EvaluationSnapshot {
        let report = EvaluationReportV2(
            totalCount: 10, passedCount: passed, requiredPassRate: 0.95,
            categoryResults: [.init(category: .conversation, totalCount: 10, passedCount: passed)],
            tagResults: [],
            failures: failures.map { .init(caseID: $0, category: .conversation, input: "fixture", expected: .assistantCapabilities, actual: .dismissConversation, type: .intentClassification) }
        )
        return .init(report: report, corpusVersion: version, createdAt: Date(timeIntervalSince1970: at))
    }

    func testReportsWhichAreaImprovedOnlyForComparableNonRegressingResults() {
        let evidence = LearningProgressEvidence(baseline: snapshot(passed: 8, at: 1, failures: ["a", "b"]), current: snapshot(passed: 10, at: 2))
        XCTAssertEqual(evidence.status, .improved)
        XCTAssertEqual(evidence.improvedCategories["conversation"] ?? 0, 0.2, accuracy: 0.00001)
        XCTAssertEqual(evidence.resolvedFailures, 2)
    }

    func testChangedDatasetAndNewFailureAreNotLearningSuccess() {
        XCTAssertEqual(LearningProgressEvidence(baseline: snapshot(passed: 8, at: 1), current: snapshot(passed: 10, version: "different", at: 2)).status, .incomparable)
        XCTAssertEqual(LearningProgressEvidence(baseline: snapshot(passed: 10, at: 1), current: snapshot(passed: 9, at: 2, failures: ["new"])).status, .regression)
        XCTAssertEqual(LearningProgressEvidence(baseline: nil, current: snapshot(passed: 10, at: 2)).status, .needsBaseline)
    }
}
