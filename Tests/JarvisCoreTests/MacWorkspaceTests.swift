import XCTest
@testable import JarvisCore

final class MacWorkspaceTests: XCTestCase {
    func pairing(host: String = "192.168.1.20", port: Int = 8765, pin: String = String(repeating: "a", count: 64)) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "host": host, "port": port,
            "fingerprint": pin, "token": String(repeating: "b", count: 43),
            "projectID": UUID().uuidString, "projectName": "가상 프로젝트"])
        return String(decoding: data, as: UTF8.self)
    }

    func testPairingRejectsPublicWildcardHostnameBadPinAndPort() throws {
        XCTAssertNoThrow(try MacWorkspacePairing(json: pairing()))
        for host in ["0.0.0.0", "8.8.8.8", "169.254.169.254", "example.com", "192.168.01.1", "::1", "10.0.0.1@evil.com"] {
            XCTAssertThrowsError(try MacWorkspacePairing(json: pairing(host: host)), host)
        }
        XCTAssertThrowsError(try MacWorkspacePairing(json: pairing(port: 0)))
        XCTAssertThrowsError(try MacWorkspacePairing(json: pairing(pin: "bad")))
        XCTAssertThrowsError(try MacWorkspacePairing(json: String(repeating: "x", count: 4097)))
    }

    func testRequestsRejectTraversalAndControlCharacters() throws {
        for path in ["../private", "/etc/passwd", "a//b", "a/./b", "a/../b", ".env", "a\\b", "a\n.swift"] {
            XCTAssertThrowsError(try MacWorkspaceRequest(projectID: "test", path: path), path)
        }
        XCTAssertNoThrow(try MacWorkspaceRequest(projectID: "test", path: "Sources/화면.swift"))
        XCTAssertNoThrow(try MacWorkspaceRequest(projectID: "test"))
        XCTAssertThrowsError(try MacWorkspaceRequest(projectID: "test", query: String(repeating: "a", count: 101)))
    }

    func testResponseMustMatchRequestAndProject() throws {
        let request = try MacWorkspaceRequest(projectID: UUID().uuidString)
        let good = MacWorkspaceResponse(version: 1, requestID: request.requestID, projectID: request.projectID,
            projectName: "demo", entries: [], file: nil, matches: [], truncated: false)
        XCTAssertNoThrow(try good.validate(for: request))
        let stale = MacWorkspaceResponse(version: 1, requestID: UUID().uuidString, projectID: request.projectID,
            projectName: "demo", entries: [], file: nil, matches: [], truncated: false)
        XCTAssertThrowsError(try stale.validate(for: request))
        let wrongProject = MacWorkspaceResponse(version: 1, requestID: request.requestID, projectID: UUID().uuidString,
            projectName: "demo", entries: [], file: nil, matches: [], truncated: false)
        XCTAssertThrowsError(try wrongProject.validate(for: request))
    }

    func testSafetyRequiresExplicitConnectionAndBlocksLockedReads() {
        let policy = SafetyPolicyEngine()
        guard case .requireConfirmation = policy.evaluate(.macWorkspace(.configure), context: .init()) else {
            return XCTFail("Connection must be confirmed")
        }
        for action in [MacWorkspaceAction.configure, .browse, .read, .search] {
            guard case .block = policy.evaluate(.macWorkspace(action), context: .init(
                externalActionsLocked: true, wasExplicitlyConfirmed: true)) else { return XCTFail("Lock must win") }
        }
        for action in [MacWorkspaceAction.disconnect, .cancel] {
            guard case .allow = policy.evaluate(.macWorkspace(action), context: .init(externalActionsLocked: true)) else {
                return XCTFail("Stop must remain available")
            }
        }
        guard case .block = policy.evaluate(.macWorkspace(.configure), context: .init(
            origin: .proactiveSuggestion, wasExplicitlyConfirmed: true)) else { return XCTFail("No automatic pairing") }
        XCTAssertNil(SemanticCapabilityID(rawValue: "macWorkspace"))
        XCTAssertFalse(CapabilityRegistry().promptDescription.contains("macWorkspace"))
    }
}
