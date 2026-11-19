import Foundation
import CryptoKit
import Darwin

public enum CodexCodePolicy {
    public static func readable(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let projectMetadata = ["makefile", "dockerfile", "gemfile", "podfile", "license", "readme",
                               "project.pbxproj", "contents.xcworkspacedata", "info.plist"].contains(filename)
        guard (SharedProjectFiles.editablePath(path) || (projectMetadata && SharedProjectFiles.validPath(path))),
              !SharedProjectFiles.protectedPath(path),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }) else { return false }
        let parts = path.lowercased().split(separator: "/").map(String.init)
        return !parts.contains(where: { ["알람", "캘린더", "시스템", "jarvis 복구함", "jarviscodexcodebackups", "assets.xcassets", "__pycache__"].contains($0) })
    }
    public static func writable(_ path: String) -> Bool {
        guard readable(path) else { return false }
        let p = path.lowercased()
        guard ["swift", "py", "js", "ts", "tsx", "jsx", "css", "html", "md", "txt", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return false }
        return !["safety", "codex", "permission", "credential", "appintent", "localdataexecution", "assistantviewmodel", "agentorchestrator", "capabilityregistry", "commandrouter", "assistantintent", "sharedproject", "shareddatasync", "jarvismacapp"].contains(where: p.contains)
            && !p.hasSuffix("agents.md") && !p.hasSuffix("agents.override.md") && !p.hasSuffix("package.swift") && !p.hasSuffix("info.plist")
            && !p.hasSuffix(".entitlements") && !p.hasSuffix(".pbxproj") && !p.hasPrefix("tools/")
    }
    public static func containsSecret(_ text: String) -> Bool {
        text.range(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----|\bsk-[A-Za-z0-9_-]{20,}|\bAKIA[A-Z0-9]{16}\b|\bAIza[A-Za-z0-9_-]{30,}|\btvly-[A-Za-z0-9_-]{16,}"#, options: .regularExpression) != nil
    }
}

public struct CodexCodeFile: Sendable, Equatable {
    public let path: String
    public let fullText: String
    public let text: String
    public let startLine: Int
    public let revision: String
}

public struct CodexCodeRequest: Sendable {
    public let model: String
    public let effort: String
    public let instruction: String
    public let files: [CodexCodeFile]
    public let tree: [String]
    public let context: [CloudConversationTurn]
    public let toolResults: [String]
    public init(model: String, effort: String, instruction: String, files: [CodexCodeFile], tree: [String], context: [CloudConversationTurn] = [], toolResults: [String] = []) {
        self.model = model; self.effort = effort; self.instruction = instruction; self.files = files; self.tree = tree; self.context = context
        self.toolResults = toolResults
    }
    public func encodedInput() throws -> String {
        guard CodexLocalModel.validID(model), CodexLocalModel.effortValues.contains(effort),
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instruction.utf8.count <= 6000, !CodexCodePolicy.containsSecret(instruction),
              files.count <= 8, Set(files.map(\.path)).count == files.count,
              files.allSatisfy({ CodexCodePolicy.readable($0.path) && (1...1000000).contains($0.startLine) && $0.text.utf8.count <= 32768 && !CodexCodePolicy.containsSecret($0.text) }),
              files.reduce(0, { $0 + $1.text.utf8.count }) <= 98304,
              tree.count <= 1000, tree.allSatisfy(CodexCodePolicy.readable), tree.reduce(0, { $0 + $1.utf8.count }) <= 32768 else { throw CodexCodeError.invalid }
        let managed = AssistantContextManager().context(for: instruction, longTermMemories: [])
        guard managed.recentTurns.isEmpty, managed.longTermMemories.isEmpty else { throw CodexCodeError.invalid }
        guard context.count <= 3, context.allSatisfy({ $0.user.utf8.count <= 6000 && $0.assistant.utf8.count <= 2000 && !CodexCodePolicy.containsSecret($0.user) && !CodexCodePolicy.containsSecret($0.assistant) }) else { throw CodexCodeError.invalid }
        var object: [String: Any] = ["instruction": instruction, "files": files.map { ["path": $0.path, "text": $0.text, "startLine": $0.startLine] as [String: Any] }, "tree": tree]
        if !context.isEmpty { object["context"] = context.map { ["user": $0.user, "assistant": $0.assistant] } }
        guard toolResults.count <= 4,
              toolResults.allSatisfy({ $0.utf8.count <= 4096 && !CodexCodePolicy.containsSecret($0) }) else { throw CodexCodeError.invalid }
        if !toolResults.isEmpty { object["toolResults"] = toolResults }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 196608, let text = String(data: data, encoding: .utf8) else { throw CodexCodeError.invalid }
        return text
    }
}

