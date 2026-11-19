import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import CoreText
import JarvisCore
import Darwin

enum CodexDocumentReader {
    static func read(_ url: URL, confirmed: Bool, locked: Bool) throws -> CodexChatDocument {
        guard case .allow = SafetyPolicyEngine().evaluate(.codexLocal(.attachmentRead),
            context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)),
              url.isFileURL, JarvisStorage.permits(url) else { throw CodexLocalError.invalid }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 16 * 1024 * 1024 else { throw CodexLocalError.invalid }
        guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 16 * 1024 * 1024 + 1), bytes.count <= 16 * 1024 * 1024 else { throw CodexLocalError.invalid }
        var text: String
        var shortened = false
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(data: bytes), !pdf.isLocked else { throw CodexLocalError.invalid }
            var pages: [String] = []
            for index in 0..<min(pdf.pageCount, 20) {
                if let content = pdf.page(at: index)?.string { pages.append(content) }
                if pages.reduce(0, { $0 + $1.utf8.count }) > 16384 { break }
            }
            text = pages.joined(separator: "\n")
            shortened = pdf.pageCount > pages.count
        } else {
            guard let decoded = String(data: bytes, encoding: .utf8) else { throw CodexLocalError.invalid }
            text = decoded
        }
        guard !CodexCodePolicy.containsSecret(text), !text.contains("\0") else { throw CodexLocalError.invalid }
        if text.utf8.count > 16384 {
            text = String(decoding: Data(text.utf8).prefix(16380), as: UTF8.self)
            shortened = true
        }
        let document = CodexChatDocument(name: String(url.lastPathComponent.prefix(60)), text: text, truncated: shortened)
        try document.validate()
        return document
    }
}

enum CodexResponseExporter {
    static func data(_ text: String, format: String) throws -> Data {
        guard text.utf8.count <= 32768 else { throw CodexLocalError.invalid }
        if format != "pdf" {
            guard ["txt", "md"].contains(format) else { throw CodexLocalError.invalid }
            return Data(text.utf8)
        }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw CodexLocalError.invalid }
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw CodexLocalError.invalid }
        let content = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 13, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        let setter = CTFramesetterCreateWithAttributedString(content)
        var position = 0, pages = 0
        repeat {
            guard pages < 20 else { throw CodexLocalError.invalid }
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: position, length: 0),
                CGPath(rect: page.insetBy(dx: 40, dy: 40), transform: nil), nil)
            let range = CTFrameGetVisibleStringRange(frame)
            guard range.length > 0 || content.length == 0 else { throw CodexLocalError.invalid }
            CTFrameDraw(frame, context); context.endPDFPage()
            position += range.length; pages += 1
        } while position < content.length
        context.closePDF()
        return output as Data
    }
    static func save(_ data: Data, to url: URL, confirmed: Bool, locked: () -> Bool) -> ToolExecutionResult<String> {
        switch SafetyPolicyEngine().evaluate(.codexLocal(.workspaceExport),
            context: .init(externalActionsLocked: locked(), wasExplicitlyConfirmed: confirmed)) {
        case .allow: break
        case .requireConfirmation(_, _, let prompt): return .needsConfirmation(message: prompt)
        case .block(_, _, let reason): return .failed(message: reason, retryable: false)
        }
        guard JarvisStorage.permits(url), data.count <= 4 * 1024 * 1024, ["txt", "md", "pdf"].contains(url.pathExtension.lowercased()),
              !["agents.md", "agents.override.md", "skill.md"].contains(url.lastPathComponent.lowercased()) else {
            return .failed(message: "TXT·Markdown·PDF 출력 파일을 선택하세요.", retryable: false)
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard !locked(), NSFileVersion.unresolvedConflictVersionsOfItem(at: target)?.isEmpty != false else { throw CodexLocalError.invalid }
                try data.write(to: target, options: .atomic)
            } catch { writeError = error }
        }
        guard coordinationError == nil, writeError == nil else { return .failed(message: "저장 권한 또는 파일 충돌을 확인하세요.", retryable: false) }
        guard !locked(), (try? Data(contentsOf: url)) == data else { return .unverifiable(message: "쓰기 후 최종 파일 내용을 확인하지 못했습니다.") }
        return .succeeded("파일 저장을 확인했습니다.")
    }
}

struct CodexExportPreview: Identifiable {
    let id = UUID()
    let data: Data
    let text: String
    let format: String
}

struct CodexPDFPreview: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data { view.document = PDFDocument(data: data) }
    }
}

struct CodexProjectFolderSelection: Equatable {
    let id = UUID()
    let projectID: UUID
}

