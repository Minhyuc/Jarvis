import Foundation

/// UI-only personal Mac bridge. Never registered with semantic routing.
public enum CodexLocalAction: Sendable, Equatable {
    case configure, serviceStart, serviceStop, configureRecovery, loginStart, loginPoll, loginCancel, logout, diagnostics, selectBackend, status, probe, models, usage, chat, chatImageRead, attachmentRead, workspaceExport, steer, workspaceRead, workspaceImport, workspaceEdit, workspaceDelete, codeConnect, codeRead, codeDraft, codeApply, codeRestore, nativeTool, agentStart, agentPoll, agentRespond, agentStop, agentSteer, agentHistoryRead, agentHistoryChange, agentConfigureExtensions, cancel, disconnect
}

public enum CodexLocalBackend: String, CaseIterable, Identifiable, Sendable {
    case cli, appServer
    public var id: String { rawValue }
    public var title: String { self == .cli ? "CLI" : "App Server" }
    public var provider: String { "Codex" }
}

/// OAuth URLs are data from a dedicated auth RPC, never model-provided links.
public enum CodexLoginURL {
    public static func validated(_ text: String) -> URL? {
        guard text.utf8.count <= 8192, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let value = URLComponents(string: text), value.scheme == "https", value.user == nil,
              value.password == nil, value.port == nil, value.fragment == nil,
              (value.host == "auth.openai.com" && value.percentEncodedPath == "/oauth/authorize"
                || value.host == "chatgpt.com" && ["/auth/login", "/oauth/authorize"].contains(value.percentEncodedPath)),
              let items = value.queryItems, Set(items.map(\.name)).count == items.count else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard fields["response_type"] == "code", !(fields["state"] ?? "").isEmpty,
              !(fields["code_challenge"] ?? "").isEmpty, fields["code_challenge_method"] == "S256",
              let redirect = fields["redirect_uri"], let callback = URLComponents(string: redirect),
              callback.scheme == "http", ["localhost", "127.0.0.1"].contains(callback.host ?? ""),
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
              callback.percentEncodedPath == "/auth/callback", (1...65535).contains(callback.port ?? 0) else { return nil }
        return value.url
    }
}

/// Only fixed version labels, numbers and booleans. No paths, accounts or text.
public struct CodexLocalDiagnostics: Decodable, Sendable {
    public let helperBuild: String
    public let pythonMajor: Int
    public let pythonMinor: Int
    public let requests: Int
    public let active: Bool
    public let managed: Bool
    func validate() throws {
        guard ["2026.11.04.2", "2026.11.04.3", "2026.11.04.4", "2026.11.04.5", "2026.11.04.6", "2026.11.10.1", "2026.11.10.2", "2026.11.10.3", "2026.11.11.1", "2026.11.11.2", "2026.11.11.3", "2026.11.11.4", "2026.11.17.1", "2026.11.18.1", "2026.11.18.2"].contains(helperBuild), pythonMajor == 3, (0...99).contains(pythonMinor),
              (0...4096).contains(requests) else { throw CodexLocalError.invalid }
    }
}

/// Explicit start consent may include only two transport repairs within ten
/// minutes for that backend and exact installed build. Never authorizes a turn.
public struct CodexServiceRecoveryBudget: Sendable {
    private let deadline: Date
    private let backend: CodexLocalBackend
    private let build: String
    private let monotonicStart: ContinuousClock.Instant
    public private(set) var remaining = 2
    public init(now: Date, backend: CodexLocalBackend, build: String, monotonicNow: ContinuousClock.Instant = .now) {
        deadline = now.addingTimeInterval(600); self.backend = backend; self.build = build
        monotonicStart = monotonicNow
    }
    public mutating func claim(now: Date, backend: CodexLocalBackend, build: String, locked: Bool, monotonicNow: ContinuousClock.Instant = .now) -> Bool {
        let elapsed = monotonicStart.duration(to: monotonicNow)
        guard !locked, remaining > 0, now < deadline, elapsed >= .zero, elapsed < .seconds(600), self.backend == backend, self.build == build else { return false }
        remaining -= 1; return true
    }
}

