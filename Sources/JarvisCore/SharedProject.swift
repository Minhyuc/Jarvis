import Foundation
import CryptoKit

public enum SharedProjectAction: Equatable, Sendable {
    case connect, disconnect, browse, read, save, create, cancel, lock, unlock
    case inspect, createFolder, move, remove
    case syncRead, syncInitialize, syncCapture, syncExport, syncImport
}

public struct SharedProjectRequest: Equatable, Sendable {
    public enum Operation: String, Sendable, Identifiable {
        case folder, note, update, move, remove
        public var id: String { rawValue }
    }
    public let operation: Operation
    public let path: String
    public let destination: String
    public let text: String
    public init(_ operation: Operation, path: String, destination: String = "", text: String = "") {
        self.operation = operation; self.path = path; self.destination = destination; self.text = text
    }
    public var action: SharedProjectAction {
        switch operation { case .folder: .createFolder; case .note: .create; case .update: .save; case .move: .move; case .remove: .remove }
    }
}

public struct SharedProjectPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let rootName: String
    public let request: SharedProjectRequest
    public let revision: String?
    public let expiresAt: Date
    public init(sessionID: UUID, rootName: String, request: SharedProjectRequest, revision: String?, now: Date = Date()) {
        id = UUID(); self.sessionID = sessionID; self.rootName = rootName; self.request = request
        self.revision = revision; expiresAt = now.addingTimeInterval(120)
    }
    public var confirmation: String {
        let target = "\(rootName)/\(request.path)"
        switch request.operation {
        case .folder: return "\(target)에 폴더를 생성할까요? 없는 상위 폴더는 임의로 만들지 않습니다."
        case .note: return "\(target)에 TXT 메모를 생성할까요? 내용: \(request.text)"
        case .update: return "\(target)의 메모를 다음 내용으로 바꿀까요? 내용: \(request.text)"
        case .move: return "대상 항목 \(target)을 목적지 \(rootName)/\(request.destination) 위치로 이동 또는 이름 변경할까요? 포함된 파일도 함께 이동합니다."
        case .remove: return "대상 항목 \(target)을 프로젝트 안의 JARVIS 복구함으로 이동할까요? 폴더라면 포함된 파일도 함께 이동하며 영구 삭제하지 않습니다."
        }
    }
}

public enum SharedProjectWorkflow: Equatable, Sendable {
    case clarify
    case noteDraft(text: String)
    case prepare(SharedProjectRequest)
    case commit(SharedProjectPlan)
}

