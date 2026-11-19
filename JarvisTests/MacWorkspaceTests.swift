// Mac 연결과 함께 보존한 통합 테스트. 재활성화 시 함께 복원합니다.
#if false
import XCTest
import Security
@testable import Jarvis

@MainActor
final class MacWorkspaceIntegrationTests: XCTestCase {
    final class Credentials: MacWorkspaceCredentialStoring {
        var value: String?
        var writable = true
        func load() -> String? { value }
        func save(_ json: String) -> Bool { if writable { value = json }; return writable }
        func delete() -> Bool { value = nil; return true }
    }
    actor Transport: MacWorkspaceTransporting {
        var calls = 0
        var delay = false
        var deny = false
        func configure(delay: Bool = false, deny: Bool = false) { self.delay = delay; self.deny = deny }
        func count() -> Int { calls }
        func perform(pairing: MacWorkspacePairing, operation: MacWorkspaceOperation,
                     request: MacWorkspaceRequest) async -> ToolExecutionResult<MacWorkspaceResponse> {
            calls += 1
            if delay { try? await Task.sleep(for: .milliseconds(150)) }
            if deny { return .needsPermission(message: "연결 권한을 확인해주세요.") }
            return .succeeded(.init(version: 1, requestID: request.requestID, projectID: request.projectID,
                projectName: "가상 프로젝트", entries: [.init(path: "main.swift", directory: false)],
                file: nil, matches: [], truncated: false))
        }
    }
    func json(pin: String = String(repeating: "a", count: 64)) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["version": 1, "host": "127.0.0.1", "port": 8765,
            "fingerprint": pin, "token": String(repeating: "b", count: 43),
            "projectID": UUID().uuidString, "projectName": "가상 프로젝트"]), as: UTF8.self)
    }
    func testPairingRequiresConfirmationAndLockWins() throws {
        let credentials = Credentials(), transport = Transport()
        var locked = false
        let store = MacWorkspaceStore(transport: transport, credentials: credentials, locked: { locked })
        guard case .needsConfirmation = store.configure(try json(), confirmed: false) else { return XCTFail() }
        XCTAssertNil(credentials.value)
        locked = true
        guard case .failed = store.configure(try json(), confirmed: true) else { return XCTFail() }
        XCTAssertNil(store.pairing)
    }
    func testOnlyValidatedPairingFieldsAreStoredWithoutStartingNetwork() async throws {
        let credentials = Credentials(), transport = Transport()
        let store = MacWorkspaceStore(transport: transport, credentials: credentials, locked: { false })
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json().utf8)) as? [String: Any])
        value["command"] = "not executable"
        let input = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        guard case .succeeded = store.configure(input, confirmed: true) else { return XCTFail() }
        let saved = try XCTUnwrap(credentials.value)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        XCTAssertNil(decoded["command"])
        let calls = await transport.count()
        XCTAssertEqual(calls, 0)
    }
    func testVerifiedListAndDeniedPermissionDoNotClaimSameResult() async throws {
        let credentials = Credentials(), transport = Transport()
        let store = MacWorkspaceStore(transport: transport, credentials: credentials, locked: { false })
        _ = store.configure(try json(), confirmed: true)
        XCTAssertFalse(store.verified)
        await store.browse()
        XCTAssertTrue(store.verified); XCTAssertEqual(store.entries.count, 1)
        await transport.configure(deny: true)
        await store.browse()
        XCTAssertFalse(store.verified); XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.message.contains("권한"))
    }
    func testLockedReadNeverCallsTransportAndStopStillWorks() async throws {
        let credentials = Credentials(), transport = Transport()
        var locked = false
        let store = MacWorkspaceStore(transport: transport, credentials: credentials, locked: { locked })
        _ = store.configure(try json(), confirmed: true)
        locked = true
        await store.browse()
        let count = await transport.count()
        XCTAssertEqual(count, 0)
        store.cancel()
        guard case .succeeded = store.disconnect() else { return XCTFail() }
        XCTAssertNil(credentials.value)
    }
    func testCancelledOrDisconnectedLateResultCannotReappear() async throws {
        let credentials = Credentials(), transport = Transport()
        await transport.configure(delay: true)
        let store = MacWorkspaceStore(transport: transport, credentials: credentials, locked: { false })
        for disconnect in [false, true] {
            _ = store.configure(try json(), confirmed: true)
            let task = Task { await store.browse() }
            let deadline = Date().addingTimeInterval(3)
            while !store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(store.busy)
            if disconnect { _ = store.disconnect() } else { store.cancel() }
            await task.value
            XCTAssertTrue(store.entries.isEmpty); XCTAssertNil(store.document); XCTAssertFalse(store.verified)
        }
    }
    func testLockDuringRequestDiscardsResponse() async throws {
        let transport = Transport()
        await transport.configure(delay: true)
        var locked = false
        let store = MacWorkspaceStore(transport: transport, credentials: Credentials(), locked: { locked })
        _ = store.configure(try json(), confirmed: true)
        let task = Task { await store.browse() }
        let deadline = Date().addingTimeInterval(3)
        while !store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        locked = true
        await task.value
        XCTAssertTrue(store.entries.isEmpty); XCTAssertFalse(store.verified)
    }
    func testFailedCredentialSaveKeepsPreviousConfiguration() throws {
        let credentials = Credentials()
        let store = MacWorkspaceStore(transport: Transport(), credentials: credentials, locked: { false })
        _ = store.configure(try json(), confirmed: true)
        let previous = store.pairing
        credentials.writable = false
        guard case .failed = store.configure(try json(), confirmed: true) else { return XCTFail() }
        XCTAssertEqual(store.pairing, previous)
    }

    func testPinnedTLSStillChecksIdentityHostPortAndExpiry() throws {
        // Public, self-signed test certificate only. No private key is retained.
        let encoded = "MIIEATCCAmmgAwIBAgIJAI35FGFJeEDtMA0GCSqGSIb3DQEBCwUAMBwxGjAYBgNVBAMMEUpBUlZJUyBNYWMgUmVhZGVyMB4XDTI2MTAyMTExMzM1OFoXDTI3MTAyMTExMzM1OFowHDEaMBgGA1UEAwwRSkFSVklTIE1hYyBSZWFkZXIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQCwM9qALq337WHTfUfUheF14KhiXYF/4zrrBDADCdMbT3ZSJ4AgS7MwjQykfz4ft7Kjo8IdazVN7SnzHP6xfN/JmZGnURjZdTRMBr2Td8miRlgfmTD+duPwooC5VtvD+yXStZvITW7fZRaLjXTc8vlOGjF70kS6NDsZmW70JvSA46HGkG590Sjz8hNAXU1SvC9muUTx8MtrmtJHOsze1/NjzypU6yd9F6ad4mfHS40gB9qbqH8lg7xJ5CpGSg5YQCcTofeORM18nx1AIVuhn04f7KJRgZWOekdeZLNzOiKh5oIIqDdDwYqHdflufom/+LIzRzABF8IAI6aR+v1UBjZppGXgLAYQ0XWbFqcOOJahBSlGp/EPfMwSkK0WXYUlIptsoh2+OPFGao+nfU3kEsM9Va0UDpQmAWtR1i8CPol1Y6aBpsAYGceYBZKTghQpTcEdOhsRplgjGAbya1js9yjhlG70wwh6+uEDAssu9JqJFL0loBHc+VKANZhzAI8PG18CAwEAAaNGMEQwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0RBAgwBocEfwAAATANBgkqhkiG9w0BAQsFAAOCAYEAkrHBOgXbJsgzBeYIHNCpMHqD4t09DdKux0oLDG6lj3RANvhz9K2u9PJXyhAISR97kkVbxxIpJQdnjaLs3lgHOA7icX7wil8ROev00N1ahiSBSfWaXpQVwpB+M7ONCOuQqMrZPqs+tMoxIFOVu6NkySM2xVatbDT5qNGkSDFfUAirg/F3NVbUpy1l3LjJfYKj+iMo3GfBJHjeIa3WvejjJW5pM2y9SGQi/jdmzHGnflwZIMZ1H7gBSQRG2t2u9wfOkhOu2i9xUN/oSg+Eq9Sd3zrZOz2H/h7gXHr4BHsFro3fFX1kv71vrhq2OlQ7/Y3+pnLZ+ol9otq8AX7X10/7jHgRQbrrm+ubbDk6tdlb9PFIznJqulCVQQ1zNVqCeT59gztXMf2ngR6wZcRB5GAiT4LnaeUMTYjvi6amI6CQBj0AJeINIMx9GQ5pwBc6TZwrng1LL3oEQHgjcQ8MXPWzbK6HLKLk99jnWhBSXEoAI5eJzWEJTJSnZmexZjo8EKl2"
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        var optional: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &optional), errSecSuccess)
        let trust = try XCTUnwrap(optional)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z"))
        SecTrustSetVerifyDate(trust, date as CFDate)
        let pairing = try MacWorkspacePairing(json: json(pin: MacWorkspaceTLSDelegate.fingerprint(data)))
        XCTAssertTrue(MacWorkspaceTLSDelegate.accepts(trust, host: "127.0.0.1", port: 8765, pairing: pairing))
        XCTAssertFalse(MacWorkspaceTLSDelegate.accepts(trust, host: "192.168.1.2", port: 8765, pairing: pairing))
        XCTAssertFalse(MacWorkspaceTLSDelegate.accepts(trust, host: "127.0.0.1", port: 9999, pairing: pairing))
        let wrongPin = try MacWorkspacePairing(json: json())
        XCTAssertFalse(MacWorkspaceTLSDelegate.accepts(trust, host: "127.0.0.1", port: 8765, pairing: wrongPin))
        SecTrustSetVerifyDate(trust, date.addingTimeInterval(800 * 86_400) as CFDate)
        XCTAssertFalse(MacWorkspaceTLSDelegate.accepts(trust, host: "127.0.0.1", port: 8765, pairing: pairing))
    }
}
#endif