enum CodexLocalProbe {
    static let text = "JARVIS 로컬 연결 테스트입니다. 도구를 사용하지 말고 'Codex 연결 테스트 응답입니다.' 한 문장만 답하세요."
    static func isolatedText() -> String {
        // No existing conversation, memory, profile or shared-file content.
        let context = AssistantContextManager().context(for: text, longTermMemories: [])
        precondition(context.summary == nil && context.recentTurns.isEmpty && context.longTermMemories.isEmpty)
        return text
    }
}

public struct CodexLocalConnection: Decodable, Sendable, CustomStringConvertible {
    public let format: Int
    public let port: Int
    public let sessionID: UUID
    private let token: String
    public var description: String { "CodexLocalConnection(loopback, credentials redacted)" }
    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 4096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["format", "port", "sessionID", "token"] else { throw CodexLocalError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == 1, (1024...65535).contains(value.port), value.token.count == 64,
              value.token.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CodexLocalError.invalid }
        return value
    }
    func request(_ action: CodexLocalAction, id: UUID, chat: CodexChatRequest? = nil, backend: CodexLocalBackend = .cli, code: CodexCodeRequest? = nil, steering: CodexTurnInput? = nil, native: CodexNativeToolRequest? = nil, agentInput: String? = nil) throws -> URLRequest {
        let path: String
        switch action {
        case .status: path = "status"
        case .probe: path = "probe"
        case .cancel: path = "cancel"
        case .models: path = "models"
        case .usage: path = "usage"
        case .chat: path = "chat"
        case .steer:
            guard backend == .appServer, steering != nil else { throw CodexLocalError.invalid }
            path = "steer"
        case .codeDraft:
            guard backend == .appServer, code != nil else { throw CodexLocalError.invalid }
            path = "codeDraft"
        case .loginStart, .loginPoll, .loginCancel, .logout:
            guard backend == .appServer else { throw CodexLocalError.invalid }
            path = action == .loginStart ? "loginStart" : action == .loginPoll ? "loginPoll" : action == .loginCancel ? "loginCancel" : "logout"
        case .agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange:
            guard backend == .appServer, let agentInput, agentInput.utf8.count <= 65536,
                  (try? JSONSerialization.jsonObject(with: Data(agentInput.utf8))) is [String: Any] else { throw CodexLocalError.invalid }
            path = action == .agentStart ? "agentStart" : action == .agentPoll ? "agentPoll" : action == .agentRespond ? "agentRespond" : action == .agentStop ? "agentStop" : action == .agentSteer ? "agentSteer" : action == .agentHistoryRead ? "agentHistoryRead" : "agentHistoryChange"
        case .diagnostics: path = "diagnostics"
        case .nativeTool:
            guard backend == .appServer, native != nil else { throw CodexLocalError.invalid }
            path = "nativeTool"
        case .agentConfigureExtensions, .configure, .serviceStart, .serviceStop, .configureRecovery, .selectBackend, .disconnect, .chatImageRead, .attachmentRead, .workspaceExport, .workspaceRead, .workspaceImport, .workspaceEdit, .workspaceDelete, .codeConnect, .codeRead, .codeApply, .codeRestore: throw CodexLocalError.invalid
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = [.probe, .chat, .codeDraft].contains(action) ? (backend == .appServer ? 120 : 80) : (backend == .appServer ? 45 : 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["requestID": id.uuidString, "sessionID": sessionID.uuidString]
        if backend == .appServer { body["backend"] = backend.rawValue }
        if action == .probe { body["prompt"] = CodexLocalProbe.isolatedText() }
        if action == .chat {
            guard let chat else { throw CodexLocalError.invalid }
            try chat.validate()
            if !chat.images.isEmpty {
                guard backend == .appServer else { throw CodexLocalError.invalid }
                if chat.images.count == 1 { body["imageJPEG"] = chat.images[0].base64EncodedString() }
                else { body["imagesJPEG"] = String(decoding: try JSONEncoder().encode(chat.images.map { $0.base64EncodedString() }), as: UTF8.self) }
            }
            body["model"] = chat.model; body["input"] = chat.input; body["effort"] = chat.effort
            if backend == .appServer {
                guard let conversation = chat.conversationID else { throw CodexLocalError.invalid }
                body["conversationID"] = conversation.uuidString
                if let source = chat.forkSource { body["forkSource"] = source.uuidString }
            }
        } else if chat != nil { throw CodexLocalError.invalid }
        if action == .codeDraft, let code {
            body["model"] = code.model; body["effort"] = code.effort; body["input"] = try code.encodedInput()
        } else if code != nil { throw CodexLocalError.invalid }
        if let steering {
            guard action == .steer, CodexTurnInput.valid(steering.text) else { throw CodexLocalError.invalid }
            body["targetID"] = steering.target.uuidString
            body["input"] = steering.text
            request.timeoutInterval = 8
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        if let native {
            guard action == .nativeTool else { throw CodexLocalError.invalid }
            body["input"] = try native.encodedInput()
            request.httpBody = try encoder.encode(body)
            request.timeoutInterval = 115
        }
        if let agentInput {
            guard [.agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange].contains(action) else { throw CodexLocalError.invalid }
            body["input"] = agentInput
            request.httpBody = try encoder.encode(body)
            if action == .agentHistoryChange { request.timeoutInterval = 115 }
        }
        return request
    }
}

public struct CodexTurnInput: Sendable {
    public let target: UUID
    public let text: String
    public init(target: UUID, text: String) { self.target = target; self.text = text }
    public static func valid(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= 1800 && !CodexCodePolicy.containsSecret(text)
    }
}

public enum CodexLocalError: Error { case invalid, unavailable }

public struct CodexLocalModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let reasoningEfforts: [String]?
    public let defaultReasoningEffort: String?
    public init(id: String, name: String, reasoningEfforts: [String]? = nil, defaultReasoningEffort: String? = nil) {
        self.id = id; self.name = name; self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
    /// Display choices, not proof of account entitlement. Available even when
    /// the local helper is disconnected or has no model-cache file.
    public static let recommended: [Self] = [
        .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        .init(id: "gpt-6-astra", name: "GPT-6 Astra"),
        .init(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
        .init(id: "gpt-6-sol", name: "GPT-6 Sol"),
        .init(id: "gpt-6-luna", name: "GPT-6 Luna"),
        .init(id: "gpt-5.6-sol", name: "GPT-5.6 Sol"),
        .init(id: "gpt-5.6-terra", name: "GPT-5.6 Terra"),
        .init(id: "gpt-5.6-luna", name: "GPT-5.6 Luna")]
    public static func catalog(merging received: [Self]) -> [Self] {
        var result = recommended
        for model in received.prefix(40) where validID(model.id) && model.name.utf8.count <= 160 {
            if let index = result.firstIndex(where: { $0.id == model.id }) {
                result[index] = .init(id: model.id, name: result[index].name, reasoningEfforts: model.reasoningEfforts)
            } else if result.count < 40 { result.append(model) }
        }
        return result
    }
    public static let effortValues = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    public static func effortName(_ value: String) -> String {
        ["none": "추론 없음", "minimal": "최소", "low": "낮음", "medium": "보통", "high": "높음", "xhigh": "매우 높음", "max": "최대", "ultra": "최상위"][value] ?? value
    }
    public static func validID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 128 && text.first?.isASCII == true
        && text.first?.isLetter == true
        && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-").contains($0) }
    }
}

public struct CodexChatDocument: Codable, Sendable, Equatable {
    public let name: String
    public let text: String
    public let truncated: Bool
    public init(name: String, text: String, truncated: Bool = false) {
        self.name = name; self.text = text; self.truncated = truncated
    }
    public func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 200, !name.contains("/"), !name.contains("\0"),
              !text.isEmpty, !text.contains("\0"), text.utf8.count <= 16384, !CodexCodePolicy.containsSecret(text) else { throw CodexLocalError.invalid }
    }
}

public struct CodexChatRequest: Sendable, Equatable {
    public let model: String
    public let input: String
    public let effort: String
    public let conversationID: UUID?
    public let images: [Data]
    public var image: Data? { images.first }
    public let documents: [CodexChatDocument]
    public let forkSource: UUID?
    public struct Input: Codable, Sendable {
        public let message: String
        public let turns: [CloudConversationTurn]
        public var documents: [CodexChatDocument]? = nil
    }
    public init(model: String, message: String, messages: [CodexChatMessage], effort: String = "low", conversationID: UUID? = nil, image: Data? = nil, forkSource: UUID? = nil, images: [Data] = [], documents: [CodexChatDocument] = []) throws {
        guard CodexLocalModel.validID(model), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 6000 else { throw CodexLocalError.invalid }
        var manager = AssistantContextManager(maximumRecentTurns: 6, maximumLongTermMemories: 1)
        // Only successful adjacent pairs in this conversation, no other project,
        // app memories, failed inputs, project files or runtime credentials.
        var pairs: [(String, String)] = []
        for index in messages.indices.dropFirst() {
            let previous = messages[index - 1], current = messages[index]
            if previous.coding != true, current.coding != true, previous.imported != true, current.imported != true, previous.role == .user, previous.state == .completed,
               current.role == .assistant, current.state == .completed {
                pairs.append((previous.text, current.text))
            }
        }
        for (user, assistant) in pairs.suffix(6) {
            manager.record(userText: user, assistantResponse: assistant, intent: .unknownCommand(text: user))
        }
        var turns = manager.context(for: message, longTermMemories: []).recentTurns.suffix(6)
            .map { CloudConversationTurn(user: $0.userText, assistant: $0.assistantResponse) }
        let encoder = JSONEncoder()
        let limit = documents.isEmpty ? 24_576 : 98304
        var bytes = try encoder.encode(Input(message: message, turns: turns, documents: documents.isEmpty ? nil : documents))
        while bytes.count > limit, !turns.isEmpty {
            turns.removeFirst(); bytes = try encoder.encode(Input(message: message, turns: turns, documents: documents.isEmpty ? nil : documents))
        }
        self.model = model; self.input = String(decoding: bytes, as: UTF8.self); self.effort = effort
        self.conversationID = conversationID
        guard image == nil || images.isEmpty else { throw CodexLocalError.invalid }
        self.images = image.map { [$0] } ?? images
        self.documents = documents
        self.forkSource = forkSource
        try validate()
    }
    public static let imageByteLimit = 1_048_576
    func validate() throws {
        guard images.count <= 4, images.reduce(0, { $0 + $1.count }) <= 3 * 1024 * 1024, documents.count <= 4 else { throw CodexLocalError.invalid }
        for image in images {
            guard (4...Self.imageByteLimit).contains(image.count),
                  image.starts(with: [0xff, 0xd8]), image.suffix(2).elementsEqual([0xff, 0xd9]) else { throw CodexLocalError.invalid }
        }
        for document in documents { try document.validate() }
        guard CodexLocalModel.validID(model), CodexLocalModel.effortValues.contains(effort), input.utf8.count <= (documents.isEmpty ? 24576 : 98304) else { throw CodexLocalError.invalid }
        let decoded = try JSONDecoder().decode(Input.self, from: Data(input.utf8))
        guard !decoded.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.message.utf8.count <= 6000, decoded.turns.count <= 6 else { throw CodexLocalError.invalid }
    }
}

public struct CodexChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, notice }
    public enum State: String, Codable, Sendable { case pending, completed, interrupted }
    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var state: State
    public var model: String
    public var backend: String? = nil
    public var coding: Bool? = nil
    public var imageAttached: Bool? = nil
    public var attachmentNames: [String]? = nil
    public var imported: Bool? = nil
    public var date: Date = Date()
    public init(role: Role, text: String, state: State = .completed, model: String = "") {
        self.role = role; self.text = text; self.state = state; self.model = model
    }
}
public struct CodexChatThread: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var model: String
    public var effort: String? = nil
    public var importFingerprint: String? = nil
    public var forkSource: UUID? = nil
    public var agentTurnID: String? = nil
    public var agentForkSource: UUID? = nil
    public var agentForkTurn: String? = nil
    public var messages: [CodexChatMessage] = []
    public init(title: String = "새 대화", model: String = "") { self.title = title; self.model = model }
}
public struct CodexChatProject: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var threads: [CodexChatThread] = []
    public init(name: String) { self.name = name }
}
public struct CodexChatWorkspace: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var projects: [CodexChatProject] = []
    public var preferredModel: String? = nil
    public var preferredEffort: String? = nil
    public init() {}
    public func encoded() throws -> Data {
        guard version == 1, projects.count <= 20,
              preferredModel == nil || preferredModel == "" || CodexLocalModel.validID(preferredModel!),
              preferredEffort == nil || CodexLocalModel.effortValues.contains(preferredEffort!),
              Set(projects.map(\.id)).count == projects.count else { throw CodexLocalError.invalid }
        var identifiers = Set<UUID>()
        for project in projects {
            guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  project.name.utf8.count <= 160, project.threads.count <= 30 else { throw CodexLocalError.invalid }
            for thread in project.threads {
                guard thread.agentTurnID == nil || (!thread.agentTurnID!.isEmpty && thread.agentTurnID!.utf8.count <= 128),
                      (thread.agentForkSource == nil && thread.agentForkTurn == nil) || (thread.agentForkSource != nil && thread.agentForkTurn?.isEmpty == false && thread.agentForkTurn!.utf8.count <= 128) else { throw CodexLocalError.invalid }
                guard identifiers.insert(thread.id).inserted, !thread.title.isEmpty, thread.title.utf8.count <= 160,
                      thread.effort == nil || CodexLocalModel.effortValues.contains(thread.effort!),
                      thread.importFingerprint.map({ $0.utf8.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
                      thread.model.isEmpty || CodexLocalModel.validID(thread.model), thread.messages.count <= 200 else { throw CodexLocalError.invalid }
                for message in thread.messages {
                    guard identifiers.insert(message.id).inserted, message.text.utf8.count <= 8192,
                          message.backend == nil || CodexLocalBackend(rawValue: message.backend!) != nil,
                          message.model.isEmpty || CodexLocalModel.validID(message.model) else { throw CodexLocalError.invalid }
                }
            }
        }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 8_388_608 else { throw CodexLocalError.invalid }
        return data
    }
    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 8_388_608 else { throw CodexLocalError.invalid }
        var value = try JSONDecoder().decode(Self.self, from: data)
        _ = try value.encoded()
        for p in value.projects.indices {
            for t in value.projects[p].threads.indices {
                for m in value.projects[p].threads[t].messages.indices where value.projects[p].threads[t].messages[m].state == .pending {
                    value.projects[p].threads[t].messages[m].state = .interrupted
                }
            }
        }
        return value
    }
}

