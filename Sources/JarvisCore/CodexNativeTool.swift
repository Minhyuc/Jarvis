import Foundation
import CoreFoundation
import Darwin

/// A user-selected tool invocation. Never constructed from model output.
public struct CodexNativeToolRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case command, verify, mcpList, mcpCall, mcpLogin, mcpLoginPoll
        case pluginList, pluginAdd, pluginRemove, pluginMarketplace, pluginLogin, pluginLoginPoll
        case gitStatus, gitDiff
    }
    public struct Server: Codable, Equatable, Sendable {
        public let command: String
        public let args: [String]
        public let url: String?
        public init(command: String = "", args: [String] = [], url: String? = nil) {
            self.command = command
            self.args = args
            self.url = url
        }
    }
    public let operation: Operation
    public let root: String
    public let command: [String]?
    public let server: Server?
    public let tool: String?
    public let arguments: String?
    public let rootIdentity: String?

    public init(operation: Operation, root: String, command: [String]? = nil,
                server: Server? = nil, tool: String? = nil, arguments: String? = nil) {
        self.operation = operation
        self.root = root
        self.command = command
        self.server = server
        self.tool = tool
        self.arguments = arguments
        self.rootIdentity = Self.identity(for: root)
    }
    private static func identity(for path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
    public func validate() throws {
        func valid(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && !value.contains("\0")
        }
        func validArgument(_ value: String) -> Bool {
            value.utf8.count <= 4096 && !value.contains("\0")
        }
        guard valid(root, limit: 4096), root.hasPrefix("/"), root != "/",
              URL(fileURLWithPath: root).standardizedFileURL.path == root else { throw CodexLocalError.invalid }
        switch operation {
        case .command, .verify:
            guard let command, (1...64).contains(command.count),
                  valid(command[0], limit: 4096), command.allSatisfy(validArgument), server == nil,
                  tool == nil, arguments == nil else { throw CodexLocalError.invalid }
            if operation == .verify { try CodexVerificationCommand(argv: command, purpose: "검증 실행").validate() }
        case .mcpList, .mcpCall, .mcpLogin, .mcpLoginPoll:
            guard command == nil, let server else { throw CodexLocalError.invalid }
            if let url = server.url {
                guard Self.httpEndpoint(url), server.command.isEmpty, server.args.isEmpty else { throw CodexLocalError.invalid }
            } else {
                guard valid(server.command, limit: 4096), server.args.count <= 64,
                      server.args.allSatisfy(validArgument), operation != .mcpLogin, operation != .mcpLoginPoll else { throw CodexLocalError.invalid }
            }
            if operation == .mcpCall {
                guard let tool, valid(tool, limit: 256), let arguments, arguments.utf8.count <= 16384,
                      let bytes = arguments.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { throw CodexLocalError.invalid }
            } else {
                guard tool == nil, arguments == nil else { throw CodexLocalError.invalid }
            }
        case .pluginList, .pluginAdd, .pluginRemove, .pluginMarketplace, .pluginLogin, .pluginLoginPoll, .gitStatus, .gitDiff:
            guard server == nil, tool == nil, arguments == nil, let command, command.count <= 1,
                  command.allSatisfy(validArgument) else { throw CodexLocalError.invalid }
            if [.pluginList, .pluginLogin, .pluginLoginPoll, .gitStatus].contains(operation) {
                guard command.isEmpty else { throw CodexLocalError.invalid }
            } else { guard command.count == 1, !command[0].isEmpty, !command[0].hasPrefix("-") else { throw CodexLocalError.invalid } }
            if operation == .gitDiff {
                guard !command[0].hasPrefix("/"), !command[0].contains("\\"),
                      !command[0].split(separator: "/", omittingEmptySubsequences: false).contains(where: { ["", ".", "..", ".git"].contains(String($0)) }) else { throw CodexLocalError.invalid }
            }
            if operation == .pluginAdd || operation == .pluginRemove {
                guard command[0].range(of: #"^[A-Za-z0-9_.-]{1,80}(@[A-Za-z0-9_.-]{1,80})?$"#, options: .regularExpression) != nil else { throw CodexLocalError.invalid }
            }
        }
        guard try JSONEncoder().encode(self).count <= 32768 else { throw CodexLocalError.invalid }
    }
    public static func httpEndpoint(_ text: String) -> Bool {
        guard text.utf8.count <= 4096, let url = URLComponents(string: text),
              url.host != nil, url.url != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host!))
    }
    public func encodedInput() throws -> String {
        try validate()
        guard let rootIdentity, Self.identity(for: root) == rootIdentity else { throw CodexLocalError.invalid }
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
    /// Local plugin MCP manifests use the same explicit server approval.
    /// Credentials and environment overrides need their own credential UI.
    public static func pluginServers(_ data: Data) throws -> [String: Server] {
        guard data.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["mcpServers"] as? [String: [String: Any]],
              (1...20).contains(entries.count) else { throw CodexLocalError.invalid }
        var servers: [String: Server] = [:]
        for (name, fields) in entries {
            guard !name.isEmpty, name.utf8.count <= 128,
                  Set(fields.keys).isSubset(of: ["command", "args", "url", "type"]),
                  fields["command"] == nil || fields["command"] is String,
                  fields["url"] == nil || fields["url"] is String,
                  fields["type"] == nil || ["stdio", "http", "streamable-http"].contains(fields["type"] as? String ?? ""),
                  fields["args"] == nil || fields["args"] is [String] else { throw CodexLocalError.invalid }
            let args = fields["args"] as? [String] ?? []
            let server = Server(command: fields["command"] as? String ?? "", args: args, url: fields["url"] as? String)
            try Self(operation: .mcpList, root: "/tmp/jarvis-tools", server: server).validate()
            servers[name] = server
        }
        return servers
    }
}


