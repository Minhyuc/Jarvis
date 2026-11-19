import AppIntents
import Foundation

extension Notification.Name {
    static let jarvisStartConversationRequested = Notification.Name(
        "com.minhyuc.jarvis.startConversationRequested"
    )
}

struct StartJarvisConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "자비스에게 말하기"
    static let description = IntentDescription("자비스를 열고 음성 명령을 시작합니다.")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "jarvis.startConversation")
        NotificationCenter.default.post(name: .jarvisStartConversationRequested, object: nil)
        return .result()
    }
}

struct PlayYouTubeFromWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "YouTube 재생"
    static let description = IntentDescription("iPhone의 JARVIS로 YouTube에서 원하는 영상을 재생합니다.")
    static let openAppWhenRun = true

    @Parameter(title: "검색할 영상 또는 노래")
    var query: String

    func perform() async throws -> some IntentResult {
        let command = "유튜브에서 \(query) 틀어줘"
        UserDefaults.standard.set(command, forKey: "jarvis.pendingCommand")
        return .result()
    }
}

struct StopCurrentJarvisAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "현재 JARVIS 알람 종료"
    static let description = IntentDescription("현재 울리고 있는 JARVIS 알람을 종료합니다.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AlarmAppIntentSafety.permitsStop() else {
            return .result(dialog: "안전 설정으로 알람 종료가 차단되었습니다.")
        }
        let result = await ToolExecutionCoordinator.shared.executeThrowing(
            key: "alarm-stop-active",
            timeout: .seconds(8),
            operation: { @MainActor in try await AlarmService.shared.stopCurrentlyAlertingAlarms() },
            mapError: { error in
                let message = error.localizedDescription
                if case LocalDataError.unverified = error { return .unverifiable(message: message) }
                if message.contains("권한") || message.lowercased().contains("permission") {
                    return .needsPermission(message: message)
                }
                return .failed(message: "현재 울리는 JARVIS 알람을 확인하지 못했습니다.", retryable: false)
            }
        )
        switch result {
        case .succeeded(let stopped):
            let name: String
            if stopped.count == 1 {
                name = stopped[0].effectiveLabel
            } else {
                name = "\(stopped[0].effectiveLabel) 외 \(stopped.count - 1)개"
            }
            let dialog = IntentDialog("현재 구동 중인 \(name) 알람을 종료했습니다.")
            return .result(dialog: dialog)
        case .needsPermission(let message), .needsConfirmation(let message),
             .failed(let message, _), .unverifiable(let message):
            return .result(dialog: IntentDialog(stringLiteral: message))
        case .handedOff:
            return .result(dialog: "알람 종료 요청을 시스템에 전달했습니다.")
        }
    }
}

@available(iOS 26.0, *)
struct StopJarvisAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "JARVIS 알람 중지"
    static let description = IntentDescription("잠금 화면에서 현재 JARVIS 알람을 중지합니다.")
    static var supportedModes: IntentModes { .background }
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "알람 ID")
    var alarmID: String

    init() {
        alarmID = ""
    }

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        guard AlarmAppIntentSafety.permitsStop() else { return .result() }
        _ = await ToolExecutionCoordinator.shared.execute(
            key: "alarm-stop-\(id.uuidString)", timeout: .seconds(8)
        ) { @MainActor in
            guard AlarmService.shared.completeAlarmKitStop(id: id) != nil else {
                return ToolExecutionResult<Void>.failed(
                    message: "종료할 알람을 찾지 못했습니다.", retryable: false
                )
            }
            return .succeeded(())
        }
        return .result()
    }
}

@MainActor
private enum AlarmAppIntentSafety {
    static func permitsStop() -> Bool {
        let decision = SafetyPolicyEngine().evaluate(
            .stopActiveAlarm,
            context: SafetyEvaluationContext(
                origin: .backgroundAutomation,
                externalActionsLocked: SafetyControlStore.externalActionsLocked,
                wasExplicitlyConfirmed: false
            )
        )
        switch decision {
        case .allow(let risk, let actionName):
            SafetyAuditStore.shared.record(actionName: actionName, risk: risk, outcome: .authorized)
            return true
        case .requireConfirmation(let risk, let actionName, _):
            SafetyAuditStore.shared.record(actionName: actionName, risk: risk, outcome: .awaitingConfirmation)
            return false
        case .block(let risk, let actionName, _):
            SafetyAuditStore.shared.record(actionName: actionName, risk: risk, outcome: .blocked)
            return false
        }
    }
}

struct JarvisShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartJarvisConversationIntent(),
            phrases: [
                "\(.applicationName)에게 말하기",
                "\(.applicationName) 실행"
            ],
            shortTitle: "자비스에게 말하기",
            systemImageName: "waveform.circle.fill"
        )
        AppShortcut(
            intent: PlayYouTubeFromWatchIntent(),
            phrases: [
                "\(.applicationName)로 유튜브 재생",
                "\(.applicationName)로 노래 틀기"
            ],
            shortTitle: "YouTube 재생",
            systemImageName: "play.rectangle.fill"
        )
        AppShortcut(
            intent: StopCurrentJarvisAlarmIntent(),
            phrases: [
                "\(.applicationName) 알람 꺼줘",
                "\(.applicationName) 알람 중지",
                "\(.applicationName) 알람 종료"
            ],
            shortTitle: "알람 끄기",
            systemImageName: "alarm.waves.left.and.right.slash"
        )
    }
}