public struct CodexCodeEdit: Decodable, Sendable { public let path: String; public let old: String?; public let new: String }
public struct CodexCodeRead: Decodable, Sendable, Equatable {
    public let path: String
    public let startLine: Int
    public let lineCount: Int
    public init(path: String, startLine: Int, lineCount: Int) { self.path = path; self.startLine = startLine; self.lineCount = lineCount }
}
public struct CodexCodeReadBatch: Sendable {
    public let files: [CodexCodeFile]
    public let reads: [CodexCodeRead]
    public let issues: [String]
}
public struct CodexCodeProposal: Decodable, Sendable {
    public let summary: String
    public let edits: [CodexCodeEdit]
    public let reads: [CodexCodeRead]?
    public let commands: [CodexVerificationCommand]?
    public static func read(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        guard data.count <= 65536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSuperset(of: ["summary", "edits"]),
              Set(object.keys).isSubset(of: ["summary", "edits", "reads", "commands"]), let edits = object["edits"] as? [[String: Any]],
              edits.allSatisfy({ Set($0.keys) == ["path", "old", "new"] }) else { throw CodexCodeError.invalid }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.summary.utf8.count <= 2000, result.edits.count <= 16,
              (result.reads ?? []).count <= 8,
              Set((result.reads ?? []).map(\.path)).count == (result.reads ?? []).count,
              (result.reads ?? []).allSatisfy({ CodexCodePolicy.readable($0.path) && (1...1000000).contains($0.startLine) && (1...600).contains($0.lineCount) }),
              (result.reads ?? []).isEmpty || result.edits.isEmpty,
              result.edits.allSatisfy({ CodexCodePolicy.writable($0.path) && ($0.old?.isEmpty != true) && $0.new.utf8.count <= 49152 && !CodexCodePolicy.containsSecret($0.new) }) else { throw CodexCodeError.invalid }
        if object.keys.contains("reads") {
            guard let reads = object["reads"] as? [[String: Any]], reads.allSatisfy({ Set($0.keys) == ["path", "startLine", "lineCount"] }) else { throw CodexCodeError.invalid }
        }
        guard (result.commands ?? []).count <= 1,
              [!result.edits.isEmpty, !(result.reads ?? []).isEmpty, !(result.commands ?? []).isEmpty].filter({ $0 }).count <= 1 else { throw CodexCodeError.invalid }
        for command in result.commands ?? [] { try command.validate() }
        if object.keys.contains("commands") {
            guard let commands = object["commands"] as? [[String: Any]],
                  commands.allSatisfy({ Set($0.keys) == ["argv", "purpose"] }) else { throw CodexCodeError.invalid }
        }
        return result
    }
}

/// Model proposals can request these verification programs only. Arbitrary
/// programs and scripts remain explicit manual native-tool invocations.
public struct CodexVerificationCommand: Codable, Sendable, Equatable {
    public let argv: [String]
    public let purpose: String
    public init(argv: [String], purpose: String) { self.argv = argv; self.purpose = purpose }
    public func validate() throws {
        guard !purpose.isEmpty, purpose.utf8.count <= 1000,
              !CodexCodePolicy.containsSecret(purpose), argv.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 1024 }) else { throw CodexCodeError.invalid }
        if argv == ["swift", "test"] || argv == ["swift", "build"] || argv == ["python3", "-m", "unittest", "discover"] { return }
        if argv.count == 4, Array(argv.prefix(3)) == ["swift", "test", "--filter"],
           !argv[3].isEmpty, !argv[3].hasPrefix("-") { return }
        if argv.count == 6, argv[0] == "xcodebuild", argv[1] == "-project", argv[3] == "-scheme",
           SharedProjectFiles.validPath(argv[2]), argv[2].hasSuffix(".xcodeproj"),
           !argv[4].isEmpty, !argv[4].hasPrefix("-"), argv[5] == "build" { return }
        throw CodexCodeError.invalid
    }
}

