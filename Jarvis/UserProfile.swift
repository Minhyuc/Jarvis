import Combine
import Foundation
import CryptoKit
import Security

enum AssistantResponseStyle: String, Codable, CaseIterable, Identifiable {
    case concise
    case warm
    case professional
    case analytical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .concise: return "간결하게"
        case .warm: return "친근하게"
        case .professional: return "전문적으로"
        case .analytical: return "분석적으로"
        }
    }

    var promptInstruction: String {
        switch self {
        case .concise:
            return "핵심만 짧고 명확하게 답한다."
        case .warm:
            return "친근하고 배려하는 말투로 답한다."
        case .professional:
            return "차분하고 전문적인 비서의 말투로 답한다."
        case .analytical:
            return "근거와 선택지를 분석해 체계적으로 답한다."
        }
    }
}

struct UserProfile: Codable, Equatable {
    var name = ""
    var preferredAddress = ""
    var occupationOrSituation = ""
    var interests = ""
    var additionalInformation = ""
    var responseStyle: AssistantResponseStyle = .concise

    var contextForAI: String {
        var lines = ["답변 스타일: \(responseStyle.promptInstruction)"]

        if !name.trimmed.isEmpty {
            lines.append("사용자 이름: \(name.trimmed)")
        }
        if !preferredAddress.trimmed.isEmpty {
            lines.append("사용자를 부를 때 사용할 호칭: \(preferredAddress.trimmed)")
        }
        if !occupationOrSituation.trimmed.isEmpty {
            lines.append("직업 또는 현재 상황: \(occupationOrSituation.trimmed)")
        }
        if !interests.trimmed.isEmpty {
            lines.append("관심사: \(interests.trimmed)")
        }
        if !additionalInformation.trimmed.isEmpty {
            lines.append("추가 참고 정보: \(additionalInformation.trimmed)")
        }

        return lines.joined(separator: "\n")
    }

    var addressForGreeting: String? {
        let preferred = preferredAddress.trimmed
        if !preferred.isEmpty { return preferred }
        let savedName = name.trimmed
        return savedName.isEmpty ? nil : savedName
    }
}

enum UserProfileStore {
    private static let service = "com.minhyuc.jarvis.profile"
    private static let account = "personalization"

    static func load() -> UserProfile {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return UserProfile()
        }
        return profile
    }

    @discardableResult
    static func save(_ profile: UserProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var item = lookup
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum LongTermMemorySource: String, Codable {
    case explicitCommand
    case repeatedConversation
    case manual

    var title: String {
        switch self {
        case .explicitCommand: return "음성·채팅 명령"
        case .repeatedConversation: return "반복 대화에서 제안"
        case .manual: return "직접 입력"
        }
    }
}

enum LongTermMemoryCategory: String, Codable, CaseIterable, Identifiable {
    case basicInformation
    case preference
    case frequentPlace
    case frequentContact
    case routine
    case responseStyle
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basicInformation: "기본 정보"
        case .preference: "선호도"
        case .frequentPlace: "자주 사용하는 장소"
        case .frequentContact: "자주 사용하는 연락처"
        case .routine: "반복 루틴"
        case .responseStyle: "AI 응답 스타일"
        case .other: "기타"
        }
    }
}

enum LongTermMemoryImportance: Int, Codable, CaseIterable, Identifiable, Comparable {
    case low = 0
    case normal = 1
    case high = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low: "낮음"
        case .normal: "보통"
        case .high: "높음"
        }
    }

    static func < (lhs: LongTermMemoryImportance, rhs: LongTermMemoryImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LongTermMemoryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var content: String
    var source: LongTermMemorySource
    var category: LongTermMemoryCategory
    var importance: LongTermMemoryImportance
    var expiresAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, content, source, category, importance, expiresAt
        case createdAt, updatedAt, lastUsedAt
    }

    init(
        id: UUID,
        content: String,
        source: LongTermMemorySource,
        category: LongTermMemoryCategory,
        importance: LongTermMemoryImportance,
        expiresAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.category = category
        self.importance = importance
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        content = try values.decode(String.self, forKey: .content)
        source = try values.decode(LongTermMemorySource.self, forKey: .source)
        category = try values.decodeIfPresent(LongTermMemoryCategory.self, forKey: .category) ?? .other
        importance = try values.decodeIfPresent(LongTermMemoryImportance.self, forKey: .importance) ?? .normal
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }

    var isExpired: Bool {
        expiresAt.map { $0 <= Date() } ?? false
    }
}

@MainActor
final class LongTermMemoryStore: ObservableObject {
    static let shared = LongTermMemoryStore()