/// Only inventory-matched locations become clickable; terminal output never supplies arbitrary URLs.
public struct CodexBuildLocation: Hashable, Sendable {
    public let path: String
    public let line: Int
    public static func parse(_ output: String, paths: [String], root: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"([^\s:]+):(\d+)(?::\d+)?:"#) else { return [] }
        let bounded = String(decoding: Data(output.utf8).prefix(48000), as: UTF8.self)
        let ns = bounded as NSString
        var result: [Self] = []
        let known = Set(paths)
        for match in regex.matches(in: bounded, range: NSRange(location: 0, length: ns.length)).prefix(100) {
            var path = ns.substring(with: match.range(at: 1))
            if path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
            if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            guard known.contains(path), let line = Int(ns.substring(with: match.range(at: 2))), (1...1000000).contains(line) else { continue }
            let item = Self(path: path, line: line)
            if !result.contains(item) { result.append(item) }
            if result.count == 30 { break }
        }
        return result
    }
}


public extension CapabilityRegistry {
    /// Explicit development-session tools, separate from general semantic routing.
    static let codexAgentTools: Set<String> = ["jarvis_project_list", "jarvis_project_read", "jarvis_project_edit", "jarvis_project_verify", "jarvis_extension_list", "jarvis_extension_inspect", "jarvis_extension_call", "jarvis_skill_list", "jarvis_skill_read", "jarvis_web_search"]
}

