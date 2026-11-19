// Mac 연결 보류. 코드는 보존하되 앱에 컴파일하지 않습니다.
#if false
import Combine
import CryptoKit
import Foundation
import Security

enum MacWorkspaceOperation: String, Sendable { case list, read, search }

protocol MacWorkspaceTransporting: Sendable {
    func perform(pairing: MacWorkspacePairing, operation: MacWorkspaceOperation,
                 request: MacWorkspaceRequest) async -> ToolExecutionResult<MacWorkspaceResponse>
}

/// Trust exactly the out-of-band pinned identity, still checking host and validity.
/// No insecure HTTP, redirects, URL credentials, background transfer or AI calls.
final class MacWorkspaceTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let pairing: MacWorkspacePairing
    init(pairing: MacWorkspacePairing) { self.pairing = pairing }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.accepts(trust, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port, pairing: pairing)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    static func accepts(_ trust: SecTrust, host: String, port: Int, pairing: MacWorkspacePairing) -> Bool {
        guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        guard host == pairing.host, port == pairing.port,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first,
              Self.fingerprint(SecCertificateCopyData(certificate) as Data) == pairing.fingerprint.lowercased(),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, pairing.host as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            return false
        }
        return true
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MacWorkspaceTransport: MacWorkspaceTransporting {
    func perform(pairing: MacWorkspacePairing, operation: MacWorkspaceOperation,
                 request: MacWorkspaceRequest) async -> ToolExecutionResult<MacWorkspaceResponse> {
        var components = URLComponents()
        components.scheme = "https"; components.host = pairing.host; components.port = pairing.port
        components.path = "/v1/\(operation.rawValue)"
        guard let url = components.url else { return .failed(message: "Mac 연결 주소를 확인해주세요.", retryable: false) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: MacWorkspaceTLSDelegate(pairing: pairing), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            var http = URLRequest(url: url)
            http.httpMethod = "POST"; http.httpBody = try JSONEncoder().encode(request)
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await session.bytes(for: http)
            guard let response = response as? HTTPURLResponse else { throw MacWorkspaceValidationError.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 401: return .needsPermission(message: "Mac 연결 토큰이 만료되었거나 맞지 않습니다. Mac의 새 연결 정보를 등록해주세요.")
            case 403: return .needsPermission(message: "허용되지 않은 경로·파일이거나 읽을 수 없는 파일입니다. Mac의 공유 폴더와 파일 제한을 확인해주세요.")
            case 429: return .failed(message: "Mac 조회 한도에 도달했습니다. 잠시 후 직접 다시 시도해주세요.", retryable: false)
            default: return .failed(message: "Mac 읽기 서비스가 요청을 처리하지 못했습니다.", retryable: false)
            }
            guard response.expectedContentLength <= 262_144 else { throw MacWorkspaceValidationError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 262_144 else { throw MacWorkspaceValidationError.invalidResponse }
                data.append(byte)
            }
            let result = try JSONDecoder().decode(MacWorkspaceResponse.self, from: data)
            try result.validate(for: request)
            if operation == .read {
                guard let file = result.file,
                      MacWorkspaceTLSDelegate.fingerprint(Data(file.text.utf8)) == file.sha256.lowercased() else {
                    throw MacWorkspaceValidationError.invalidResponse
                }
            }
            return .succeeded(result)
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .failed(message: "Mac 조회를 중지했습니다.", retryable: false)
            }
            return .failed(message: "Mac에 연결하지 못했습니다. 같은 네트워크·서비스 실행·인증서·로컬 네트워크 권한을 확인해주세요. 인증서 검증은 생략하지 않습니다.", retryable: false)
        }
    }
}

protocol MacWorkspaceCredentialStoring {
    func load() -> String?
    func save(_ json: String) -> Bool
    func delete() -> Bool
}

