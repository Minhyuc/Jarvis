import Foundation

public enum ToolExecutionResult<Value: Sendable>: Sendable {
    /// The app verified the requested local state change or received a verified result.
    case succeeded(Value)
    /// iOS accepted a request to another app. The final outcome is not observable.
    case handedOff(Value)
    case needsPermission(message: String)
    case needsConfirmation(message: String)
    case failed(message: String, retryable: Bool)
    case unverifiable(message: String)

    public var accepted: Bool {
        switch self {
        case .succeeded, .handedOff: true
        case .needsPermission, .needsConfirmation, .failed, .unverifiable: false
        }
    }
}

public enum ToolExecutionStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case handedOff
    case needsPermission
    case needsConfirmation
    case failed
    case unverifiable
}

public extension ToolExecutionResult {
    var status: ToolExecutionStatus {
        switch self {
        case .succeeded: .succeeded
        case .handedOff: .handedOff
        case .needsPermission: .needsPermission
        case .needsConfirmation: .needsConfirmation
        case .failed: .failed
        case .unverifiable: .unverifiable
        }
    }

    func map<Mapped: Sendable>(
        _ transform: @Sendable (Value) -> Mapped
    ) -> ToolExecutionResult<Mapped> {
        switch self {
        case .succeeded(let value): .succeeded(transform(value))
        case .handedOff(let value): .handedOff(transform(value))
        case .needsPermission(let message): .needsPermission(message: message)
        case .needsConfirmation(let message): .needsConfirmation(message: message)
        case .failed(let message, let retryable): .failed(message: message, retryable: retryable)
        case .unverifiable(let message): .unverifiable(message: message)
        }
    }
}

extension ToolExecutionResult: Equatable where Value: Equatable {}

public struct ToolRetryPolicy: Equatable, Sendable {
    public let maximumAttempts: Int

    public init(maximumAttempts: Int = 1) {
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public static let none = ToolRetryPolicy()
    public static let once = ToolRetryPolicy(maximumAttempts: 2)
}

/// Prevents identical tool work from being started twice and provides a common
/// timeout result. Tool implementations must remain cancellation-cooperative.
public actor ToolExecutionCoordinator {
    public static let shared = ToolExecutionCoordinator()
    private var activeKeys: Set<String> = []

    public init() {}

    public func execute<Value: Sendable>(
        key: String,
        timeout: Duration = .seconds(15),
        retryPolicy: ToolRetryPolicy = .none,
        operation: @escaping @Sendable () async -> ToolExecutionResult<Value>
    ) async -> ToolExecutionResult<Value> {
        guard !Task.isCancelled else {
            return .failed(message: "작업이 취소되었습니다.", retryable: false)
        }
        guard activeKeys.insert(key).inserted else {
            return .failed(message: "같은 작업을 이미 처리하고 있습니다.", retryable: false)
        }
        defer { activeKeys.remove(key) }

        var attempt = 1
        while true {
            let result = await executeOnce(timeout: timeout, operation: operation)
            guard !Task.isCancelled else {
                return .failed(message: "작업이 취소되었습니다.", retryable: false)
            }
            if case .failed(_, let retryable) = result,
               retryable,
               attempt < retryPolicy.maximumAttempts,
               !Task.isCancelled {
                attempt += 1
                continue
            }
            return result
        }
    }

    /// Adapts legacy throwing APIs at the common execution boundary. The error
    /// mapper must distinguish permission denial from transient transport
    /// failures; callers must opt in to retries only for idempotent operations.
    public func executeThrowing<Value: Sendable>(
        key: String,
        timeout: Duration = .seconds(15),
        retryPolicy: ToolRetryPolicy = .none,
        operation: @escaping @Sendable () async throws -> Value,
        mapError: @escaping @Sendable (Error) -> ToolExecutionResult<Value>
    ) async -> ToolExecutionResult<Value> {
        await execute(key: key, timeout: timeout, retryPolicy: retryPolicy) {
            do {
                return .succeeded(try await operation())
            } catch is CancellationError {
                return .failed(message: "작업이 취소되었습니다.", retryable: false)
            } catch {
                return mapError(error)
            }
        }
    }

    private func executeOnce<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async -> ToolExecutionResult<Value>
    ) async -> ToolExecutionResult<Value> {
        await withTaskGroup(of: ToolExecutionResult<Value>.self) { group in
            group.addTask {
                guard !Task.isCancelled else {
                    return .failed(message: "작업이 취소되었습니다.", retryable: false)
                }
                return await operation()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    // A timeout does not prove that a side effect did not occur.
                    // Never automatically repeat work with an unknown outcome.
                    return .failed(message: "작업 응답 시간이 초과되었습니다. 실행 여부를 확인한 뒤 다시 요청해주세요.", retryable: false)
                } catch {
                    return .failed(message: "작업이 취소되었습니다.", retryable: false)
                }
            }
            let result = await group.next()
                ?? .failed(message: "작업 결과를 확인하지 못했습니다.", retryable: true)
            group.cancelAll()
            return result
        }
    }
}
