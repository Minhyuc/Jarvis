import Foundation

@MainActor
protocol CodexServiceTransport: AnyObject {
    var onDisconnect: (() -> Void)? { get set }
    var installedBuild: String? { get }
    var matchesInstalledBuild: Bool { get }
    func start(completion: @escaping (Data?, String?) -> Void)
    func stop()
}

/// Owns one private XPC connection. It never persists pairing data or retries.
@MainActor
final class CodexManagedService: CodexServiceTransport {
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var timer: Task<Void, Never>?
    private var completion: ((Data?, String?) -> Void)?
    var onDisconnect: (() -> Void)?
    private var pairedBuild: String?
    var installedBuild: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/JARVISCodexService.xpc")
        return try? CodexServiceIdentity.requirement(for: url)
    }
    var matchesInstalledBuild: Bool { pairedBuild != nil && pairedBuild == installedBuild }

    func start(completion: @escaping (Data?, String?) -> Void) {
        stop()
        let stamp = UUID(); generation = stamp; self.completion = completion
        do {
            let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/JARVISCodexService.xpc")
            let requirement = try CodexServiceIdentity.requirement(for: url)
            pairedBuild = requirement
            let peer = NSXPCConnection(serviceName: CodexServiceIdentity.identifier)
            peer.setCodeSigningRequirement(requirement)
            peer.remoteObjectInterface = NSXPCInterface(with: JARVISCodexServiceProtocol.self)
            let failed: () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == stamp else { return }
                    if self.completion != nil {
                        self.finish(stamp, data: nil, error: "앱의 전용 보조 서비스 연결이 끊겼습니다. 자동으로 다시 요청하지 않습니다.")
                    } else { self.stop(); self.onDisconnect?() }
                }
            }
            peer.interruptionHandler = failed; peer.invalidationHandler = failed
            connection = peer; peer.resume()
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.finish(stamp, data: nil, error: "서비스 시작 시간이 초과되었습니다. 앱 서명과 Python·Codex 설치를 확인하세요.")
            }
            let proxy = peer.remoteObjectProxyWithErrorHandler { _ in failed() } as? JARVISCodexServiceProtocol
            guard let proxy else { failed(); return }
            proxy.start { [weak self] data, error in
                Task { @MainActor in self?.finish(stamp, data: data, error: error) }
            }
        } catch { finish(stamp, data: nil, error: "서명된 내장 서비스를 찾지 못했습니다. 최신 JARVIS Mac 앱으로 다시 빌드하세요.") }
    }
    private func finish(_ stamp: UUID, data: Data?, error: String?) {
        guard generation == stamp, let callback = completion else { return }
        completion = nil; timer?.cancel(); timer = nil
        if data == nil { stop() }
        callback(data, error)
    }
    func stop() {
        generation = UUID(); timer?.cancel(); timer = nil
        let callback = completion; completion = nil
        callback?(nil, "서비스 시작을 취소했습니다.")
        // Invalidation also closes Python's stdin, including when the app exits.
        connection?.invalidate(); connection = nil
        pairedBuild = nil
    }
    deinit { connection?.invalidate(); timer?.cancel() }
}