@MainActor
final class CodexChatWorkspaceStore: ObservableObject {
    @Published private(set) var data = CodexChatWorkspace()
    @Published var projectID: UUID?
    @Published var threadID: UUID?
    @Published private(set) var message = ""
    @Published private(set) var loaded = false
    private(set) var activeMessage: UUID?
    private var activeThread: UUID?
    private var revision: Data?
    private var previewOnly = false
    private let storageURL: URL?
    private var locked: Bool { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) }
    private var file: URL {
        storageURL ?? JarvisStorage.support
            .appendingPathComponent("JARVISCodexWorkspace", isDirectory: true).appendingPathComponent("workspace.json")
    }
    var thread: CodexChatThread? { data.projects.flatMap(\.threads).first { $0.id == threadID } }
    var selectedModel: String { thread?.model.isEmpty == false ? thread!.model : data.preferredModel ?? "" }
    var selectedEffort: String { thread?.effort ?? data.preferredEffort ?? "low" }
    init(preview: CodexChatWorkspace? = nil, storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let preview {
            data = preview; loaded = true; previewOnly = true
            projectID = preview.projects.first?.id; threadID = preview.projects.first?.threads.first?.id
        } else { load() }
    }

    private func allowed(_ action: CodexLocalAction, confirmed: Bool = false) -> Bool {
        switch SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(externalActionsLocked: locked, wasExplicitlyConfirmed: confirmed)) {
        case .allow: return true
        case .block(_, _, let reason): message = reason; return false
        case .requireConfirmation(_, _, let prompt): message = prompt; return false
        }
    }
    func load() {
        guard !loaded, allowed(.workspaceRead) else { return }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                try checkPrivate(file)
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 8_388_609) ?? Data()
                data = try .read(bytes); revision = bytes
            }
            loaded = true; projectID = data.projects.first?.id; threadID = data.projects.first?.threads.first?.id
            message = ""
        } catch { message = "대화 저장소를 읽지 못했습니다. 기존 파일은 덮어쓰지 않습니다. 앱 지원 폴더의 workspace.json을 확인하세요." }
    }
    func reload() {
        guard activeMessage == nil else { return }
        loaded = false; revision = nil; load()
    }
    private func checkPrivate(_ url: URL) throws {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (info[.referenceCount] as? NSNumber)?.intValue == 1,
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CodexLocalError.invalid }
    }
    @discardableResult
    private func commit(_ next: CodexChatWorkspace, action: CodexLocalAction = .workspaceEdit, confirmed: Bool = false) -> Bool {
        guard !previewOnly, loaded, allowed(action, confirmed: confirmed) else { return false }
        do {
            let bytes = try next.encoded(), directory = file.deletingLastPathComponent()
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let info = try fm.attributesOfItem(atPath: directory.path)
            guard info[.type] as? FileAttributeType == .typeDirectory,
                  (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CodexLocalError.invalid }
            var coordinationError: NSError?, writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { target in
                do {
                    if fm.fileExists(atPath: target.path) {
                        try checkPrivate(target)
                        let handle = try FileHandle(forReadingFrom: target); defer { try? handle.close() }
                        guard try handle.read(upToCount: 8_388_609) == revision else { throw CodexLocalError.invalid }
                    } else if revision != nil { throw CodexLocalError.invalid }
                    try bytes.write(to: target, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? { throw error }
            revision = bytes
            data = next; message = ""; return true
        } catch { message = "대화를 저장하지 못했습니다. 다른 창의 변경, 저장 공간·권한 또는 보관 한도를 확인하세요. 다른 창을 닫은 뒤 대화 목록을 새로 고침할 수 있습니다. 기록을 자동으로 덮어쓰거나 삭제하지 않습니다."; return false }
    }
    @discardableResult
    func branchConversation(after messageID: UUID) -> Bool {
        guard activeMessage == nil, let source = thread,
              let index = source.messages.firstIndex(where: { $0.id == messageID }),
              source.messages[index].role == .assistant, source.messages[index].state == .completed,
              let project = data.projects.firstIndex(where: { $0.id == projectID && $0.threads.contains(where: { $0.id == source.id }) }) else { return false }
        let prefix = source.messages.prefix(through: index)
        guard prefix.count <= 197, data.projects[project].threads.count < 30 else {
            message = "이 위치에서 분기할 수 있는 대화 또는 메시지 수 한도를 넘었습니다."
            return false
        }
        let suffix = " · 분기"
        var title = source.title
        while title.utf8.count + suffix.utf8.count > 160 { title.removeLast() }
        var branch = CodexChatThread(title: title + suffix, model: source.model)
        branch.effort = source.effort
        if index == source.messages.count - 1, source.messages[index].coding == true, let turn = source.agentTurnID {
            branch.agentForkSource = source.id; branch.agentForkTurn = turn
        }
        if index == source.messages.count - 1, source.messages[index].coding != true,
           source.messages[index].imported != true { branch.forkSource = source.id }
        branch.messages = prefix.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        }
        var next = data
        next.projects[project].threads.append(branch)
        guard commit(next) else { return false }
        threadID = branch.id
        return true
    }

    func importChatGPT(_ preview: CodexChatImport, selected: Set<UUID>, confirmed: Bool) -> Bool {
        guard activeMessage == nil, allowed(.workspaceImport, confirmed: confirmed) else { return false }
        let known = Set(data.projects.flatMap(\.threads).compactMap(\.importFingerprint))
        let selectedThreads = preview.threads.filter { selected.contains($0.id) }
        let newThreads = selectedThreads.filter { thread in
            thread.importFingerprint.map { !known.contains($0) } ?? false
        }
        guard !newThreads.isEmpty else {
            message = "선택한 대화는 이미 가져왔습니다."
            return false
        }
        var next = data
        let base = "ChatGPT 가져오기"
        let names = Set(next.projects.map(\.name))
        let name = names.contains(base) ? (2...21).map { "\(base) \($0)" }.first { !names.contains($0) } ?? base : base
        var project = CodexChatProject(name: name)
        project.threads = newThreads
        next.projects.append(project)
        guard commit(next, action: .workspaceImport, confirmed: confirmed) else { return false }
        projectID = project.id; threadID = newThreads.first?.id
        let duplicates = selectedThreads.count - newThreads.count
        message = duplicates > 0 ? "대화 \(newThreads.count)개를 가져왔습니다. 이미 있는 대화 \(duplicates)개는 건너뛰었습니다." : "대화 \(newThreads.count)개를 가져왔습니다."
        return true
    }

    func createProject(_ name: String) {
        guard activeMessage == nil else { return }
        var next = data
        let project = CodexChatProject(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        next.projects.append(project)
        if commit(next) { projectID = project.id; threadID = nil }
    }
    func createThread(model: String) {
        guard activeMessage == nil else { return }
        guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { message = "먼저 프로젝트를 만드세요."; return }
        var next = data; var thread = CodexChatThread(model: model.isEmpty ? selectedModel : model)
        thread.effort = selectedEffort
        next.projects[index].threads.append(thread)
        if commit(next) { threadID = thread.id }
    }
    func prepareFolderSelection(projectID id: UUID, model: String) -> CodexProjectFolderSelection? {
        guard activeMessage == nil, allowed(.workspaceRead),
              let project = data.projects.first(where: { $0.id == id }) else { return nil }
        projectID = id
        if !project.threads.contains(where: { $0.id == threadID }) { threadID = project.threads.first?.id }
        if threadID == nil { createThread(model: model) }
        guard thread != nil else { return nil }
        return .init(projectID: id)
    }
    func acceptsFolderSelection(_ selection: CodexProjectFolderSelection) -> Bool {
        projectID == selection.projectID && data.projects.contains(where: { $0.id == selection.projectID })
    }
    @discardableResult
    func createGeneralThread() -> Bool {
        guard activeMessage == nil else { return false }
        var next = data
        var thread = CodexChatThread(model: selectedModel)
        thread.effort = selectedEffort
        let p: Int
        if let existing = next.projects.firstIndex(where: { $0.name == "일반 대화" }) { p = existing }
        else { next.projects.append(CodexChatProject(name: "일반 대화")); p = next.projects.count - 1 }
        next.projects[p].threads.append(thread)
        guard commit(next) else { return false }
        projectID = next.projects[p].id; threadID = thread.id
        return true
    }
    func rename(_ id: UUID, name: String) {
        guard activeMessage == nil else { return }
        var next = data; let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = next.projects.firstIndex(where: { $0.id == id }) { next.projects[p].name = text }
        else {
            for p in next.projects.indices {
                if let t = next.projects[p].threads.firstIndex(where: { $0.id == id }) { next.projects[p].threads[t].title = text }
            }
        }
        _ = commit(next)
    }
    func delete(_ id: UUID, confirmed: Bool) {
        guard activeMessage == nil else { return }
        var next = data
        next.projects.removeAll { $0.id == id }
        for p in next.projects.indices { next.projects[p].threads.removeAll { $0.id == id } }
        if commit(next, action: .workspaceDelete, confirmed: confirmed) {
            if !next.projects.contains(where: { $0.id == projectID }) { projectID = next.projects.first?.id }
            if !next.projects.flatMap(\.threads).contains(where: { $0.id == threadID }) {
                threadID = next.projects.first(where: { $0.id == projectID })?.threads.first?.id
            }
        }
    }
    func model(_ model: String, effort: String = "low") {
        guard CodexLocalModel.validID(model), CodexLocalModel.effortValues.contains(effort), activeMessage == nil else { message = "올바른 모델과 추론 수준을 선택하세요."; return }
        var next = data
        next.preferredModel = model; next.preferredEffort = effort
        for p in next.projects.indices {
            if let t = next.projects[p].threads.firstIndex(where: { $0.id == threadID }) {
                next.projects[p].threads[t].model = model; next.projects[p].threads[t].effort = effort
            }
        }
        _ = commit(next)
    }
    func recordCode(_ text: String, user: Bool, threadID: UUID) {
        guard activeMessage == nil, text.utf8.count <= 6000 else { return }
        var next = data
        for p in next.projects.indices {
            guard let t = next.projects[p].threads.firstIndex(where: { $0.id == threadID }), next.projects[p].threads[t].messages.count < 198 else { continue }
            var item = CodexChatMessage(role: user ? .user : .assistant, text: text, model: selectedModel)
            item.coding = true; item.backend = "appServer"
            next.projects[p].threads[t].messages.append(item)
            if user && next.projects[p].threads[t].messages.count == 1 { next.projects[p].threads[t].title = String(text.prefix(32)) }
        }
        _ = commit(next)
    }
    func recordAgentCompletion(_ text: String, turn: String, threadID: UUID) {
        guard activeMessage == nil, !turn.isEmpty, turn.utf8.count <= 128, text.utf8.count <= 6000 else { return }
        var next = data
        for p in next.projects.indices {
            guard let t = next.projects[p].threads.firstIndex(where: { $0.id == threadID }), next.projects[p].threads[t].messages.count < 198 else { continue }
            var item = CodexChatMessage(role: .assistant, text: text, model: selectedModel)
            item.coding = true; item.backend = "appServer"
            next.projects[p].threads[t].messages.append(item); next.projects[p].threads[t].agentTurnID = turn
            next.projects[p].threads[t].agentForkSource = nil; next.projects[p].threads[t].agentForkTurn = nil
        }
        _ = commit(next)
    }
    func clearAgentSession(_ id: UUID) {
        var next = data
        for p in next.projects.indices {
            for t in next.projects[p].threads.indices {
                if next.projects[p].threads[t].id == id { next.projects[p].threads[t].agentTurnID = nil }
                if next.projects[p].threads[t].agentForkSource == id { next.projects[p].threads[t].agentForkSource = nil; next.projects[p].threads[t].agentForkTurn = nil }
            }
        }
        _ = commit(next)
    }
    func canStartCodeTurn() -> Bool {
        guard allowed(.workspaceEdit), let thread, thread.messages.count < 170 else {
            message = "이 대화의 코드 작업 보관 한도에 도달했습니다. 새 대화를 만들어주세요."; return false
        }
        return true
    }
    struct Draft: Identifiable {
        let id = UUID()
        let thread: CodexChatThread
        let session: UUID
        let text: String
        let payload: CodexChatRequest
    }
    func readChatImage(_ url: URL) throws -> Data {
        guard allowed(.chatImageRead, confirmed: true), JarvisStorage.permits(url) else { throw CodexLocalError.invalid }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CodexLocalError.invalid }
        guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        guard let sourceData = try handle.read(upToCount: limit + 1), sourceData.count <= limit,
              let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw CodexLocalError.invalid }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CodexLocalError.invalid
        }
        CGImageDestinationAddImage(encoder, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(encoder), output.length <= CodexChatRequest.imageByteLimit else {
            throw CodexLocalError.invalid
        }
        return output as Data
    }

    func prepare(_ text: String, session: UUID?, image: Data? = nil, images: [Data] = [], documents: [CodexChatDocument] = []) -> Draft? {
        guard allowed(.workspaceRead), let session, activeMessage == nil else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 6000,
              CodexLocalModel.validID(selectedModel) else { message = "모델을 선택하고 메시지를 입력하세요."; return nil }
        if thread == nil, !createGeneralThread() { return nil }
        guard let thread else { return nil }
        guard thread.messages.count <= 197 else { message = "이 대화의 보관 한도에 도달했습니다. 새 대화를 만들어주세요."; return nil }
        do { return Draft(thread: thread, session: session, text: text, payload: try CodexChatRequest(model: selectedModel, message: text, messages: thread.messages, effort: selectedEffort, conversationID: thread.id, image: image, forkSource: thread.forkSource, images: images, documents: documents)) }
        catch { message = "모델을 선택하고 6,000바이트 이내의 메시지를 입력하세요."; return nil }
    }
    @discardableResult
    func send(_ draft: Draft, connection: CodexLocalStore, confirmed: Bool = false) -> Bool {
        guard allowed(.chat, confirmed: confirmed) else { return false }
        guard thread == draft.thread,
              connection.sessionID == draft.session, connection.ready, !connection.busy, activeMessage == nil else {
            message = "대화 또는 연결이 바뀌었습니다. 내용을 확인하고 다시 전송하세요."; return false
        }
        var user = CodexChatMessage(role: .user, text: draft.text, state: .pending, model: draft.payload.model)
        user.backend = connection.backend.rawValue
        if draft.payload.image != nil { user.imageAttached = true }
        if !draft.payload.documents.isEmpty { user.attachmentNames = draft.payload.documents.map(\.name) }
        var next = data
        for p in next.projects.indices {
            if let t = next.projects[p].threads.firstIndex(where: { $0.id == draft.thread.id }) {
                next.projects[p].threads[t].messages.append(user)
                if next.projects[p].threads[t].messages.count == 1 {
                    next.projects[p].threads[t].title = String(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
                }
            }
        }
        guard commit(next) else { return false }
        activeMessage = user.id; activeThread = draft.thread.id
        connection.send(draft.payload, expectedSession: draft.session, confirmed: confirmed) { [weak self] result in self?.finish(result) }
        return true
    }
    func recordSteering(_ text: String, threadID: UUID, messageID: UUID) {
        var next = data
        for p in next.projects.indices {
            guard let t = next.projects[p].threads.firstIndex(where: { $0.id == threadID }),
                  let m = next.projects[p].threads[t].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            let original = next.projects[p].threads[t].messages[m].text
            let combined = original + "\n\n추가 메시지: " + text
            if combined.utf8.count <= 8192 {
                next.projects[p].threads[t].messages[m].text = combined
            } else if next.projects[p].threads[t].messages.count < 199 {
                next.projects[p].threads[t].messages.append(.init(role: .notice, text: "작업에 추가한 메시지: " + text))
            }
        }
        _ = commit(next)
    }

    private func finish(_ result: ToolExecutionResult<CodexLocalReply>) {
        guard let activeMessage, let activeThread else { return }
        self.activeMessage = nil; self.activeThread = nil
        var next = data
        var answer: String?, failure = "응답을 확인하지 못했습니다. 자동 재시도하지 않습니다."
        switch result {
        case .succeeded(let value): if !locked { answer = value.reply }
        case .failed(let text, _), .needsPermission(let text), .needsConfirmation(let text), .unverifiable(let text): failure = text
        case .handedOff: break
        }
        for p in next.projects.indices {
            guard let t = next.projects[p].threads.firstIndex(where: { $0.id == activeThread }),
                  let m = next.projects[p].threads[t].messages.firstIndex(where: { $0.id == activeMessage }) else { continue }
            let model = next.projects[p].threads[t].messages[m].model
            next.projects[p].threads[t].messages[m].state = answer == nil ? .interrupted : .completed
            var response = CodexChatMessage(role: answer == nil ? .notice : .assistant, text: answer ?? failure, model: model)
            response.backend = next.projects[p].threads[t].messages[m].backend
            next.projects[p].threads[t].messages.append(response)
        }
        // Cancellation bookkeeping remains possible while locked, but cannot
        // insert a late model answer or start a new request.
        if !commit(next, action: answer == nil ? .cancel : .workspaceEdit) {
            // Preserve visible pending state; restart recovery marks it interrupted.
            message = "응답 기록을 저장하지 못했습니다. 다시 전송하기 전에 저장 상태를 확인하세요."
        }
    }
}

private struct CodexNameEditor: View {
    let title: String
    let hint: String
    @State var text: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            TextField(hint, text: $text).textFieldStyle(.roundedBorder).onSubmit { submit() }
            HStack { Spacer(); Button("취소") { dismiss() }; Button("저장") { submit() }.keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420)
    }
    private func submit() { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; save(text); dismiss() }
}