public struct CodexQuota: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let windowDurationMins: Int?
        public let resetsAt: Double?
        public var remaining: Int { max(0, min(100, Int((100 - usedPercent).rounded(.down)))) }
    }
    public let primary: Window?
    public let secondary: Window?
    public let checkedAt: Double
    func validate() throws {
        guard checkedAt.isFinite, (0...4102444800).contains(checkedAt) else { throw CodexLocalError.invalid }
        for window in [primary, secondary].compactMap({ $0 }) {
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                  window.windowDurationMins.map({ (1...525600).contains($0) }) ?? true,
                  window.resetsAt.map({ $0.isFinite && (0...4102444800).contains($0) }) ?? true else { throw CodexLocalError.invalid }
        }
    }
}

public enum CodexAccountPlan: String, Decodable, Sendable {
    case free, go, plus, pro, team, business, enterprise, edu

    public var title: String {
        self == .edu ? "Edu" : rawValue.capitalized
    }
}

public struct CodexLocalReply: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable { case succeeded, needsLogin, busy, cancelled, failed }
    public let format: Int
    public let sessionID: UUID
    public let requestID: UUID
    public let status: Status
    public let reply: String?
    public let reason: String?
    public let models: [CodexLocalModel]?
    public let protocolVersion: Int?
    public let backend: String?
    public let authVersion: Int?
    public let authURL: String?
    public let loginState: String?
    public let diagnostics: CodexLocalDiagnostics?
    public let codeVersion: Int?
    public let nativeVersion: Int?
    public let agentVersion: Int?
    public let quota: CodexQuota?
    public let accountPlan: CodexAccountPlan?
    static let upgradeMessage = "로컬 보조 프로그램이 이 앱과 호환되지 않습니다. 내장 서비스는 중지 후 시작·자동 연결을 다시 눌러주세요. 수동 연결은 보조 프로그램을 재시작하고 연결 파일을 다시 선택하세요. 대화 기록과 로그인은 삭제하지 않습니다."
    func requiresUpdate(for action: CodexLocalAction, backend: CodexLocalBackend = .cli) -> Bool {
        guard status == .succeeded else { return false }
        if [.agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange].contains(action) { return agentVersion != 2 || protocolVersion != 3 || self.backend != backend.rawValue }
        if action == .nativeTool { return nativeVersion != 1 || protocolVersion != 3 || self.backend != backend.rawValue }
        if action == .codeDraft { return codeVersion != 3 || protocolVersion != 3 || self.backend != backend.rawValue }
        if [.loginStart, .loginPoll, .loginCancel, .logout].contains(action) {
            return authVersion != 1 || protocolVersion != 3 || self.backend != backend.rawValue
        }
        return [.status, .probe, .chat].contains(action)
            && !(backend == .cli ? [2, 3].contains(protocolVersion ?? 0) : protocolVersion == 3)
    }

    static func validated(_ data: Data, connection: CodexLocalConnection, id: UUID, action: CodexLocalAction, backend: CodexLocalBackend = .cli) throws -> Self {
        guard data.count <= ([.codeDraft, .nativeTool, .agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange].contains(action) ? 196608 : 32768) else { throw CodexLocalError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        if let quota = value.quota { try quota.validate() }
        if value.accountPlan != nil {
            guard action == .status, backend == .appServer, value.status == .succeeded,
                  value.protocolVersion == 3 else { throw CodexLocalError.invalid }
        }
        guard value.format == 1, value.sessionID == connection.sessionID, value.requestID == id,
              (value.reply?.utf8.count ?? 0) <= ([.codeDraft, .nativeTool, .agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange].contains(action) ? 65536 : 8192) else { throw CodexLocalError.invalid }
        if value.protocolVersion == 3, value.backend != backend.rawValue { throw CodexLocalError.invalid }
        if let url = value.authURL {
            guard action == .loginStart, backend == .appServer, value.status == .succeeded,
                  CodexLoginURL.validated(url) != nil else { throw CodexLocalError.invalid }
        }
        if action == .loginStart, value.status == .succeeded, value.authURL == nil { throw CodexLocalError.invalid }
        if let state = value.loginState, !["pending", "completed", "cancelled", "expired", "failed"].contains(state) { throw CodexLocalError.invalid }
        if action == .loginPoll, value.status == .succeeded, value.loginState == nil { throw CodexLocalError.invalid }
        if let diagnostics = value.diagnostics { try diagnostics.validate() }
        if [.probe, .chat, .codeDraft, .nativeTool].contains(action), value.status == .succeeded, value.reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw CodexLocalError.invalid
        }
        if let models = value.models {
            guard models.count <= 40, Set(models.map(\.id)).count == models.count,
                  models.allSatisfy({ CodexLocalModel.validID($0.id) && $0.name.utf8.count <= 160
                      && ($0.reasoningEfforts == nil || ($0.reasoningEfforts!.count <= 8 && $0.reasoningEfforts!.allSatisfy(CodexLocalModel.effortValues.contains)))
                      && ($0.defaultReasoningEffort == nil || $0.reasoningEfforts?.contains($0.defaultReasoningEffort!) == true) }) else { throw CodexLocalError.invalid }
        }
        return value
    }
}