/// Explicit shared-folder grammar only. No fuzzy basename search or old-target reuse.
/// Examples: 공유 폴더의 "메모/장보기.txt" 메모 만들어줘 내용: 우유
public struct SharedProjectCommandParser: Sendable {
    public init() {}
    public func parse(_ raw: String) -> SharedProjectWorkflow? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        input = input.replacingOccurrences(of: #"^자비스(?:야)?[\s,，:：]*"#, with: "", options: .regularExpression)
        // A literal-content request without a destination is a draft, never an
        // invented filename or a model-written file. Ask for its exact path.
        if !input.hasPrefix("공유 폴더"), !input.hasPrefix("공유폴더") {
            let pattern = #"^(.+?)(?:이라는\s*문구가\s*적혀\s*있는|라는\s*문구가\s*적혀\s*있는|이라고\s*적혀\s*있는|라고\s*적혀\s*있는|이라는\s*내용의|라는\s*내용의)\s*(?:메모|[tT][xX][tT]\s*파일|텍스트\s*파일)(?:을|를)?\s*(?:만들어줘|생성해줘|만들어\s*줘)[.!]?$"#
            guard input.utf8.count <= 8192,
                  let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let range = Range(match.range(at: 1), in: input) else { return nil }
            var text = String(input[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            for (left, right) in [("\"", "\""), ("“", "”"), ("'", "'")] {
                if text.hasPrefix(left), text.hasSuffix(right), text.count >= 2 {
                    text = String(text.dropFirst().dropLast()); break
                }
            }
            guard !text.isEmpty, text.utf8.count <= 4096 else { return .clarify }
            return .noteDraft(text: text)
        }
        guard input.hasPrefix("공유 폴더") || input.hasPrefix("공유폴더") else { return nil }
        input = input.replacingOccurrences(of: #"^공유\s*폴더(?:의|에|에서)?\s*"#, with: "", options: .regularExpression)
        guard input.utf8.count <= 8192 else { return .clarify }
        input = input.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        input = input.replacingOccurrences(of: #"내용\s*[:：]\s*|내용은\s+"#, with: "내용:", options: .regularExpression)
        let contentParts = input.components(separatedBy: "내용:")
        guard contentParts.count <= 2 else { return .clarify }
        var command = contentParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var parent = ""
        if let regex = try? NSRegularExpression(pattern: #"^([^\s\"]+)\s*폴더에\s+(.+)$"#),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
           let name = Range(match.range(at: 1), in: command), let rest = Range(match.range(at: 2), in: command) {
            parent = String(command[name]); command = String(command[rest])
        }
        let text = contentParts.count == 2 ? contentParts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard text.utf8.count <= 4096 else { return .clarify }
        func captures(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  match.range.length == command.utf16.count else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: command).map { String(command[$0]) } }
        }
        func prepared(_ op: SharedProjectRequest.Operation, _ rawPath: String, destination: String = "") -> SharedProjectWorkflow {
            let ambiguous = ["거기", "그곳", "그거", "이거", "저거", "어디든", "아무데나", "전체", "모두", "전부", "아까", "이전", "현재"]
            guard !ambiguous.contains(rawPath), !ambiguous.contains(destination) else { return .clarify }
            var path = parent.isEmpty ? rawPath : parent + "/" + rawPath
            if [.note, .update].contains(op), URL(fileURLWithPath: path).pathExtension.isEmpty { path += ".txt" }
            guard SharedProjectFiles.validPath(path),
                  destination.isEmpty || SharedProjectFiles.validPath(destination),
                  !path.hasPrefix(SharedProjectFiles.recoveryFolder), !destination.hasPrefix(SharedProjectFiles.recoveryFolder) else { return .clarify }
            if op == .note || op == .update {
                guard path.lowercased().hasSuffix(".txt"), SharedProjectFiles.editablePath(path), !text.isEmpty else { return .clarify }
            }
            return .prepare(.init(op, path: path, destination: destination, text: text))
        }
        // Quotes make spaces and nested destinations unambiguous. Unquoted paths without spaces also work.
        // Keep each capture singular by using a small explicit pair of patterns.
        for quoted in [true, false] {
            let p = quoted ? #"\"([^\"]+)\""# : #"([^\s\"]+)"#
            if let c = captures(p + #"\s*폴더(?:를)?\s*(?:생성해줘|만들어줘|만들어|생성해)[.!]?$"#) { return prepared(.folder, c[0]) }
            if let c = captures(p + #"\s*(?:메모|파일)(?:를)?\s*(?:생성해줘|만들어줘|만들어|생성해)[.!]?$"#) { return prepared(.note, c[0]) }
            if let c = captures(p + #"\s*(?:메모|파일)(?:를)?\s*(?:수정해줘|변경해줘|바꿔줘)[.!]?$"#) { return prepared(.update, c[0]) }
            if let c = captures(p + #"\s*(?:폴더|메모|파일)?(?:를|을)?\s*(?:삭제해줘|삭제해|지워줘)[.!]?$"#) { return prepared(.remove, c[0]) }
            if let c = captures(p + #"\s*(?:폴더|메모|파일)?(?:를|을)?\s*"# + p + #"(?:으로|로)\s*(?:이동해줘|옮겨줘|이름을 바꿔줘|변경해줘)[.!]?$"#) {
                return prepared(.move, c[0], destination: c[1])
            }
        }
        return .clarify
    }

    /// Only an explicit root-relative TXT path can complete this question.
    /// Full commands are classified separately by the dialogue manager.
    public func noteDestination(_ answer: String, text: String) -> SharedProjectRequest? {
        var path = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 2 { path = String(path.dropFirst().dropLast()) }
        guard text.utf8.count <= 4096, !text.isEmpty,
              path.lowercased().hasSuffix(".txt"), SharedProjectFiles.validPath(path), SharedProjectFiles.editablePath(path),
              !SharedProjectFiles.protectedPath(path), !path.hasPrefix(SharedProjectFiles.recoveryFolder) else { return nil }
        return .init(.note, path: path, text: text)
    }
}

public struct SharedProjectRecovery: Equatable, Identifiable, Sendable {
    public let originalPath: String
    public let recoveryPath: String
    public var id: String { recoveryPath }
}

public struct SharedProjectEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let directory: Bool
    public var id: String { path }
}

public struct SharedProjectDocument: Equatable, Sendable {
    public let path: String
    public let text: String
    public let revision: String
}

public struct SharedProjectOutput: Sendable {
    public var entries: [SharedProjectEntry] = []
    public var document: SharedProjectDocument?
    public var truncated = false
    public var itemRevision: String?
    public var recovery: SharedProjectRecovery?
    public init() {}
}

/// Cancels coordination waiting on a provider, and prevents a late commit.
public final class SharedProjectCancellation: @unchecked Sendable {
    private let mutex = NSLock()
    private var stopped = false
    private var coordinator: NSFileCoordinator?
    public init() {}
    public var cancelled: Bool { mutex.lock(); defer { mutex.unlock() }; return stopped }
    public func cancel() {
        mutex.lock(); stopped = true; let active = coordinator; mutex.unlock()
        active?.cancel()
    }
    fileprivate func attach(_ value: NSFileCoordinator?) {
        mutex.lock(); coordinator = value; let shouldCancel = stopped; mutex.unlock()
        if shouldCancel { value?.cancel() }
    }
}

/// A deterministic, UI-only file executor. Never sends content to a model or runs code.
/// The picker grants OS access; policy confirmation grants this app's narrower operation.
public struct SharedProjectFiles: Sendable {
    public static let maximumBytes = 262_144
    public static let recoveryFolder = "JARVIS 복구함"
    /// Reserved even before initialization. General file tools must not mutate
    /// structured records, journals, tombstones or their parent directories.
    public static func protectedPath(_ path: String) -> Bool {
        ["알람", "캘린더", "시스템"].contains(path.precomposedStringWithCanonicalMapping.split(separator: "/").first.map(String.init) ?? "")
    }
    private static let extensions = Set(["swift", "py", "js", "ts", "tsx", "jsx", "json", "md", "txt",
        "yaml", "yml", "toml", "xml", "html", "css", "c", "h", "cpp", "hpp", "rs", "go", "java", "kt", "m", "mm", "sh"])
    private static let excluded = Set(["node_modules", "Pods", "DerivedData", "build", "dist", "target", "vendor"])
    public init() {}

    public static func validPath(_ path: String, allowEmpty: Bool = false) -> Bool {
        if path.isEmpty { return allowEmpty }
        guard path.utf8.count <= 1024, !path.contains("\\"), !path.contains("*"), !path.contains("?"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !excluded.contains(String($0))
        }
    }

    public static func editablePath(_ path: String) -> Bool {
        guard validPath(path), extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return !["secret", "credential", "password", "token", "keychain", "pairing", "googleservice-info"].contains(where: name.contains)
    }

    public static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func perform(_ action: SharedProjectAction, root: URL, path: String = "",
                        text: String = "", expectedRevision: String? = nil, confirmed: Bool = false, destination: String = "",
                        locked: @Sendable () -> Bool, cancelled: @Sendable () -> Bool = { false },
                        cancellation: SharedProjectCancellation? = nil) -> ToolExecutionResult<SharedProjectOutput> {
        func authorize() throws {
            guard !cancelled(), cancellation?.cancelled != true else { throw Problem.cancelled }
            switch SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(
                externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
            case .allow: break
            case .requireConfirmation: throw Problem.confirmation
            case .block: throw Problem.locked
            }
        }
        do {
            try authorize()
            guard root.isFileURL, root.path != "/", root.standardizedFileURL.path != NSHomeDirectory(),
                  try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  Self.validPath(path, allowEmpty: action == .browse || action == .connect) else { throw Problem.path }
            // File providers may return a canonical /private/... URL for a /var/... grant.
            // Normalize the selected root once, not each child independently.
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            if action == .connect { return .succeeded(.init()) }
            if [.save, .create, .createFolder, .move, .remove].contains(action),
               Self.protectedPath(path) || Self.protectedPath(destination) { throw Problem.path }
            guard [.browse, .read, .save, .create, .inspect, .createFolder, .move, .remove].contains(action) else { throw Problem.path }
            guard [.browse, .inspect, .createFolder, .move, .remove].contains(action) || Self.editablePath(path) else { throw Problem.path }
            if [.create, .createFolder, .save, .remove].contains(action), path == Self.recoveryFolder || path.hasPrefix(Self.recoveryFolder + "/") { throw Problem.path }
            let target = path.isEmpty ? root : root.appendingPathComponent(path)
            var coordinatorError: NSError?
            var output: Result<SharedProjectOutput, Error>?
            let coordinator = NSFileCoordinator()
            cancellation?.attach(coordinator)
            defer { cancellation?.attach(nil) }
            func access(_ coordinated: URL) {
                output = Result {
                    try authorize() // Lock and cancellation are checked again after provider coordination.
                    let item = [.move, .remove, .createFolder].contains(action) ? root.appendingPathComponent(path) : coordinated
                    try validate(root: root, target: item, allowMissing: action == .create || action == .createFolder)
                    var value = SharedProjectOutput()
                    if action == .browse {
                        let children = try FileManager.default.contentsOfDirectory(at: coordinated,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                        value.truncated = children.count > 500
                        for child in children.prefix(500) {
                            let relative = path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent
                            guard Self.validPath(relative) else { continue }
                            do { try validate(root: root, target: child, allowMissing: false) }
                            catch { continue }
                            let directory = try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                            if directory || Self.editablePath(relative) {
                                value.entries.append(.init(path: relative, directory: directory))
                            }
                        }
                        value.entries.sort { $0.directory == $1.directory ? $0.path < $1.path : $0.directory }
                    } else if action == .inspect {
                        value.itemRevision = try treeRevision(item)
                    } else if action == .createFolder {
                        guard !FileManager.default.fileExists(atPath: item.path) else { throw Problem.conflict }
                        try authorize()
                        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
                        guard try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Problem.uncertain }
                    } else if action == .move || action == .remove {
                        guard let expectedRevision, try treeRevision(item) == expectedRevision else { throw Problem.conflict }
                        let finalPath: String
                        if action == .remove {
                            finalPath = Self.recoveryFolder + "/" + UUID().uuidString + "-" + item.lastPathComponent
                        } else { finalPath = destination }
                        guard Self.validPath(finalPath), finalPath != path, !finalPath.hasPrefix(path + "/"),
                              action == .remove || finalPath != Self.recoveryFolder,
                              action == .remove || !finalPath.hasPrefix(Self.recoveryFolder + "/") else { throw Problem.path }
                        let final = root.appendingPathComponent(finalPath)
                        if action == .remove {
                            let recovery = root.appendingPathComponent(Self.recoveryFolder)
                            if FileManager.default.fileExists(atPath: recovery.path) { try validate(root: root, target: recovery, allowMissing: false) }
                            else { try authorize(); try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false) }
                        }
                        try validate(root: root, target: final, allowMissing: true)
                        guard !FileManager.default.fileExists(atPath: final.path) else { throw Problem.conflict }
                        try authorize()
                        try FileManager.default.moveItem(at: item, to: final)
                        guard !FileManager.default.fileExists(atPath: item.path), try treeRevision(final) == expectedRevision else { throw Problem.uncertain }
                        if action == .remove { value.recovery = .init(originalPath: path, recoveryPath: finalPath) }
                    } else if action == .read {
                        let data = try read(coordinated)
                        value.document = .init(path: path, text: String(decoding: data, as: UTF8.self), revision: Self.revision(data))
                    } else {
                        let data = Data(text.utf8)
                        guard data.count <= Self.maximumBytes, !data.contains(0) else { throw Problem.large }
                        guard NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty != false else { throw Problem.conflict }
                        if action == .create {
                            guard !FileManager.default.fileExists(atPath: coordinated.path) else { throw Problem.conflict }
                        } else {
                            guard let expectedRevision, Self.revision(try read(coordinated)) == expectedRevision else { throw Problem.conflict }
                        }
                        try authorize()
                        // No overwrite on create; atomic replace only after optimistic revision check.
                        try data.write(to: coordinated, options: action == .create ? [.withoutOverwriting] : [.atomic])
                        guard try read(coordinated) == data else { throw Problem.uncertain }
                        value.document = .init(path: path, text: text, revision: Self.revision(data))
                    }
                    return value
                }
            }
            if [.move, .remove, .createFolder].contains(action) {
                coordinator.coordinate(writingItemAt: root, options: [], error: &coordinatorError, byAccessor: access)
            } else if action == .save || action == .create {
                coordinator.coordinate(writingItemAt: target, options: action == .save ? .forReplacing : [], error: &coordinatorError, byAccessor: access)
            } else {
                coordinator.coordinate(readingItemAt: target, options: [], error: &coordinatorError, byAccessor: access)
            }
            if let coordinatorError { throw coordinatorError }
            guard let output else { throw Problem.uncertain }
            return .succeeded(try output.get())
        } catch let problem as Problem {
            switch problem {
            case .confirmation: return .needsConfirmation(message: "선택한 폴더 또는 파일 저장을 먼저 확인해주세요.")
            case .locked: return .failed(message: "안전 잠금이 켜져 있습니다.", retryable: false)
            case .cancelled: return .failed(message: "작업을 취소했습니다. 이미 전달된 저장은 파일을 다시 확인해주세요.", retryable: false)
            case .conflict: return .failed(message: "다른 수정이나 충돌 버전이 있습니다. 덮어쓰지 않았습니다. 초안을 복사한 뒤 파일을 다시 열어 비교해주세요.", retryable: false)
            case .large: return .failed(message: "UTF-8 파일당 256 KiB, 폴더 작업은 500항목·깊이 12·총 8 MiB까지 지원합니다.", retryable: false)
            case .path: return .failed(message: "허용 폴더의 정확한 상대 경로만 사용할 수 있습니다. 숨김·링크·민감 이름·미지원 항목을 포함한 폴더 작업은 차단됩니다.", retryable: false)
            case .uncertain: return .unverifiable(message: "파일 저장 여부를 확인하지 못했습니다. 자동 재시도하지 말고 파일을 확인해주세요.")
            }
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(code) {
                return .needsPermission(message: "폴더 접근 권한이 없습니다. 폴더를 다시 선택해주세요.")
            }
            return .failed(message: "파일 제공자가 작업을 완료하지 못했습니다. 다운로드·권한·저장 공간을 확인해주세요. 저장 중이었다면 파일을 다시 확인해주세요.", retryable: false)
        }
    }

    func validate(root: URL, target: URL, allowMissing: Bool) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = target.standardizedFileURL.path
        guard candidate == root.standardizedFileURL.path || candidate.hasPrefix(root.standardizedFileURL.path + "/") else { throw Problem.path }
        guard target.resolvingSymlinksInPath().path == base || target.resolvingSymlinksInPath().path.hasPrefix(base + "/") else { throw Problem.path }
        // contentsOfDirectory can return URLs relative to a base URL. Rebuild an
        // absolute cursor so deleting components cannot repeatedly append "..".
        let rootPath = root.standardizedFileURL.path
        var cursor = URL(fileURLWithPath: candidate)
        while cursor.path != rootPath {
            guard cursor.path.hasPrefix(rootPath + "/") else { throw Problem.path }
            if allowMissing && cursor.path == candidate && !FileManager.default.fileExists(atPath: cursor.path) {
                cursor = URL(fileURLWithPath: cursor.deletingLastPathComponent().standardizedFileURL.path); continue
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: cursor.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular,
                  type != .typeRegular || ((attrs[.referenceCount] as? NSNumber)?.intValue ?? 1) <= 1 else { throw Problem.path }
            cursor = URL(fileURLWithPath: cursor.deletingLastPathComponent().standardizedFileURL.path)
        }
    }

    private func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= Self.maximumBytes else { throw Problem.large }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw Problem.large }
        return data
    }

    /// Bounded content fingerprint, not names alone: stale approval cannot move
    /// a changed subtree. Links, hidden/build/binary items are not silently swept up.
    private func treeRevision(_ target: URL) throws -> String {
        var hasher = SHA256()
        var count = 0, bytes = 0
        let deadline = Date().addingTimeInterval(5)
        func visit(_ url: URL, relative: String, depth: Int) throws {
            guard !["알람", "캘린더", "시스템"].contains(url.lastPathComponent.precomposedStringWithCanonicalMapping) else { throw Problem.path }
            count += 1
            guard count <= 500, depth <= 12, Date() < deadline else { throw Problem.large }
            guard NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw Problem.conflict }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if attrs[.type] as? FileAttributeType == .typeDirectory {
                hasher.update(data: Data(("D:" + relative + "\u{0}").utf8))
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard children.count <= 500 else { throw Problem.large }
                for child in children {
                    guard Self.validPath(child.lastPathComponent) else { throw Problem.path }
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      ((attrs[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1,
                      Self.editablePath(url.lastPathComponent), NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty != false else { throw Problem.path }
                let data = try read(url); bytes += data.count
                guard bytes <= 8 * 1024 * 1024 else { throw Problem.large }
                hasher.update(data: Data(("F:" + relative + "\u{0}").utf8)); hasher.update(data: data)
            }
        }
        try visit(target, relative: "", depth: 0)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum Problem: Error { case confirmation, locked, cancelled, conflict, large, path, uncertain }
}


private func usbPathWithoutLinks(_ url: URL) -> Bool {
    var cursor = URL(fileURLWithPath: "/")
    for part in url.standardizedFileURL.pathComponents.dropFirst() {
        cursor.appendPathComponent(part)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cursor.path) else { break }
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return false }
    }
    return true
}

// USB installation storage. Callers retain their existing intent/approval checks.
public final class USBDataStore: @unchecked Sendable {
    public let root: URL
    public let preferences: USBPreferences
    private let device: UInt64
    private let inode: UInt64
    public init(root: URL, expectedVolume: String, confirmed: Bool, locked: Bool) throws {
        guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.codeConnect), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)),
              root.isFileURL, root.standardizedFileURL == root.resolvingSymlinksInPath(), usbPathWithoutLinks(root),
              try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == expectedVolume else { throw CocoaError(.fileReadNoPermission) }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              let dev = attrs[.systemNumber] as? NSNumber, let node = attrs[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadNoPermission) }
        self.root = root; device = dev.uint64Value; inode = node.uint64Value
        preferences = try USBPreferences(file: root.appendingPathComponent("Data/preferences.plist"))
        preferences.available = { [weak self] in self?.available == true }
    }
    public var available: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: root.path) else { return false }
        return usbPathWithoutLinks(root.appendingPathComponent("Data/preferences.plist")) && a[.type] as? FileAttributeType == .typeDirectory && (a[.systemNumber] as? NSNumber)?.uint64Value == device && (a[.systemFileNumber] as? NSNumber)?.uint64Value == inode
    }
    public func permits(_ url: URL) -> Bool {
        guard available, url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        return usbPathWithoutLinks(url) && (path == root.path || path.hasPrefix(root.path + "/"))
    }
}

