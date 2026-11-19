import AlarmKit
import Foundation
import SwiftUI
import UserNotifications

enum JarvisAlarmError: LocalizedError, Equatable {
    case permissionDenied
    case invalidTime
    case alarmNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "알람 권한이 필요합니다. 설정에서 JARVIS의 알람 또는 알림 권한을 허용해주세요."
        case .invalidTime:
            return "알람 시간을 확인하지 못했습니다. 예를 들어 오전 7시 또는 10분 뒤로 말씀해주세요."
        case .alarmNotFound:
            return "해당 알람을 찾지 못했습니다."
        }
    }
}

@available(iOS 26.0, *)
private struct JarvisAlarmMetadata: AlarmMetadata {
    let createdAt: Date
    let label: String
    let message: String
}

@MainActor
final class AlarmService: ObservableObject {
    static let shared = AlarmService()

    @Published private(set) var alarms: [JarvisAlarmRecord] = []
    @Published private(set) var statusMessage: String?
    var storageIssue: String? { store.storageIssue }
    var canRestore: Bool { store.canRestore }
    var pendingRecoveryDescription: String {
        guard let pending = journal.load().first else { return "기록된 미완료 변경이 없습니다. 목록과 시스템 예약을 확인해주세요." }
        if let old = pending.old { return "\(old.effectiveLabel) · \(formattedDate(old.date))의 변경 전 상태로 복구합니다." }
        return "미완료된 새 알람 ‘\(pending.next?.effectiveLabel ?? "알람")’ 예약을 제거합니다."
    }

    private let store: AlarmStore
    private let resolver = AlarmTimeResolver()
    private let speechRenderer = AlarmSpeechRenderer()
    private let journal: RecordPersistence<AlarmPendingChange>
    private let installOverride: (@MainActor (JarvisAlarmRecord) async throws -> Void)?
    private let cancelOverride: (@MainActor (JarvisAlarmRecord) async throws -> Void)?
    private let verifyOverride: (@MainActor (JarvisAlarmRecord) async throws -> Bool)?

    init(store: AlarmStore, journal: RecordPersistence<AlarmPendingChange>? = nil,
         install: (@MainActor (JarvisAlarmRecord) async throws -> Void)? = nil,
         cancel: (@MainActor (JarvisAlarmRecord) async throws -> Void)? = nil,
         verify: (@MainActor (JarvisAlarmRecord) async throws -> Bool)? = nil) {
        self.store = store
        self.journal = journal ?? RecordPersistence(defaults: .standard,
            key: "jarvis.alarm.pending-change", fileURL: store.persistence.fileURL?.appendingPathExtension("journal"))
        installOverride = install; cancelOverride = cancel; verifyOverride = verify
        alarms = store.alarms
        let pending = self.journal.load()
        if !pending.isEmpty || self.journal.blocked { statusMessage = "이전 알람 변경이 중단되었습니다. 예약 상태 확인·복구가 필요합니다." }
    }

    convenience init() {
        self.init(store: .shared)
    }

    @discardableResult
    func schedule(
        _ request: AlarmRequest,
        label: String?,
        message: String?,
        delivery: AlarmDeliveryMode
    ) async throws -> JarvisAlarmRecord {
        let date = try resolver.resolve(request)
        let resolvedMessage = message ?? defaultMessage(for: label)
        return try await schedule(
            at: date,
            label: label ?? "",
            message: delivery == .jarvisVoice
                ? personalizedVoiceMessage(resolvedMessage)
                : resolvedMessage,
            delivery: delivery,
            id: UUID(),
            createdAt: Date()
        )
    }