/// Redirects, cookies, disk caches and arbitrary URLs are deliberately absent.
public final class CodexLocalClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    static func rejection(for statusCode: Int) -> ToolExecutionResult<CodexLocalReply>? {
        switch statusCode {
        case 400:
            return .failed(message: "로컬 보조 프로그램이 요청 형식을 거절했습니다. " + CodexLocalReply.upgradeMessage, retryable: false)
        case 401, 403:
            return .needsPermission(message: "로컬 연결 인증 또는 지원 기능이 일치하지 않아 요청이 거절됐습니다. " + CodexLocalReply.upgradeMessage)
        case 404, 405:
            return .failed(message: "현재 로컬 보조 프로그램이 이 대화 경로를 지원하지 않습니다. " + CodexLocalReply.upgradeMessage, retryable: false)
        default: return nil
        }
    }

    private func readChatStream(_ bytes: URLSession.AsyncBytes, locked: @Sendable () -> Bool,
                                maximumOutput: Int = 8192, onPartial: @Sendable (String) async -> Void) async throws -> Data {
        var frame = Data()
        var partial = ""
        var partialBytes = 0
        var lastUpdate = ContinuousClock.now.advanced(by: .milliseconds(-100))
        for try await byte in bytes {
            if byte != 10 {
                guard frame.count < max(32768, maximumOutput * 2) else { throw CodexLocalError.invalid }
                frame.append(byte)
                continue
            }
            guard !locked(), !Task.isCancelled else { throw CancellationError() }
            let object = try JSONSerialization.jsonObject(with: frame)
            if let fields = object as? [String: Any], fields.keys.contains("delta") {
                guard fields.count == 1, let delta = fields["delta"] as? String, !delta.isEmpty else {
                    throw CodexLocalError.invalid
                }
                partialBytes += delta.utf8.count
                guard partialBytes <= maximumOutput else { throw CodexLocalError.invalid }
                partial.append(delta)
                let now = ContinuousClock.now
                if lastUpdate.duration(to: now) >= .milliseconds(60) {
                    await onPartial(partial)
                    lastUpdate = now
                }
                frame.removeAll(keepingCapacity: true)
            } else {
                return frame
            }
        }
        throw CodexLocalError.unavailable
    }

    public func perform(_ action: CodexLocalAction, connection: CodexLocalConnection, id: UUID,
                        confirmed: Bool = false, chat: CodexChatRequest? = nil, backend: CodexLocalBackend = .cli, code: CodexCodeRequest? = nil, steering: CodexTurnInput? = nil,
                        onPartial: (@Sendable (String) async -> Void)? = nil, native: CodexNativeToolRequest? = nil, agentInput: String? = nil, locked: @Sendable () -> Bool) async -> ToolExecutionResult<CodexLocalReply> {
        switch SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(
            externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .requireConfirmation(_, _, let prompt): return .needsConfirmation(message: prompt)
        case .block(_, _, let reason): return .failed(message: reason, retryable: false)
        case .allow: break
        }
        guard !Task.isCancelled else { return .failed(message: "요청을 취소했습니다.", retryable: false) }
        var request: URLRequest
        do { request = try connection.request(action, id: id, chat: chat, backend: backend, code: code, steering: steering, native: native, agentInput: agentInput) }
        catch { return .failed(message: "전송할 연결·대화 형식을 확인하지 못했습니다. 요청을 전송하지 않았습니다.", retryable: false) }
        if [.chat, .nativeTool].contains(action), backend == .appServer, onPartial != nil {
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForResource = [.probe, .chat, .codeDraft].contains(action) ? (backend == .appServer ? 125 : 85) : (backend == .appServer ? 48 : 23)
        if action == .nativeTool || action == .agentHistoryChange { config.timeoutIntervalForResource = 120 }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, let rejected = Self.rejection(for: http.statusCode) { return rejected }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let contentType = http.value(forHTTPHeaderField: "Content-Type") else {
                throw CodexLocalError.unavailable
            }
            var data = Data()
            if contentType == "application/x-ndjson", [.chat, .nativeTool].contains(action), backend == .appServer, let onPartial {
                data = try await readChatStream(bytes, locked: locked, maximumOutput: action == .nativeTool ? 98304 : 8192, onPartial: onPartial)
            } else {
                guard contentType.hasPrefix("application/json") else { throw CodexLocalError.unavailable }
                for try await byte in bytes {
                    guard data.count < ([.codeDraft, .nativeTool, .agentStart, .agentPoll, .agentRespond, .agentStop, .agentSteer, .agentHistoryRead, .agentHistoryChange].contains(action) ? 196608 : 32768) else { throw CodexLocalError.invalid }
                    data.append(byte)
                }
            }
            let value = try CodexLocalReply.validated(data, connection: connection, id: id, action: action, backend: backend)
            if ![.cancel, .loginCancel].contains(action), locked() || Task.isCancelled { throw CancellationError() }
            if value.requiresUpdate(for: action, backend: backend) { return .needsPermission(message: CodexLocalReply.upgradeMessage) }
            if action == .nativeTool, value.status == .failed, let output = value.reply {
                return .failed(message: "도구 실행 실패\n" + output, retryable: false)
            }
            switch value.status {
            case .succeeded: return .succeeded(value)
            case .needsLogin:
                return .needsPermission(message: backend == .appServer
                    ? "App Server 전용 로그인이 필요합니다. 연결 설정의 ChatGPT 로그인 버튼을 눌러주세요. 기존 CLI 로그인과 별도로 관리합니다."
                    : "Mac 터미널에서 Codex에 ChatGPT 계정으로 로그인한 뒤 다시 확인해주세요. API 키 인증으로 자동 전환하지 않습니다.")
            case .busy where action == .steer: return .failed(message: "현재 작업이 시작되기 전이거나 이미 끝났습니다. 작업당 추가 전송 한도는 3회입니다.", retryable: false)
            case .busy: return .failed(message: "로컬 Codex가 처리 중이거나 요청 한도에 도달했습니다. 대화는 시간당 60회, 고정 테스트는 10회까지이며 자동 재시도하지 않습니다.", retryable: false)
            case .cancelled: return .failed(message: "Codex 요청을 중단했습니다.", retryable: false)
            case .failed:
                if action == .steer { return .failed(message: "진행 중인 작업에 메시지를 전달했는지 확인하지 못했습니다.", retryable: false) }
                if backend == .appServer {
                    let messages = [
                        "appserver_configuration": "App Server 전용 폴더의 권한 또는 설정 격리를 확인하지 못했습니다. 전용 폴더에 사용자 config·AGENTS 파일을 넣지 마세요.",
                        "native_root_changed": "선택한 프로젝트 폴더가 바뀌었거나 접근할 수 없습니다. 폴더를 다시 연결하고 실행 내용을 검토하세요.",
                        "native_mcp_unavailable": "MCP 도구 목록을 읽지 못했습니다. 프로그램·인자·설치와 서버 인증 상태를 확인하세요.",
                        "native_tool_failed": "도구 실행을 완료하지 못했습니다. 프로그램·인자와 프로젝트 접근 권한을 확인하세요.",
                        "appserver_tool_blocked": "텍스트 연결 단계에서 도구 또는 실행 승인 요청이 감지돼 연결을 중단했습니다. 파일·명령은 실행하도록 승인하지 않았습니다.",
                        "appserver_timeout": "App Server 응답 시간이 초과됐습니다. 자동 재전송하지 않습니다. 연결 상태를 확인하세요.",
                        "appserver_disconnected": "App Server 연결이 끊겼습니다. 상태 확인 후 새 요청으로 이어갈 수 있습니다. 이전 요청을 자동 재전송하지 않습니다."]
                    if value.reason == "session_capacity" {
                        return .failed(message: "로컬 연결의 중복 방지 기록이 한도에 도달했습니다. 보조 서비스를 중지하고 다시 연결하세요. 질문은 자동 재전송하지 않습니다.", retryable: false)
                    }
                    if value.reason == "appserver_runtime_changed" {
                        return .failed(message: "Codex 실행 파일 업데이트가 감지돼 이전 세션을 종료했습니다. 로그인 상태를 다시 확인하세요. 기존 질문은 재전송하지 않습니다.", retryable: false)
                    }
                    if value.reason == "appserver_auth_url" {
                        return .failed(message: "공식 로그인 주소와 로컬 콜백을 확인하지 못해 브라우저를 열지 않았습니다. Codex 버전과 연결 상태를 확인하세요.", retryable: false)
                    }
                    return .failed(message: messages[value.reason ?? ""] ?? "App Server 요청을 완료하지 못했습니다. 로그인·연결·모델 상태를 확인하세요. 자동 재시도하지 않습니다.", retryable: false)
                }
                let message = value.reason == "provider_unavailable"
                    ? "Codex 실행기가 응답 서비스를 사용할 수 없다고 반환했습니다. CLI 버전·서비스 상태·계정에서 사용 가능한 모델을 확인해주세요. 답변 생성 성공이 아니며 자동 재시도하지 않습니다."
                    : "로컬 Codex 요청을 확인하지 못했습니다. CLI 버전·로그인·사용 한도를 확인해주세요. 자동 재시도하지 않습니다."
                return .failed(message: message, retryable: false)
            }
        } catch {
            if let urlError = error as? URLError,
               [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(urlError.code) {
                return .failed(message: "Mac 로컬 보조 프로그램에 접속하지 못했습니다. 프로그램 실행 상태를 확인하고 연결 파일을 다시 선택하세요.", retryable: false)
            }
            if [.probe, .chat, .codeDraft].contains(action) { return .unverifiable(message: "응답을 확인하지 못했습니다. 처리 여부가 불명확하므로 자동으로 다시 전송하지 않습니다.") }
            if action == .models { return .failed(message: "모델 목록을 받지 못했습니다. 보조 프로그램을 재시작하거나 입력창의 모델 메뉴에서 모델 ID를 직접 입력하세요.", retryable: false) }
            return .failed(message: "Mac 로컬 보조 프로그램에 연결하지 못했습니다. 실행 상태와 연결 파일을 확인해주세요.", retryable: false)
        }
    }
}