/// File-backed defaults avoid CFPreferences persistent domains on the Mac.
public final class USBPreferences: UserDefaults, @unchecked Sendable {
    private let mutex = NSRecursiveLock()
    private let file: URL?
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private var revision: Data?
    public var available: @Sendable () -> Bool = { false }
    public private(set) var persistenceFailed = false
    public init(file: URL?) throws {
        self.file = file
        super.init(suiteName: "jarvis.usb.memory." + UUID().uuidString)!
        if let file { guard usbPathWithoutLinks(file) else { throw CocoaError(.fileReadNoPermission) } }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular, (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: file)
            guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            values = value; revision = data
        }
    }
    public override func object(forKey key: String) -> Any? { mutex.lock(); defer { mutex.unlock() }; return values[key] ?? registered[key] }
    public override func set(_ value: Any?, forKey key: String) {
        guard available(), let file else { return }
        willChangeValue(forKey: key)
        mutex.lock()
        var next = values; next[key] = value
        do {
            let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            guard current == revision else { throw CocoaError(.fileWriteFileExists) }
            let data = try PropertyListSerialization.data(fromPropertyList: next, format: .binary, options: 0)
            guard data.count <= 1_048_576, available() else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            values = next; revision = data; persistenceFailed = false
        } catch { persistenceFailed = true }
        mutex.unlock(); didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    public override func removeObject(forKey key: String) { set(nil, forKey: key) }
    public override func register(defaults registrationDictionary: [String: Any]) { mutex.lock(); registered.merge(registrationDictionary) { old, _ in old }; mutex.unlock() }
    public override func dictionaryRepresentation() -> [String: Any] { mutex.lock(); defer { mutex.unlock() }; return registered.merging(values) { _, new in new } }
    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public override func bool(forKey key: String) -> Bool {
        if key == "jarvis.safety.externalActionsLocked" {
            guard available(), let file else { return true }
            mutex.lock()
            let current = FileManager.default.fileExists(atPath: file.path) ? try? Data(contentsOf: file) : nil
            if current != revision { persistenceFailed = true }
            let failed = persistenceFailed; mutex.unlock()
            if failed { return true }
        }
        return (object(forKey: key) as? NSNumber)?.boolValue ?? false
    }
    public override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    public override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    public override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    public override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    public override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    public override func synchronize() -> Bool { !persistenceFailed }
}