/// Placeholder and insertion point share the same text container and font.
final class CodexComposerTextView: NSTextView {
    var submit: (() -> Void)?
    var placeholder = "Codex에게 메시지 보내기…"
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let text = NSAttributedString(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor])
        text.draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y))
    }
    override func keyDown(with event: NSEvent) {
        guard [36, 76].contains(event.keyCode) else { super.keyDown(with: event); return }
        // Return must finish an active Korean/Japanese composition first.
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        guard isEditable else { return }
        if event.modifierFlags.contains(.shift) { insertNewline(nil) }
        else if event.modifierFlags.intersection([.option, .control]).isEmpty {
            if !event.isARepeat { submit?() }
        } else { super.keyDown(with: event) }
    }
}

struct CodexComposerEditor: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    var placeholder = "Codex에게 메시지 보내기…"
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexComposerEditor
        init(_ parent: CodexComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string; view.needsDisplay = true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = CodexComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 54))
        view.isRichText = false; view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor; view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 54)
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CodexComposerTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        view.isEditable = enabled; view.isSelectable = enabled
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.submit = submit; view.placeholder = placeholder; view.needsDisplay = true
    }
}

struct CodexNativeToolsPanel: View {
    let root: URL
    @ObservedObject var connection: CodexLocalStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @State private var mode = "shell"
    @State private var command = "[\"/usr/bin/git\", \"status\", \"--short\"]"
    @State private var program = ""
    @State private var serverArguments = "[]"
    @State private var tool = ""
    @State private var arguments = "{}"
    @State private var servers: [String: CodexNativeToolRequest.Server] = [:]
    @State private var selectedServer = ""
    @State private var pending: CodexNativeToolRequest?
    @State private var output = ""
    @State private var httpURL = ""
    @State private var useHTTP = false
    @State private var libraryValue = ""
    @State private var gitPath = ""
    @State private var gitFiles: [String] = []
    @State private var authURL: URL?
    @State private var connectionName = ""
    @AppStorage("jarvis.codex.mcpConnections") private var savedData = Data()
    @State private var confirmSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("프로젝트 도구 실행").font(.title2.bold())
                Spacer()
                Button("닫기") { dismiss() }.disabled(connection.busy)
            }
            Text(root.path).font(.caption).textSelection(.enabled)
            if let pending {
                Text("이번 실행 내용").font(.headline)
                ScrollView {
                    Text((try? pending.encodedInput()) ?? "").textSelection(.enabled)
                        .font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(mode == "git" ? "선택한 프로젝트의 Git 상태·작업 중 변경·스테이징 변경만 읽습니다. 커밋·스테이징·파일 복구는 실행하지 않습니다."
                     : mode == "library" ? "플러그인 관리용 별도 Codex 프로필에서 선택한 설치·제거·로그인 작업만 수행합니다. 설치 구성 요소는 도구·파일 공유 승인 없이 자동 실행하지 않습니다."
                     : mode == "shell"
                     ? "프로젝트 쓰기를 허용하는 Codex 샌드박스에서 최대 30초 실행합니다. 네트워크는 차단됩니다. 명령은 Mac의 다른 파일을 읽을 수 있으므로 내용을 확인하세요."
                     : "이 MCP 프로그램은 Mac 사용자 권한으로 실행됩니다. 도구 목록 조회도 프로그램을 시작하며 네트워크·파일에 접근할 수 있습니다. 프로그램과 인자를 신뢰할 때 허용하세요.")
                    .font(.callout)
                HStack {
                    Button("허용 안 함") { self.pending = nil }
                    Spacer()
                    Button("이번 실행 허용") { execute(pending) }
                        .disabled(locked || connection.busy || !connection.ready)
                }
            } else {
                Picker("종류", selection: $mode) {
                    Text("셸·파일 명령").tag("shell")
                    Text("MCP").tag("mcp")
                    Text("플러그인 MCP").tag("plugin")
                    Text("플러그인 관리").tag("library")
                    Text("Git").tag("git")
                }.pickerStyle(.segmented).disabled(connection.busy)
                if mode == "shell" {
                    Text("실행할 프로그램과 인자를 JSON 배열로 입력하세요.").font(.callout)
                    TextEditor(text: $command).font(.body.monospaced()).frame(height: 80)
                    Button("실행 내용 검토") { prepare(.command) }
                        .disabled(connection.busy || locked)
                } else if mode == "library" {
                    TextField("플러그인@마켓 이름 또는 마켓 경로·HTTPS URL", text: $libraryValue)
                    HStack {
                        Button("목록 조회") { prepare(.pluginList) }
                        Button("설치 검토") { prepare(.pluginAdd) }
                        Button("제거 검토") { prepare(.pluginRemove) }
                        Button("마켓 추가 검토") { prepare(.pluginMarketplace) }
                    }.disabled(connection.busy || locked)
                    HStack {
                        Button("플러그인 전용 로그인") { prepare(.pluginLogin) }
                        Button("로그인 상태 확인") { prepare(.pluginLoginPoll) }
                    }.disabled(connection.busy || locked)
                    Text("설치·제거는 별도 플러그인 보관소에서 Codex CLI로 처리합니다. 설치한 MCP 구성은 플러그인 MCP 탭에서 선택하고, 스킬은 SKILL.md를 채팅에 첨부해 사용합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if mode == "git" {
                    Button("변경 파일 조회") { prepare(.gitStatus) }.disabled(connection.busy || locked)
                    if !gitFiles.isEmpty {
                        Picker("변경 파일", selection: $gitPath) {
                            ForEach(gitFiles, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("프로젝트 상대 파일 경로", text: $gitPath)
                    Button("파일별 변경 비교") { prepare(.gitDiff) }.disabled(connection.busy || locked || gitPath.isEmpty)
                    Text("스테이징된 변경과 작업 파일 변경을 구분해 표시합니다. JARVIS가 적용한 파일은 채팅의 변경 기록·복구에서 되돌릴 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if mode == "plugin" {
                        Button("플러그인의 .mcp.json 선택…", action: choosePlugin)
                            .disabled(connection.busy || locked)
                        if !servers.isEmpty {
                            Picker("서버", selection: $selectedServer) {
                                ForEach(servers.keys.sorted(), id: \.self) { Text($0).tag($0) }
                            }.onChange(of: selectedServer) { _, name in
                                if let server = servers[name] {
                                    program = server.command
                                    serverArguments = String(decoding: (try? JSONEncoder().encode(server.args)) ?? Data(), as: UTF8.self)
                                    useHTTP = server.url != nil; httpURL = server.url ?? ""
                                }
                            }
                        }
                    }
                    Toggle("HTTP MCP", isOn: $useHTTP).disabled(connection.busy)
                    if useHTTP {
                        TextField("HTTPS MCP 주소", text: $httpURL)
                        HStack {
                            Button("OAuth 로그인") { prepare(.mcpLogin) }
                            Button("로그인 상태 확인") { prepare(.mcpLoginPoll) }
                        }.disabled(connection.busy || locked)
                    } else {
                        TextField("MCP 실행 프로그램", text: $program)
                        TextField("프로그램 인자 JSON 배열", text: $serverArguments).font(.body.monospaced())
                    }
                    HStack {
                        TextField("저장할 연결 이름", text: $connectionName)
                        Button("연결 저장") { confirmSave = true }.disabled(locked || connection.busy || connectionName.isEmpty)
                        Menu("저장된 연결") {
                            ForEach(savedConnections.keys.sorted(), id: \.self) { name in
                                Button(name) {
                                    if let server = savedConnections[name] {
                                        connectionName = name; program = server.command; useHTTP = server.url != nil
                                        httpURL = server.url ?? ""
                                        serverArguments = String(decoding: (try? JSONEncoder().encode(server.args)) ?? Data(), as: UTF8.self)
                                    }
                                }
                            }
                        }
                        Button("저장 삭제") { removeConnection() }.disabled(locked || connection.busy || savedConnections[connectionName] == nil)
                    }
                    Button("도구 목록 조회 내용 검토") { prepare(.mcpList) }
                        .disabled(connection.busy || locked)
                    Divider()
                    TextField("호출할 도구 이름", text: $tool)
                    TextEditor(text: $arguments).font(.body.monospaced()).frame(height: 70)
                    Button("도구 호출 내용 검토") { prepare(.mcpCall) }
                        .disabled(connection.busy || locked)
                    Text("stdio와 HTTP MCP를 지원합니다. URL에 인증 정보를 넣지 마세요. 인증은 Codex의 OAuth 저장소에서 관리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let authURL {
                    Text(authURL.absoluteString).font(.caption).textSelection(.enabled).lineLimit(3)
                    Button("브라우저에서 로그인") {
                        guard !locked, approved(.nativeTool) else { return }
                        _ = NSWorkspace.shared.open(authURL)
                    }
                }
                if connection.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("도구 실행 중")
                        Spacer()
                        Button("중지") { connection.stop() }
                    }
                }
                ScrollView {
                    Text(connection.busy ? connection.partialReply : output).textSelection(.enabled).font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120)
            }
        }
        .padding(24).frame(width: 760, height: 760)
        .interactiveDismissDisabled(connection.busy)
        .onChange(of: locked) { _, value in
            if value { pending = nil; connection.stop() }
        }
        .alert("이 MCP 연결 설정을 저장할까요?", isPresented: $confirmSave) {
            Button("취소", role: .cancel) {}
            Button("이 설정 저장") { saveConnection() }
        } message: { Text("연결 이름과 프로그램·인자 또는 HTTP 주소를 현재 저장소에 저장합니다. OAuth 인증 정보는 Codex가 관리합니다.\n" + program + "\n" + serverArguments + "\n" + httpURL) }
    }
    private var savedConnections: [String: CodexNativeToolRequest.Server] {
        var connections = (try? JSONDecoder().decode([String: CodexNativeToolRequest.Server].self, from: savedData)) ?? [:]
        if let profile = try? CodexAgentProfile.read(JarvisStorage.preferences.data(forKey: "jarvis.codex.agentProfile") ?? Data()) {
            for item in profile.extensions { if connections[item.name] == nil { connections[item.name] = item.server } }
        }
        return connections
    }
    private func approved(_ action: CodexLocalAction) -> Bool {
        if case .allow = SafetyPolicyEngine().evaluate(.codexLocal(action), context: .init(
            externalActionsLocked: locked, wasExplicitlyConfirmed: true)) { return true }
        return false
    }
    private func currentServer() throws -> CodexNativeToolRequest.Server {
        if useHTTP { return .init(url: httpURL) }
        return .init(command: program, args: try JSONDecoder().decode([String].self, from: Data(serverArguments.utf8)))
    }
    private func saveConnection() {
        guard approved(.nativeTool), connectionName.utf8.count <= 80 else { return }
        do {
            let server = try currentServer()
            try CodexNativeToolRequest(operation: .mcpList, root: root.path, server: server).validate()
            guard !CodexCodePolicy.containsSecret(program + serverArguments + httpURL) else { throw CodexLocalError.invalid }
            var records = savedConnections
            guard records.count < 20 || records[connectionName] != nil else { throw CodexLocalError.invalid }
            records[connectionName] = server
            savedData = try JSONEncoder().encode(records); output = "연결 설정을 저장했습니다."
        } catch { output = "연결 이름·프로그램 인자·URL 또는 민감정보를 확인하세요." }
    }
    private func removeConnection() {
        guard approved(.workspaceEdit) else { return }
        var records = savedConnections; records.removeValue(forKey: connectionName)
        savedData = (try? JSONEncoder().encode(records)) ?? Data()
        output = "저장한 연결 설정을 삭제했습니다. Codex의 OAuth 인증은 별도로 관리됩니다."
    }
    private func prepare(_ operation: CodexNativeToolRequest.Operation) {
        do {
            let request: CodexNativeToolRequest
            if operation == .command {
                let argv = try JSONDecoder().decode([String].self, from: Data(command.utf8))
                request = .init(operation: operation, root: root.path, command: argv)
            } else if operation.rawValue.hasPrefix("plugin") || operation == .gitStatus || operation == .gitDiff {
                let values = [.pluginList, .pluginLogin, .pluginLoginPoll, .gitStatus].contains(operation)
                    ? [] : [operation == .gitDiff ? gitPath : libraryValue]
                request = .init(operation: operation, root: root.path, command: values)
            } else {
                request = .init(operation: operation, root: root.path,
                                server: try currentServer(),
                                tool: operation == .mcpCall ? tool : nil,
                                arguments: operation == .mcpCall ? arguments : nil)
            }
            _ = try request.encodedInput()
            pending = request
        } catch { output = "입력 형식을 확인하세요. 프로그램 인자는 JSON 배열, 도구 인자는 JSON 객체여야 합니다." }
    }
    private func execute(_ request: CodexNativeToolRequest) {
        guard !locked, !connection.busy, pending != nil else { return }
        pending = nil
        output = ""; authURL = nil
        connection.runNative(request, confirmed: true) { result in
            switch result {
            case .succeeded(let value):
                output = "도구 실행 완료\n" + (value.reply ?? "")
                if let text = value.reply, let data = text.data(using: .utf8),
                   let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if let url = result["authURL"] as? String, let parsed = URLComponents(string: url),
                       parsed.scheme == "https", parsed.host != nil, parsed.user == nil, parsed.password == nil,
                       [.mcpLogin, .pluginLogin].contains(request.operation) { authURL = parsed.url }
                    if request.operation == .gitStatus, let rows = result["files"] as? [[String: String]] {
                        gitFiles = rows.compactMap { $0["path"] }; gitPath = gitFiles.first ?? ""
                    }
                }
            case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message):
                output = message
            case .handedOff: output = "요청을 전달했으며 완료 여부는 확인할 수 없습니다."
            }
        }
    }
    private func choosePlugin() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.json]
        picker.showsHiddenFiles = true
        picker.allowsMultipleSelection = false
        picker.message = "신뢰하는 플러그인의 .mcp.json을 선택하세요. 선택 후 서버와 실행 내용을 검토합니다."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 65536 else { throw CodexLocalError.invalid }
            guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; servers = try CodexNativeToolRequest.pluginServers(Data(contentsOf: url))
            selectedServer = servers.keys.sorted().first ?? ""
            if let server = servers[selectedServer] {
                program = server.command
                serverArguments = String(decoding: try JSONEncoder().encode(server.args), as: UTF8.self)
                useHTTP = server.url != nil; httpURL = server.url ?? ""
            }
            output = "서버를 선택한 뒤 프로그램과 인자를 확인하세요."
        } catch { output = "이 파일은 지원되지 않습니다. command와 args로 구성된 stdio mcpServers 형식이 필요합니다. 환경 변수·인증 정보가 포함된 구성은 별도 설정이 필요합니다." }
    }
}

