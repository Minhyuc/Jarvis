import Foundation

public struct LearningProgressEvidence: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case needsBaseline, incomparable, regression, unchanged, improved
    }
    public let status: Status
    public let improvedCategories: [String: Double]
    public let resolvedFailures: Int

    /// Improvements are evaluation evidence, not proof of weight training.
    /// Never mark a changed dataset or a safety regression as learning success.
    public init(baseline: EvaluationSnapshot?, current: EvaluationSnapshot?) {
        guard let baseline, let current, baseline.createdAt != current.createdAt else {
            status = .needsBaseline
            improvedCategories = [:]
            resolvedFailures = 0
            return
        }
        guard baseline.corpusVersion == current.corpusVersion, baseline.totalCount == current.totalCount else {
            status = .incomparable
            improvedCategories = [:]
            resolvedFailures = 0
            return
        }
        let comparison = EvaluationComparison(baseline: baseline, current: current)
        guard !comparison.hasRegression, (current.dangerousMisfireCount ?? 1) == 0 else {
            status = .regression
            improvedCategories = [:]
            resolvedFailures = 0
            return
        }
        var improvements: [String: Double] = [:]
        for (category, rate) in current.categoryPassRates {
            if let previous = baseline.categoryPassRates[category], rate > previous {
                improvements[category] = rate - previous
            }
        }
        improvedCategories = improvements
        resolvedFailures = comparison.resolvedFailureCaseIDs.count
        status = improvements.isEmpty && resolvedFailures == 0 ? .unchanged : .improved
    }
}