/// A task grant covers only the reviewed relative paths and line ranges.
public struct CodexTaskReadGrant: Sendable {
    private let task: UUID
    private let deadline: Date
    private let ranges: [CodexCodeRead]
    private var remaining = 8
    public init(task: UUID, ranges: [CodexCodeRead], deadline: Date) {
        self.task = task; self.ranges = ranges; self.deadline = deadline
    }
    public mutating func consume(_ reads: [CodexCodeRead], task: UUID, now: Date = Date(), locked: Bool) -> Bool {
        guard !locked, self.task == task, deadline > now, remaining > 0,
              !reads.isEmpty, reads.count <= 8,
              reads.allSatisfy({ requested in
                  (1...1000000).contains(requested.startLine) && (1...600).contains(requested.lineCount)
                  && ranges.contains(where: { approved in
                      (1...1000000).contains(approved.startLine) && (1...600).contains(approved.lineCount)
                      && CodexCodePolicy.readable(approved.path)
                      && approved.path == requested.path && requested.startLine >= approved.startLine
                      && requested.startLine + requested.lineCount <= approved.startLine + approved.lineCount
                  })
              }) else { return false }
        remaining -= 1
        return true
    }
}

public struct CodexCodePlan: Identifiable, Sendable {
    public let id: UUID
    public let session: UUID
    public let path: String
    public let before: String?
    public let after: String
    public let expires: Date
}
public struct CodexCodeBackup: Codable, Identifiable, Sendable {
    public let id: UUID
    public let rootIdentity: String
    public let path: String
    public let before: String?
    public let after: String
    public let created: Date
}

public enum CodexCodeError: Error { case invalid, permission, confirmation, locked, changed, cancelled, io, invalidRange, sourceTooLarge, rangeTooLarge, secret }