struct CodexMessageText: NSViewRepresentable {
    let text: String
    var secondary = false
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.string != text {
            let selection = view.selectedRange()
            let preservesSelection = selection.length > 0 && text.hasPrefix(view.string)
            view.string = text
            if preservesSelection { view.setSelectedRange(selection) }
        }
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let maximumWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 820
        guard maximumWidth > 0 else { return .zero }
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maximumWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: view.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        return CGSize(width: min(maximumWidth, ceil(bounds.width) + 1), height: ceil(bounds.height) + 2)
    }
}

struct CodexModelSelectionPanel: View {
    let models: [CodexLocalModel]
    let selected: String
    let busy: Bool
    let canRefresh: Bool
    let choose: (CodexLocalModel) -> Void
    let refresh: () -> Void
    let manual: () -> Void
    var usesServerCatalog = false
    @State private var hovered: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("모델 선택").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(usesServerCatalog ? "App Server 모델" : "기본").fontWeight(.semibold)
                Text(usesServerCatalog ? "연결에서 조회한 모델 목록" : "추천 및 최근 모델").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(models) { model in
                        Button { choose(model) } label: {
                            HStack {
                                Text(model.name).lineLimit(1)
                                Spacer()
                                if selected == model.id { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }.padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
                                .background(hovered == model.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).onHover { hovered = $0 ? model.id : nil }
                    }
                }
            }.frame(height: min(360, CGFloat(models.count) * 40))
            Divider()
            HStack {
                Button("새로 고침", systemImage: "arrow.clockwise", action: refresh).disabled(!canRefresh || busy)
                Spacer()
                Button("직접 입력…", action: manual)
            }.font(.caption).buttonStyle(.plain)
            Text("계정의 모델 사용 가능 여부는 연결 후 확인됩니다.").font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.1)))
            .disabled(busy)
    }
}

struct CodexThreadSidebarRow: View {
    let title: String
    let selected: Bool
    let deletionDisabled: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left").font(.caption)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("대화 삭제").accessibilityLabel("\(title) 대화 삭제")
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
                .disabled(deletionDisabled)
        }.padding(.vertical, 6).padding(.horizontal, 8)
            .background(selected || hovered ? Color.primary.opacity(selected ? 0.09 : 0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
    }
}

struct CodexWorkspaceView: View {
    @StateObject private var connection = CodexLocalStore()
    @StateObject private var workspace: CodexChatWorkspaceStore
    @State private var input = ""
    @StateObject private var agent = CodexAgentWorkspaceStore()
    @State private var useAgent = true
    @State private var chatImages: [Data] = []
    @State private var chatDocuments: [CodexChatDocument] = []
    @State private var imageMessage = ""
    @State private var chatSearch = ""
    @State private var importPreview: CodexChatImport?
    @State private var importSelection: Set<UUID> = []
    @State private var importWork: Task<Void, Never>?
    @State private var importPickerID: UUID?
    @State private var importMessage = ""

    @State private var steerStatus = ""
    @State private var showFiles = false
    @State private var diagnosticPreview: String?
    @State private var diagnosticKey: String?
    @State private var exportPreview: CodexExportPreview?
    @State private var showNativeTools = false
    @State private var showAgentHistory = false
    @State private var showAgentExtensions = false
    @State private var showConnection = false
    @StateObject private var code = CodexCodeWorkspaceStore(projectID: UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!)
    @State private var pickingCode = false
    @State private var showQuota = false
    @State private var candidateCode: URL?
    @State private var folderSelection: CodexProjectFolderSelection?
    @State private var confirmCode = false
    @State private var showProject = false
    @State private var showModel = false
    @State private var showModelList = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleteID: UUID?
    @State private var deleteName = ""
    @State private var showDelete = false
    @State private var preserveInputOnNextSelection = false
    @State private var expanded: Set<UUID> = []
    @AppStorage("jarvis.safety.externalActionsLocked") private var locked = false
    @Environment(\.scenePhase) private var scenePhase

    init(preview: CodexChatWorkspace? = nil, codeStore: CodexCodeWorkspaceStore? = nil) {
        _workspace = StateObject(wrappedValue: CodexChatWorkspaceStore(preview: preview))
        _code = StateObject(wrappedValue: codeStore ?? CodexCodeWorkspaceStore(projectID: UUID(uuidString: "C0DEC0DE-0000-4000-8000-000000000001")!))
        _expanded = State(initialValue: Set(preview?.projects.map(\.id) ?? []))
    }

