import Foundation
import Security

// No input paths, commands, model messages or credentials are accepted here.
@objc protocol JARVISCodexServiceProtocol {
    func start(withReply reply: @escaping (Data?, String?) -> Void)
    func stop(withReply reply: @escaping () -> Void)
}

enum CodexServiceIdentity {
    static let identifier = "com.minhyuc.jarvis.mac.codex-service"
    static func requirement(for url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw CocoaError(.executableNotLoadable)
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw CocoaError(.executableNotLoadable)
        }
        // Exact bundled code identity, including ad-hoc personal Debug builds.
        let value = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess else {
            throw CocoaError(.executableNotLoadable)
        }
        return value
    }
}