public struct CodexAgentCall: Decodable, Sendable, Equatable {
    public let approvalID: UUID
    public let callID: String
    public let threadID: String
    public let turnID: String
    public let tool: String
    public let arguments: String
    public let expiresAt: Double
    public func validatedArguments() throws -> [String: Any] {
        guard CapabilityRegistry.codexAgentTools.contains(tool), arguments.utf8.count <= 40000,
              let fields = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              !CodexCodePolicy.containsSecret(arguments), !callID.isEmpty, callID.utf8.count <= 128 else { throw CodexLocalError.invalid }
        switch tool {
        case "jarvis_project_list", "jarvis_extension_list", "jarvis_skill_list": guard fields.isEmpty else { throw CodexLocalError.invalid }
        case "jarvis_project_read":
            guard Set(fields.keys) == ["path", "startLine", "lineCount"], let path = fields["path"] as? String,
                  CodexCodePolicy.readable(path), let start = fields["startLine"] as? Int, (1...1000000).contains(start),
                  let count = fields["lineCount"] as? Int, (1...600).contains(count),
                  CFGetTypeID(fields["startLine"] as! NSNumber) != CFBooleanGetTypeID(),
                  CFGetTypeID(fields["lineCount"] as! NSNumber) != CFBooleanGetTypeID() else { throw CodexLocalError.invalid }
        case "jarvis_project_edit":
            guard Set(fields.keys) == ["path", "old", "new"], let path = fields["path"] as? String, CodexCodePolicy.writable(path),
                  let new = fields["new"] as? String, !new.isEmpty, !new.contains("\0"), new.utf8.count <= 32768,
                  fields["old"] is NSNull || (fields["old"] as? String).map({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 32768 }) == true else { throw CodexLocalError.invalid }
        case "jarvis_extension_call":
            guard Set(fields.keys) == ["extensionID", "tool", "arguments"], let id = fields["extensionID"] as? String, UUID(uuidString: id) != nil,
                  let tool = fields["tool"] as? String, !tool.isEmpty, tool.utf8.count <= 256,
                  let args = fields["arguments"] as? String, args.utf8.count <= 16384,
                  (try? JSONSerialization.jsonObject(with: Data(args.utf8))) is [String: Any] else { throw CodexLocalError.invalid }
        case "jarvis_extension_inspect":
            guard Set(fields.keys) == ["extensionID"], let id = fields["extensionID"] as? String, UUID(uuidString: id) != nil else { throw CodexLocalError.invalid }
        case "jarvis_skill_read":
            guard Set(fields.keys) == ["skillID"], let id = fields["skillID"] as? String, UUID(uuidString: id) != nil else { throw CodexLocalError.invalid }
        case "jarvis_web_search":
            guard Set(fields.keys) == ["query"], let query = fields["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= 2000, !query.contains("\0") else { throw CodexLocalError.invalid }
        case "jarvis_project_verify":
            guard Set(fields.keys) == ["argv", "purpose"], let argv = fields["argv"] as? [String], let purpose = fields["purpose"] as? String else { throw CodexLocalError.invalid }
            try CodexVerificationCommand(argv: argv, purpose: purpose).validate()
        default: throw CodexLocalError.invalid
        }
        return fields
    }
    public var intent: AssistantIntent { .codexLocal(tool == "jarvis_project_edit" ? .codeApply : ["jarvis_project_verify", "jarvis_extension_call", "jarvis_extension_inspect", "jarvis_web_search"].contains(tool) ? .nativeTool : .codeDraft) }
}

public struct CodexAgentSnapshot: Decodable, Sendable {
    public struct Event: Decodable, Sendable { public let sequence: Int; public let kind: String; public let text: String }
    public let agentVersion: Int
    public let jobID: UUID
    public let state: String
    public let threadID: String?
    public let turnID: String?
    public let reply: String
    public let pending: CodexAgentCall?
    public let events: [Event]
    public let sessionMode: String?
    public static func read(_ text: String) throws -> Self {
        guard text.utf8.count <= 65536 else { throw CodexLocalError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard [1, 2].contains(value.agentVersion), ["running", "awaitingApproval", "completed", "failed", "cancelled"].contains(value.state),
              value.reply.utf8.count <= 8192, value.events.count <= 80,
              value.events.allSatisfy({ $0.sequence > 0 && $0.text.utf8.count <= 7200 }),
              Set(value.events.map(\.sequence)).count == value.events.count,
              value.pending == nil || (value.state == "awaitingApproval" && value.pending?.threadID == value.threadID && value.pending?.turnID == value.turnID) else { throw CodexLocalError.invalid }
        return value
    }
}


public struct CodexAgentExtension: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var server: CodexNativeToolRequest.Server
    public var allowedTools: [String]
    public init(name: String, server: CodexNativeToolRequest.Server, allowedTools: [String]) { self.name = name; self.server = server; self.allowedTools = allowedTools }
}
public struct CodexAgentSkill: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var document: CodexChatDocument
    public init(document: CodexChatDocument) { self.document = document }
}
public struct CodexAgentProfile: Codable, Equatable, Sendable {
    public var extensions: [CodexAgentExtension] = []
    public var skills: [CodexAgentSkill] = []
    public var webSearchEnabled = false
    public init() {}
    public func encoded() throws -> Data {
        guard extensions.count <= 8, skills.count <= 4, Set(extensions.map(\.id)).count == extensions.count,
              Set(extensions.map(\.name)).count == extensions.count,
              Set(skills.map(\.id)).count == skills.count else { throw CodexLocalError.invalid }
        for item in extensions {
            guard !item.name.isEmpty, item.name.utf8.count <= 100, (1...20).contains(item.allowedTools.count),
                  Set(item.allowedTools).count == item.allowedTools.count,
                  item.allowedTools.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else { throw CodexLocalError.invalid }
            try CodexNativeToolRequest(operation: .mcpList, root: "/tmp/jarvis-profile", server: item.server).validate()
            let config = item.server.command + " " + item.server.args.joined(separator: " ") + (item.server.url ?? "")
            guard !CodexCodePolicy.containsSecret(config), config.range(of: #"(?i)--?(password|token|secret|api[-_]?key)([=\s]|$)|bearer\s"#, options: .regularExpression) == nil else { throw CodexLocalError.invalid }
        }
        for item in skills { try item.document.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 98304 else { throw CodexLocalError.invalid }
        return data
    }
    public static func read(_ data: Data) throws -> Self {
        if data.isEmpty { return .init() }
        guard data.count <= 98304 else { throw CodexLocalError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data); _ = try value.encoded(); return value
    }
}