    var body: some View {
        let pickingSelection = folderSelection
        HStack(spacing: 0) {
            sidebar.frame(width: 248)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                conversation
                composer
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showAgentHistory) {
            if let root = code.root {
                CodexAgentHistoryPanel(root: root, connection: connection,
                    names: Dictionary(uniqueKeysWithValues: workspace.data.projects.flatMap(\.threads).map { ($0.id, $0.title) }),
                    changed: { id, operation in if operation == "delete" || operation == "forget" { workspace.clearAgentSession(id) } })
            }
        }
        .sheet(isPresented: $showAgentExtensions) { CodexAgentExtensionsPanel() }
        .sheet(isPresented: $showNativeTools) {
            if let root = code.root {
                CodexNativeToolsPanel(root: root, connection: connection)
                    .id(root.path)
            }
        }
        .sheet(item: $exportPreview) { preview in
            VStack(alignment: .leading, spacing: 12) {
                Text("답변 파일 미리보기 · " + preview.format.uppercased()).font(.headline)
                if preview.format == "pdf" { CodexPDFPreview(data: preview.data) }
                else { ScrollView { Text(preview.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                HStack {
                    Button("닫기") { exportPreview = nil }
                    Spacer()
                    Button("저장 위치 선택…") { saveExport(preview) }.disabled(locked)
                }
            }.padding(20).frame(width: 700, height: 650)
        }
        .sheet(item: $importPreview) { preview in
            VStack(alignment: .leading, spacing: 14) {
                Text("ChatGPT 대화 가져오기").font(.title2.bold())
                Text("선택한 대화의 텍스트를 현재 저장소에 저장합니다.")
                if preview.omittedCount > 0 {
                    Text("형식 또는 크기 제한으로 대화 \(preview.omittedCount)개가 목록에서 제외됐습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                List {
                    ForEach(preview.threads) { thread in
                        Toggle(isOn: Binding(get: { importSelection.contains(thread.id) }, set: { checked in
                            if checked { importSelection.insert(thread.id) } else { importSelection.remove(thread.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(thread.title).lineLimit(2)
                                Text("메시지 \(thread.messages.count)개").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !workspace.message.isEmpty { Text(workspace.message).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("모두 선택") { importSelection = Set(preview.threads.map(\.id)) }
                    Button("선택 해제") { importSelection = [] }
                    Spacer()
                    Button("취소", role: .cancel) { importPreview = nil; importSelection = [] }
                    Button("선택한 대화 가져오기") {
                        guard !locked, !connection.busy, !code.busy,
                              workspace.importChatGPT(preview, selected: importSelection, confirmed: true) else { return }
                        chatSearch = ""; importPreview = nil; importSelection = []
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importSelection.isEmpty || locked || connection.busy || code.busy)
                }
            }.padding(20).frame(width: 580, height: 450)
        }
        .sheet(isPresented: $showConnection) {
            VStack(spacing: 12) {
                HStack { Text("Codex 로컬 연결").font(.title2.bold()); Spacer(); Button("닫기") { showConnection = false } }
                ScrollView { CodexLocalPanel(store: connection) }
            }.padding(22).frame(width: 720, height: 650)
        }
        .fileImporter(isPresented: $pickingCode, allowedContentTypes: [.folder]) { result in
            guard let pickingSelection, folderSelection == pickingSelection,
                  workspace.acceptsFolderSelection(pickingSelection), !locked else { return }
            if case .success(let url) = result { candidateCode = url; confirmCode = true }
            else { folderSelection = nil; candidateCode = nil }
        }
        .alert("프로젝트 폴더를 연결할까요?", isPresented: $confirmCode) {
            Button("취소", role: .cancel) { candidateCode = nil; folderSelection = nil }
            Button("선택 폴더 연결") {
                guard let selection = folderSelection, workspace.acceptsFolderSelection(selection), !locked,
                      !connection.busy, !code.busy, let url = candidateCode else { return }
                code.connect(url, confirmed: true); candidateCode = nil; folderSelection = nil
            }.disabled(connection.busy || code.busy || locked)
        } message: { Text("프로젝트: \(workspace.data.projects.first(where: { $0.id == folderSelection?.projectID })?.name ?? "")\n\(candidateCode?.path ?? "")\n프로젝트 작업 모드에서는 선택한 폴더 경로와 요청을, 변경안 검토 모드에서는 요청과 상대 파일 목록을 \(connection.backend.provider)에 제공합니다. 소스 내용은 별도로 승인한 범위만 전송하며 변경은 파일별 확인 후 적용합니다.") }
        .sheet(isPresented: $showProject) {
            CodexNameEditor(title: "새 프로젝트", hint: "프로젝트 이름", text: "") {
                workspace.createProject($0)
                if let id = workspace.projectID { expanded.insert(id) }
            }
        }
        .sheet(isPresented: $showRename) {
            CodexNameEditor(title: "이름 변경", hint: "이름", text: renameText) { if let id = renameID { workspace.rename(id, name: $0) } }
        }
        .sheet(isPresented: $showModel) {
            CodexNameEditor(title: "Codex 모델 ID", hint: "계정에서 사용할 수 있는 모델 ID", text: workspace.selectedModel) { workspace.model($0) }
        }
        .alert("삭제하시겠습니까?", isPresented: $showDelete) {
            Button("취소", role: .cancel) { deleteID = nil }
            Button("삭제", role: .destructive) {
                guard !connection.busy, !code.busy, !locked, let id = deleteID else { return }
                if id == workspace.threadID || id == workspace.projectID { code.resetConversation(); code.record = nil }
                workspace.delete(id, confirmed: true); deleteID = nil
            }.disabled(connection.busy || code.busy || locked)
        } message: { Text("\(deleteName)\nJARVIS 대화 목록의 로컬 기록을 삭제합니다. 되돌릴 수 없습니다. Codex 전용 프로필의 세션 기록·OpenAI 측 기록과 연결한 실제 폴더·소스 파일은 삭제하지 않습니다.") }
        .onChange(of: workspace.threadID) { _, _ in
            steerStatus = ""; showFiles = false; chatImages = []; chatDocuments = []; imageMessage = ""
            agent.stop(); agent.record = nil
            code.resetConversation(preservingRecovery: true); code.record = nil
            if preserveInputOnNextSelection { preserveInputOnNextSelection = false }
            else { input = "" }
        }
        .onChange(of: workspace.projectID) { _, id in
            agent.stop(); agent.record = nil
            code.disconnect(preservingRecovery: true)
            if folderSelection?.projectID != id { folderSelection = nil; candidateCode = nil; confirmCode = false; pickingCode = false }
            if let id { expanded.insert(id) }
        }
        .onChange(of: agent.running) { _, value in if !value && !connection.busy && code.root != nil { code.refresh() } }
        .onChange(of: connection.sessionID) { _, _ in agent.stop() }
        .onChange(of: workspace.selectedModel) { _, _ in if agent.running { agent.stop() } }
        .onChange(of: workspace.selectedEffort) { _, _ in if agent.running { agent.stop() } }
        .onChange(of: connection.models) { _, models in
            if workspace.selectedModel.isEmpty, let model = models.first {
                workspace.model(model.id, effort: model.defaultReasoningEffort ?? model.reasoningEfforts?.first ?? "low")
            } else if let model = models.first(where: { $0.id == workspace.selectedModel }),
                      let levels = model.reasoningEfforts, !levels.contains(workspace.selectedEffort),
                      let effort = model.defaultReasoningEffort ?? levels.first {
                workspace.model(model.id, effort: effort)
            }
        }
        .onChange(of: connection.sessionID) { _, _ in code.resetConversation() }
        .onChange(of: connection.backend) { _, _ in agent.stop(); chatImages = []; chatDocuments = []; imageMessage = ""; code.resetConversation() }
        .onChange(of: workspace.selectedModel) { _, _ in code.stop() }
        .onChange(of: workspace.selectedEffort) { _, _ in code.stop() }
        .onAppear {
            if let id = workspace.projectID { expanded.insert(id) }
            if workspace.selectedModel.isEmpty, let model = connection.models.first { workspace.model(model.id) }
        }
        .onChange(of: locked) { _, value in
            showModelList = false
            if value { agent.stop(); clearChatImport(); exportPreview = nil; diagnosticKey = nil; diagnosticPreview = nil; showFiles = false; steerStatus = ""; chatImages = []; chatDocuments = []; imageMessage = ""; code.disconnect(); candidateCode = nil; folderSelection = nil; pickingCode = false; confirmCode = false; deleteID = nil; showDelete = false; connection.stopService() } else { workspace.load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { connection.becameActive() }
            else if connection.busy && !connection.loginPending { code.stop(); connection.stop() }
        }
        .onDisappear { agent.stop(); clearChatImport(); code.disconnect(preservingRecovery: true); connection.disconnect() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("JARVIS").font(.headline)
                Spacer()
            }.buttonStyle(.plain)
            Button {
                if connection.busy { connection.stop() }
                input = ""; workspace.createGeneralThread()
            } label: { Label("새 대화", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)).disabled(!workspace.loaded)
            Button("ChatGPT 대화 가져오기…", systemImage: "square.and.arrow.down", action: chooseChatImport)
                .font(.callout).buttonStyle(.plain).disabled(connection.busy || code.busy || importWork != nil || !workspace.loaded)
            if !importMessage.isEmpty { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("대화 검색", text: $chatSearch).textFieldStyle(.plain)
                if !chatSearch.isEmpty {
                    Button { chatSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("검색 지우기")
                }
            }
            .font(.callout)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("프로젝트").font(.caption).foregroundStyle(.secondary); Spacer(); Button { showProject = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).disabled(connection.busy || !workspace.loaded) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else {
                        ForEach(workspace.data.projects) { project in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(project.id) }, set: { if $0 { expanded.insert(project.id) } else { expanded.remove(project.id) } })) {
                                ForEach(project.threads) { thread in
                                    sidebarThread(thread, projectID: project.id)
                                }
                                Button("새 대화", systemImage: "plus") {
                                    workspace.projectID = project.id; workspace.createThread(model: connection.models.first?.id ?? "")
                                }.font(.caption).buttonStyle(.plain).padding(8).disabled(connection.busy)
                            } label: {
                                HStack(spacing: 6) {
                                    Button {
                                        if connection.busy { connection.stop() }
                                        workspace.projectID = project.id; workspace.threadID = project.threads.first?.id; expanded.insert(project.id)
                                    } label: { Label(project.name, systemImage: "folder").font(.subheadline.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                                        .buttonStyle(.plain).contextMenu {
                                            Button("접근 폴더 선택…") { chooseProjectFolder(project.id) }.disabled(connection.busy || code.busy)
                                            management(id: project.id, name: project.name)
                                        }
                                    Button { chooseProjectFolder(project.id) } label: { Image(systemName: "folder.badge.gearshape").frame(width: 22, height: 22) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .help("\(project.name) 프로젝트의 접근 폴더 선택")
                                        .accessibilityLabel("\(project.name) 접근 폴더 선택")
                                        .disabled(connection.busy || code.busy || pickingCode || confirmCode)
                                }
                            }
                            if workspace.projectID == project.id, let root = code.root {
                                Label(root.lastPathComponent, systemImage: "checkmark.shield").font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).padding(.leading, 24).help("이 프로젝트에 연결된 접근 폴더: \(root.path)")
                            }
                        }
                        if workspace.data.projects.isEmpty { Text("바로 메시지를 보내면\n일반 대화에 저장됩니다.").font(.callout).foregroundStyle(.secondary).padding(.top, 12) }
                    }
                }
            }
            Spacer(minLength: 0)
            Text((JarvisStorage.portable ? "USB에 대화 저장" : "이 Mac에 대화 저장") + "\n코드 변경은 폴더 연결·개별 승인 후 적용합니다.").font(.caption).foregroundStyle(.secondary)
            Button("대화 목록 새로 고침", systemImage: "arrow.clockwise") { workspace.reload() }.font(.caption).buttonStyle(.plain).disabled(connection.busy)
            Button { code.stop(); showConnection = true } label: {
                Label(connection.ready ? "\(connection.backend.title) 연결됨" : "Codex 연결 설정", systemImage: connection.ready ? "checkmark.circle" : "link")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }.padding(18).background(Color(nsColor: .windowBackgroundColor))
            .disabled(locked)
    }
    private var searchResults: some View {
        let query = String(chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).prefix(150))
        let matches = workspace.data.projects.compactMap { project -> (CodexChatProject, [CodexChatThread])? in
            let threads = project.threads.filter { thread in
                thread.title.localizedCaseInsensitiveContains(query)
                    || thread.messages.contains { $0.role != .notice && $0.text.localizedCaseInsensitiveContains(query) }
            }
            return threads.isEmpty ? nil : (project, threads)
        }
        return VStack(alignment: .leading, spacing: 8) {
            if matches.isEmpty {
                Text("검색 결과가 없습니다.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(matches, id: \.0.id) { match in
                Text(match.0.name).font(.caption).foregroundStyle(.secondary)
                ForEach(match.1) { thread in
                    sidebarThread(thread, projectID: match.0.id)
                }
            }
        }
    }

    private func sidebarThread(_ thread: CodexChatThread, projectID: UUID) -> some View {
        CodexThreadSidebarRow(title: thread.title, selected: workspace.threadID == thread.id,
                             deletionDisabled: connection.busy || code.busy || locked, open: {
            if connection.busy { connection.stop() }
            workspace.projectID = projectID
            workspace.threadID = thread.id
        }, remove: { requestDelete(id: thread.id, name: thread.title) })
        .contextMenu { management(id: thread.id, name: thread.title) }
    }

    private func management(id: UUID, name: String) -> some View {
        Group {
            Button("이름 변경") { renameID = id; renameText = name; showRename = true }.disabled(connection.busy || locked)
            Button("삭제", role: .destructive) { requestDelete(id: id, name: name) }.disabled(connection.busy || code.busy || locked)
        }
    }
    private func requestDelete(id: UUID, name: String) {
        guard !connection.busy, !code.busy, !locked else { return }
        deleteID = id; deleteName = name; showDelete = true
    }
    private func chooseProjectFolder(_ id: UUID) {
        guard !connection.busy, !code.busy, !locked, !pickingCode, !confirmCode,
              let selection = workspace.prepareFolderSelection(projectID: id, model: workspace.selectedModel) else { return }
        folderSelection = selection; candidateCode = nil; expanded.insert(id); pickingCode = true
    }
    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.thread?.title ?? "Codex").font(.headline).lineLimit(1)
                Text(code.root == nil ? "\(connection.backend.title) · 텍스트 대화" : useAgent && code.attachments.isEmpty ? "Codex 프로젝트 작업 · 승인 기반 호스트 도구" : "변경안 검토 · 소스 전송·파일 반영은 개별 승인").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { code.stop(); showConnection = true } label: { Image(systemName: "slider.horizontal.3") }.help("연결 설정").buttonStyle(.plain).disabled(code.busy)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let thread = workspace.thread, !thread.messages.isEmpty {
                        ForEach(thread.messages) { item in
                            messageRow(item).id(item.id)
                        }
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text(workspace.thread == nil ? "어떤 작업을 함께 할까요?" : "새로운 대화를 시작하세요").font(.title2.weight(.semibold))
                            Text("아래에 메시지를 입력해 대화를 시작하세요.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 100)
                    }
                    if agent.running || agent.snapshot != nil { CodexAgentPanel(store: agent, manageConnections: { showNativeTools = true }) }
                    if code.root != nil, !agent.running { codeConversation }
                    if (code.root == nil || !code.taskActive) && (connection.activeGeneration != nil || code.busy) {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Codex 작업 중").font(.callout.weight(.semibold))
                        }.accessibilityElement(children: .combine)
                        if !connection.partialReply.isEmpty && !code.busy {
                            CodexMessageText(text: connection.partialReply)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.frame(maxWidth: 820, alignment: .leading).padding(28).frame(maxWidth: .infinity)
            }
            .onChange(of: workspace.thread?.messages.count) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: connection.partialReply.isEmpty) { _, empty in
                if !empty { reader.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: agent.pending?.approvalID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: agent.snapshot?.reply) { _, _ in if agent.running { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: connection.activeGeneration) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: workspace.threadID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func messageRow(_ item: CodexChatMessage) -> some View {
        HStack(alignment: .top) {
            if item.role == .user { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(item.role == .user ? "나" : item.role == .assistant ? (item.imported == true ? "ChatGPT" : "Codex") : "요청 상태")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if item.state == .pending { Text("응답 대기").font(.caption).foregroundStyle(.secondary) }
                    if item.state == .interrupted { Text("중단·미완료").font(.caption).foregroundStyle(.orange) }
                    if item.imported == true {
                        Text("가져온 기록").font(.caption2).foregroundStyle(.tertiary)
                    } else if item.role == .assistant {
                        Text(item.model + " · " + (CodexLocalBackend(rawValue: item.backend ?? "cli")?.title ?? "CLI")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if item.role == .assistant && item.state == .completed {
                        Menu {
                            Button("Markdown으로 저장") { exportResponse(item, format: "md") }
                            Button("TXT로 저장") { exportResponse(item, format: "txt") }
                            Button("PDF로 저장") { exportResponse(item, format: "pdf") }
                        } label: { Image(systemName: "square.and.arrow.up") }
                            .menuStyle(.borderlessButton).fixedSize().help("이 답변을 파일로 저장")
                            .disabled(locked)
                        Button {
                            if workspace.branchConversation(after: item.id) { chatSearch = "" }
                        } label: {
                            Label("여기서 새 대화로 분기", systemImage: "arrow.triangle.branch")
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("여기서 새 대화로 분기")
                        .disabled(locked || connection.busy || code.busy || connection.steering)
                    }
                }
                if item.imageAttached == true {
                    Label("이미지 첨부", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                }
                if let names = item.attachmentNames {
                    Text("첨부 · " + names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                // Plain text deliberately cannot open model-generated links or execute content.
                CodexMessageText(text: item.text, secondary: item.role == .notice)
            }.padding(item.role == .user ? 16 : 0)
                .background(item.role == .user ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 16))
            if item.role != .user { Spacer(minLength: 20) }
        }
    }
    private var codeConversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let saved = code.recovery, !code.taskActive {
                GroupBox("중단된 작업") {
                    VStack(alignment: .leading) {
                        Text(saved.instruction).lineLimit(3).textSelection(.enabled)
                        Text("원본을 다시 읽고 필요한 허가를 새로 받습니다. 이전 명령은 자동 재실행하지 않습니다.").font(.caption)
                        HStack {
                            Button("이 프로젝트에서 다시 검토·시작") { code.resumeRecovery(connection: connection) }
                                .disabled(code.root?.path != saved.root || !connection.ready || connection.busy || locked)
                            Button("복구 기록 지우기") { code.discardRecovery() }
                        }
                    }
                }
            }
            if code.taskActive || !code.activities.isEmpty {
                HStack {
                    if code.busy { ProgressView().controlSize(.small) }
                    Text(code.phase).font(.callout.weight(.semibold))
                    Spacer()
                    if code.taskActive { Button("이 작업 취소") { code.stop(); connection.stop() } }
                }
                DisclosureGroup("작업 과정") {
                    ForEach(Array(code.activities.enumerated()), id: \.offset) { _, activity in
                        Text(activity).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if !code.liveOutput.isEmpty {
                DisclosureGroup("터미널 출력", isExpanded: .constant(true)) {
                    ScrollViewReader { reader in
                        ScrollView {
                            CodexMessageText(text: code.liveOutput)
                            Color.clear.frame(height: 1).id("terminal-bottom")
                        }
                        .onChange(of: code.liveOutput) { _, _ in reader.scrollTo("terminal-bottom", anchor: .bottom) }
                    }.frame(maxHeight: 260)
                }
            }
            ForEach(CodexBuildLocation.parse(code.liveOutput, paths: code.paths, root: code.root?.path ?? ""), id: \.self) { location in
                Button("소스 확인 · \(location.path):\(location.line)") {
                    diagnosticPreview = code.previewDiagnostic(location)
                    diagnosticKey = diagnosticPreview == nil ? nil : location.path + ":" + String(location.line)
                }
                    .popover(isPresented: Binding(get: { diagnosticKey == location.path + ":" + String(location.line) }, set: { if !$0 { diagnosticPreview = nil; diagnosticKey = nil } })) {
                        ScrollView { Text(diagnosticPreview ?? "").font(.body.monospaced()).textSelection(.enabled).padding() }.frame(width: 680, height: 400)
                    }
            }
            if code.message != code.phase && workspace.thread?.messages.last?.text != code.message {
                Text(code.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !code.pendingReads.isEmpty {
                let approvalID = code.permissionID
                GroupBox("코드 읽기·OpenAI 전송 허가 요청") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("다음 범위만 전송합니다. 키·개인정보가 포함될 수 있다면 거절하고 파일에서 제거한 뒤 다시 요청하세요.")
                        ForEach(Array(code.readIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        ForEach(Array(code.pendingReads.enumerated()), id: \.offset) { _, read in
                            Text("\(read.path) · \(read.startLine)줄부터 최대 \(read.lineCount)줄").font(.caption.monospaced())
                        }
                        ForEach(code.pendingFiles, id: \.path) { file in
                            DisclosureGroup("전송할 코드 미리보기 · \(file.path)") {
                                Text(file.text).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        HStack {
                            Button("한 번만 허용") { code.approveReads(approvalID) }.disabled(connection.steering || connection.busy || locked)
                            Button("이번 작업에서 허용") { code.approveReads(approvalID, forTask: true) }.disabled(connection.steering || connection.busy || locked)
                            Button("허용 안 함", role: .cancel) { code.rejectReads() }
                        }
                        Text("작업 허용은 표시된 파일·줄 범위의 반복 조회에만 적용됩니다. 새 파일, 파일 변경과 명령 실행은 별도 승인합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let command = code.pendingCommand {
                let approvalID = code.permissionID
                GroupBox("검증 실행 허가 요청") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(command.purpose)
                        Text(String(decoding: (try? JSONEncoder().encode(command.argv)) ?? Data(), as: UTF8.self))
                            .font(.body.monospaced()).textSelection(.enabled)
                        Text("소스 프로젝트는 읽기 전용입니다. 임시 빌드·테스트 출력만 허용하며 네트워크는 차단합니다. 최대 60초 실행 후 결과를 확인합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("검증 프로그램이 읽은 Mac의 정보가 출력에 포함될 수 있습니다. 실행 후 전송할 출력을 따로 검토합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("한 번만 허용") { code.approveCommand(approvalID) }.disabled(connection.busy || locked)
                            Button("허용 안 함") { code.rejectReads() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if code.awaitingResult {
                let approvalID = code.permissionID
                GroupBox("검증 결과를 Codex에 전달할까요?") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("개인정보·인증 정보를 제거하고 전달할 출력을 3,500바이트 이내로 편집할 수 있습니다. 실제 실행 성공·실패 표시는 그대로 전달됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $code.resultDraft).font(.caption.monospaced()).frame(height: 150)
                        HStack {
                            Button("이 결과 전송·계속") { code.approveResult(approvalID) }.disabled(connection.busy || locked)
                            Button("허용 안 함") { code.rejectReads() }
                        }
                    }
                }
            }
            ForEach(code.plans) { plan in
                GroupBox(plan.path) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((code.proposal?.edits.filter { $0.path == plan.path } ?? []).enumerated()), id: \.offset) { _, edit in
                            Text(edit.old == nil ? "새 파일" : "변경 전").font(.caption.bold())
                            if let old = edit.old { Text(old).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.red) }
                            Text("변경 후").font(.caption.bold())
                            Text(edit.new).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        HStack {
                            Button("한 번만 허용 · 적용 후 계속") { code.apply(plan, confirmed: true) }.disabled(code.busy || connection.busy || locked)
                            Button("허용 안 함") { code.stop() }
                        }
                        Text("원본 백업 후 저장을 확인하고, 승인한 파일의 갱신 내용과 저장 결과를 Codex에 전달해 다음 단계를 진행합니다. 검증 명령은 따로 승인합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !code.backups.isEmpty {
                DisclosureGroup("변경 기록·복구") {
                    ForEach(code.backups) { backup in
                        DisclosureGroup("\(backup.path) · \(backup.created.formatted())") {
                            Text("복구 전").font(.caption.bold())
                            Text(backup.after).font(.caption.monospaced()).textSelection(.enabled)
                            Text("복구 후").font(.caption.bold())
                            Text(backup.before ?? "새로 만든 파일 삭제").font(.caption.monospaced()).textSelection(.enabled)
                            Button("이 백업 복구 승인") { code.restore(backup, confirmed: true) }.disabled(code.busy || locked)
                        }
                    }
                }
            }
        }.disabled(locked)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !workspace.message.isEmpty { Text(workspace.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if locked { Text("안전 잠금이 켜져 있습니다. 설정에서 해제한 뒤 사용하세요.").foregroundStyle(.orange) }
            if !steerStatus.isEmpty { Text(steerStatus).font(.caption).foregroundStyle(.secondary) }
            if !connection.message.isEmpty { Text(connection.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(chatImages.enumerated()), id: \.offset) { index, data in
                    if let image = NSImage(data: data) {
                    HStack(spacing: 9) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 48)
                            .accessibilityLabel("첨부 이미지 미리보기")
                        Text("이미지 질문 · 전송 시 OpenAI에 공유").font(.caption)
                        Button { chatImages.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("이미지 첨부 제거")
                    }
                    }
                }
                ForEach(Array(chatDocuments.enumerated()), id: \.offset) { index, document in
                    DisclosureGroup(document.name + (document.truncated ? " · 일부 발췌" : "")) {
                        ScrollView { Text(document.text).font(.caption).textSelection(.enabled) }.frame(maxHeight: 150)
                        Button("첨부 제거") { chatDocuments.remove(at: index) }
                    }
                }
                if !imageMessage.isEmpty { Text(imageMessage).font(.caption).foregroundStyle(.secondary) }
                if !code.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(code.attachments, id: \.path) { file in
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                    Text(file.path).lineLimit(1)
                                    Button { code.remove(file.path) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel("첨부 해제")
                                }.font(.caption).padding(7)
                                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.scrollIndicators(.hidden)
                    Text("전송 시 첨부한 줄 범위를 OpenAI에 공유합니다.").font(.caption2).foregroundStyle(.secondary)
                }
                CodexComposerEditor(text: $input, submit: sendCurrentMessage,
                                    placeholder: (connection.canSteer || agent.running) ? "현재 작업에 추가할 메시지…" : "Codex와 함께 작업하세요…")
                .frame(height: min(130, max(54, CGFloat(input.components(separatedBy: "\n").count) * 22)))
                .accessibilityLabel("Codex 메시지")
                HStack {
                    Menu {
                        Button("파일·PDF 첨부…", systemImage: "doc.badge.plus") { chooseChatDocuments() }
                            .disabled(connection.busy || code.busy || locked || !code.attachments.isEmpty)
                        Button("이미지 첨부…", systemImage: "photo.badge.plus", action: chooseChatImage)
                            .disabled(connection.backend != .appServer || !code.attachments.isEmpty)
                        Button("셸·MCP·플러그인 도구 실행…", systemImage: "terminal") {
                            code.stop()
                            showNativeTools = true
                        }.disabled(code.root == nil || connection.backend != .appServer || !connection.ready || connection.busy || code.busy)
                        Button(code.root == nil ? "프로젝트 폴더 연결…" : "프로젝트 폴더 변경…", systemImage: "folder") {
                            if workspace.projectID == nil { _ = workspace.createGeneralThread() }
                            if let id = workspace.projectID { chooseProjectFolder(id) }
                        }
                        if code.root != nil {
                            Button("작업 세션·이력 관리…") { showAgentHistory = true }.disabled(connection.busy || code.busy || !connection.ready)
                            Button("작업 확장·스킬·검색 설정…") { showAgentExtensions = true }.disabled(connection.busy || code.busy)
                            Toggle("Codex 프로젝트 작업 · 호스트 도구", isOn: $useAgent).disabled(connection.busy || code.busy)
                            Button("프로젝트 파일 보기·첨부", systemImage: "doc.badge.plus") { openProjectFiles() }
                            Divider()
                            Button("폴더 연결 해제", systemImage: "xmark.circle") { showFiles = false; code.disconnect() }
                        }
                    } label: { Image(systemName: "plus").font(.headline) }
                        .fixedSize()
                        .disabled(connection.busy || code.busy)
                        .accessibilityLabel("첨부 및 프로젝트 옵션")
                        .popover(isPresented: $showFiles) { CodexProjectFilePicker(store: code) }
                    if let root = code.root {
                        Button {
                            openProjectFiles()
                        } label: {
                            Label(root.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .frame(maxWidth: 165, alignment: .leading)
                        .disabled(connection.busy || code.busy)
                        .help("프로젝트 파일 \(code.paths.count)개 보기")
                    }
                    Menu {
                        Label("Codex · 사용 중", systemImage: "checkmark")
                        Divider()
                        Button("Claude · 연결 준비 중") {}.disabled(true)
                    } label: { Label("Codex", systemImage: "sparkles") }
                        .fixedSize().accessibilityLabel("AI 선택").help("AI 제공자 선택 · 현재는 Codex만 연결됩니다.")
                    Button(quotaLabel) { showQuota.toggle() }.font(.caption).buttonStyle(.plain).disabled(code.busy)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .popover(isPresented: $showQuota) { quotaDetails }
                    Spacer(minLength: 16)
                    modelMenu
                    effortMenu
                    if connection.activeGeneration != nil || code.busy || agent.running {
                        if agent.running && agent.pending == nil {
                            Button("이 작업에 반영", action: sendCurrentMessage).buttonStyle(.borderedProminent)
                                .disabled(agent.steering || !CodexTurnInput.valid(input))
                        }
                        if connection.canSteer {
                            Button(connection.steering ? "전달 중…" : "이 작업에 반영", action: sendCurrentMessage)
                                .buttonStyle(.borderedProminent)
                                .disabled(connection.steering || !CodexTurnInput.valid(input))
                        }
                        Button {
                            agent.stop(); code.stop()
                            connection.stop()
                        } label: {
                            Image(systemName: "stop.fill").font(.headline).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Circle())
                        .accessibilityLabel("작업 중지")
                        .help("Codex 작업 중지")
                    }
                    else {
                        Button(action: sendCurrentMessage) { Image(systemName: "arrow.up").font(.headline).frame(width: 24, height: 24) }
                            .buttonStyle(.borderedProminent).clipShape(Circle())
                            .disabled(!workspace.loaded || workspace.selectedModel.isEmpty || !connection.ready || connection.busy || connection.steering || locked || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.utf8.count > 6000)
                            .help("Enter 전송 · Shift+Enter 줄바꿈")
                    }
                }
            }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.12)))
                .disabled(locked)
            Text("대화는 선택한 전용 저장소에 저장됩니다. 응답은 사실·실행 결과로 검증된 것이 아닙니다.").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }.frame(maxWidth: 850).padding(.horizontal, 24).padding(.bottom, 18).frame(maxWidth: .infinity)
    }
    private func clearChatImport() {
        importPickerID = nil
        importWork?.cancel(); importWork = nil
        importPreview = nil; importSelection = []; importMessage = ""
    }

    private func chooseChatImport() {
        guard !locked, !connection.busy, !code.busy, importWork == nil, importPickerID == nil else { return }
        let pickerID = UUID()
        importPickerID = pickerID
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "미리보기"
        panel.message = "ChatGPT 데이터 내보내기에서 압축을 푼 대화 JSON 파일을 선택하세요."
        panel.begin { response in
            guard importPickerID == pickerID else { return }
            importPickerID = nil
            guard response == .OK, let url = panel.url, !locked, !connection.busy,
                  !code.busy, importWork == nil else { return }
            importMessage = "대화 파일을 읽는 중…"
            let parse = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                    throw CodexLocalError.invalid
                }
                guard JarvisStorage.permits(url) else { throw CodexLocalError.invalid }; let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                guard let bytes = try handle.read(upToCount: CodexChatImport.byteLimit + 1),
                      bytes.count <= CodexChatImport.byteLimit else { throw CodexLocalError.invalid }
                try Task.checkCancellation()
                return try CodexChatImport.read(bytes)
            }
            importWork = Task {
                defer { if !Task.isCancelled { importWork = nil } }
                do {
                    let preview = try await withTaskCancellationHandler {
                        try await parse.value
                    } onCancel: {
                        parse.cancel()
                    }
                    guard !Task.isCancelled, !locked else { return }
                    guard !preview.threads.isEmpty else {
                        importMessage = "가져올 수 있는 대화가 없습니다. 내보내기 파일과 대화 크기를 확인하세요."
                        return
                    }
                    importMessage = ""
                    importSelection = []
                    importPreview = preview
                } catch {
                    guard !Task.isCancelled, !locked else { return }
                    importMessage = "대화 파일을 읽지 못했습니다. 압축을 푼 32MiB 이하의 ChatGPT 대화 JSON을 선택하세요."
                }
            }
        }
    }

    private func chooseChatImage() {
        guard !locked, !connection.busy, !code.busy, connection.backend == .appServer,
              code.attachments.isEmpty else { return }
        let thread = workspace.threadID
        let project = workspace.projectID
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty, !locked, !connection.busy, !code.busy,
                  connection.backend == .appServer, workspace.threadID == thread,
                  workspace.projectID == project, code.attachments.isEmpty else { return }
            do {
                guard panel.urls.count <= 4 else { throw CodexLocalError.invalid }
                let selected = try panel.urls.map { try workspace.readChatImage($0) }
                guard chatImages.count + selected.count <= 4,
                      (chatImages + selected).reduce(0, { $0 + $1.count }) <= 3 * 1024 * 1024 else { throw CodexLocalError.invalid }
                chatImages += selected
                imageMessage = ""
            } catch {
                imageMessage = "이미지를 준비하지 못했습니다. 16MB 이하의 JPEG 또는 PNG 파일을 선택해주세요."
            }
        }
    }

    private func chooseChatDocuments() {
        guard !locked, !connection.busy, !code.busy, code.attachments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText, .sourceCode, .json]
        panel.allowsMultipleSelection = true
        let project = workspace.projectID, thread = workspace.threadID
        guard panel.runModal() == .OK, project == workspace.projectID, thread == workspace.threadID else { return }
        do {
            guard panel.urls.count + chatDocuments.count <= 4 else { throw CodexLocalError.invalid }
            let selected = try panel.urls.map { try CodexDocumentReader.read($0, confirmed: true, locked: locked) }
            chatDocuments += selected; imageMessage = ""
        } catch { imageMessage = "최대 4개의 UTF-8 파일 또는 텍스트 PDF를 선택하세요. 암호·스캔 PDF, 16MB 초과 파일과 알려진 비밀 키가 포함된 내용은 첨부할 수 없습니다." }
    }

    private func exportResponse(_ item: CodexChatMessage, format: String) {
        guard !locked, item.role == .assistant, item.state == .completed else { return }
        do {
            exportPreview = CodexExportPreview(data: try CodexResponseExporter.data(item.text, format: format), text: item.text, format: format)
        } catch { imageMessage = "답변 파일을 준비하지 못했습니다." }
    }
    private func saveExport(_ preview: CodexExportPreview) {
        guard !locked else { return }
        let format = preview.format
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .plainText]
        panel.nameFieldStringValue = "Codex 답변." + format
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let result = CodexResponseExporter.save(preview.data, to: target, confirmed: true, locked: { JarvisStorage.preferences.bool(forKey: SharedProjectStore.lockKey) })
            switch result {
            case .succeeded(let text): imageMessage = text; exportPreview = nil
            case .failed(let text, _), .needsConfirmation(let text), .needsPermission(let text), .unverifiable(let text): imageMessage = text; exportPreview = nil
            case .handedOff: imageMessage = "파일 저장 완료를 확인하지 못했습니다."; exportPreview = nil
            }
    }

    private func openProjectFiles() {
        guard !locked, !connection.busy, !code.busy, code.root != nil else { return }
        code.refresh()
        showFiles = true
    }
    private var quotaLabel: String {
        guard let quota = connection.quota else {
            return !connection.connected ? "잔여 사용량 · 연결 필요" : connection.quotaMessage.contains("확인 중") ? "잔여 사용량 · 조회 중" : "잔여 사용량 · 확인 불가"
        }
        let values = [quota.primary, quota.secondary].compactMap { $0 }.map { "\(quotaPeriod($0.windowDurationMins)) \($0.remaining)%" }
        return values.isEmpty ? "잔여 사용량 · 확인 불가" : "잔여 " + values.joined(separator: " · ")
    }
    private func quotaPeriod(_ minutes: Int?) -> String {
        guard let minutes else { return "한도" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)일" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return "\(minutes)분"
    }
    private var quotaDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(connection.backend.provider) 잔여 사용량").font(.headline)
            Text(connection.quotaMessage).font(.caption)
            if let quota = connection.quota {
                ForEach(Array([quota.primary, quota.secondary].compactMap { $0 }.enumerated()), id: \.offset) { index, window in
                    Text("\(index == 0 ? "기본" : "추가") 한도 · 잔여 \(window.remaining)%")
                    if let mins = window.windowDurationMins { Text("집계 구간: \(mins)분").font(.caption) }
                    if let reset = window.resetsAt { Text("갱신 예정: \(Date(timeIntervalSince1970: reset).formatted())").font(.caption) }
                }
                Text("확인: \(Date(timeIntervalSince1970: quota.checkedAt).formatted())").font(.caption).foregroundStyle(.secondary)
            }
            Button("사용량 새로 고침") { connection.refreshUsage() }.disabled(!connection.connected || connection.busy || code.busy || locked)
        }.padding(18).frame(width: 340)
    }
    private func sendCurrentMessage() {
        if agent.running {
            guard CodexTurnInput.valid(input), agent.pending == nil else { return }
            let text = input
            agent.steer(text) { accepted in if accepted && input == text { input = "" } }
            return
        }
        if connection.canSteer {
            let text = input
            guard CodexTurnInput.valid(text), let thread = workspace.threadID else { return }
            let messageID = workspace.activeMessage
            let coding = messageID == nil && code.root != nil
            connection.steer(text) { accepted, status in
                guard workspace.threadID == thread else { return }
                steerStatus = status
                if accepted {
                    if coding { code.recordSteering(text) }
                    else if let messageID { workspace.recordSteering(text, threadID: thread, messageID: messageID) }
                    if input == text { input = "" }
                }
            }
            return
        }
        steerStatus = ""
        guard connection.ready, !connection.busy, !connection.steering, !locked, workspace.loaded,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.utf8.count <= 6000 else { return }
        let previousThread = workspace.threadID
        if code.root != nil, chatImages.isEmpty, chatDocuments.isEmpty {
            guard let threadID = workspace.threadID, !code.busy, workspace.canStartCodeTurn() else { return }
            if useAgent, code.attachments.isEmpty, let executor = code.agentExecutor() {
                code.stop()
                agent.record = { text, user in workspace.recordCode(text, user: user, threadID: threadID) }
                agent.completed = { text, turn in workspace.recordAgentCompletion(text, turn: turn, threadID: threadID) }
                var context = AssistantContextManager(maximumRecentTurns: 3, maximumLongTermMemories: 1)
                let messages = workspace.thread?.messages ?? []
                for index in messages.indices.dropFirst() {
                    let previous = messages[index - 1], current = messages[index]
                    if previous.role == .user, current.role == .assistant, previous.coding == true, current.coding == true,
                       previous.state == .completed, current.state == .completed {
                        context.record(userText: previous.text, assistantResponse: current.text, intent: .unknownCommand(text: previous.text))
                    }
                }
                let turns = context.context(for: input, longTermMemories: []).recentTurns.suffix(3).map { CloudConversationTurn(user: $0.userText, assistant: $0.assistantResponse) }
                do {
                    let profile = try CodexAgentProfile.read(JarvisStorage.preferences.data(forKey: "jarvis.codex.agentProfile") ?? Data())
                    if agent.start(input, model: workspace.selectedModel, effort: workspace.selectedEffort, executor: executor, context: turns,
                        backupDirectory: code.agentBackupRoot(), conversationID: threadID, resumeTurn: workspace.thread?.agentTurnID,
                        forkSource: workspace.thread?.agentForkSource, forkTurn: workspace.thread?.agentForkTurn, profile: profile, connection: connection) { input = "" }
                } catch { imageMessage = "확장 설정을 읽지 못했습니다. 작업 확장 설정에서 확인해주세요." }
                return
            }
            agent.stop()
            code.record = { text, user in workspace.recordCode(text, user: user, threadID: threadID) }
            if code.request(input, model: workspace.selectedModel, effort: workspace.selectedEffort, connection: connection) { input = "" }
            return
        }
        guard (chatImages.isEmpty || connection.backend == .appServer) && (chatImages.isEmpty && chatDocuments.isEmpty || code.attachments.isEmpty) else {
            imageMessage = "이미지와 코드 범위는 별도 메시지로 전송해주세요."
            return
        }
        guard let plan = workspace.prepare(input, session: connection.sessionID, images: chatImages, documents: chatDocuments) else { return }
        if previousThread != workspace.threadID { preserveInputOnNextSelection = true }
        // The user's Return/send-button gesture confirms this exact visible
        // message/model/session only. No stored or background authorization.
        if workspace.send(plan, connection: connection, confirmed: true) {
            input = ""; chatImages = []; chatDocuments = []; imageMessage = ""
        }
    }
    private var modelMenu: some View {
        Button { showModelList.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "cpu")
                Text(connection.models.first(where: { $0.id == workspace.selectedModel })?.name ?? (workspace.selectedModel.isEmpty ? "모델 선택" : workspace.selectedModel)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }.padding(.horizontal, 9).padding(.vertical, 5)
        }.buttonStyle(.plain)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 190, alignment: .trailing)
            .disabled(!workspace.loaded || connection.busy || locked)
            .popover(isPresented: $showModelList, arrowEdge: .bottom) {
                CodexModelSelectionPanel(models: connection.models, selected: workspace.selectedModel,
                                         busy: connection.busy, canRefresh: connection.connected, choose: { model in
                    let efforts = model.reasoningEfforts ?? ["low", "medium", "high"]
                    let effort = model.id == workspace.selectedModel && efforts.contains(workspace.selectedEffort)
                        ? workspace.selectedEffort
                        : model.defaultReasoningEffort ?? (efforts.contains(workspace.selectedEffort) ? workspace.selectedEffort : efforts.first ?? "low")
                    workspace.model(model.id, effort: effort)
                    showModelList = false
                }, refresh: { connection.refreshModels() }, manual: { showModelList = false; showModel = true },
                                         usesServerCatalog: connection.usesServerModelCatalog)
            }
    }
    private var effortMenu: some View {
        let levels = connection.models.first(where: { $0.id == workspace.selectedModel })?.reasoningEfforts
            ?? ["low", "medium", "high", "xhigh", "max"]
        return Menu {
            ForEach(levels, id: \.self) { effort in
                Button(CodexLocalModel.effortName(effort)) { workspace.model(workspace.selectedModel, effort: effort) }
            }
            Text("추론 수준이 높으면 응답 시간과 사용량이 늘 수 있습니다.")
        } label: { Text("추론 · " + CodexLocalModel.effortName(workspace.selectedEffort)) }
            .fixedSize().disabled(!workspace.loaded || workspace.selectedModel.isEmpty || connection.busy || locked)
    }
}
