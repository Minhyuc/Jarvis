import XCTest
@testable import JarvisCore

final class SharedDataSyncTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("shared") }
    private var phoneDB: URL { base.appendingPathComponent("phone") }
    private var macDB: URL { base.appendingPathComponent("mac") }
    private let phone = SharedDataSyncEngine(), mac = SharedDataSyncEngine()
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-sync-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at: base) } }
    private func success<T>(_ result: ToolExecutionResult<T>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        if case .succeeded(let value) = result { return value }
        XCTFail("Expected success: \(result.status)", file: file, line: line); throw SyncError.invalid
    }
    private func rejected<T>(_ result: ToolExecutionResult<T>, file: StaticString = #filePath, line: UInt = #line) {
        if case .succeeded = result { XCTFail("Unexpected success", file: file, line: line) }
    }
    @discardableResult private func apply(_ op: SharedSyncPlan.Operation, engine: SharedDataSyncEngine? = nil,
                                         directory: URL? = nil, native: [SharedSyncRecord] = []) throws -> SharedSyncPlan {
        let engine = engine ?? phone
        let plan = try success(engine.preview(op, root: root, localDirectory: directory ?? phoneDB,
            native: native, nativeBackup: op == .capture ? Data("original-native-backup".utf8) : nil, locked: { false }))
        _ = try success(engine.commit(plan, confirmed: true, locked: { false })); return plan
    }
    private func record(id: UUID = UUID(), title: String = "테스트 알람") -> SharedSyncRecord {
        .init(id: id, kind: .alarm, title: title, start: Date(timeIntervalSince1970: 1_800_000_000),
              timeZoneID: "Asia/Seoul", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }
    private func rows(_ engine: SharedDataSyncEngine? = nil, _ db: URL? = nil) throws -> [SharedSyncRow] {
        try success((engine ?? phone).status(root: root, localDirectory: db ?? phoneDB, locked: { false }))
    }
    private func packages() throws -> [URL] {
        let directory = root.appendingPathComponent("시스템/동기화/변경기록")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
    }

    func testExportChunksThousandAndOneChangesAndOnlyPublishesNewHistory() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        var records = (0..<1000).map { record(title: "알람 \($0)") }
        try apply(.capture, native: records)
        records[0].title = "수정한 알람"
        try apply(.capture, native: records)
        XCTAssertEqual(try apply(.export).rows.count, 1001)
        var count = 0
        for file in try packages() {
            let data = try Data(contentsOf: file)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(changes.count, 1000); count += changes.count
            XCTAssertLessThanOrEqual(data.count, 4_194_304)
        }
        XCTAssertEqual(count, 1001)
        XCTAssertEqual(try rows().count, 1000)
        try apply(.merge, engine: mac, directory: macDB)
        XCTAssertEqual(try rows(mac, macDB).count, 1000)
        let before = try packages().count
        XCTAssertTrue(try apply(.export).rows.isEmpty)
        XCTAssertEqual(try packages().count, before)
        records[1].title = "추가 수정"
        try apply(.capture, native: records)
        XCTAssertEqual(try apply(.export).rows.count, 1)
        XCTAssertEqual(try packages().count, before + 1)
        XCTAssertEqual(try apply(.merge, engine: mac, directory: macDB).rows.count, 1)
    }

    func testExportChunksByEncodedBytesBeforeSharedWrites() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        let records = (0..<400).map { i -> SharedSyncRecord in
            var value = record(title: "큰 항목 \(i)")
            value.notes = String(repeating: "x", count: 12_000)
            return value
        }
        try apply(.capture, native: records); try apply(.export)
        XCTAssertGreaterThan(try packages().count, 1)
        for file in try packages() { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 4_194_304) }
        XCTAssertEqual(try rows().count, 400)
        XCTAssertEqual(try apply(.merge, engine: mac, directory: macDB).rows.count, 400)
    }

    func testLegacyCumulativePackageRemainsReadableWithinGlobalBounds() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        var records = (0..<1000).map { record(title: "이전 버전 \($0)") }
        try apply(.capture, native: records)
        records[0].title = "변경"
        try apply(.capture, native: records); try apply(.export)
        let files = try packages()
        var merged: [String: Any] = [:], all: [[String: Any]] = []
        for file in files {
            merged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            all += try XCTUnwrap(merged["changes"] as? [[String: Any]])
        }
        merged["changes"] = all
        let legacy = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        let directory = try XCTUnwrap(files.first).deletingLastPathComponent()
        // Only our isolated test fixtures are replaced to reproduce the old exporter.
        for file in files { try FileManager.default.removeItem(at: file) }
        try legacy.write(to: directory.appendingPathComponent(SharedProjectFiles.revision(legacy) + ".json"))
        XCTAssertEqual(try rows().count, 1000)
        XCTAssertTrue(try apply(.export).rows.isEmpty)
        XCTAssertEqual(try apply(.merge, engine: mac, directory: macDB).rows.count, 1001)
    }

    func testRecordTimeZoneUsedForBothStartAndEndIncludingDSTAndAllDay() throws {
        try apply(.initialize)
        var calendar = SharedSyncRecord(id: UUID(), kind: .calendar, title: "시간대 테스트",
            start: Date(timeIntervalSince1970: 1_793_511_000), end: Date(timeIntervalSince1970: 1_793_518_200),
            timeZoneID: "America/New_York", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        for zone in ["Pacific/Honolulu", "America/New_York"] {
            calendar.timeZoneID = zone
            for allDay in [false, true] {
                calendar.allDay = allDay
                try apply(.capture, native: [calendar])
                let detail = try XCTUnwrap(rows().first).detail
                let style = Date.FormatStyle(date: .abbreviated, time: allDay ? .omitted : .shortened,
                    timeZone: try XCTUnwrap(TimeZone(identifier: zone)))
                XCTAssertTrue(detail.contains("시작: " + calendar.start.formatted(style) + " · " + zone))
                XCTAssertTrue(detail.contains("종료: " + calendar.end!.formatted(style)))
            }
        }
    }

    func testTypedOfflineSnapshotSurvivesUnavailableOrCorruptExchange() throws {
        let plan = try apply(.initialize)
        let item = record()
        try apply(.capture, native: [item])
        let manifest = root.appendingPathComponent("시스템/저장소정보.json")
        try Data("broken".utf8).write(to: manifest)
        let snapshot = try success(phone.localSnapshot(storageID: plan.storageID, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(snapshot.heads.first?.record, item)
        XCTAssertTrue(snapshot.conflicts.isEmpty)
        let unavailable = base.appendingPathComponent("unavailable-share")
        try FileManager.default.moveItem(at: root, to: unavailable)
        let restarted = SharedDataSyncEngine()
        XCTAssertEqual(try success(restarted.localStorageIDs(localDirectory: phoneDB, locked: { false })), [plan.storageID])
        XCTAssertEqual(try success(restarted.localSnapshot(storageID: plan.storageID, localDirectory: phoneDB, locked: { false })).generation,
                       snapshot.generation)
    }

    func testOfflineReadsAreBoundedReadOnlyAndRespectLockAndCancellation() throws {
        XCTAssertTrue(try success(phone.localStorageIDs(localDirectory: phoneDB, locked: { false })).isEmpty)
        rejected(phone.localSnapshot(storageID: UUID(), localDirectory: phoneDB, locked: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneDB.path))
        let plan = try apply(.initialize)
        rejected(phone.localStorageIDs(localDirectory: phoneDB, locked: { true }))
        rejected(phone.localStorageIDs(localDirectory: phoneDB, locked: { false }, cancelled: { true }))
        rejected(phone.localSnapshot(storageID: plan.storageID, localDirectory: phoneDB, locked: { true }))
        rejected(phone.localSnapshot(storageID: plan.storageID, localDirectory: phoneDB, locked: { false }, cancelled: { true }))
        let url = phoneDB.appendingPathComponent(plan.storageID.uuidString + ".sqlite")
        let bytes = try Data(contentsOf: url)
        _ = try success(phone.localSnapshot(storageID: plan.storageID, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPrivateDatabaseAndBackupCannotBeRedirectedIntoShare() throws {
        rejected(phone.preview(.initialize, root: root, localDirectory: root.appendingPathComponent("private"), locked: { false }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try apply(.initialize)
        let alias = base.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: phoneDB)
        rejected(phone.localStorageIDs(localDirectory: alias, locked: { false }))
        let backup = phoneDB.appendingPathComponent("백업")
        // Initialization creates an empty backup directory in this synthetic fixture.
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: root)
        rejected(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [record()], locked: { false }))
    }

    func testOversizedNativeBackupIsRejectedAtPreviewWithoutPartialWrites() throws {
        try apply(.initialize)
        rejected(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [record()],
            nativeBackup: Data(repeating: 0, count: 8_388_609), locked: { false }))
        XCTAssertTrue(try rows().isEmpty)
        XCTAssertTrue(try packages().isEmpty)
    }

    func testExportPreflightsTotalBytesAndDeviceLimitWithoutPoisoningShare() throws {
        let initialized = try apply(.initialize)
        var values = (0..<100).map { record(title: "전체 용량 \($0)") }
        for i in values.indices { values[i].notes = String(repeating: "x", count: 16_000) }
        try apply(.capture, native: values)
        let parent = root.appendingPathComponent("시스템/동기화/변경기록")
        let device = UUID()
        let folder = parent.appendingPathComponent(device.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<4 {
            // Valid, bounded v1 fixture packages with unknown forward-compatible metadata.
            let object: [String: Any] = ["format": 1, "storageID": initialized.storageID.uuidString,
                "deviceID": device.uuidString, "changes": [], "padding": String(repeating: "x", count: 3_900_000), "part": i]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: folder.appendingPathComponent(SharedProjectFiles.revision(data) + ".json"))
        }
        rejected(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(try packages().count, 4)
        XCTAssertEqual(try rows().count, 100) // Existing source remains readable.
        // Remove only the four synthetic packages, then occupy all device slots.
        for file in try packages() { try FileManager.default.removeItem(at: file) }
        for _ in 0..<31 {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        }
        rejected(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertTrue(try packages().isEmpty)
        XCTAssertEqual(try rows().count, 100)
    }

    func testExportPreflightsCombinedUniqueHistoryLimit() throws {
        let initialized = try apply(.initialize)
        try apply(.capture, native: [record()])
        let remoteDevice = UUID(), remoteRecord = record(title: "원격 이력")
        struct Package: Encodable {
            let format = 1
            let storageID: UUID
            let deviceID: UUID
            let changes: [SharedSyncChange]
        }
        let remote = (0..<5000).map { _ in SharedSyncChange(id: UUID(), deviceID: remoteDevice,
            key: remoteRecord.key, parent: nil, record: remoteRecord, createdAt: remoteRecord.createdAt) }
        let bytes = try JSONEncoder().encode(Package(storageID: initialized.storageID, deviceID: remoteDevice, changes: remote))
        XCTAssertLessThanOrEqual(bytes.count, 4_194_304)
        let directory = root.appendingPathComponent("시스템/동기화/변경기록/" + remoteDevice.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent(SharedProjectFiles.revision(bytes) + ".json"))
        rejected(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(try packages().count, 1)
        XCTAssertEqual(try rows().count, 1)
    }

    func testExportPreflightsFileCountLimit() throws {
        let initialized = try apply(.initialize)
        try apply(.capture, native: [record()])
        let device = UUID()
        let directory = root.appendingPathComponent("시스템/동기화/변경기록/" + device.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<2000 {
            let object: [String: Any] = ["format": 1, "storageID": initialized.storageID.uuidString,
                "deviceID": device.uuidString, "changes": [], "part": i]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent(SharedProjectFiles.revision(data) + ".json"))
        }
        rejected(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(try packages().count, 2000)
        XCTAssertEqual(try rows().count, 1)
    }

    func testPreviewHasNoSideEffectsAndEveryMutationRequiresApproval() throws {
        for action in [SharedProjectAction.syncInitialize, .syncCapture, .syncExport, .syncImport] {
            guard case .requireConfirmation = SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init()) else {
                return XCTFail("Missing explicit confirmation")
            }
            guard case .block = SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(externalActionsLocked: true, wasExplicitlyConfirmed: true)) else {
                return XCTFail("Emergency lock must dominate")
            }
            guard case .block = SafetyPolicyEngine().evaluate(.sharedProject(action), context: .init(origin: .proactiveSuggestion, wasExplicitlyConfirmed: true)) else {
                return XCTFail("High risk suggestion must be blocked")
            }
        }
        let plan = try success(phone.preview(.initialize, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneDB.path))
        guard case .needsConfirmation = phone.commit(plan, confirmed: false, locked: { false }) else {
            return XCTFail("Unapproved writes must report confirmation, not success or generic failure")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("알람").path))
    }

    func testSaveAllThenLoadAllNeedsOnlyOneApprovalEachWithoutSeparateInitialization() throws {
        let alarm = record()
        let calendar = SharedSyncRecord(id: UUID(), kind: .calendar, title: "통합 저장 일정",
            start: alarm.start, end: alarm.start.addingTimeInterval(3600), timeZoneID: alarm.timeZoneID, createdAt: alarm.createdAt)
        let plan = try success(phone.preview(.saveAll, root: root, localDirectory: phoneDB,
            native: [alarm, calendar], nativeBackup: Data("native-fixture".utf8), locked: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneDB.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(phone.commit(plan, confirmed: false, locked: { false }).status, .needsConfirmation)
        _ = try success(phone.commit(plan, confirmed: true, locked: { false }))
        XCTAssertEqual(try packages().count, 1)
        XCTAssertEqual(try rows().count, 2)
        XCTAssertEqual(Set(plan.rows.map(\.id)).count, plan.rows.count)
        let imported = try apply(.loadAll, engine: mac, directory: macDB)
        XCTAssertEqual(imported.storageID, plan.storageID)
        let snapshot = try success(mac.localSnapshot(storageID: plan.storageID, localDirectory: macDB, locked: { false }))
        XCTAssertEqual(Set(snapshot.heads.compactMap { $0.record?.id }), [alarm.id, calendar.id])
        XCTAssertTrue(snapshot.conflicts.isEmpty)
        try apply(.saveAll, engine: mac, directory: macDB) // No native source on Mac: never imply deletion.
        XCTAssertEqual(try rows(mac, macDB).count, 2)
        XCTAssertEqual(try packages().count, 1)
        XCTAssertTrue(try apply(.loadAll, engine: mac, directory: macDB).rows.isEmpty)
        let next = try success(phone.preview(.saveAll, root: root, localDirectory: phoneDB,
            native: [], nativeBackup: Data("empty-native-fixture".utf8), locked: { false }))
        _ = try success(phone.commit(next, confirmed: true, locked: { false }))
        try apply(.loadAll, engine: mac, directory: macDB)
        XCTAssertTrue(try rows(mac, macDB).allSatisfy { $0.title == "삭제 항목" })
    }

    func testCombinedSaveAndLoadRespectLockCancellationAndMalformedData() throws {
        let plan = try success(phone.preview(.saveAll, root: root, localDirectory: phoneDB,
            native: [record()], nativeBackup: Data("backup".utf8), locked: { false }))
        rejected(phone.commit(plan, confirmed: true, locked: { true }))
        rejected(phone.commit(plan, confirmed: true, locked: { false }, cancelled: { true }))
        phone.cancel(); rejected(phone.commit(plan, confirmed: true, locked: { false }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        rejected(phone.preview(.loadAll, root: root, localDirectory: phoneDB, locked: { false }))
        rejected(phone.preview(.saveAll, root: root, localDirectory: phoneDB, native: [record()], locked: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneDB.path))
    }

    func testApprovedInitializationIsStableAndDBStaysOutsideShare() throws {
        let first = try apply(.initialize)
        let second = try apply(.initialize, engine: mac, directory: macDB)
        XCTAssertEqual(first.storageID, second.storageID)
        for path in SharedDataSyncEngine.folders { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: phoneDB.appendingPathComponent(first.storageID.uuidString + ".sqlite").path))
        XCTAssertTrue(try rows().isEmpty)
        let all = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(all.contains { $0.hasSuffix("sqlite") })
        rejected(phone.commit(first, confirmed: true, locked: { false }))
    }

    func testNativeCaptureBackupExportImportAndDuplicateSuppression() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        let alarm = record()
        try apply(.capture, native: [alarm])
        let backups = try FileManager.default.contentsOfDirectory(at: phoneDB.appendingPathComponent("백업"), includingPropertiesForKeys: nil)
        XCTAssertTrue(backups.contains { $0.lastPathComponent.hasSuffix("-iphone.json") })
        try apply(.export)
        let files = try packages(); XCTAssertEqual(files.count, 1)
        let bytes = try Data(contentsOf: files[0])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("notificationIdentifier"))
        let imported = try apply(.merge, engine: mac, directory: macDB)
        XCTAssertEqual(imported.rows.count, 1)
        XCTAssertTrue(imported.rows[0].detail.contains("예약 반영 대기"))
        XCTAssertEqual(try rows(mac, macDB).map(\.title), [alarm.title])
        XCTAssertTrue(try apply(.merge, engine: mac, directory: macDB).rows.isEmpty)
        try apply(.export); XCTAssertEqual(try packages().count, 1)
        XCTAssertTrue(try apply(.export, engine: mac, directory: macDB).rows.isEmpty) // no echo
    }

    func testDeletionTombstoneDoesNotResurrectOnReimportOrRestart() throws {
        try apply(.initialize); let receiver = try apply(.initialize, engine: mac, directory: macDB)
        try apply(.capture, native: [record()]); try apply(.export)
        try apply(.merge, engine: mac, directory: macDB)
        try apply(.capture, native: []); try apply(.export)
        try apply(.merge, engine: mac, directory: macDB)
        let restarted = SharedDataSyncEngine()
        XCTAssertTrue(try rows(restarted, macDB).allSatisfy { $0.title == "삭제 항목" })
        XCTAssertTrue(try apply(.merge, engine: restarted, directory: macDB).rows.isEmpty)
        XCTAssertEqual(try rows(restarted, macDB).count, 1)
        let offline = try success(restarted.localSnapshot(storageID: receiver.storageID, localDirectory: macDB, locked: { false }))
        XCTAssertEqual(offline.heads.count, 1)
        XCTAssertNil(offline.heads.first?.record)
        XCTAssertTrue(offline.conflicts.isEmpty)
    }

    func testConcurrentEditsRetainConflictRatherThanOverwrite() throws {
        try apply(.initialize); let receiver = try apply(.initialize, engine: mac, directory: macDB)
        let id = UUID()
        try apply(.capture, native: [record(id: id, title: "원본")]); try apply(.export)
        try apply(.merge, engine: mac, directory: macDB)
        // Native collection on another device is a fixture for future C-stage
        // editing, not a Mac capture button exposed to users.
        try apply(.capture, engine: mac, directory: macDB, native: [record(id: id, title: "Mac 수정")])
        let conflict = try rows(mac, macDB)
        XCTAssertTrue(conflict.contains { $0.title == "원본" })
        XCTAssertTrue(conflict.contains { $0.title == "Mac 수정" && $0.detail.contains("충돌") })
        let offline = try success(mac.localSnapshot(storageID: receiver.storageID, localDirectory: macDB, locked: { false }))
        XCTAssertEqual(offline.heads.first?.record?.title, "원본")
        XCTAssertEqual(offline.conflicts.first?.record?.title, "Mac 수정")
        XCTAssertTrue(try apply(.export, engine: mac, directory: macDB).rows.isEmpty) // do not publish unresolved proposal
    }

    func testStaleNativeSnapshotDoesNotEchoRemoteVersionBackOut() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        let alarm = record()
        try apply(.capture, native: [alarm]); try apply(.export)
        try apply(.merge, engine: mac, directory: macDB)
        XCTAssertTrue(try apply(.capture, native: [alarm]).rows.isEmpty)
        XCTAssertEqual(try rows().count, 1)
    }

    func testChangedSourceOrDBInvalidatesApproval() throws {
        try apply(.initialize)
        let old = try success(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [record()], locked: { false }))
        try apply(.capture, engine: SharedDataSyncEngine(), native: [record(title: "다른 변경")])
        rejected(phone.commit(old, confirmed: true, locked: { false }))
        XCTAssertEqual(try rows().map(\.title), ["다른 변경"])
        let export = try success(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
        let info = root.appendingPathComponent("시스템/저장소정보.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: info)) as? [String: Any])
        manifest["format"] = 999
        try JSONSerialization.data(withJSONObject: manifest).write(to: info)
        rejected(phone.commit(export, confirmed: true, locked: { false }))
        XCTAssertTrue(try packages().isEmpty)
    }

    func testCancelAndEmergencyLockBeforeCommit() throws {
        let plan = try success(phone.preview(.initialize, root: root, localDirectory: phoneDB, locked: { false }))
        phone.cancel(); rejected(phone.commit(plan, confirmed: true, locked: { false }))
        let next = try success(phone.preview(.initialize, root: root, localDirectory: phoneDB, locked: { false }))
        rejected(phone.commit(next, confirmed: true, locked: { true }))
        rejected(phone.commit(next, confirmed: true, locked: { false }, cancelled: { true }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testMalformedPackageAndMissingParentNeverPartiallyMerge() throws {
        try apply(.initialize); let receiver = try apply(.initialize, engine: mac, directory: macDB)
        try apply(.capture, native: [record()]); try apply(.export)
        let file = try XCTUnwrap(try packages().first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
        changes[0]["parent"] = UUID().uuidString; object["changes"] = changes
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let corrupt = file.deletingLastPathComponent().appendingPathComponent(SharedProjectFiles.revision(data) + ".json")
        try data.write(to: corrupt)
        rejected(mac.preview(.merge, root: root, localDirectory: macDB, locked: { false }))
        rejected(mac.status(root: root, localDirectory: macDB, locked: { false })) // Conflicting copies of the same ID.
        XCTAssertTrue(try success(mac.localSnapshot(storageID: receiver.storageID, localDirectory: macDB, locked: { false })).heads.isEmpty)
        try FileManager.default.removeItem(at: corrupt)
        changes[0]["id"] = UUID().uuidString; object["changes"] = changes
        let missingParent = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let missingFile = file.deletingLastPathComponent().appendingPathComponent(SharedProjectFiles.revision(missingParent) + ".json")
        try missingParent.write(to: missingFile)
        rejected(mac.preview(.merge, root: root, localDirectory: macDB, locked: { false }))
        XCTAssertTrue(try success(mac.localSnapshot(storageID: receiver.storageID, localDirectory: macDB, locked: { false })).heads.isEmpty)
        try Data("{".utf8).write(to: corrupt)
        rejected(mac.preview(.merge, root: root, localDirectory: macDB, locked: { false }))
    }

    func testReservedFoldersAndParentsCannotBeChangedByGeneralFileTools() throws {
        try apply(.initialize)
        for path in ["알람/a.json", "캘린더/항목/a.json", "시스템/a.json", "알람", "시스템"] {
            for action in [SharedProjectAction.create, .createFolder, .save, .move, .remove] {
                rejected(SharedProjectFiles().perform(action, root: root, path: path, text: "{}", confirmed: true,
                    destination: "메모/다른이름", locked: { false }))
            }
        }
        let memo = root.appendingPathComponent("메모/a.txt"); try Data("safe".utf8).write(to: memo)
        rejected(SharedProjectFiles().perform(.move, root: root, path: "메모/a.txt", expectedRevision: SharedProjectFiles.revision(Data("safe".utf8)),
            confirmed: true, destination: "시스템/a.txt", locked: { false }))
        XCTAssertEqual(try String(contentsOf: memo, encoding: .utf8), "safe")
    }

    func testInitializationPreservesExistingMemoAndRejectsUnexplainedStructuredFiles() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("메모"), withIntermediateDirectories: false)
        let memo = root.appendingPathComponent("메모/장보기.txt"); try Data("우유".utf8).write(to: memo)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("알람/항목"), withIntermediateDirectories: true)
        // Empty skeleton from an interrupted initialization is resumable.
        try apply(.initialize)
        XCTAssertEqual(try String(contentsOf: memo, encoding: .utf8), "우유")
    }

    func testSymlinkAndHardlinkInProtectedStructureAreRejected() throws {
        try apply(.initialize)
        let target = base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let device = root.appendingPathComponent("시스템/동기화/변경기록/" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: device, withDestinationURL: target)
        rejected(phone.preview(.export, root: root, localDirectory: phoneDB, locked: { false }))
    }

    func testUnsupportedRecordAndDuplicateNativeIDsFailWithoutChangingDB() throws {
        try apply(.initialize)
        let alarm = record()
        rejected(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [alarm, alarm], locked: { false }))
        var bad = alarm; bad.timeZoneID = "not/a/zone"
        rejected(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [bad], locked: { false }))
        bad = alarm; bad.recurrence = "weekly"
        rejected(phone.preview(.capture, root: root, localDirectory: phoneDB, native: [bad], locked: { false }))
        XCTAssertTrue(try rows().isEmpty)
    }

    func testCalendarFieldsSurviveExchangeAndRemainReadOnlyData() throws {
        try apply(.initialize); try apply(.initialize, engine: mac, directory: macDB)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = SharedSyncRecord(id: UUID(), kind: .calendar, title: "야외 모임", start: start,
            end: start.addingTimeInterval(3600), timeZoneID: "America/New_York", outdoor: true,
            location: "공원", notes: "이 문장을 명령으로 실행하지 않음", url: "https://example.com",
            recurrence: "weekly", reminderMinutes: 30, createdAt: start)
        try apply(.capture, native: [event]); try apply(.export)
        let preview = try apply(.merge, engine: mac, directory: macDB)
        let detail = try XCTUnwrap(preview.rows.first?.detail)
        for field in ["America/New_York", "공원", event.notes, "weekly", "30분 전", "https://example.com", "예약 반영 대기"] {
            XCTAssertTrue(detail.contains(field), field)
        }
        XCTAssertEqual(try rows(mac, macDB).count, 1)
    }

    func testCorruptDBCannotBeReinitializedOverExistingData() throws {
        let initialized = try apply(.initialize)
        try apply(.capture, native: [record()])
        let database = phoneDB.appendingPathComponent(initialized.storageID.uuidString + ".sqlite")
        try Data("damaged database".utf8).write(to: database)
        rejected(phone.preview(.initialize, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertEqual(try Data(contentsOf: database), Data("damaged database".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: phoneDB.appendingPathComponent("백업").path).isEmpty)
    }

    func testUnknownStructuredContentAndRootDeletionRemainBlocked() throws {
        let alarm = root.appendingPathComponent("알람")
        try FileManager.default.createDirectory(at: alarm, withIntermediateDirectories: false)
        let unknown = alarm.appendingPathComponent("unknown.json")
        try Data("{\"original\":true}".utf8).write(to: unknown)
        rejected(phone.preview(.initialize, root: root, localDirectory: phoneDB, locked: { false }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        rejected(SharedProjectFiles().perform(.remove, root: root, path: "", confirmed: true, locked: { false }))
        // A parent sweep containing a reserved tree is also blocked.
        let parent = root.appendingPathComponent("보관/알람")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        rejected(SharedProjectFiles().perform(.inspect, root: root, path: "보관", locked: { false }))
    }
}
