import AppIntents

struct StartJarvisConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "자비스에게 말하기"
    static let description = IntentDescription("자비스를 열고 음성 명령을 시작합니다.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "jarvis.startConversation")
        return .result()
    }
}

struct StartJarvisStandbyIntent: AppIntent {
    static let title: LocalizedStringResource = "자비스 음성 대기 시작"
    static let description = IntentDescription("자비스를 열고 호출어 대기를 시작합니다.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "jarvis.startStandby")
        return .result()
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
            intent: StartJarvisStandbyIntent(),
            phrases: ["\(.applicationName) 음성 대기 시작"],
            shortTitle: "음성 대기 시작",
            systemImageName: "ear"
        )
    }
}
