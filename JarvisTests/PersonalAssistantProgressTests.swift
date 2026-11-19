import XCTest
import UserNotifications
@testable import Jarvis

@MainActor
final class LocalDataStabilityTests: XCTestCase {
    private var originalLock = false
    override func setUp() {
        super.setUp()
        originalLock = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
    }
    override func tearDown() {
        UserDefaults.standard.set(originalLock, forKey: SafetyControlStore.externalActionsLockKey)
        super.tearDown()
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "stability-" + UUID().uuidString)! }
    private func alarm(label: String = "기존") -> JarvisAlarmRecord {
        .init(id: UUID(), date: Date().addingTimeInterval(7_200), label: label, message: "가상 알람",
            delivery: .system, isEnabled: true, backend: .alarmKit, notificationIdentifier: nil,
            soundFileName: nil, createdAt: Date())
    }
    private func event(_ title: String, after: TimeInterval = 3_600) -> JarvisCalendarEvent {
        .init(id: UUID(), title: title, startDate: Date().addingTimeInterval(after),
            endDate: Date().addingTimeInterval(after + 1_800), isAllDay: false, isOutdoor: false,
            location: "", notes: "", urlString: "", recurrence: .none, reminderMinutesBefore: 0,
            createdAt: Date(), updatedAt: Date())
    }
    func testAllMaintenanceActionsObeyLockAndBulkNeedsConfirmation() async {
        var ran = false
        let confirmation: ToolExecutionResult<Void> = await LocalDataExecution.perform(.localData(.deleteAllCalendarEvents)) { ran = true }
        XCTAssertEqual(confirmation.status, .needsConfirmation); XCTAssertFalse(ran)
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        for action in [LocalDataAction.createAlarm, .changeAlarm, .deleteAlarm, .deleteAllCalendarEvents,
                       .refreshNotifications, .reconcileAlarms, .restoreStorage] {
            let result: ToolExecutionResult<Void> = await LocalDataExecution.perform(.localData(action), confirmed: true) { ran = true }
            XCTAssertEqual(result.status, .failed)
        }
        XCTAssertFalse(ran)
    }
    func testCancelledWriteNeverEntersOperationAndDuplicateIsRejected() async throws {
        var ran = false
        let task = Task { @MainActor in
            await Task.yield()
            return await LocalDataExecution.perform(.localData(.createAlarm)) { ran = true }
        }
        task.cancel(); _ = await task.value; XCTAssertFalse(ran)
        var started = false
        let first = Task { @MainActor in
            await LocalDataExecution.perform(.localData(.createAlarm)) {
                started = true; try await Task.sleep(for: .milliseconds(100))
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while !started, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard started else { first.cancel(); XCTFail("first operation did not start"); return }
        let duplicate: ToolExecutionResult<Void> = await LocalDataExecution.perform(.localData(.changeAlarm)) { ran = true }
        XCTAssertEqual(duplicate.status, .failed); XCTAssertFalse(ran)
        _ = await first.value
    }
    func testFailedPersistenceDoesNotPublishNewList() throws {
        let persistence = RecordPersistence<JarvisAlarmRecord>(defaults: defaults(), key: "alarms")
        let store = AlarmStore(persistence: persistence)
        let old = alarm(); try store.upsert(old)
        persistence.writeOverride = { _ in throw LocalDataError.storage }
        XCTAssertThrowsError(try store.upsert(alarm(label: "새")))
        XCTAssertEqual(store.alarms, [old]); XCTAssertNotNil(store.storageIssue)
    }
    func testCorruptDataUsesReadOnlyBackupAndRequiresExplicitRecovery() throws {
        let data = defaults(), old = alarm()
        data.set(Data("bad-json".utf8), forKey: "jarvis.savedAlarms.v2")
        data.set(try JSONEncoder().encode([old]), forKey: "jarvis.savedAlarms.v2.backup")
        let store = AlarmStore(defaults: data)
        XCTAssertEqual(store.alarms, [old]); XCTAssertTrue(store.canRestore)
        XCTAssertThrowsError(try store.upsert(alarm()))
        XCTAssertThrowsError(try store.restore(confirmed: false))
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        XCTAssertThrowsError(try store.restore(confirmed: true))
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        try store.restore(confirmed: true)
        XCTAssertEqual(AlarmStore(defaults: data).alarms, [old])
        XCTAssertNotNil(data.data(forKey: "jarvis.savedAlarms.v2"))
    }
    func testCorruptDataWithoutBackupCannotBeOverwritten() {
        let data = defaults()
        data.set(Data("malformed".utf8), forKey: "jarvis.calendar.events.v1")
        let store = JarvisCalendarStore(defaults: data)
        XCTAssertNotNil(store.storageIssue)
        XCTAssertThrowsError(try store.upsert(event("새 일정")))
        XCTAssertEqual(data.data(forKey: "jarvis.calendar.events.v1"), Data("malformed".utf8))
    }
    func testMissingPrimaryWithBackupIsReadOnlyRatherThanEmpty() throws {
        let data = defaults(), old = alarm()
        data.set(try JSONEncoder().encode([old]), forKey: "jarvis.savedAlarms.v2.backup")
        let store = AlarmStore(defaults: data)
        XCTAssertEqual(store.alarms, [old]); XCTAssertNotNil(store.storageIssue)
        XCTAssertThrowsError(try store.upsert(alarm()))
    }
    func testAtomicFilesMigrateLegacyDataAndReload() throws {
        let data = defaults(), old = alarm()
        data.set(try JSONEncoder().encode([old]), forKey: "alarms")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("alarms.json")
        let persistence = RecordPersistence<JarvisAlarmRecord>(defaults: data, key: "alarms", fileURL: url)
        XCTAssertEqual(persistence.load(), [old])
        try persistence.save([old])
        XCTAssertEqual(RecordPersistence<JarvisAlarmRecord>(defaults: data, key: "alarms", fileURL: url).load(), [old])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path))
    }
    private final class Backend {
        var installed: [UUID: JarvisAlarmRecord] = [:]
        var failNew = false
        var failRollback = false
        var installCount = 0
        func install(_ record: JarvisAlarmRecord) throws {
            installCount += 1
            if (failNew && record.label == "새") || (failRollback && record.label == "기존") { throw URLError(.cannotConnectToHost) }
            installed[record.id] = record
        }
        func cancel(_ record: JarvisAlarmRecord) { installed.removeValue(forKey: record.id) }
        func verify(_ record: JarvisAlarmRecord) -> Bool {
            record.isEnabled ? installed[record.id] == record : installed[record.id] == nil
        }
    }
    private func service(store: AlarmStore, backend: Backend, journal: RecordPersistence<AlarmPendingChange>) -> AlarmService {
        AlarmService(store: store, journal: journal, install: { try backend.install($0) },
                     cancel: { backend.cancel($0) }, verify: { backend.verify($0) })
    }
    func testAlarmFailedReplacementRestoresOldReservationAndData() async throws {
        let store = AlarmStore(defaults: defaults()), old = alarm(), backend = Backend()
        try store.upsert(old); backend.installed[old.id] = old; backend.failNew = true
        let journal = RecordPersistence<AlarmPendingChange>(defaults: defaults(), key: "journal")
        let service = service(store: store, backend: backend, journal: journal)
        do { _ = try await service.update(id: old.id, label: "새"); XCTFail("must fail") } catch {}
        XCTAssertEqual(backend.installed[old.id], old); XCTAssertEqual(store.alarms, [old])
        XCTAssertTrue(journal.load().isEmpty)
    }
    func testUncertainRollbackSurvivesRestartAndExplicitRepair() async throws {
        let store = AlarmStore(defaults: defaults()), old = alarm(), backend = Backend()
        try store.upsert(old); backend.installed[old.id] = old; backend.failNew = true; backend.failRollback = true
        let journal = RecordPersistence<AlarmPendingChange>(defaults: defaults(), key: "journal")
        let first = service(store: store, backend: backend, journal: journal)
        do { _ = try await first.update(id: old.id, label: "새"); XCTFail() } catch {}
        XCTAssertEqual(journal.load().count, 1)
        let restarted = service(store: store, backend: backend, journal: journal)
        XCTAssertNotNil(restarted.statusMessage)
        do { try await restarted.delete(id: old.id); XCTFail() } catch {}
        backend.failRollback = false
        do { try await restarted.recoverPendingChange(confirmed: false); XCTFail() } catch {}
        try await restarted.recoverPendingChange(confirmed: true)
        XCTAssertEqual(backend.installed[old.id], old); XCTAssertTrue(journal.load().isEmpty)
    }
    func testAlarmUIServiceCannotBypassEmergencyLock() async throws {
        let store = AlarmStore(defaults: defaults()), backend = Backend(), old = alarm()
        try store.upsert(old); backend.installed[old.id] = old
        let service = service(store: store, backend: backend,
            journal: RecordPersistence(defaults: defaults(), key: "journal"))
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        do { try await service.deleteAll(confirmed: true); XCTFail() } catch {}
        do { try await service.setEnabled(false, id: old.id); XCTFail() } catch {}
        XCTAssertEqual(backend.installed[old.id], old); XCTAssertEqual(store.alarms, [old])
    }
    func testLockAfterSystemChangeRestoresExactPreAuthorizedAlarm() async throws {
        let store = AlarmStore(defaults: defaults()), backend = Backend(), old = alarm()
        try store.upsert(old); backend.installed[old.id] = old
        let journal = RecordPersistence<AlarmPendingChange>(defaults: defaults(), key: "journal")
        let service = AlarmService(store: store, journal: journal, install: { record in
            try backend.install(record)
            if record.label == "새" { UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey) }
        }, cancel: { backend.cancel($0) }, verify: { backend.verify($0) })
        do { _ = try await service.update(id: old.id, label: "새"); XCTFail() } catch {}
        XCTAssertEqual(backend.installed[old.id], old)
        XCTAssertEqual(store.alarms, [old]); XCTAssertTrue(journal.load().isEmpty)
    }
    func testAlarmStaleEditorSnapshotCannotOverwriteNewerRecord() async throws {
        let store = AlarmStore(defaults: defaults()), backend = Backend(), old = alarm()
        try store.upsert(old)
        var current = old; current.label = "다른 변경"; try store.upsert(current)
        let service = service(store: store, backend: backend, journal: RecordPersistence(defaults: defaults(), key: "journal"))
        do { _ = try await service.update(id: old.id, label: "새", expected: old); XCTFail() } catch {}
        XCTAssertEqual(store.alarms, [current]); XCTAssertEqual(backend.installCount, 0)
    }
    func testCancellationDuringAlarmReplacementRestoresPreviousReservation() async throws {
        let store = AlarmStore(defaults: defaults()), backend = Backend(), old = alarm()
        try store.upsert(old); backend.installed[old.id] = old
        var changing = false
        let journal = RecordPersistence<AlarmPendingChange>(defaults: defaults(), key: "journal")
        let service = AlarmService(store: store, journal: journal, install: { record in
            try backend.install(record)
            if record.label == "새" { changing = true; try await Task.sleep(for: .seconds(1)) }
        }, cancel: { backend.cancel($0) }, verify: { backend.verify($0) })
        let task = Task { @MainActor in try await service.update(id: old.id, label: "새") }
        let deadline = Date().addingTimeInterval(3)
        while !changing, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(changing); task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
        XCTAssertEqual(backend.installed[old.id], old)
        XCTAssertEqual(store.alarms, [old]); XCTAssertTrue(journal.load().isEmpty)
    }
    func testCalendarFailedEditRestoresExactOldVersionAndMarksPending() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), old = event("기존")
        try store.upsert(old)
        let snapshot = store.event(id: old.id)!
        var next = snapshot; next.title = "변경"
        let result = await CalendarDataExecution.save(next, store: store, expectedUpdatedAt: snapshot.updatedAt,
            confirmed: true, schedule: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(result.status, .unverifiable)
        XCTAssertEqual(store.event(id: old.id), snapshot); XCTAssertNotNil(store.notificationIssue)
    }
    func testCalendarRejectsStaleApprovalAndLockWithoutCallingNotificationTool() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), old = event("기존")
        try store.upsert(old)
        var ran = false
        let stale = await CalendarDataExecution.save(old, store: store, expectedUpdatedAt: .distantPast,
            confirmed: true, schedule: { _ in ran = true })
        XCTAssertEqual(stale.status, .failed)
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        let locked = await CalendarDataExecution.deleteAll(store: store, confirmed: true)
        XCTAssertEqual(locked.status, .failed); XCTAssertFalse(ran); XCTAssertEqual(store.events.count, 1)
    }
    func testCalendarPlannerSkipsOldEventsSortsByAlertAndIncludesFarFuture() throws {
        let store = JarvisCalendarStore(defaults: defaults())
        var events = (0..<50).map { event("과거 \($0)", after: -86_400 * Double($0 + 1)) }
        let late = event("나중", after: 20_000)
        var earlyAlert = event("사전 알림", after: 21_000); earlyAlert.reminderMinutesBefore = 120
        let distant = event("미래", after: 86_400 * 500)
        events += [late, earlyAlert, distant]
        let planned = JarvisCalendarNotificationService.plannedOccurrences(events: events, store: store, now: Date())
        XCTAssertEqual(planned.map(\.id), [earlyAlert.id, late.id, distant.id])
    }
    private final class Notifications: NotificationReservationBackend {
        var requests: [String: UNNotificationRequest] = [:]
        var failID: String?
        var deny = false
        var added = 0
        func pending() async -> [UNNotificationRequest] { Array(requests.values) }
        func add(_ request: UNNotificationRequest) async throws {
            if request.identifier == failID { throw URLError(.cannotConnectToHost) }
            added += 1; requests[request.identifier] = request
        }
        func remove(_ ids: [String]) { ids.forEach { requests.removeValue(forKey: $0) } }
        func authorize(requestIfNeeded: Bool) async throws { if deny { throw JarvisCalendarNotificationError.permissionDenied } }
    }
    private func notification(_ id: String, body: String = "기존 알림") -> UNNotificationRequest {
        let content = UNMutableNotificationContent(); content.body = body
        return .init(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false))
    }
    func testCalendarRollingBudgetNeverEvictsAlarmRequests() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), backend = Notifications()
        for index in 0..<52 { let request = notification("jarvis.alarm.\(index)"); backend.requests[request.identifier] = request }
        let events = (0..<10).map { event("미래 \($0)", after: 3_600 + Double($0) * 600) }
        let service = JarvisCalendarNotificationService(store: store, backend: backend, render: { _, _ in nil })
        try await service.rebuild(events: events)
        XCTAssertEqual(backend.requests.count, 56)
        XCTAssertEqual(backend.requests.keys.filter { $0.hasPrefix("jarvis.alarm.") }.count, 52)
        XCTAssertNotNil(service.statusMessage); XCTAssertNotNil(service.coverageEnd)
    }
    func testNotificationFailureRestoresOldRequestsWithoutTouchingAlarms() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), backend = Notifications()
        let old = notification("jarvis.calendar.old"), alarm = notification("jarvis.alarm.keep")
        backend.requests = [old.identifier: old, alarm.identifier: alarm]
        let next = event("새 일정")
        backend.failID = "jarvis.calendar.\(next.id.uuidString).\(Int(next.startDate.timeIntervalSince1970))"
        let service = JarvisCalendarNotificationService(store: store, backend: backend, render: { _, _ in nil })
        do { try await service.rebuild(events: [next]); XCTFail() } catch {}
        XCTAssertEqual(Set(backend.requests.keys), [old.identifier, alarm.identifier])
        XCTAssertTrue(backend.requests[old.identifier]!.content.isEqual(old.content))
        XCTAssertNotNil(service.statusMessage)
    }
    func testPermissionFailureDoesNotRemoveExistingNotifications() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), backend = Notifications()
        let old = notification("jarvis.calendar.old")
        backend.requests[old.identifier] = old; backend.deny = true
        let service = JarvisCalendarNotificationService(store: store, backend: backend, render: { _, _ in nil })
        do { try await service.rebuild(events: [event("다음")]); XCTFail() } catch {}
        XCTAssertEqual(backend.requests.count, 1); XCTAssertEqual(backend.added, 0)
    }
    func testLockDuringPreparationKeepsPreviousReservations() async throws {
        let store = JarvisCalendarStore(defaults: defaults()), backend = Notifications()
        let old = notification("jarvis.calendar.old"); backend.requests[old.identifier] = old
        let service = JarvisCalendarNotificationService(store: store, backend: backend, render: { _, _ in
            UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey); return nil
        })
        do { try await service.rebuild(events: [event("다음")]); XCTFail() } catch {}
        XCTAssertNotNil(backend.requests[old.identifier])
    }
}