    @Published private(set) var memories: [LongTermMemoryRecord]
    @Published private(set) var deletionMarkers: [String: Date] = [:]
    @Published private(set) var storageError: String?
    private let testDefaults: UserDefaults?
    private let canPersist: () -> Bool
    private var committedMemories: [LongTermMemoryRecord] = []
    private var committedMarkers: [String: Date] = [:]
    private struct Envelope: Codable { var memories: [LongTermMemoryRecord]; var deletionMarkers: [String: Date] }

    private static let service = "com.minhyuc.jarvis.long-term-memory"
    private static let account = "memories"
    private let maximumMemories = 100

    init(defaults: UserDefaults? = nil, canPersist: @escaping () -> Bool = { true }) {
        testDefaults = defaults
        self.canPersist = canPersist
        memories = []
        if let defaults, let data = defaults.data(forKey: "memory-test-state"),
           let state = try? JSONDecoder().decode(Envelope.self, from: data) {
            memories = state.memories; deletionMarkers = state.deletionMarkers
        } else if defaults == nil {
            memories = Self.loadFromKeychain()
            if let state = Self.loadEnvelope() { memories = state.memories; deletionMarkers = state.deletionMarkers }
        }
        committedMemories = memories; committedMarkers = deletionMarkers
    }

    var contextForAI: [String] {
        activeMemories.filter { !conflictingMemoryIDs().contains($0.id) }.suffix(30).map(\.content)
    }

    var activeMemories: [LongTermMemoryRecord] {
        memories.filter { !$0.isExpired }
    }

    @discardableResult
    func add(
        _ rawContent: String,
        source: LongTermMemorySource,
        category: LongTermMemoryCategory? = nil,
        importance: LongTermMemoryImportance = .normal,
        expiresAt: Date? = nil,
        sensitiveConfirmed: Bool = false
    ) -> LongTermMemoryRecord? {
        let content = sanitized(rawContent)
        guard !content.isEmpty else { return nil }
        guard !requiresSensitiveConfirmation(content) || sensitiveConfirmed else { return nil }
        guard permitted(.remember(content: content)) else { return nil }
        if source == .repeatedConversation, deletionMarkers[fingerprint(content)] != nil { return nil }

        let normalized = normalize(content)
        if let index = memories.firstIndex(where: { normalize($0.content) == normalized }) {
            memories[index].importance = max(memories[index].importance, importance)
            memories[index].expiresAt = expiresAt ?? memories[index].expiresAt
            memories[index].updatedAt = Date()
            guard persist() else { return nil }
            return memories[index]
        }

        // Similar wording may encode a different address, time or preference.
        // Only exact duplicates merge; potential conflicts remain reviewable.

        guard memories.count < maximumMemories else { storageError = "기억은 최대 100개까지 보관합니다. 기존 기억을 정리해주세요."; return nil }
        let now = Date()
        let record = LongTermMemoryRecord(
            id: UUID(),
            content: content,
            source: source,
            category: category ?? inferredCategory(for: content),
            importance: importance,
            expiresAt: expiresAt,
            createdAt: now,
            updatedAt: now
        )
        memories.append(record)
        guard persist() else { return nil }
        return record
    }