    @discardableResult
    func schedule(
        at date: Date,
        label: String,
        message: String,
        delivery: AlarmDeliveryMode = .system,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) async throws -> JarvisAlarmRecord {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.createAlarm)) { [self] in
            guard store.record(id: id) == nil else { throw LocalDataError.changed }
            let record = try await prepared(id: id, date: date, label: label, message: message,
                delivery: delivery, createdAt: createdAt)
            try await transact(old: nil, next: record)
            return record
        })
    }

    func refresh() async {
        let result: ToolExecutionResult<Void> = await LocalDataExecution.perform(.localData(.reconcileAlarms)) { [self] in
        try store.ensureWritable()
        guard journal.load().isEmpty, !journal.blocked else {
            throw LocalDataError.unverified("이전 변경의 복구가 필요합니다. 목록을 자동으로 덮어쓰지 않았습니다.")
        }
        var records = store.alarms
        if #available(iOS 26.0, *), records.contains(where: { $0.backend == .alarmKit }) {
            let systemAlarms = try AlarmManager.shared.alarms
            let activeIDs = Set(systemAlarms.map(\.id))
            records = records.map { record in
                guard record.backend == .alarmKit else { return record }
                var updated = record
                updated.isEnabled = activeIDs.contains(record.id)
                return updated
            }
        }

        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))
        records = records.map { record in
            guard record.backend == .localNotification,
                  let identifier = record.notificationIdentifier else { return record }
            var updated = record
            updated.isEnabled = pendingIDs.contains(identifier)
            return updated
        }
        try LocalDataExecution.check(.localData(.reconcileAlarms))
        try store.replace(with: records)
        alarms = store.alarms
        }
        switch result {
        case .succeeded: break
        case .failed(let message, _), .needsPermission(let message), .needsConfirmation(let message), .unverifiable(let message): statusMessage = message
        case .handedOff: statusMessage = "알람 예약 상태를 확인하지 못했습니다."
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID, expected: JarvisAlarmRecord? = nil) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.changeAlarm)) { [self] in
        guard var record = store.record(id: id) else { throw JarvisAlarmError.alarmNotFound }
        if let expected, expected != record { throw LocalDataError.changed }
        let old = record
        if enabled {
            while record.date <= Date() {
                record.date = Calendar.current.date(byAdding: .day, value: 1, to: record.date)
                    ?? Date().addingTimeInterval(86_400)
            }
            record = try await prepared(id: id, date: record.date, label: record.label,
                message: record.message, delivery: record.delivery, createdAt: record.createdAt)
        } else {
            record.isEnabled = false
        }
        try await transact(old: old, next: record)
        })
    }

    @discardableResult
    func update(
        id: UUID,
        date: Date? = nil,
        label: String? = nil,
        message: String? = nil,
        delivery: AlarmDeliveryMode? = nil,
        expected: JarvisAlarmRecord? = nil
    ) async throws -> JarvisAlarmRecord {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.changeAlarm)) { [self] in
        guard var record = store.record(id: id) else { throw JarvisAlarmError.alarmNotFound }
        if let expected, expected != record { throw LocalDataError.changed }
        let old = record
        let wasEnabled = record.isEnabled
        record.date = date ?? record.date
        record.label = label ?? record.label
        record.delivery = delivery ?? record.delivery
        let nextMessage = message ?? record.message
        record.message = record.delivery == .jarvisVoice
            ? personalizedVoiceMessage(nextMessage)
            : nextMessage
        record.soundFileName = nil
        record.notificationIdentifier = nil

        if wasEnabled {
            record = try await prepared(id: id, date: record.date, label: record.label,
                message: record.message, delivery: record.delivery, createdAt: record.createdAt)
        }
        try await transact(old: old, next: record)
        return record
        })
    }

    func delete(id: UUID, expected: JarvisAlarmRecord? = nil) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.deleteAlarm)) { [self] in
        guard let record = store.record(id: id) else { throw JarvisAlarmError.alarmNotFound }
        if let expected, expected != record { throw LocalDataError.changed }
        try await transact(old: record, next: nil)
        })
    }

    func deleteAll(confirmed: Bool = false) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.cancelAlarm(.all), confirmed: confirmed) { [self] in
        var deleted = 0
        for record in store.alarms {
            do {
                try LocalDataExecution.check(.cancelAlarm(.all), confirmed: confirmed)
                try await transact(old: record, next: nil)
                deleted += 1
            } catch {
                if deleted > 0 { throw LocalDataError.unverified("알람 \(deleted)개를 삭제한 뒤 중단되었습니다. 나머지 알람과 예약 상태를 확인해주세요.") }
                throw error
            }
        }
        })
    }

    /// Stops alarms that are alerting right now. AlarmKit alarms can be stopped
    /// directly. A delivered TTS notification can be removed, although iOS does
    /// not expose a guaranteed API for interrupting a custom notification sound
    /// that has already begun playing.
    func stopCurrentlyAlertingAlarms(now: Date = Date()) async throws -> [JarvisAlarmRecord] {
        try LocalDataExecution.check(.stopActiveAlarm)
        var stopped: [JarvisAlarmRecord] = []
        var persistenceFailure: String?

        if #available(iOS 26.0, *) {
            let alerting = (try? AlarmManager.shared.alarms.filter { $0.state == .alerting }) ?? []
            for alarm in alerting {
                do {
                    try AlarmManager.shared.stop(id: alarm.id)
                    if let record = try markStopped(id: alarm.id) { stopped.append(record) }
                } catch LocalDataError.unverified(let message) {
                    persistenceFailure = message
                } catch {
                    continue
                }
            }
        }

        // Older system alarms and TTS reminders use local notifications. Treat
        // only notifications fired in the last minute as active so an old
        // delivered notification is not mistaken for the current alert.
        let localCandidates = store.alarms.filter {
            $0.backend == .localNotification
                && $0.isEnabled
                && now.timeIntervalSince($0.date) >= 0
                && now.timeIntervalSince($0.date) < 60
        }
        if !localCandidates.isEmpty {
            let identifiers = localCandidates.compactMap(\.notificationIdentifier)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            for record in localCandidates {
                do { if let updated = try markStopped(id: record.id) { stopped.append(updated) } }
                catch { persistenceFailure = error.localizedDescription }
            }
        }

        if let persistenceFailure { throw LocalDataError.unverified(persistenceFailure) }
        guard !stopped.isEmpty else { throw JarvisAlarmError.alarmNotFound }
        return stopped
    }

    /// Keeps the app's metadata synchronized when AlarmKit invokes its lock-screen
    /// stop action. Calling `stop` again is harmlessly ignored if the system has
    /// already completed the stop before the intent runs.
    func completeAlarmKitStop(id: UUID) -> JarvisAlarmRecord? {
        do { try LocalDataExecution.check(.stopActiveAlarm) } catch { return nil }
        if #available(iOS 26.0, *) {
            do {
                let manager = AlarmManager.shared
                if try manager.alarms.contains(where: { $0.id == id && $0.state == .alerting }) {
                    try manager.stop(id: id)
                }
                guard try !manager.alarms.contains(where: { $0.id == id && $0.state == .alerting }) else {
                    statusMessage = "시스템 알람 종료를 확인하지 못했습니다."; return nil
                }
            } catch { statusMessage = "시스템 알람 종료를 확인하지 못했습니다."; return nil }
        }
        do { return try markStopped(id: id) } catch { statusMessage = error.localizedDescription; return nil }
    }

    func matches(for query: AlarmQuery, now: Date = Date()) -> [JarvisAlarmRecord] {
        let enabled = store.alarms.filter(\.isEnabled)
        switch query {
        case .all:
            return enabled
        case .today:
            return enabled.filter { Calendar.current.isDateInToday($0.date) }
        case .tomorrow:
            return enabled.filter { Calendar.current.isDateInTomorrow($0.date) }
        case .latest:
            return Array(enabled.sorted { $0.createdAt > $1.createdAt }.prefix(1))
        case .next:
            return Array(enabled.filter { $0.date > now }.sorted { $0.date < $1.date }.prefix(1))
        case .named(let name):
            let compactName = compact(name)
            return enabled.filter {
                let label = compact($0.label)
                return !label.isEmpty && (label.contains(compactName) || compactName.contains(label))
            }
        case .atTime(let request):
            guard let target = try? resolver.resolve(request, now: now) else { return [] }
            return enabled.filter {
                abs($0.date.timeIntervalSince(target)) < 90
                    || Calendar.current.component(.hour, from: $0.date) == Calendar.current.component(.hour, from: target)
                    && Calendar.current.component(.minute, from: $0.date) == Calendar.current.component(.minute, from: target)
            }
        }
    }

    func list(filter: AlarmListFilter, now: Date = Date()) -> [JarvisAlarmRecord] {
        let query: AlarmQuery
        switch filter {
        case .all: query = .all
        case .today: query = .today
        case .tomorrow: query = .tomorrow
        case .next: query = .next
        case .named(let name): query = .named(name)
        }
        return matches(for: query, now: now).sorted { $0.date < $1.date }
    }

    func resolvedDate(for request: AlarmRequest, now: Date = Date()) throws -> Date {
        try resolver.resolve(request, now: now)
    }

    func message(forLabel label: String) -> String {
        guard !label.isEmpty else { return "설정한 알람 시간입니다." }
        let endings: [(String, String)] = [
            ("일어나기", "일어나실 시간입니다."),
            ("먹기", "드실 시간입니다."),
            ("마시기", "드실 시간입니다."),
            ("자기", "주무실 시간입니다."),
            ("오기", "오실 시간입니다."),
            ("가기", "가실 시간입니다."),
            ("끄기", "끄실 시간입니다."),
            ("하기", "하실 시간입니다.")
        ]
        for (ending, replacement) in endings where label.hasSuffix(ending) {
            return String(label.dropLast(ending.count)) + replacement
        }
        return "\(label) 알림입니다."
    }

    func spokenConfirmation(for alarm: JarvisAlarmRecord, request: AlarmRequest) -> String {
        if alarm.delivery == .jarvisVoice {
            if case .afterMinutes(let minutes) = request {
                let delay = minutes >= 60
                    ? "\(minutes / 60)시간" + (minutes % 60 == 0 ? "" : " \(minutes % 60)분")
                    : "\(minutes)분"
                return "\(delay) 뒤 JARVIS 음성 알림을 설정했습니다."
            }
            return "\(formattedDate(alarm.date))에 JARVIS 음성 알림을 설정했습니다."
        }
        if case .afterMinutes(let minutes) = request {
            let delay: String
            if minutes >= 60, minutes.isMultiple(of: 60) {
                delay = "\(minutes / 60)시간"
            } else if minutes >= 60 {
                delay = "\(minutes / 60)시간 \(minutes % 60)분"
            } else {
                delay = "\(minutes)분"
            }
            return "\(delay) 뒤 알람을 맞췄습니다."
        }
        return "\(formattedDate(alarm.date))에 알람을 맞췄습니다."
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        let day: String
        if Calendar.current.isDateInToday(date) {
            day = "오늘"
        } else if Calendar.current.isDateInTomorrow(date) {
            day = "내일"
        } else {
            formatter.dateFormat = "M월 d일"
            day = formatter.string(from: date)
        }
        formatter.dateFormat = "a h시 m분"
        let time = formatter.string(from: date).replacingOccurrences(of: " 0분", with: "")
        return "\(day) \(time)"
    }

    private func save(_ record: JarvisAlarmRecord) throws {
        try store.upsert(record)
        alarms = store.alarms
    }

    private func defaultMessage(for label: String?) -> String {
        guard let label, !label.isEmpty else { return "설정한 알람 시간입니다." }
        return "\(label) 알림입니다."
    }

    private func personalizedVoiceMessage(_ message: String) -> String {
        let spokenMessage = voiceDirectiveMessage(message)
        guard let address = UserProfileStore.load().addressForGreeting,
              !address.isEmpty,
              !spokenMessage.hasPrefix(address) else { return spokenMessage }
        return "\(address), \(spokenMessage)"
    }

    private func voiceDirectiveMessage(_ message: String) -> String {
        let endings = [
            ("끄실 시간입니다.", "끄셔야 합니다."),
            ("드실 시간입니다.", "드셔야 합니다."),
            ("가실 시간입니다.", "가셔야 합니다."),
            ("오실 시간입니다.", "오셔야 합니다."),
            ("하실 시간입니다.", "하셔야 합니다."),
            ("일어나실 시간입니다.", "일어나셔야 합니다.")
        ]
        for (ending, replacement) in endings where message.hasSuffix(ending) {
            return String(message.dropLast(ending.count)) + replacement
        }
        return message
    }

    @available(iOS 26.0, *)
    private func scheduleWithAlarmKit(id: UUID, at date: Date, label: String, message: String, compensating: Bool = false) async throws {
        let manager = AlarmManager.shared
        let authorization = manager.authorizationState == .notDetermined
            ? try await manager.requestAuthorization()
            : manager.authorizationState
        guard authorization == .authorized else { throw JarvisAlarmError.permissionDenied }
        if !compensating { try LocalDataExecution.check(.localData(.createAlarm)) }

        let title: LocalizedStringResource = "\(message)"
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: title)
        } else {
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: AlarmButton(
                    text: "중지",
                    textColor: .white,
                    systemImageName: "stop.fill"
                )
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: JarvisAlarmMetadata(createdAt: Date(), label: label, message: message),
            tintColor: .blue
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: StopJarvisAlarmIntent(alarmID: id),
            sound: .default
        )
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    private func scheduleLocalNotification(
        identifier: String,
        at date: Date,
        label: String,
        message: String,
        soundFileName: String?,
        delivery: AlarmDeliveryMode,
        compensating: Bool = false
    ) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var authorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            authorized = try await center.requestAuthorization(options: [.alert, .sound])
        }
        guard authorized else { throw JarvisAlarmError.permissionDenied }

        let pending = await center.pendingNotificationRequests()
        guard pending.contains(where: { $0.identifier == identifier }) || pending.count < 64 else {
            throw LocalDataError.blocked("알림 예약 공간이 부족합니다. 기존 알림을 정리한 뒤 다시 요청해주세요.")
        }
        if !compensating { try LocalDataExecution.check(.localData(.createAlarm)) }

        let content = UNMutableNotificationContent()
        let typeTitle = delivery == .system ? "JARVIS 알람" : "JARVIS 음성 알림"
        content.title = label.isEmpty ? typeTitle : "\(typeTitle) · \(label)"
        content.body = message
        if delivery == .system {
            content.sound = .default
        } else if let soundFileName {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundFileName))
        } else {
            // TTS 생성 실패 시 시스템 알림음을 대신 재생하지 않는다.
            content.sound = nil
        }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        try await center.add(
            UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
        )
    }

    private func cancelSystemAlarm(_ record: JarvisAlarmRecord) async throws {
        switch record.backend {
        case .alarmKit:
            if #available(iOS 26.0, *) { try AlarmManager.shared.cancel(id: record.id) }
        case .localNotification:
            if let identifier = record.notificationIdentifier {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: [identifier])
            }
        }
    }

    private func markStopped(id: UUID) throws -> JarvisAlarmRecord? {
        guard var record = store.record(id: id) else { return nil }
        record.isEnabled = false
        let oldSound = record.soundFileName
        record.soundFileName = nil
        do { try save(record) }
        catch { throw LocalDataError.unverified("알람 정지 요청은 처리했지만 목록을 저장하지 못했습니다. 예약 상태를 확인해주세요.") }
        speechRenderer.remove(fileName: oldSound)
        return record
    }

    private func prepared(id: UUID, date: Date, label: String, message: String,
                          delivery: AlarmDeliveryMode, createdAt: Date) async throws -> JarvisAlarmRecord {
        try store.ensureWritable()
        guard date > Date() else { throw JarvisAlarmError.invalidTime }
        let sound = delivery == .jarvisVoice
            ? await speechRenderer.render(message: message, fileToken: "alarm-" + UUID().uuidString) : nil
        if delivery == .jarvisVoice, sound == nil {
            throw LocalDataError.blocked("음성 파일을 생성하지 못했습니다. 기존 알람은 유지했습니다.")
        }
        var backend: JarvisAlarmBackend = .localNotification
        if delivery == .system, #available(iOS 26.0, *) { backend = .alarmKit }
        return .init(id: id, date: date, label: label, message: message, delivery: delivery,
            isEnabled: true, backend: backend,
            notificationIdentifier: backend == .localNotification ? "jarvis.alarm.\(id.uuidString)" : nil,
            soundFileName: sound, createdAt: createdAt)
    }

    private func install(_ record: JarvisAlarmRecord, compensating: Bool = false) async throws {
        guard record.isEnabled else { return }
        if let installOverride { try await installOverride(record); return }
        if record.backend == .alarmKit, #available(iOS 26.0, *) {
            try await scheduleWithAlarmKit(id: record.id, at: record.date, label: record.label, message: record.message, compensating: compensating)
        } else {
            try await scheduleLocalNotification(identifier: record.notificationIdentifier!, at: record.date,
                label: record.label, message: record.message, soundFileName: record.soundFileName, delivery: record.delivery, compensating: compensating)
        }
    }
    private func cancelReservation(_ record: JarvisAlarmRecord) async throws {
        if let cancelOverride { try await cancelOverride(record) } else { try await cancelSystemAlarm(record) }
    }
    private func verified(_ record: JarvisAlarmRecord, enabled: Bool) async throws -> Bool {
        if let verifyOverride {
            var expected = record; expected.isEnabled = enabled
            return try await verifyOverride(expected)
        }
        if record.backend == .alarmKit, #available(iOS 26.0, *) {
            return try AlarmManager.shared.alarms.contains { $0.id == record.id } == enabled
        }
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return requests.contains { $0.identifier == record.notificationIdentifier } == enabled
    }

    /// Journal is durable before touching the system. Rollback is limited to
    /// the exact pre-authorized snapshot, never an interpreted new action.
    private func transact(old: JarvisAlarmRecord?, next: JarvisAlarmRecord?) async throws {
        try store.ensureWritable()
        guard journal.load().isEmpty, !journal.blocked else { throw LocalDataError.recovery }
        try LocalDataExecution.check(.localData(.changeAlarm))
        let change = AlarmPendingChange(old: old, next: next)
        try journal.save([change])
        do {
            if let old, old.isEnabled { try await cancelReservation(old) }
            try LocalDataExecution.check(.localData(.changeAlarm))
            if let next { try await install(next) }
            let expected = next ?? old!
            guard try await verified(expected, enabled: next?.isEnabled ?? false) else { throw LocalDataError.recovery }
            try LocalDataExecution.check(.localData(.changeAlarm))
            if let next { try save(next) } else if let old { try store.remove(id: old.id); alarms = store.alarms }
            try journal.save([])
            if old?.soundFileName != next?.soundFileName { speechRenderer.remove(fileName: old?.soundFileName) }
            statusMessage = nil
        } catch {
            let failure = error
            let restored = await Task { @MainActor [self] in
                do {
                    if let next { try await cancelReservation(next) }
                    if let old, old.isEnabled {
                        guard old.date > Date() else { throw LocalDataError.recovery }
                        try await install(old, compensating: true)
                    }
                    if let old {
                        guard try await verified(old, enabled: old.isEnabled) else { throw LocalDataError.recovery }
                        try save(old)
                    } else if let next { try store.remove(id: next.id) }
                    try journal.save([])
                    return true
                } catch { return false }
            }.value
            alarms = store.alarms
            statusMessage = restored ? "알람 변경에 실패하여 기존 상태로 복구했습니다." : LocalDataError.recovery.localizedDescription
            if restored { throw LocalDataError.blocked(statusMessage! + " " + failure.localizedDescription) }
            throw LocalDataError.recovery
        }
    }

    func restoreStorage(confirmed: Bool) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.restoreStorage), confirmed: confirmed) { [self] in
            try store.restore(confirmed: confirmed); alarms = store.alarms
            statusMessage = "목록을 복구했습니다. 실제 시스템 예약 상태는 별도로 확인해주세요."
        })
    }

    func recoverPendingChange(confirmed: Bool) async throws {
        try LocalDataExecution.value(await LocalDataExecution.perform(.localData(.restoreStorage), confirmed: confirmed) { [self] in
            guard let change = journal.load().first else {
                if journal.blocked { throw LocalDataError.recovery }; return
            }
            if let next = change.next { try await cancelReservation(next) }
            try LocalDataExecution.check(.localData(.restoreStorage), confirmed: confirmed)
            if let old = change.old {
                if old.isEnabled { guard old.date > Date() else { throw LocalDataError.recovery }; try await install(old) }
                guard try await verified(old, enabled: old.isEnabled) else { throw LocalDataError.recovery }
                try LocalDataExecution.check(.localData(.restoreStorage), confirmed: confirmed)
                try save(old)
            } else if let next = change.next { try store.remove(id: next.id) }
            try LocalDataExecution.check(.localData(.restoreStorage), confirmed: confirmed)
            try journal.save([]); alarms = store.alarms; statusMessage = nil
        })
    }

    private func compact(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

struct AlarmPendingChange: Codable {
    let old: JarvisAlarmRecord?
    let next: JarvisAlarmRecord?
}
