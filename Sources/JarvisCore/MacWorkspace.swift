import Foundation

/// UI-only operations. File paths/content and credentials never enter model prompts.
public enum MacWorkspaceAction: Equatable, Sendable {
    case configure, disconnect, cancel, browse, read, search
}

public enum MacWorkspaceValidationError: Error, LocalizedError {
    case invalidPairing, invalidPath, invalidQuery, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidPairing: "Mac 연결 정보가 올바르지 않습니다. 로컬 IPv4 주소·인증서·연결 토큰을 확인해주세요."
        case .invalidPath: "허용된 프로젝트 안의 상대 경로만 조회할 수 있습니다."
        case .invalidQuery: "검색어는 1~100자로 입력해주세요."
        case .invalidResponse: "Mac 응답의 작업·프로젝트 정보를 확인하지 못했습니다."
        }
    }
}

public struct MacWorkspacePairing: Codable, Equatable, Sendable {
    public let version: Int
    public let host: String
    public let port: Int
    public let fingerprint: String
    public let token: String
    public let projectID: String
    public let projectName: String

    public init(json: String) throws {
        guard json.utf8.count <= 4_096, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, Self.isLocalIPv4(value.host), (1024...65535).contains(value.port),
              value.fingerprint.count == 64, value.fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (40...128).contains(value.token.count), value.token.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
              }), UUID(uuidString: value.projectID) != nil,
              !value.projectName.isEmpty, value.projectName.count <= 80,
              !value.projectName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw MacWorkspaceValidationError.invalidPairing }
        self = value
    }

    public static func isLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                && Int(part).map { (0...255).contains($0) && String($0) == part } == true
        }) else { return false }
        let p = parts.compactMap { Int($0) }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 192 && p[1] == 168)
    }
}

public struct MacWorkspaceRequest: Codable, Sendable {
    public let requestID: String
    public let projectID: String
    public let path: String
    public let query: String
    public init(projectID: String, path: String = "", query: String = "") throws {
        guard Self.isRelativePath(path) else { throw MacWorkspaceValidationError.invalidPath }
        guard query.count <= 100, !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw MacWorkspaceValidationError.invalidQuery }
        requestID = UUID().uuidString; self.projectID = projectID; self.path = path; self.query = query
    }
    public static func isRelativePath(_ path: String) -> Bool {
        guard path.utf8.count <= 1_024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }
}

public struct MacWorkspaceEntry: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let directory: Bool
    public var id: String { path }
}
public struct MacWorkspaceFile: Codable, Equatable, Sendable {
    public let path: String
    public let text: String
    public let sha256: String
}
public struct MacWorkspaceMatch: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let line: Int
    public let excerpt: String
    public var id: String { "\(path):\(line)" }
}
public struct MacWorkspaceResponse: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let projectID: String
    public let projectName: String
    public let entries: [MacWorkspaceEntry]
    public let file: MacWorkspaceFile?
    public let matches: [MacWorkspaceMatch]
    public let truncated: Bool

    public func validate(for request: MacWorkspaceRequest) throws {
        guard version == 1, requestID == request.requestID, projectID == request.projectID,
              projectName.count <= 80, entries.count <= 80, matches.count <= 40,
              Set(entries.map(\.id)).count == entries.count, Set(matches.map(\.id)).count == matches.count,
              entries.allSatisfy({ MacWorkspaceRequest.isRelativePath($0.path) && !$0.path.isEmpty }),
              matches.allSatisfy({ MacWorkspaceRequest.isRelativePath($0.path) && !$0.path.isEmpty
                  && $0.line > 0 && $0.excerpt.count <= 200 }) else { throw MacWorkspaceValidationError.invalidResponse }
        if let file {
            guard file.path == request.path, MacWorkspaceRequest.isRelativePath(file.path),
                  file.text.utf8.count <= 65_536, file.sha256.count == 64,
                  file.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw MacWorkspaceValidationError.invalidResponse
            }
        }
    }
}