public enum JarvisStorage {
    private static let lock = NSLock()
    private static var active: USBDataStore?
    private static let pending = try! USBPreferences(file: nil)
    public static var portable: Bool { Bundle.main.bundleIdentifier == "com.minhyuc.jarvis.mac" || (Bundle.main.object(forInfoDictionaryKey: "JARVISPortable") as? Bool == true) || (Bundle.main.object(forInfoDictionaryKey: "JARVISPortable") as? String == "YES") }
    public static var store: USBDataStore? { lock.lock(); defer { lock.unlock() }; return active }
    public static func activate(_ value: USBDataStore) { lock.lock(); active = value; lock.unlock() }
    public static func revoke() { lock.lock(); active = nil; lock.unlock() }
    public static var preferences: UserDefaults { portable ? store?.preferences ?? pending : .standard }
    public static var support: URL {
        if portable { return (store?.root ?? URL(fileURLWithPath: "/Volumes/JARVIS/Jarvis")).appendingPathComponent("Data/ApplicationSupport") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    public static func permits(_ url: URL) -> Bool {
        guard portable else { return true }
        guard let store, store.permits(url) else { return false }
        let relative = String(url.standardizedFileURL.path.dropFirst(store.root.path.count)).split(separator: "/").map(String.init)
        guard let first = relative.first else { return false }
        return !["data", "applications", "builds", "archives", "migration-report.json"].contains(first.lowercased())
    }
}
