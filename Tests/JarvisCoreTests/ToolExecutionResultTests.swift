import XCTest
@testable import JarvisCore

final class ToolExecutionResultTests: XCTestCase {
    func testOnlySucceededAndHandedOffAreAccepted() {
        XCTAssertTrue(ToolExecutionResult<Int>.succeeded(30).accepted)
        XCTAssertTrue(ToolExecutionResult<Int>.handedOff(30).accepted)
        XCTAssertFalse(ToolExecutionResult<Int>.failed(message: "실패", retryable: true).accepted)
        XCTAssertFalse(ToolExecutionResult<Int>.unverifiable(message: "확인 불가").accepted)
    }

    func testCoordinatorRejectsDuplicateWork() async {
        let coordinator = ToolExecutionCoordinator()
        let first = Task {
            await coordinator.execute(key: "youtube", timeout: .seconds(1)) {
                try? await Task.sleep(for: .milliseconds(100))
                return .handedOff("youtube")
            }
        }
        try? await Task.sleep(for: .milliseconds(10))

        let duplicate: ToolExecutionResult<String> = await coordinator.execute(key: "youtube") {
            .handedOff("duplicate")
        }

        XCTAssertEqual(
            duplicate,
            .failed(message: "같은 작업을 이미 처리하고 있습니다.", retryable: false)
        )
        _ = await first.value
    }

    func testCoordinatorReturnsTimeout() async {
        let coordinator = ToolExecutionCoordinator()
        let result: ToolExecutionResult<String> = await coordinator.execute(
            key: "slow",
            timeout: .milliseconds(10)
        ) {
            try? await Task.sleep(for: .seconds(1))
            return .succeeded("late")
        }

        XCTAssertEqual(
            result,
            .failed(message: "작업 응답 시간이 초과되었습니다. 실행 여부를 확인한 뒤 다시 요청해주세요.", retryable: false)
        )
    }

    func testTimeoutDoesNotRetryEvenWhenCallerOptedIntoRetry() async {
        let attempts = AttemptCounter()
        let result: ToolExecutionResult<String> = await ToolExecutionCoordinator().execute(
            key: "uncertain-result", timeout: .milliseconds(10), retryPolicy: .once
        ) {
            _ = await attempts.increment()
            try? await Task.sleep(for: .seconds(1))
            return .handedOff("possibly completed")
        }
        XCTAssertFalse(result.accepted)
        let count = await attempts.value
        XCTAssertEqual(count, 1)
    }

    func testAlreadyCancelledTaskNeverStartsTool() async {
        let attempts = AttemptCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ToolExecutionCoordinator().execute(key: "cancelled-before-start") {
                _ = await attempts.increment()
                return ToolExecutionResult<String>.succeeded("not allowed")
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .failed(message: "작업이 취소되었습니다.", retryable: false))
        let count = await attempts.value
        XCTAssertEqual(count, 0)
    }

    func testCancellationDiscardsLateSuccessAndReleasesDuplicateKey() async {
        let coordinator = ToolExecutionCoordinator()
        let attempts = AttemptCounter()
        let task = Task {
            await coordinator.execute(key: "cancel-running", retryPolicy: .once) {
                _ = await attempts.increment()
                try? await Task.sleep(for: .seconds(1))
                return ToolExecutionResult<String>.succeeded("late success")
            }
        }
        while await attempts.value == 0 { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .failed(message: "작업이 취소되었습니다.", retryable: false))
        let count = await attempts.value
        XCTAssertEqual(count, 1)
        let next = await coordinator.execute(key: "cancel-running") { ToolExecutionResult<String>.succeeded("new") }
        XCTAssertEqual(next, .succeeded("new"))
    }

    func testCoordinatorRetriesOnlyRetryableFailures() async {
        let coordinator = ToolExecutionCoordinator()
        let attempts = AttemptCounter()
        let result: ToolExecutionResult<String> = await coordinator.execute(
            key: "retryable",
            retryPolicy: .once
        ) {
            let attempt = await attempts.increment()
            return attempt == 1
                ? .failed(message: "temporary", retryable: true)
                : .succeeded("done")
        }

        XCTAssertEqual(result, .succeeded("done"))
        let retryCount = await attempts.value
        XCTAssertEqual(retryCount, 2)
    }

    func testCoordinatorDoesNotRetryPermissionOrPermanentFailure() async {
        let coordinator = ToolExecutionCoordinator()
        let attempts = AttemptCounter()
        let result: ToolExecutionResult<String> = await coordinator.execute(
            key: "permission",
            retryPolicy: ToolRetryPolicy(maximumAttempts: 3)
        ) {
            _ = await attempts.increment()
            return .needsPermission(message: "권한 필요")
        }

        XCTAssertEqual(result, .needsPermission(message: "권한 필요"))
        let permissionAttempts = await attempts.value
        XCTAssertEqual(permissionAttempts, 1)
    }

    func testExecuteThrowingMapsPermissionAndDoesNotRetryMutation() async {
        struct PermissionError: Error {}
        let coordinator = ToolExecutionCoordinator()
        let attempts = AttemptCounter()

        let result: ToolExecutionResult<String> = await coordinator.executeThrowing(
            key: "permission-throwing",
            retryPolicy: .none,
            operation: {
                _ = await attempts.increment()
                throw PermissionError()
            },
            mapError: { _ in .needsPermission(message: "권한 필요") }
        )

        XCTAssertEqual(result, .needsPermission(message: "권한 필요"))
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 1)
    }

    func testResultMapPreservesNonSuccessState() {
        let success = ToolExecutionResult<Int>.succeeded(3).map { String($0) }
        let handoff = ToolExecutionResult<Int>.handedOff(4).map { String($0) }
        let failure = ToolExecutionResult<Int>.failed(message: "실패", retryable: false).map { String($0) }

        XCTAssertEqual(success, .succeeded("3"))
        XCTAssertEqual(handoff, .handedOff("4"))
        XCTAssertEqual(failure, .failed(message: "실패", retryable: false))
    }
}

private actor AttemptCounter {
    private var count = 0
    var value: Int { count }

    func increment() -> Int {
        count += 1
        return count
    }
}