@MainActor
final class PersonalAssistantProgressTests: XCTestCase {
    private final class Credentials: OpenAICredentialStoring {
        var value = ""; func load() -> String { value }
        func save(_ key: String) -> Bool { value = key; return true }
        func delete() -> Bool { value = ""; return true }
    }
    private actor Transport: OpenAIResponding {
        var calls = 0
        let answer: String
        let delay: Bool
        init(answer: String = "수정한 테스트 답변입니다.", delay: Bool = false) { self.answer = answer; self.delay = delay }
        func generate(apiKey: String, instructions: String, input: String, maximumOutputTokens: Int) async throws -> OpenAITextResponse {
            calls += 1
            if delay { try await Task.sleep(for: .milliseconds(100)) }
            return .init(text: answer, inputTokens: 10, outputTokens: 5)
        }
    }
    private struct SemanticPlacesClient: AIClient {
        func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? {
            .init(capabilityID: .nearbyPlaces, primaryArgument: "market", secondaryArgument: "search", confidence: 0.95)
        }
        func reply(to text: String, context: AIConversationContext?) async throws -> String { "테스트 답변" }
        func summarizeWebSearch(query: String, answer: String) async throws -> String { answer }
    }
    private final class Navigation: NavigationServing {
        var opened: [PreparedNavigation] = []
        var searched: [String] = []
        var modes: [NavigationTravelMode] = []
        var nearbyResult: ToolExecutionResult<[NearbyPlace]> = .succeeded([
            .init(id: "a", name: "A마트 서초점", address: "서울 서초구", latitude: 37.50, longitude: 127.01,
                  sourceLatitude: 37.49, sourceLongitude: 127.0, distance: 300),
            .init(id: "b", name: "B마트 잠실점", address: "서울 송파구", latitude: 37.51, longitude: 127.02,
                  sourceLatitude: 37.49, sourceLongitude: 127.0, distance: 400)
        ])
        func nearby(category: NearbyPlaceCategory) async -> ToolExecutionResult<[NearbyPlace]> { nearbyResult }
        func search(destination: String) async throws -> [NavigationSearchCandidate] { searched.append(destination); return [] }
        func isNaverMapInstalled() -> Bool { true }
        func open(_ route: PreparedNavigation, mode: NavigationTravelMode) async -> ToolExecutionResult<NavigationLaunchResult> {
            opened.append(route); modes.append(mode); return .handedOff(.naverMap)
        }
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "jarvis.progress.tests.\(UUID())")! }
    private func setup(answer: String = "수정한 테스트 답변입니다.") -> (ImprovementReviewStore, OpenAIIntegrationStore, Transport, UserDefaults) {
        let transport = Transport(answer: answer), preferences = defaults()
        let cloud = OpenAIIntegrationStore(defaults: preferences, credentials: Credentials(), transport: transport, isLocked: { false }, audit: { _, _, _ in })
        var configuration = OpenAIConfiguration(); configuration.enabled = true
        _ = cloud.apply(configuration, key: "test-key", confirmed: true)
        let review = ImprovementReviewStore(defaults: preferences, cloud: cloud, locked: { false })
        return (review, cloud, transport, preferences)
    }
    private func send(_ text: String, to model: AssistantViewModel) async throws {
        let count = model.messages.count
        model.textInput = text; model.submitText()
        let deadline = Date().addingTimeInterval(4)
        while (model.messages.count < count + 2 || model.state == .thinking || model.state == .speaking) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.messages.count, count + 2)
    }
    private func candidate(in store: ImprovementReviewStore) -> ImprovementExample {
        store.configure(collection: true, semantic: false, confirmed: true)
        store.considerCorrection(question: "물의 화학식은?", answer: "잘못된 답변", correction: "그게 아니라 H2O야")
        let item = store.pending[0]; store.saveCandidate(item); return item
    }

    func testFiveTurnNearbyConversationOpensExactSelectedCoordinates() async throws {
        let oldLock = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        defer { UserDefaults.standard.set(oldLock, forKey: SafetyControlStore.externalActionsLockKey) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("근처 마트가 어떤 게 있어?", to: model)
        XCTAssertTrue(model.response.contains("A마트")); XCTAssertTrue(navigation.opened.isEmpty)
        try await send("두 번째 마트 영업 중이야?", to: model)
        XCTAssertTrue(model.response.contains("확인하지 못"))
        try await send("거기는 어디 있어?", to: model)
        XCTAssertTrue(model.response.contains("송파구"))
        try await send("거기로 안내해줘", to: model)
        XCTAssertTrue(model.response.contains("자가용과 대중교통"))
        try await send("자가용으로", to: model)
        XCTAssertEqual(navigation.opened.count, 1)
        XCTAssertEqual(navigation.opened.first?.destinationLongitude, 127.02)
        XCTAssertEqual(navigation.modes, [.car]); XCTAssertTrue(navigation.searched.isEmpty)
        XCTAssertFalse(model.response.contains("완료"))
    }

    func testNearbyNavigationAsksForSelectionInsteadOfGuessing() async throws {
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("근처 마트로 안내해줘", to: model)
        XCTAssertTrue(model.response.contains("어느 곳")); XCTAssertTrue(navigation.opened.isEmpty)
        try await send("거기로 자가용 안내해줘", to: model)
        XCTAssertTrue(model.response.contains("번호")); XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testTopicChangeAndCancellationDropPlaces() async throws {
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("근처 마트 찾아줘", to: model)
        try await send("지금 몇 시야?", to: model)
        try await send("거기로 안내해줘", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
        try await send("근처 마트 찾아줘", to: model)
        try await send("아냐 됐어", to: model)
        try await send("두 번째로 자가용 안내해줘", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testLockBlocksSelectedPlaceHandoff() async throws {
        let oldLock = SafetyControlStore.externalActionsLocked
        defer { UserDefaults.standard.set(oldLock, forKey: SafetyControlStore.externalActionsLockKey) }
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("근처 마트 찾아줘", to: model)
        try await send("B마트 잠실점으로 자가용 안내해줘", to: model)
        XCTAssertTrue(model.response.contains("안전 잠금")); XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testPermissionFailureIsNotReportedAsSearchSuccess() async throws {
        let navigation = Navigation(); navigation.nearbyResult = .needsPermission(message: "위치 권한을 허용해주세요.")
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("근처 마트 찾아줘", to: model)
        XCTAssertTrue(model.response.contains("권한")); XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testModelProposedNavigationRequiresConfirmationBoundToCoordinates() async throws {
        let oldLock = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        defer { UserDefaults.standard.set(oldLock, forKey: SafetyControlStore.externalActionsLockKey) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: SemanticPlacesClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("장을 볼 곳 좀 알아봐", to: model)
        try await send("두 번째로 자가용 안내해줘", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
        XCTAssertTrue(model.response.contains("승인"))
        try await send("네", to: model)
        XCTAssertEqual(navigation.opened.count, 1)
        XCTAssertEqual(navigation.opened.first?.destinationLongitude, 127.02)
        XCTAssertTrue(navigation.searched.isEmpty)
    }

    func testUnrelatedAcceptancePrefixCannotApproveNavigation() async throws {
        let oldLock = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        defer { UserDefaults.standard.set(oldLock, forKey: SafetyControlStore.externalActionsLockKey) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: SemanticPlacesClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("장을 볼 곳 좀 알아봐", to: model)
        try await send("두 번째로 자가용 안내해줘", to: model)
        try await send("실행해달라는 게 아니라 지금 몇 시야?", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
        try await send("네", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testCorrectionPrefixStartsNewCommandAndCannotLeaveOldApproval() async throws {
        let oldLock = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        defer { UserDefaults.standard.set(oldLock, forKey: SafetyControlStore.externalActionsLockKey) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: SemanticPlacesClient(), speechOutputEnabled: false, navigationService: navigation)
        try await send("장을 볼 곳 좀 알아봐", to: model)
        try await send("두 번째로 자가용 안내해줘", to: model)
        XCTAssertTrue(model.response.contains("승인"))
        try await send("아니 지금 몇 시야?", to: model)
        XCTAssertTrue(model.response.contains("시각"))
        try await send("네", to: model)
        XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testCorrectionCollectionRequiresOptInAndSave() {
        let (review, cloud, _, preferences) = setup()
        review.considerCorrection(question: "q", answer: "wrong", correction: "그게 아니라")
        XCTAssertTrue(review.pending.isEmpty)
        review.configure(collection: true, semantic: false, confirmed: false)
        XCTAssertFalse(review.collectionEnabled)
        review.configure(collection: true, semantic: false, confirmed: true)
        review.considerCorrection(question: "q", answer: "wrong", correction: "그게 아니라")
        XCTAssertEqual(review.pending.count, 1)
        let reloaded = ImprovementReviewStore(defaults: preferences, cloud: cloud, locked: { false })
        XCTAssertTrue(reloaded.pending.isEmpty); XCTAssertTrue(reloaded.examples.isEmpty)
        review.saveCandidate(review.pending[0])
        let saved = ImprovementReviewStore(defaults: preferences, cloud: cloud, locked: { false })
        XCTAssertEqual(saved.examples.count, 1)
    }

    func testOpenAICorrectionIsNotLearningUntilReviewedAndRetested() async {
        let (review, _, transport, _) = setup()
        let item = candidate(in: review)
        await review.assist(id: item.id, retest: false, confirmed: false)
        XCTAssertNil(review.examples[0].assistedAt)
        await review.assist(id: item.id, retest: false, confirmed: true)
        XCTAssertFalse(review.examples[0].verifiedImprovement)
        review.approveAnswer(id: item.id, answer: "물은 H2O입니다.")
        XCTAssertNil(review.verifiedReference(for: item.question))
        await review.assist(id: item.id, retest: true, confirmed: true)
        XCTAssertFalse(review.examples[0].verifiedImprovement)
        review.verifyRetest(id: item.id)
        XCTAssertTrue(review.examples[0].verifiedImprovement)
        XCTAssertEqual(review.verifiedReference(for: item.question), "물은 H2O입니다.")
        review.delete(item.id)
        XCTAssertNil(review.verifiedReference(for: item.question))
        let calls = await transport.calls; XCTAssertEqual(calls, 2)
    }

    func testLiveEvaluationUsesActualTransportButDoesNotAutoGrade() async {
        let (review, cloud, transport, _) = setup()
        await review.runEvaluation(confirmed: true)
        XCTAssertEqual(review.runs.count, 1)
        XCTAssertEqual(review.runs[0].observations.count, 8)
        XCTAssertEqual(review.runs[0].reviewedCount, 0)
        let calls = await transport.calls; XCTAssertEqual(calls, 13)
        XCTAssertEqual(cloud.observedResults.conversationResponses, 0)
    }

    func testDeletedCorrectionIsNotResurrectedByLateAPIResponse() async throws {
        let transport = Transport(delay: true), preferences = defaults()
        let cloud = OpenAIIntegrationStore(defaults: preferences, credentials: Credentials(), transport: transport, isLocked: { false }, audit: { _, _, _ in })
        var configuration = OpenAIConfiguration(); configuration.enabled = true
        _ = cloud.apply(configuration, key: "test-key", confirmed: true)
        let review = ImprovementReviewStore(defaults: preferences, cloud: cloud, locked: { false })
        let item = candidate(in: review)
        let task = Task { await review.assist(id: item.id, retest: false, confirmed: true) }
        while !review.busy { try await Task.sleep(for: .milliseconds(1)) }
        review.delete(item.id)
        await task.value
        XCTAssertTrue(review.examples.isEmpty)
        XCTAssertNil(review.verifiedReference(for: item.question))
    }

    func testLockedImprovementStoreBlocksCloudButAllowsDeletionAndDisable() async {
        let (_, cloud, transport, preferences) = setup()
        let review = ImprovementReviewStore(defaults: preferences, cloud: cloud, locked: { true })
        review.configure(collection: true, semantic: true, confirmed: true)
        XCTAssertFalse(review.collectionEnabled)
        await review.runEvaluation(confirmed: true)
        let count = await transport.calls; XCTAssertEqual(count, 0)
        review.disable(); review.deleteAll()
        XCTAssertFalse(review.semanticAssistanceEnabled)
    }

    func testSemanticFallbackIsOptInAndRegistryValidated() async throws {
        let json = #"{"capabilityID":"nearbyPlaces","primaryArgument":"market","secondaryArgument":"search","confidence":0.92}"#
        let (review, cloud, transport, _) = setup(answer: json)
        let client = OpenAIHybridAIClient(local: MockAIClient(), store: cloud, review: review)
        let context = SemanticResolutionContext(summary: nil, recentUserTexts: [])
        let off = try await client.interpretCommand("장을 볼 곳 좀 알아봐", capabilities: CapabilityRegistry().promptDescription, context: context)
        XCTAssertNil(off)
        review.configure(collection: false, semantic: true, confirmed: true)
        let result = await AgentOrchestrator().resolve("장을 볼 곳 좀 알아봐", previousIntent: nil, context: context, semanticResolver: client)
        XCTAssertEqual(result, .intent(.init(intent: .nearbyPlaces(category: .market, navigate: false, mode: nil), source: .semanticModel)))
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
}

@MainActor
final class PersonalWorkflowAppTests: XCTestCase {
    private actor MemoryClient: AIClient {
        var seen: [[String]] = []
        func interpretCommand(_ text: String, capabilities: String, context: SemanticResolutionContext) async throws -> SemanticIntentCandidate? { nil }
        func reply(to text: String, context: AIConversationContext?) async throws -> String {
            seen.append(context?.longTermMemories ?? [])
            try? await Task.sleep(for: .milliseconds(150))
            return (context?.longTermMemories.isEmpty ?? true) ? "참고한 기억이 없습니다." : "기억을 참고한 답변입니다."
        }
        func summarizeWebSearch(query: String, answer: String) async throws -> String { answer }
    }
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "jarvis.workflow.tests.\(UUID())")! }
    private func send(_ text: String, to model: AssistantViewModel) async throws {
        let before = model.messages.count
        model.textInput = text; model.submitText()
        let deadline = Date().addingTimeInterval(3)
        while (model.messages.count < before + 2 || model.state == .thinking) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(model.messages.count, before + 2)
    }
    private func unlocked() -> Bool {
        let old = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey); return old
    }
    private func restore(_ old: Bool) { UserDefaults.standard.set(old, forKey: SafetyControlStore.externalActionsLockKey) }
    private func model(calendar: JarvisCalendarStore) -> AssistantViewModel {
        AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, calendarStore: calendar,
            scheduleCalendarEvent: { _ in }, cancelCalendarEvent: { _ in })
    }

    func testCalendarCreateConflictMoveAndDeleteThroughRealVM() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let model = model(calendar: calendar)
        try await send("내일 오후 3시 회의 일정 등록해줘", to: model)
        XCTAssertTrue(calendar.events.isEmpty)
        XCTAssertTrue(model.response.contains("저장할까요"))
        try await send("네", to: model)
        XCTAssertEqual(calendar.events.count, 1)
        XCTAssertTrue(model.response.contains("알림을 예약"))
        try await send("내일 오후 3시 운동 일정 등록해줘", to: model)
        XCTAssertTrue(model.response.contains("겹치는 일정"))
        try await send("취소", to: model)
        XCTAssertEqual(calendar.events.count, 1)
        try await send("회의 일정을 내일 오후 4시로 옮겨줘", to: model)
        try await send("네", to: model)
        XCTAssertEqual(Calendar.current.component(.hour, from: calendar.events[0].startDate), 16)
        try await send("회의 일정 취소해줘", to: model)
        XCTAssertEqual(calendar.events.count, 1)
        try await send("네", to: model)
        XCTAssertTrue(calendar.events.isEmpty)
    }

    func testCalendarAmbiguityClarifiesAndNewTopicInvalidatesApproval() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let second = self.model(calendar: calendar)
        try await send("3시 회의 일정 등록해줘", to: second)
        XCTAssertTrue(second.response.contains("어느 날"))
        try await send("내일", to: second)
        XCTAssertTrue(second.response.contains("오전"))
        try await send("오후", to: second)
        XCTAssertTrue(second.response.contains("저장할까요"))
        try await send("지금 몇 시야?", to: second)
        try await send("네", to: second)
        XCTAssertTrue(calendar.events.isEmpty)
        second.stopAll()
    }

    func testCalendarApprovalRejectsChangedOrLockedTarget() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let second = self.model(calendar: calendar)
        try await send("내일 오후 3시 회의 일정 등록해줘", to: second)
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        try await send("네", to: second)
        XCTAssertTrue(second.response.contains("안전 잠금")); XCTAssertTrue(calendar.events.isEmpty)
        second.stopAll()
    }

    func testNotificationFailureIsReportedAsPartialCompletion() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, calendarStore: calendar,
            scheduleCalendarEvent: { _ in throw URLError(.notConnectedToInternet) }, cancelCalendarEvent: { _ in })
        try await send("내일 오후 3시 회의 일정 등록해줘", to: model)
        try await send("네", to: model)
        XCTAssertEqual(calendar.events.count, 1)
        XCTAssertTrue(model.response.contains("일정은 저장했지만"))
        XCTAssertFalse(model.response.contains("예약했습니다"))
    }

    func testCalendarTargetVersionInvalidatesOldApproval() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let second = self.model(calendar: calendar)
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        var event = try calendar.create(title: "회의", startDate: start, endDate: start.addingTimeInterval(3_600),
            isAllDay: false, isOutdoor: false, location: "", notes: "")
        try await send("회의 일정 취소해줘", to: second)
        event.notes = "확인 도중 변경"; try calendar.upsert(event)
        try await send("네", to: second)
        XCTAssertEqual(calendar.events.count, 1)
        XCTAssertTrue(second.response.contains("확인 중 일정이 변경"))
        second.stopAll()
    }

    func testMemoryConflictsAreExcludedUntilExplicitResolution() throws {
        let old = unlocked(); defer { restore(old) }
        let store = LongTermMemoryStore(defaults: defaults())
        let first = store.add("나는 매운 음식을 좋아한다", source: .explicitCommand, category: .preference)!
        let second = store.add("나는 매운 음식을 좋아하지 않는다", source: .explicitCommand, category: .preference)!
        XCTAssertEqual(store.memories.count, 2)
        XCTAssertTrue(store.relevantRecords(for: "매운 음식 좋아해").isEmpty)
        XCTAssertFalse(store.resolveConflict(keeping: first.id, removing: [second.id], confirmed: false))
        XCTAssertTrue(store.resolveConflict(keeping: first.id, removing: [second.id], confirmed: true))
        XCTAssertEqual(store.memories.map(\.id), [first.id])
        XCTAssertFalse(store.maySuggest(second.content))
    }

    func testMemoryDeletionMarkersSurviveReloadAndExplicitConsentCanRestore() {
        let old = unlocked(); defer { restore(old) }
        let preferences = defaults(), store = LongTermMemoryStore(defaults: preferences)
        let record = store.add("나는 민트 음료를 좋아한다", source: .explicitCommand)!
        XCTAssertTrue(store.delete(id: record.id))
        let reloaded = LongTermMemoryStore(defaults: preferences)
        XCTAssertFalse(reloaded.maySuggest(record.content))
        XCTAssertNil(reloaded.add(record.content, source: .repeatedConversation))
        XCTAssertTrue(reloaded.relevantRecords(for: "민트 음료").isEmpty)
        XCTAssertNotNil(reloaded.add(record.content, source: .explicitCommand))
        XCTAssertFalse(reloaded.deleteAll(confirmed: false))
        XCTAssertTrue(reloaded.deleteAll(confirmed: true))
    }

    func testMemorySensitiveWritesAndEmergencyLockNeedConsent() {
        let old = unlocked(); defer { restore(old) }
        let store = LongTermMemoryStore(defaults: defaults())
        XCTAssertNil(store.add("계좌번호는 테스트", source: .manual))
        let record = store.add("계좌번호는 테스트", source: .manual, sensitiveConfirmed: true)!
        XCTAssertFalse(store.update(id: record.id, content: "계좌번호는 변경"))
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        XCTAssertNil(store.add("나는 커피를 좋아한다", source: .explicitCommand))
        XCTAssertFalse(store.delete(id: record.id))
    }

    func testDeletedMemoryCancelsInFlightAnswerAndIsNotInNextContext() async throws {
        let old = unlocked(); defer { restore(old) }
        let store = LongTermMemoryStore(defaults: defaults()), client = MemoryClient()
        let record = store.add("나는 민트 음료를 좋아한다", source: .explicitCommand)!
        let model = AssistantViewModel(aiClient: client, speechOutputEnabled: false, memoryStore: store)
        model.textInput = "민트 음료에 대한 내 취향은?"; model.submitText()
        let deadline = Date().addingTimeInterval(3)
        while await client.seen.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.delete(id: record.id))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(model.messages.filter { $0.role == .assistant }.isEmpty)
        try await send("민트 음료에 대한 내 취향은?", to: model)
        let contexts = await client.seen
        XCTAssertFalse(contexts.first?.isEmpty ?? true)
        XCTAssertTrue(contexts.last?.isEmpty == true)
        XCTAssertTrue(model.response.contains("기억이 없습니다"))
    }

    func testMemoryPersistenceFailureRollsBackInsteadOfClaimingSuccess() {
        let old = unlocked(); defer { restore(old) }
        var writable = true
        let store = LongTermMemoryStore(defaults: defaults(), canPersist: { writable })
        let record = store.add("나는 민트 음료를 좋아한다", source: .explicitCommand)!
        writable = false
        XCTAssertFalse(store.delete(id: record.id))
        XCTAssertEqual(store.memories.map(\.id), [record.id])
        XCTAssertTrue(store.deletionMarkers.isEmpty)
        XCTAssertNil(store.add("나는 커피 음료를 좋아한다", source: .explicitCommand))
        XCTAssertNotNil(store.storageError)
    }

    func testMemoryExplanationDoesNotAttributeUnrelatedToolReplyToOldMemory() async throws {
        let old = unlocked(); defer { restore(old) }
        let store = LongTermMemoryStore(defaults: defaults()), client = MemoryClient()
        _ = store.add("나는 민트 음료를 좋아한다", source: .explicitCommand)
        let model = AssistantViewModel(aiClient: client, speechOutputEnabled: false, memoryStore: store)
        try await send("민트 음료에 대한 내 취향은?", to: model)
        try await send("지금 몇 시야?", to: model)
        try await send("왜 이렇게 답했어?", to: model)
        XCTAssertTrue(model.response.contains("참고한 장기 기억은 없습니다"))
    }

    func testWeatherAdviceRunsAutomaticallyButDisabledAndManualModesDiffer() async throws {
        let old = unlocked(); defer { restore(old) }
        for mode in ProactiveSuggestionMode.allCases {
            let settings = ProactiveSuggestionSettingsStore(defaults: defaults()); settings.mode = mode
            let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, suggestionSettings: settings,
                weatherResultOverride: { _ in (.succeeded("오늘 최고 12도, 최저 3도입니다."), .init(high: 12, low: 3, rainProbability: 80, yesterdayHigh: 20)) })
            try await send("오늘 날씨 알려줘", to: model)
            switch mode {
            case .disabled: XCTAssertNil(model.activeSuggestion); XCTAssertFalse(model.response.contains("우산"))
            case .requiresApproval: XCTAssertTrue(model.activeSuggestion?.title.contains("우산") == true)
            case .automatic: XCTAssertTrue(model.response.contains("우산")); XCTAssertTrue(model.response.contains("8도")); XCTAssertNil(model.activeSuggestion)
            }
            model.stopAll()
        }
    }

    func testSuggestionCooldownExpiryAndFeedbackHistory() {
        let settings = ProactiveSuggestionSettingsStore(defaults: defaults()), now = Date()
        settings.mode = .automatic
        let advice = ProactiveSuggestion(id: "weather.test", title: "겉옷", reason: "예보", proposedIntent: nil, observedAt: now)
        XCTAssertTrue(settings.canPresent(advice, now: now))
        settings.markPresented(advice, now: now)
        XCTAssertFalse(settings.canPresent(advice, now: now.addingTimeInterval(1)))
        let expired = ProactiveSuggestion(id: "other", title: "", reason: "", proposedIntent: nil, observedAt: now.addingTimeInterval(-400))
        XCTAssertFalse(settings.canPresent(expired, now: now))
        settings.record(advice, outcome: "helpful")
        XCTAssertEqual(settings.events.first?.outcome, "helpful")
    }

    func testOutingConnectsActualEventAndForecastButDoesNotGuessTravelTime() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        _ = try calendar.create(title: "야외 산책", startDate: start, endDate: start.addingTimeInterval(3_600),
            isAllDay: false, isOutdoor: true, location: "", notes: "")
        let settings = ProactiveSuggestionSettingsStore(defaults: defaults()); settings.mode = .requiresApproval
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, calendarStore: calendar,
            scheduleCalendarEvent: { _ in }, cancelCalendarEvent: { _ in }, suggestionSettings: settings,
            outingForecastOverride: { _, _ in "예보상 비 올 확률은 80%입니다. 우산을 챙겨주세요." })
        try await send("내일 외출 준비 도와줘", to: model)
        XCTAssertTrue(model.response.contains("야외 산책"))
        XCTAssertTrue(model.response.contains("우산"))
        XCTAssertTrue(model.response.contains("이동 시간은 확인하지 않았"))
        XCTAssertNotNil(model.activeSuggestion?.proposedIntent)
        XCTAssertEqual(calendar.events.count, 1)
        model.stopAll()
    }

    func testOutingWeatherFailureStopsBeforeReminderProposal() async throws {
        let old = unlocked(); defer { restore(old) }
        let calendar = JarvisCalendarStore(defaults: defaults())
        let start = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        _ = try calendar.create(title: "산책", startDate: start, endDate: start.addingTimeInterval(3_600),
            isAllDay: false, isOutdoor: true, location: "", notes: "")
        let settings = ProactiveSuggestionSettingsStore(defaults: defaults()); settings.mode = .automatic
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, calendarStore: calendar,
            scheduleCalendarEvent: { _ in }, cancelCalendarEvent: { _ in }, suggestionSettings: settings,
            outingForecastOverride: { _, _ in throw URLError(.notConnectedToInternet) })
        try await send("내일 외출 준비 도와줘", to: model)
        XCTAssertTrue(model.response.contains("중단"))
        XCTAssertNil(model.activeSuggestion)
        XCTAssertTrue(settings.events.isEmpty)
    }
}