    @discardableResult
    func update(
        id: UUID,
        content rawContent: String,
        category: LongTermMemoryCategory? = nil,
        importance: LongTermMemoryImportance? = nil,
        expiresAt: Date?? = nil,
        sensitiveConfirmed: Bool = false
    ) -> Bool {
        let content = sanitized(rawContent)
        guard !requiresSensitiveConfirmation(content) || sensitiveConfirmed else { return false }
        guard !content.isEmpty,
              permitted(.remember(content: content)),
              let index = memories.firstIndex(where: { $0.id == id }) else {
            return false
        }
        deletionMarkers[fingerprint(memories[index].content)] = Date()
        memories[index].content = content
        if let category { memories[index].category = category }
        if let importance { memories[index].importance = importance }
        if let expiresAt { memories[index].expiresAt = expiresAt }
        memories[index].updatedAt = Date()
        return persist()
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard permitted(.forgetMemory(.matching("선택한 기억"))) else { return false }
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return false }
        deletionMarkers[fingerprint(memories[index].content)] = Date()
        memories.remove(at: index)
        return persist()
    }

    @discardableResult
    func deleteLatest() -> LongTermMemoryRecord? {
        guard permitted(.forgetMemory(.latest)) else { return nil }
        guard let record = memories.popLast() else { return nil }
        deletionMarkers[fingerprint(record.content)] = Date()
        guard persist() else { return nil }
        return record
    }

    @discardableResult
    func deleteBestMatch(for rawQuery: String) -> LongTermMemoryRecord? {
        let query = sanitized(rawQuery)
        guard permitted(.forgetMemory(.matching("선택한 기억"))) else { return nil }
        guard !query.isEmpty else { return nil }
        let queryNormalized = normalize(query)
        let queryTerms = terms(in: query)

        let ranked = memories.enumerated().compactMap { index, memory -> (Int, Double)? in
            let memoryNormalized = normalize(memory.content)
            if memoryNormalized.contains(queryNormalized) || queryNormalized.contains(memoryNormalized) {
                return (index, 1)
            }
            let memoryTerms = terms(in: memory.content)
            let overlap = queryTerms.intersection(memoryTerms).count
            guard overlap > 0 else { return nil }
            let score = Double(overlap) / Double(max(1, queryTerms.count))
            return score >= 0.45 ? (index, score) : nil
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 > rhs.0 : lhs.1 > rhs.1
        }

        guard let index = ranked.first?.0 else { return nil }
        let removed = memories.remove(at: index)
        deletionMarkers[fingerprint(removed.content)] = Date()
        guard persist() else { return nil }
        return removed
    }

    func containsSimilar(_ rawContent: String) -> Bool {
        let content = sanitized(rawContent)
        let normalized = normalize(content)
        guard !normalized.isEmpty else { return false }

        return memories.contains { normalize($0.content) == normalized }
    }

    func relevantRecords(for rawText: String, limit: Int = 8) -> [LongTermMemoryRecord] {
        let queryTerms = terms(in: rawText)
        guard !queryTerms.isEmpty else { return [] }
        let conflicts = conflictingMemoryIDs()
        return activeMemories.filter { !conflicts.contains($0.id) }.compactMap { memory -> (LongTermMemoryRecord, Int)? in
            let overlap = queryTerms.intersection(terms(in: memory.content)).count
            guard overlap > 0 else { return nil }
            let score = overlap * 20 + memory.importance.rawValue * 3
            return (memory, score)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.updatedAt > rhs.0.updatedAt : lhs.1 > rhs.1
        }
        .prefix(max(1, limit))
        .map(\.0)
    }

    func markReferenced(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let now = Date()
        var changed = false
        for index in memories.indices where idSet.contains(memories[index].id) {
            memories[index].lastUsedAt = now
            changed = true
        }
        if changed { persist(notify: false) }
    }

    func conflictingMemoryIDs() -> Set<UUID> {
        var result: Set<UUID> = []
        let current = activeMemories
        for leftIndex in current.indices {
            for rightIndex in current.indices where rightIndex > leftIndex {
                let left = current[leftIndex]
                let right = current[rightIndex]
                guard left.category == right.category else { continue }
                let leftTerms = terms(in: left.content)
                let rightTerms = terms(in: right.content)
                let overlap = leftTerms.intersection(rightTerms).count
                guard overlap >= 2 else { continue }
                let oppositePolarity = hasNegativeMarker(left.content) != hasNegativeMarker(right.content)
                let exclusiveCategory = [.frequentPlace, .frequentContact, .responseStyle]
                    .contains(left.category)
                if oppositePolarity || exclusiveCategory {
                    result.insert(left.id)
                    result.insert(right.id)
                }
            }
        }
        return result
    }

    func conflicts(with id: UUID) -> [LongTermMemoryRecord] {
        guard let selected = activeMemories.first(where: { $0.id == id }) else { return [] }
        return activeMemories.filter { other in
            guard other.id != id, other.category == selected.category else { return false }
            let overlap = terms(in: selected.content).intersection(terms(in: other.content)).count
            return overlap >= 2 && (hasNegativeMarker(selected.content) != hasNegativeMarker(other.content)
                || [.frequentPlace, .frequentContact, .responseStyle].contains(selected.category))
        }
    }

    func requiresSensitiveConfirmation(_ rawContent: String) -> Bool {
        let compact = normalize(rawContent)
        let sensitiveTerms = [
            "주민등록번호", "여권번호", "계좌번호", "비밀번호", "비밀번호는",
            "공동인증서", "보안코드", "카드번호", "주소는", "병력", "진단명"
        ]
        return sensitiveTerms.contains(where: compact.contains)
    }

    @discardableResult
    func deleteAll(confirmed: Bool = false) -> Bool {
        guard permitted(.forgetMemory(.all), confirmed: confirmed) else { return false }
        for memory in memories { deletionMarkers[fingerprint(memory.content)] = Date() }
        memories.removeAll()
        return persist()
    }

    func maySuggest(_ content: String) -> Bool { deletionMarkers[fingerprint(content)] == nil }

    @discardableResult
    func resolveConflict(keeping id: UUID, removing ids: [UUID], confirmed: Bool) -> Bool {
        let conflicts = Set(conflicts(with: id).map(\.id))
        guard !conflicts.isEmpty, !ids.isEmpty, !ids.contains(id),
              Set(ids).isSubset(of: conflicts), memories.contains(where: { $0.id == id }),
              permitted(.resolveMemoryConflict(keepID: id, removeIDs: ids), confirmed: confirmed) else { return false }
        for memory in memories where ids.contains(memory.id) { deletionMarkers[fingerprint(memory.content)] = Date() }
        memories.removeAll { ids.contains($0.id) }
        return persist()
    }

    private func permitted(_ intent: AssistantIntent, confirmed: Bool = false) -> Bool {
        if case .allow = SafetyPolicyEngine().evaluate(intent, context: .init(
            externalActionsLocked: SafetyControlStore.externalActionsLocked, wasExplicitlyConfirmed: confirmed)) { return true }
        return false
    }

    private func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(normalize(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func inferredCategory(for content: String) -> LongTermMemoryCategory {
        let compact = normalize(content)
        if ["말투", "간결", "자세히", "답변", "호칭"].contains(where: compact.contains) {
            return .responseStyle
        }
        if ["자주가", "집", "회사", "학교", "근무지"].contains(where: compact.contains) {
            return .frequentPlace
        }
        if ["연락처", "전화", "가족", "친구"].contains(where: compact.contains) {
            return .frequentContact
        }
        if ["매일", "매주", "루틴", "습관", "항상"].contains(where: compact.contains) {
            return .routine
        }
        if ["좋아", "싫어", "선호", "알레르기", "못먹", "안먹"].contains(where: compact.contains) {
            return .preference
        }
        if ["이름", "생일", "직업", "전공", "살고"].contains(where: compact.contains) {
            return .basicInformation
        }
        return .other
    }

    private func hasNegativeMarker(_ text: String) -> Bool {
        let compact = normalize(text)
        return ["싫", "안", "못", "아니", "않"].contains(where: compact.contains)
    }

    private func duplicateScore(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let overlap = lhs.intersection(rhs).count
        guard overlap >= 2 else { return 0 }
        return Double(overlap) / Double(max(1, min(lhs.count, rhs.count)))
    }

    private func sanitized(_ text: String) -> String {
        let singleLine = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(500))
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func terms(in text: String) -> Set<String> {
        let ignored: Set<String> = [
            "나는", "내가", "저는", "제가", "나도", "저도", "그리고",
            "그런데", "정말", "진짜", "기억", "기억해", "말했지"
        ]
        let suffixes = [
            "이라고", "라는", "한다는", "한다고", "합니다", "이에요", "예요",
            "이야", "해요", "하고", "해서", "에게", "에서", "으로",
            "은", "는", "이", "가", "을", "를", "도", "에"
        ]
        return Set(
            text.lowercased()
                .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !ignored.contains($0) }
                .map { token in
                    for suffix in suffixes where token.count > suffix.count + 1 && token.hasSuffix(suffix) {
                        return String(token.dropLast(suffix.count))
                    }
                    return token
                }
                .filter { $0.count >= 2 }
        )
    }

    @discardableResult
    private func persist(notify: Bool = true) -> Bool {
        func failed() -> Bool {
            memories = committedMemories; deletionMarkers = committedMarkers
            storageError = "기억 저장소에 반영하지 못했습니다. 기기 잠금 상태와 저장 공간을 확인해주세요."
            return false
        }
        guard canPersist() else { return failed() }
        if deletionMarkers.count > 1_000 {
            deletionMarkers = Dictionary(uniqueKeysWithValues: deletionMarkers.sorted { $0.value > $1.value }.prefix(1_000).map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(Envelope(memories: memories, deletionMarkers: deletionMarkers)) else { return failed() }
        func succeeded() -> Bool {
            committedMemories = memories; committedMarkers = deletionMarkers; storageError = nil
            if notify { NotificationCenter.default.post(name: .jarvisMemoriesChanged, object: nil) }
            return true
        }
        if let testDefaults { testDefaults.set(data, forKey: "memory-test-state"); return succeeded() }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return succeeded() }
        guard updateStatus == errSecItemNotFound else { return failed() }
        var item = lookup
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? succeeded() : failed()
    }

    private static func loadFromKeychain() -> [LongTermMemoryRecord] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let records = try? JSONDecoder().decode([LongTermMemoryRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static func loadEnvelope() -> Envelope? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}

extension Notification.Name { static let jarvisMemoriesChanged = Notification.Name("jarvis.memories.changed") }

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
