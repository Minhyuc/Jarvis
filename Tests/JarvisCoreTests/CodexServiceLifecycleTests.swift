import XCTest
@testable import JarvisCore

final class CodexServiceLifecycleTests: XCTestCase {
    private let url = "https://auth.openai.com/oauth/authorize?response_type=code&state=synthetic&code_challenge=fake&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"
    func testOAuthURLMustHaveExactOriginAndLocalPKCECallback() {
        XCTAssertNotNil(CodexLoginURL.validated(url))
        for bad in [url.replacingOccurrences(of: "auth.openai.com", with: "auth.openai.com.evil.test"),
                    url.replacingOccurrences(of: "https://", with: "http://"),
                    url.replacingOccurrences(of: "auth.openai.com", with: "user@auth.openai.com"),
                    url.replacingOccurrences(of: "1455", with: "99999"),
                    url.replacingOccurrences(of: "127.0.0.1", with: "evil.test"),
                    url.replacingOccurrences(of: "S256", with: "plain"),
                    url + "&state=duplicate", url + "#fragment", url + "\n"] {
            XCTAssertNil(CodexLoginURL.validated(bad))
        }
    }
    func testRecoveryLeaseCannotChangeBackendBuildOrRunWhileLockedAndIsBounded() {
        let now = Date(), mono = ContinuousClock.now
        var budget = CodexServiceRecoveryBudget(now: now, backend: .appServer, build: "build-a", monotonicNow: mono)
        XCTAssertFalse(budget.claim(now: now, backend: .cli, build: "build-a", locked: false))
        XCTAssertFalse(budget.claim(now: now, backend: .appServer, build: "build-b", locked: false))
        XCTAssertFalse(budget.claim(now: now, backend: .appServer, build: "build-a", locked: true))
        XCTAssertEqual(budget.remaining, 2)
        XCTAssertTrue(budget.claim(now: now, backend: .appServer, build: "build-a", locked: false))
        XCTAssertTrue(budget.claim(now: now, backend: .appServer, build: "build-a", locked: false))
        XCTAssertFalse(budget.claim(now: now, backend: .appServer, build: "build-a", locked: false))
        var expired = CodexServiceRecoveryBudget(now: now, backend: .cli, build: "a", monotonicNow: mono)
        XCTAssertFalse(expired.claim(now: now, backend: .cli, build: "a", locked: false, monotonicNow: mono.advanced(by: .seconds(600))))
        XCTAssertFalse(expired.claim(now: now.addingTimeInterval(601), backend: .cli, build: "a", locked: false))
    }
    func testLoginRPCIsAppServerOnlyAndCarriesNoCallerCredentialsOrPaths() throws {
        let id = UUID()
        let descriptor: [String: Any] = ["format": 1, "port": 54321, "sessionID": UUID().uuidString, "token": String(repeating: "a", count: 64)]
        let connection = try CodexLocalConnection.read(JSONSerialization.data(withJSONObject: descriptor))
        for action in [CodexLocalAction.loginStart, .loginPoll, .loginCancel, .logout] {
            XCTAssertThrowsError(try connection.request(action, id: id, backend: .cli))
            let request = try connection.request(action, id: id, backend: .appServer)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            XCTAssertEqual(Set(body.keys), ["requestID", "sessionID", "backend"])
        }
        var reply: [String: Any] = ["format": 1, "sessionID": connection.sessionID.uuidString,
            "requestID": id.uuidString, "status": "succeeded", "protocolVersion": 3, "backend": "appServer", "authVersion": 1, "authURL": url]
        func parse(_ action: CodexLocalAction = .loginStart) throws -> CodexLocalReply {
            try CodexLocalReply.validated(JSONSerialization.data(withJSONObject: reply), connection: connection, id: id, action: action, backend: .appServer)
        }
        XCTAssertFalse(try parse().requiresUpdate(for: .loginStart, backend: .appServer))
        XCTAssertThrowsError(try parse(.chat))
        reply["authVersion"] = nil
        XCTAssertTrue(try parse().requiresUpdate(for: .loginStart, backend: .appServer))
        reply["authURL"] = "https://evil.test"
        XCTAssertThrowsError(try parse())
        reply["authURL"] = nil
        XCTAssertThrowsError(try parse())
    }
}
