import Foundation

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var state: AssistantState = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var standbyEnabled = false
    @Published var textInput = ""

    private let speechRecognition = SpeechRecognitionService()
    private let speechSynthesis = SpeechSynthesisService()
    private let router = CommandRouter()
    private let aiClient: AIClient = MockAIClient()
    private let youtube = YouTubeLauncher()

    private var silenceTask: Task<Void, Never>?
    private var latestCommand = ""
    private var isFinalizingCommand = false
    private var wakeWordLocked = false

    var isActivelyListening: Bool {
        state == .waitingForWakeWord || state == .listeningForCommand
    }

    func startOneShotConversation() {
        standbyEnabled = false
        Task { await prepareAndListenForCommand() }
    }

    func startStandby() {
        standbyEnabled = true
        Task {
            guard await ensurePermissions() else { return }
            listenForWakeWord()
        }
    }

    func stopAll() {
        standbyEnabled = false
        silenceTask?.cancel()
        speechRecognition.stop()
        speechSynthesis.stop()
        state = .idle
    }

    func submitText() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInput = ""
        transcript = text
        Task { await process(text) }
    }

    func consumePendingIntent() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "jarvis.startStandby") {
            defaults.removeObject(forKey: "jarvis.startStandby")
            startStandby()
        } else if defaults.bool(forKey: "jarvis.startConversation") {
            defaults.removeObject(forKey: "jarvis.startConversation")
            startOneShotConversation()
        }
    }

    private func prepareAndListenForCommand() async {
        guard await ensurePermissions() else { return }
        listenForCommand()
    }

    private func ensurePermissions() async -> Bool {
        state = .preparing
        let allowed = await speechRecognition.requestPermissions()
        if !allowed {
            state = .error("설정에서 마이크와 음성 인식 권한을 허용해주세요.")
        }
        return allowed
    }

    private func listenForWakeWord() {
        speechRecognition.stop()
        state = .waitingForWakeWord
        wakeWordLocked = false

        do {
            try speechRecognition.start(
                onPartial: { [weak self] text in
                    Task { @MainActor in self?.handleWakeWordCandidate(text) }
                },
                onFinal: { [weak self] text in
                    Task { @MainActor in self?.handleWakeWordCandidate(text) }
                },
                onError: { [weak self] error in
                    Task { @MainActor in self?.handleRecognitionError(error) }
                }
            )
        } catch {
            handleRecognitionError(error)
        }
    }

    private func handleWakeWordCandidate(_ text: String) {
        transcript = text
        guard standbyEnabled, !wakeWordLocked, router.containsWakeWord(text) else { return }
        wakeWordLocked = true
        speechRecognition.stop()
        state = .wakeWordDetected

        speechSynthesis.speak("네, 말씀하세요") { [weak self] in
            Task { @MainActor in self?.listenForCommand() }
        }
    }

    private func listenForCommand() {
        latestCommand = ""
        isFinalizingCommand = false
        transcript = ""
        state = .listeningForCommand

        do {
            try speechRecognition.start(
                onPartial: { [weak self] text in
                    Task { @MainActor in self?.receivedCommandText(text, isFinal: false) }
                },
                onFinal: { [weak self] text in
                    Task { @MainActor in self?.receivedCommandText(text, isFinal: true) }
                },
                onError: { [weak self] error in
                    Task { @MainActor in self?.handleRecognitionError(error) }
                }
            )
        } catch {
            handleRecognitionError(error)
        }
    }

    private func receivedCommandText(_ text: String, isFinal: Bool) {
        guard !isFinalizingCommand else { return }
        latestCommand = text
        transcript = text
        silenceTask?.cancel()

        if isFinal {
            finalizeCommand()
        } else {
            silenceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                await self?.finalizeCommand()
            }
        }
    }

    private func finalizeCommand() {
        guard !isFinalizingCommand else { return }
        let command = latestCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        isFinalizingCommand = true
        silenceTask?.cancel()
        speechRecognition.stop()
        state = .transcribing
        Task { await process(command) }
    }

    private func process(_ text: String) async {
        state = .thinking

        switch router.route(text) {
        case .playYouTube(let query):
            let message = "유튜브에서 \(query)을 검색합니다."
            response = message
            state = .speaking
            speechSynthesis.speak(message) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    _ = await self.youtube.openSearch(query: query)
                    self.finishInteraction()
                }
            }

        case .generalConversation:
            do {
                let answer = try await aiClient.reply(to: text)
                response = answer
                state = .speaking
                speechSynthesis.speak(answer) { [weak self] in
                    Task { @MainActor in self?.finishInteraction() }
                }
            } catch {
                state = .error("답변을 만들지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    private func finishInteraction() {
        isFinalizingCommand = false
        if standbyEnabled {
            listenForWakeWord()
        } else {
            state = .idle
        }
    }

    private func handleRecognitionError(_ error: Error) {
        guard state != .idle else { return }
        speechRecognition.stop()
        state = .error("음성 인식 오류: \(error.localizedDescription)")
    }
}