struct MacWorkspaceCredentials: MacWorkspaceCredentialStoring {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.minhyuc.jarvis.mac-reader", kSecAttrAccount as String: "pairing-v1"] }
    func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ json: String) -> Bool {
        let values: [String: Any] = [kSecValueData as String: Data(json.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    func delete() -> Bool {
        let result = SecItemDelete(query as CFDictionary)
        return result == errSecSuccess || result == errSecItemNotFound
    }
}

/// A separate read-only space. Contents never enter chat, memories or cloud AI.
@MainActor
final class MacWorkspaceStore: ObservableObject {
    static let shared = MacWorkspaceStore()
    @Published private(set) var pairing: MacWorkspacePairing?
    @Published private(set) var entries: [MacWorkspaceEntry] = []
    @Published private(set) var matches: [MacWorkspaceMatch] = []
    @Published private(set) var document: MacWorkspaceFile?
    @Published private(set) var path = ""
    @Published private(set) var busy = false
    @Published private(set) var verified = false
    @Published private(set) var partial = false
    @Published private(set) var message = "Mac을 연결하면 지정한 프로젝트를 읽기 전용으로 확인할 수 있습니다."
    private let transport: any MacWorkspaceTransporting
    private let credentials: any MacWorkspaceCredentialStoring
    private let locked: () -> Bool
    private var generation = UUID()
    private var work: Task<ToolExecutionResult<MacWorkspaceResponse>, Never>?
    private var observer: AnyCancellable?

    init(transport: any MacWorkspaceTransporting = MacWorkspaceTransport(),
         credentials: any MacWorkspaceCredentialStoring = MacWorkspaceCredentials(),
         locked: @escaping () -> Bool = { SafetyControlStore.externalActionsLocked }) {
        self.transport = transport; self.credentials = credentials; self.locked = locked
        if let json = credentials.load() { pairing = try? MacWorkspacePairing(json: json) }
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.locked() else { return }
                self.invalidate(); self.message = "안전 잠금으로 Mac 조회를 중단하고 화면 내용을 지웠습니다."
            }
    }

    @discardableResult
    func configure(_ json: String, confirmed: Bool) -> ToolExecutionResult<Void> {
        guard let denial = denial(for: .configure, confirmed: confirmed) else {
            do {
                let candidate = try MacWorkspacePairing(json: json)
                let canonical = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
                guard credentials.save(canonical) else {
                    message = "연결 정보를 Keychain에 저장하지 못했습니다. 이전 연결 정보는 유지했습니다."
                    return .failed(message: message, retryable: false)
                }
                invalidate(); pairing = candidate
                message = "연결 정보를 저장했습니다. 프로젝트 불러오기를 눌러 실제 연결을 확인해주세요."
                return .succeeded(())
            } catch {
                message = MacWorkspaceValidationError.invalidPairing.localizedDescription
                return .failed(message: message, retryable: false)
            }
        }
        show(denial)
        return denial
    }

    @discardableResult
    func disconnect() -> ToolExecutionResult<Void> {
        if let denial = denial(for: .disconnect) { return denial }
        invalidate(); pairing = nil
        if !credentials.delete() {
            message = "조회는 중지했지만 저장된 연결 정보를 삭제하지 못했습니다. 다시 삭제하거나 Mac 서비스를 중지해주세요."
            return .unverifiable(message: message)
        }
        message = "이 아이폰의 연결 정보를 삭제했습니다. 다른 연결도 폐기하려면 Mac 서비스를 중지해주세요."
        return .succeeded(())
    }

    func cancel() {
        guard denial(for: .cancel) == nil else { return }
        invalidate(); message = "Mac 조회를 중지하고 읽은 내용을 지웠습니다."
    }

    func browse(_ path: String = "") async { await perform(.list, path: path) }
    func read(_ path: String) async { await perform(.read, path: path) }
    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "검색어를 입력해주세요."; return }
        await perform(.search, path: path, query: query)
    }

    private func perform(_ operation: MacWorkspaceOperation, path: String, query: String = "") async {
        let action: MacWorkspaceAction = operation == .list ? .browse : operation == .read ? .read : .search
        if let denial = denial(for: action) { show(denial); return }
        guard let pairing else { message = "Mac 연결 정보를 먼저 등록해주세요."; return }
        invalidate(clearPath: false); busy = true
        let epoch = generation
        do {
            let request = try MacWorkspaceRequest(projectID: pairing.projectID, path: path, query: query)
            let transport = transport
            let job = Task<ToolExecutionResult<MacWorkspaceResponse>, Never> {
                await ToolExecutionCoordinator.shared.execute(key: "mac-workspace-read", timeout: .seconds(18)) { @MainActor [weak self] in
                    guard let self, epoch == self.generation, !self.locked(), !Task.isCancelled else {
                        return ToolExecutionResult<MacWorkspaceResponse>.failed(
                            message: "취소 또는 안전 잠금으로 Mac 요청을 보내지 않았습니다.", retryable: false)
                    }
                    return await transport.perform(pairing: pairing, operation: operation, request: request)
                }
            }
            work = job
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard epoch == generation else { return }
            work = nil; busy = false
            guard !Task.isCancelled, !locked() else { invalidate(); message = "취소 또는 안전 잠금으로 결과를 폐기했습니다."; return }
            switch result {
            case .succeeded(let response):
                try response.validate(for: request)
                verified = true; partial = response.truncated
                if operation == .list { self.path = path; entries = response.entries }
                document = response.file; matches = response.matches
                message = "Mac의 읽기 결과를 확인했습니다. 파일 수정·명령 실행·AI 전송은 하지 않았습니다."
            case .handedOff: message = "Mac 읽기 결과를 확인하지 못했습니다."
            case .needsPermission(let text), .needsConfirmation(let text), .failed(let text, _), .unverifiable(let text): message = text
            }
        } catch {
            if epoch == generation { busy = false; message = "요청 또는 Mac 응답 정보를 확인하지 못했습니다." }
        }
    }

    private func invalidate(clearPath: Bool = true) {
        generation = UUID(); work?.cancel(); work = nil; busy = false; verified = false
        entries = []; matches = []; document = nil; partial = false
        if clearPath { path = "" }
    }
    private func show(_ result: ToolExecutionResult<Void>) {
        switch result {
        case .needsPermission(let value), .needsConfirmation(let value), .failed(let value, _), .unverifiable(let value):
            invalidate(); message = value
        case .succeeded, .handedOff: break
        }
    }
    private func denial(for action: MacWorkspaceAction, confirmed: Bool = false) -> ToolExecutionResult<Void>? {
        switch SafetyPolicyEngine().evaluate(.macWorkspace(action), context: .init(
            externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .allow(let risk, let name):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: confirmed ? .confirmed : .authorized)
            return nil
        case .requireConfirmation(let risk, let name, let prompt):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .awaitingConfirmation)
            return .needsConfirmation(message: prompt)
        case .block(let risk, let name, let reason):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .blocked)
            return .failed(message: reason, retryable: false)
        }
    }
}
#endif