/// UI-only executor. The model receives bounded source snapshots, never a root
/// handle. Component-wise openat/O_NOFOLLOW rejects symlinks and hard links.
public final class CodexCodeFiles: @unchecked Sendable {
    public let root: URL
    public let session = UUID()
    public let identity: String
    private let mutex = NSLock()
    private var consumed: Set<UUID> = []
    public init(root: URL, confirmed: Bool = false, locked: Bool = false) throws {
        guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.codeConnect), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)),
              root.isFileURL else { throw CodexCodeError.permission }
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let accountHome = getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) }
        guard !["/", "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private", NSHomeDirectory(), accountHome ?? ""].contains(resolved.path) else { throw CodexCodeError.invalid }
        let fd = open(resolved.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexCodeError.invalid }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw CodexCodeError.io }
        self.root = resolved; identity = "\(info.st_dev):\(info.st_ino)"
    }
    private func authorize(_ action: CodexLocalAction, confirmed: Bool, locked: () -> Bool, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw CodexCodeError.cancelled }
        switch SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .allow: break
        case .requireConfirmation: throw CodexCodeError.confirmation
        case .block: throw CodexCodeError.locked
        }
    }
    private func openRoot() throws -> Int32 {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { throw CodexCodeError.permission }
            throw CodexCodeError.io
        }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0, "\(rootInfo.st_dev):\(rootInfo.st_ino)" == identity else { close(fd); throw CodexCodeError.changed }
        return fd
    }
    private func parent(_ path: String) throws -> (Int32, String) {
        guard CodexCodePolicy.readable(path) else { throw CodexCodeError.invalid }
        var fd = try openRoot()
        let components = path.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd); fd = next
            guard fd >= 0 else { throw CodexCodeError.invalid }
        }
        return (fd, components.last!)
    }
    private func read(_ path: String, missing: Bool = false) throws -> Data? {
        let (directory, name) = try parent(path); defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT, missing { return nil }
        guard fd >= 0 else { throw CodexCodeError.invalid }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0 else { throw CodexCodeError.invalid }
        guard info.st_size <= 1048576 else { throw CodexCodeError.sourceTooLarge }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1048577) ?? Data()
        guard data.count <= 1048576, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw CodexCodeError.invalid }
        return data
    }
    public func inventory(locked: () -> Bool, cancelled: () -> Bool = { false }) -> ToolExecutionResult<[String]> {
        do {
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
            let directory = try openRoot()
            defer { close(directory) }
            var enumerationError: Error?
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else { throw CodexCodeError.io }
            var paths: [String] = [], visited = 0, bytes = 0
            let rootComponents = root.standardizedFileURL.pathComponents
            for case let url as URL in walker {
                visited += 1; if visited > 10000 || paths.count >= 1000 { break }
                try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
                let components = url.standardizedFileURL.pathComponents
                guard components.starts(with: rootComponents) else { walker.skipDescendants(); continue }
                let p = components.dropFirst(rootComponents.count).joined(separator: "/")
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                if values.isDirectory == true {
                    if !SharedProjectFiles.validPath(p) || ["JARVIS 복구함", "알람", "캘린더", "시스템"].contains(url.lastPathComponent) { walker.skipDescendants() }
                } else if CodexCodePolicy.readable(p), bytes + p.utf8.count <= 32768 {
                    paths.append(p); bytes += p.utf8.count
                }
            }
            if let enumerationError { throw enumerationError }
            let verifiedDirectory = try openRoot()
            close(verifiedDirectory)
            return .succeeded(paths.sorted())
        } catch { return failure(error) }
    }
    public func snapshot(_ path: String, startLine: Int = 1, lineCount: Int = 200, locked: () -> Bool, cancelled: () -> Bool = { false }, maximumBytes: Int = 32768, truncateToFit: Bool = false) -> ToolExecutionResult<CodexCodeFile> {
        do {
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
            guard (1...1000000).contains(startLine), (1...600).contains(lineCount), (1...32768).contains(maximumBytes) else { throw CodexCodeError.invalidRange }
            guard let data = try read(path), let full = String(data: data, encoding: .utf8) else { throw CodexCodeError.invalid }
            let lines = full.components(separatedBy: "\n")
            guard startLine <= lines.count else { throw CodexCodeError.invalidRange }
            guard !CodexCodePolicy.containsSecret(full) else { throw CodexCodeError.secret }
            let requested = Array(lines.dropFirst(startLine - 1).prefix(lineCount))
            var selected: [String] = [], bytes = 0
            for line in requested {
                let size = line.utf8.count + (selected.isEmpty ? 0 : 1)
                if bytes + size > maximumBytes {
                    guard truncateToFit, !selected.isEmpty else { throw CodexCodeError.rangeTooLarge }
                    break
                }
                selected.append(line); bytes += size
            }
            let text = selected.joined(separator: "\n")
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
            return .succeeded(.init(path: path, fullText: full, text: text, startLine: startLine, revision: SharedProjectFiles.revision(data)))
        } catch { return failure(error) }
    }
    /// Local previews only: partial failures never authorize transmission. The UI
    /// must show these exact effective ranges and obtain a fresh sharing approval.
    public func previewReads(_ requests: [CodexCodeRead], inventory: [String], locked: () -> Bool, cancelled: () -> Bool = { false }) -> ToolExecutionResult<CodexCodeReadBatch> {
        do {
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
            guard !requests.isEmpty, requests.count <= 8, Set(requests.map(\.path)).count == requests.count else { throw CodexCodeError.invalid }
            var files: [CodexCodeFile] = [], reads: [CodexCodeRead] = [], issues: [String] = [], bytes = 0
            for request in requests {
                try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
                guard let path = inventory.first(where: { $0 == request.path }), CodexCodePolicy.readable(path) else {
                    issues.append("요청한 파일이 현재 연결 폴더의 목록에 없습니다. 폴더 목록을 새로 확인해주세요."); continue
                }
                let available = min(32768, 98304 - bytes)
                guard available > 0 else { issues.append("\(path): 총 96KiB 한도로 이번 전송에서 제외했습니다."); continue }
                switch snapshot(path, startLine: request.startLine, lineCount: request.lineCount, locked: locked, cancelled: cancelled, maximumBytes: available, truncateToFit: true) {
                case .succeeded(let file):
                    let count = file.text.components(separatedBy: "\n").count
                    files.append(file); bytes += file.text.utf8.count
                    reads.append(.init(path: path, startLine: file.startLine, lineCount: count))
                    if count < request.lineCount { issues.append("\(path): 파일 끝 또는 크기 한도에 맞춰 \(count)줄을 준비했습니다.") }
                case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message): issues.append("\(path): \(message)")
                case .handedOff: issues.append("\(path): 로컬 파일 읽기를 확인하지 못했습니다.")
                }
            }
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: cancelled)
            return .succeeded(.init(files: files, reads: reads, issues: issues))
        } catch { return failure(error) }
    }
    public func prepare(_ proposal: CodexCodeProposal, files: [CodexCodeFile], now: Date = Date(), locked: () -> Bool = { false }) throws -> [CodexCodePlan] {
        try authorize(.codeRead, confirmed: false, locked: locked, cancelled: { false })
        var plans: [CodexCodePlan] = []
        for (path, edits) in Dictionary(grouping: proposal.edits, by: \.path) {
            guard CodexCodePolicy.writable(path) else { throw CodexCodeError.invalid }
            if let file = files.first(where: { $0.path == path }) {
                let original = Data(file.fullText.utf8)
                var ranges: [(Range<Int>, Data)] = []
                for edit in edits {
                    guard let old = edit.old, file.text.contains(old), let range = original.range(of: Data(old.utf8)),
                          original.range(of: Data(old.utf8), in: (range.lowerBound + 1)..<original.count) == nil else { throw CodexCodeError.invalid }
                    ranges.append((range, Data(edit.new.utf8)))
                }
                ranges.sort { $0.0.lowerBound < $1.0.lowerBound }
                for i in ranges.indices.dropFirst() where ranges[i - 1].0.upperBound > ranges[i].0.lowerBound { throw CodexCodeError.invalid }
                var next = original
                for (range, data) in ranges.reversed() { next.replaceSubrange(range, with: data) }
                guard next.count <= 1048576, next != original, let after = String(data: next, encoding: .utf8) else { throw CodexCodeError.invalid }
                plans.append(.init(id: UUID(), session: session, path: path, before: file.fullText, after: after, expires: now.addingTimeInterval(600)))
            } else {
                guard edits.count == 1, edits[0].old == nil, !edits[0].new.isEmpty, try read(path, missing: true) == nil else { throw CodexCodeError.invalid }
                plans.append(.init(id: UUID(), session: session, path: path, before: nil, after: edits[0].new, expires: now.addingTimeInterval(600)))
            }
        }
        return plans.sorted { $0.path < $1.path }
    }
    private func backupDirectory(_ url: URL) throws {
        guard url.isFileURL, !url.path.hasPrefix(root.path + "/"), url.path != root.path,
              !["Mobile Documents", "CloudStorage", "CloudDocs"].contains(where: url.path.contains) else { throw CodexCodeError.invalid }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CodexCodeError.invalid }
    }
    private func writeBytes(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw CodexCodeError.io }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CodexCodeError.io }
    }
    private func saveBackup(_ backup: CodexCodeBackup, directory: URL) throws {
        try backupDirectory(directory)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard entries.count < 100 else { throw CodexCodeError.invalid }
        let url = directory.appendingPathComponent(backup.id.uuidString + ".json")
        let bytes = try JSONEncoder().encode(backup)
        guard bytes.count <= 4194304 else { throw CodexCodeError.invalid }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexCodeError.io }; defer { close(fd) }
        try writeBytes(bytes, fd: fd)
    }
    public func backups(directory: URL, locked: () -> Bool) -> ToolExecutionResult<[CodexCodeBackup]> {
        do {
            try authorize(.codeRead, confirmed: false, locked: locked, cancelled: { false })
            // Viewing is read-only: an absent backup directory is an empty list.
            guard FileManager.default.fileExists(atPath: directory.path) else { return .succeeded([]) }
            let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CodexCodeError.invalid }
            var items: [CodexCodeBackup] = []
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).prefix(100) where url.pathExtension == "json" {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { continue }; defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 4194304 else { continue }
                let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4194305) ?? Data()
                guard bytes.count <= 4194304, let item = try? JSONDecoder().decode(CodexCodeBackup.self, from: bytes),
                      item.rootIdentity == identity, CodexCodePolicy.writable(item.path),
                      item.after.utf8.count <= 1048576, (item.before?.utf8.count ?? 0) <= 1048576 else { continue }
                items.append(item)
            }
            return .succeeded(items.sorted { $0.created > $1.created })
        } catch { return failure(error) }
    }
    /// One file per approval. File coordination and immediate revision checks
    /// preserve dirty working trees; Git reset/clean and model shell are absent.
    public func apply(_ plan: CodexCodePlan, backupDirectory: URL, confirmed: Bool, locked: () -> Bool, cancelled: () -> Bool = { false }) -> ToolExecutionResult<CodexCodeBackup> {
        mutex.lock(); defer { mutex.unlock() }
        var didWrite = false
        do {
            try authorize(.codeApply, confirmed: confirmed, locked: locked, cancelled: cancelled)
            guard plan.session == session, plan.expires > Date(), !consumed.contains(plan.id),
                  CodexCodePolicy.writable(plan.path), plan.after.utf8.count <= 1048576,
                  !CodexCodePolicy.containsSecret(plan.after) else { throw CodexCodeError.invalid }
            let backup = CodexCodeBackup(id: UUID(), rootIdentity: identity, path: plan.path, before: plan.before, after: plan.after, created: Date())
            var coordinationError: NSError?, workError: Error?
            let coordinator = NSFileCoordinator()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 20); timer.setEventHandler { coordinator.cancel() }; timer.resume()
            defer { timer.cancel() }
            coordinator.coordinate(writingItemAt: root.appendingPathComponent(plan.path), options: .forReplacing, error: &coordinationError) { _ in
                do {
                    try authorize(.codeApply, confirmed: confirmed, locked: locked, cancelled: cancelled)
                    guard try read(plan.path, missing: true) == plan.before.map({ Data($0.utf8) }) else { throw CodexCodeError.changed }
                    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(plan.path))?.isEmpty != false else { throw CodexCodeError.changed }
                    try saveBackup(backup, directory: backupDirectory)
                    try atomicWrite(plan.path, data: Data(plan.after.utf8), expected: plan.before.map { Data($0.utf8) }, beforeCommit: {
                        try authorize(.codeApply, confirmed: confirmed, locked: locked, cancelled: cancelled)
                    })
                    didWrite = true
                    guard try read(plan.path) == Data(plan.after.utf8) else { throw CodexCodeError.io }
                } catch { workError = error }
            }
            if let error = workError ?? coordinationError { throw error }
            guard didWrite else { throw CodexCodeError.cancelled }
            consumed.insert(plan.id)
            return .succeeded(backup)
        } catch {
            if didWrite { return .unverifiable(message: "쓰기 후 최종 확인에 실패했습니다. 백업은 보존했으며 추가 적용 전에 원본을 다시 확인해주세요.") }
            return failure(error)
        }
    }
    private func atomicWrite(_ path: String, data: Data, expected: Data?, beforeCommit: () throws -> Void) throws {
        let (directory, name) = try parent(path); defer { close(directory) }
        let temporary = ".jarvis-code-" + UUID().uuidString + ".tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexCodeError.io }
        defer { close(fd); unlinkat(directory, temporary, 0) }
        try writeBytes(data, fd: fd)
        var info = stat()
        if expected != nil {
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CodexCodeError.changed }
            guard fchmod(fd, info.st_mode & 0o777) == 0 else { throw CodexCodeError.io }
        }
        try beforeCommit()
        guard try read(path, missing: true) == expected else { throw CodexCodeError.changed }
        guard renameatx_np(directory, temporary, directory, name, expected == nil ? UInt32(RENAME_EXCL) : 0) == 0 else { throw CodexCodeError.changed }
    }
    public func restore(_ backup: CodexCodeBackup, confirmed: Bool, locked: () -> Bool, cancelled: () -> Bool = { false }) -> ToolExecutionResult<String> {
        mutex.lock(); defer { mutex.unlock() }
        var mutated = false
        do {
            try authorize(.codeRestore, confirmed: confirmed, locked: locked, cancelled: cancelled)
            guard backup.rootIdentity == identity, CodexCodePolicy.writable(backup.path),
                  (backup.before?.utf8.count ?? 0) <= 1048576, backup.after.utf8.count <= 1048576 else { throw CodexCodeError.invalid }
            var coordinationError: NSError?, workError: Error?, restored = false
            let coordinator = NSFileCoordinator(), timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 20); timer.setEventHandler { coordinator.cancel() }; timer.resume()
            defer { timer.cancel() }
            coordinator.coordinate(writingItemAt: root.appendingPathComponent(backup.path), options: .forReplacing, error: &coordinationError) { _ in
                do {
                    try authorize(.codeRestore, confirmed: confirmed, locked: locked, cancelled: cancelled)
                    guard try read(backup.path) == Data(backup.after.utf8) else { throw CodexCodeError.changed }
                    if let before = backup.before {
                        try atomicWrite(backup.path, data: Data(before.utf8), expected: Data(backup.after.utf8), beforeCommit: {
                            try authorize(.codeRestore, confirmed: confirmed, locked: locked, cancelled: cancelled)
                        })
                    } else {
                        let (directory, name) = try parent(backup.path); defer { close(directory) }
                        try authorize(.codeRestore, confirmed: confirmed, locked: locked, cancelled: cancelled)
                        guard try read(backup.path) == Data(backup.after.utf8), unlinkat(directory, name, 0) == 0 else { throw CodexCodeError.changed }
                    }
                    mutated = true
                    guard try read(backup.path, missing: true) == backup.before.map({ Data($0.utf8) }) else { throw CodexCodeError.io }
                    restored = true
                } catch { workError = error }
            }
            if let error = workError ?? coordinationError { throw error }
            guard restored else { throw CodexCodeError.cancelled }
            return .succeeded("선택한 파일의 백업 복구를 확인했습니다. 빌드·테스트는 별도로 실행해야 합니다.")
        } catch {
            if mutated { return .unverifiable(message: "복구 요청 후 최종 확인에 실패했습니다. 원본과 보존된 백업을 확인해주세요.") }
            return failure(error)
        }
    }
    private func failure<T: Sendable>(_ error: Error) -> ToolExecutionResult<T> {
        let systemError = error as NSError
        if (systemError.domain == NSCocoaErrorDomain && systemError.code == CocoaError.fileReadNoPermission.rawValue)
            || (systemError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(systemError.code)) {
            return .needsPermission(message: "프로젝트 폴더의 내용을 읽을 권한이 없습니다. 접근할 폴더를 다시 선택해주세요.")
        }
        if let e = error as? CodexCodeError {
            switch e {
            case .invalidRange: return .failed(message: "요청한 줄 범위가 파일에 없습니다. 시작 줄을 확인해주세요.", retryable: false)
            case .sourceTooLarge: return .failed(message: "로컬 원본이 1MiB 한도를 초과하여 읽지 않았습니다.", retryable: false)
            case .rangeTooLarge: return .failed(message: "코드 범위 또는 한 줄이 전송 크기 한도를 초과했습니다. 더 짧은 범위를 선택해주세요.", retryable: false)
            case .secret: return .failed(message: "비밀 키로 보이는 내용이 감지되어 이 파일은 전송하지 않습니다. 파일에서 키를 분리한 뒤 다시 요청해주세요.", retryable: false)
            default: break
            }
        }
        if let e = error as? CodexCodeError, case .permission = e { return .needsPermission(message: "프로젝트의 파일 접근·쓰기 권한을 확인해주세요.") }
        if let e = error as? CodexCodeError, case .confirmation = e { return .needsConfirmation(message: "표시된 파일 변경 또는 백업 복구를 직접 승인해주세요.") }
        if let e = error as? CodexCodeError, case .locked = e { return .failed(message: "안전 잠금으로 코드 조회·변경을 중단했습니다.", retryable: false) }
        if let e = error as? CodexCodeError, case .changed = e { return .failed(message: "원본 또는 프로젝트가 변경됐습니다. 다시 읽고 변경안을 검토해주세요.", retryable: false) }
        return .failed(message: "파일 권한·저장 공간·코드 크기·비밀정보·보호 경로 또는 취소 상태를 확인해주세요. 적용을 완료했다고 판단하지 않습니다.", retryable: false)
    }
}
