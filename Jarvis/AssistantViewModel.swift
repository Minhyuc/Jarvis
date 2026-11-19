import Foundation
import Combine
import AVFoundation

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
    let sources: [WebSearchSource]

    init(role: Role, text: String, sources: [WebSearchSource] = []) {
        self.role = role
        self.text = text
        self.sources = sources
    }
}

@MainActor
final class AssistantViewModel: ObservableObject {
    private enum InputSource {
        case voice
        case text
        case automation
    }

    @Published private(set) var state: AssistantState = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var response = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var aiModeDescription = "AI 준비 중"
    @Published private(set) var activeSuggestion: ProactiveSuggestion?
    @Published private(set) var voiceActivityLevel = 0.0
    @Published var textInput = ""

    private let speechRecognition = SpeechRecognitionService()
    private let speechSynthesis: any SpeechOutputServing
    private let router = CommandRouter()
    private let agentOrchestrator = AgentOrchestrator()
    private let aiClient: any AIClient
    private let youtube = YouTubeLauncher()
    private let appLauncher = AppLauncher()
    private let briefingService = BriefingService()
    private let restaurantService = RestaurantRecommendationService()
    private let webSearchService = WebSearchService()
    private let navigationService: any NavigationServing
    private let improvementReview: ImprovementReviewStore
    private let phoneCallService = PhoneCallService()
    private let musicRecognitionShortcut = MusicRecognitionShortcutService()
    private let systemVolumeService = SystemVolumeService()
    private let alarmService = AlarmService.shared
    private let longTermMemoryStore: LongTermMemoryStore
    private let calendarStore: JarvisCalendarStore
    private let projectStore: SharedProjectStore
    private let scheduleCalendarEvent: @MainActor (JarvisCalendarEvent) async throws -> Void
    private let cancelCalendarEvent: @MainActor (JarvisCalendarEvent) async throws -> Void
    private let safetyPolicy = SafetyPolicyEngine()
    private let safetyAuditStore = SafetyAuditStore.shared
    private let toolExecutionCoordinator = ToolExecutionCoordinator.shared
    private let responsePresenter = AssistantResponsePresenter()
    private let dialogueInputResolver = DialogueInputResolver()
    private let suggestionEngine = ProactiveSuggestionEngine()
    private let suggestionSettings: ProactiveSuggestionSettingsStore
    private let weatherResultOverride: (@MainActor (WeatherRequest) async -> (ToolExecutionResult<String>, WeatherAdviceFacts?))?
    private let outingForecastOverride: (@MainActor (Date, String) async throws -> String)?
    private var weatherAdviceFacts: WeatherAdviceFacts?
    private let speechOutputEnabled: Bool
    private var processingTask: Task<Void, Never>?
    private var cloudSettingsObserver: AnyCancellable?
    private var practiceSettingsObserver: AnyCancellable?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var voiceObservers: [NSObjectProtocol] = []
    private var memoryObserver: AnyCancellable?
    private var suggestionModeObserver: AnyCancellable?
    private var memoryAnswerID: UUID?
    private var recognitionPreparationTask: Task<Void, Never>?
    private var interactionID = UUID()
    private var recognitionID = UUID()
    private var speechPlaybackID = UUID()
    private var speechWaiter: SpeechWaiter?

    private final class SpeechWaiter {
        var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func finish() { let next = continuation; continuation = nil; next?.resume() }
    }

    private var silenceTask: Task<Void, Never>?
    private var systemInvocationTask: Task<Void, Never>?
    private var shortcutResponseTask: Task<Void, Never>?
    private var latestCommand = ""
    private var isFinalizingCommand = false
    private var recognitionRetryCount = 0
    private var contextManager = AssistantContextManager()
    private var dialogueManager = DialogueStateManager()
    private var pendingSongRecognition: PendingSongRecognition?
    private var pendingAutomaticSuggestion: ProactiveSuggestion?
    private var recentIntentKeys: [String] = []
    private var lastReferencedMemories: [LongTermMemoryRecord] = []

    private struct PendingSongRecognition {
        let token: String
        let userText: String
        let intent: AssistantIntent
    }

    init(aiClient overrideClient: (any AIClient)? = nil, speechOutputEnabled: Bool = true,
         navigationService: (any NavigationServing)? = nil, improvementReview: ImprovementReviewStore? = nil,
         speechOutput: (any SpeechOutputServing)? = nil, memoryStore: LongTermMemoryStore? = nil,
         calendarStore: JarvisCalendarStore? = nil,
         scheduleCalendarEvent: (@MainActor (JarvisCalendarEvent) async throws -> Void)? = nil,
         cancelCalendarEvent: (@MainActor (JarvisCalendarEvent) async throws -> Void)? = nil,
         suggestionSettings: ProactiveSuggestionSettingsStore? = nil,
         weatherResultOverride: (@MainActor (WeatherRequest) async -> (ToolExecutionResult<String>, WeatherAdviceFacts?))? = nil,
         outingForecastOverride: (@MainActor (Date, String) async throws -> String)? = nil,
         projectStore: SharedProjectStore? = nil) {
        self.projectStore = projectStore ?? .shared
        self.suggestionSettings = suggestionSettings ?? .shared
        self.weatherResultOverride = weatherResultOverride
        self.outingForecastOverride = outingForecastOverride
        self.longTermMemoryStore = memoryStore ?? .shared
        self.calendarStore = calendarStore ?? .shared
        self.scheduleCalendarEvent = scheduleCalendarEvent ?? { try await JarvisCalendarNotificationService.shared.schedule($0) }
        self.cancelCalendarEvent = cancelCalendarEvent ?? { try await JarvisCalendarNotificationService.shared.cancel($0) }
        self.speechSynthesis = speechOutput ?? SpeechSynthesisService()
        self.navigationService = navigationService ?? NavigationService()
        self.improvementReview = improvementReview ?? .shared
        let selection = AIClientFactory.make()
        aiClient = overrideClient ?? selection.client
        aiModeDescription = overrideClient == nil && OpenAIIntegrationStore.shared.configuration.enabled
            ? "OpenAI · \(OpenAIResponsesTransport.model)" : (overrideClient == nil ? selection.description : "테스트 대화 엔진")
        self.speechOutputEnabled = speechOutputEnabled
        for name in [Notification.Name.jarvisSpeechVoiceChanged, .jarvisSpeechPreviewRequested] {
            voiceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.stopAll() }
            })
        }
        memoryObserver = NotificationCenter.default.publisher(for: .jarvisMemoriesChanged)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                self.contextManager.reset(); self.lastReferencedMemories = []
                if let pending = self.dialogueManager.current() {
                    switch pending.task {
                    case .memorySuggestion, .sensitiveMemoryRequest: self.dialogueManager.cancel()
                    default: break
                    }
                }
                if self.memoryAnswerID != nil { self.stopAll() }
            } }
        suggestionModeObserver = NotificationCenter.default.publisher(for: .jarvisSuggestionModeChanged)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.stopAll(); self?.activeSuggestion = nil } }
        audioInterruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                MainActor.assumeIsolated {
                    guard let self, self.state == .speaking || self.state == .listeningForCommand
                            || self.state == .wakeWordDetected else { return }
                    SpeechDiagnosticsStore.shared.interrupted()
                    self.stopAll()
                    self.state = .error("통화 등으로 음성이 중단되었습니다. 다시 요청해주세요.")
                }
            }
        practiceSettingsObserver = NotificationCenter.default.publisher(for: .jarvisCommandPracticeChanged)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.stopAll() } }
        if overrideClient == nil {
            cloudSettingsObserver = NotificationCenter.default.publisher(for: .jarvisOpenAIConfigurationChanged)
                .sink { [weak self] _ in
                    // This notification is posted only by the main-actor
                    // settings store. Cancel before the toggle returns so a
                    // queued cloud answer cannot appear after disabling it.
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.stopAll()
                        self.aiModeDescription = OpenAIIntegrationStore.shared.configuration.enabled
                            ? "OpenAI · \(OpenAIResponsesTransport.model)" : selection.description
                    }
                }
        }
    }

    deinit {
        voiceObservers.forEach(NotificationCenter.default.removeObserver)
        if let audioInterruptionObserver { NotificationCenter.default.removeObserver(audioInterruptionObserver) }
    }

    var isActivelyListening: Bool {
        state == .listeningForCommand
    }

    func startOneShotConversation() {
        cancelCurrentWork()
        recognitionRetryCount = 0
        recognitionPreparationTask = Task { await prepareAndListenForCommand() }
    }

    func startSystemInvokedConversation() {
        cancelCurrentWork()
        recognitionRetryCount = 0
        systemInvocationTask?.cancel()
        systemInvocationTask = Task {
            guard await ensurePermissions() else { return }
            // Siri/Voice Shortcut may still own the audio route for a moment after
            // bringing JARVIS forward. Waiting briefly prevents the first reply
            // from being swallowed by that handoff.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            state = .wakeWordDetected
            speakCurrent("네.") { [weak self] in self?.listenForCommand() }
        }
    }

    func stopAll() {
        cancelCurrentWork()
        projectStore.pause()
        pendingAutomaticSuggestion = nil
        dialogueManager.cancel()
        state = .idle
    }

    /// Invalidates queued callbacks before releasing audio/continuations. A new
    /// turn may preserve dialogue, but must never inherit an old audio action.
    private func cancelCurrentWork() {
        interactionID = UUID()
        recognitionID = UUID()
        speechPlaybackID = UUID()
        NotificationCenter.default.post(name: .jarvisSpeechPreviewStopRequested, object: nil)
        processingTask?.cancel()
        processingTask = nil
        memoryAnswerID = nil
        recognitionPreparationTask?.cancel()
        recognitionPreparationTask = nil
        systemInvocationTask?.cancel()
        systemInvocationTask = nil
        shortcutResponseTask?.cancel()
        shortcutResponseTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        pendingAutomaticSuggestion = nil
        speechWaiter?.finish()
        speechWaiter = nil
        speechRecognition.stop()
        voiceActivityLevel = 0
        speechSynthesis.stop()
    }

    func suspendForBackground() {
        stopAll()
    }

    func submitText() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInput = ""
        transcript = text
        appendMessage(role: .user, text: text)
        startProcessing(text, source: .text)
    }

    func consumePendingIntent(defaults: UserDefaults = .standard, isForeground: Bool = true) {
        // Do not consume a request while Siri/permission UI has made the app
        // inactive: suspension would cancel it after the pending flag was lost.
        guard isForeground else { return }
        defaults.removeObject(forKey: "jarvis.startStandby")
        if let command = defaults.string(forKey: "jarvis.pendingCommand") {
            defaults.removeObject(forKey: "jarvis.pendingCommand")
            defaults.removeObject(forKey: "jarvis.startConversation")
            transcript = command
            appendMessage(role: .user, text: command)
            startProcessing(command, source: .automation)
            return
        }
        if defaults.bool(forKey: "jarvis.startConversation") {
            defaults.removeObject(forKey: "jarvis.startConversation")
            startSystemInvokedConversation()
        }
    }

    func dismissActiveSuggestion() {
        if let activeSuggestion { suggestionSettings.record(activeSuggestion, outcome: "dismissed") }
        activeSuggestion = nil
    }

    func rateActiveSuggestion(helpful: Bool) {
        guard let activeSuggestion else { return }
        suggestionSettings.record(activeSuggestion, outcome: helpful ? "helpful" : "notHelpful")
    }

    func acceptActiveSuggestion() {
        cancelCurrentWork()
        acceptActiveSuggestion(source: .text, approvalText: "능동 제안 실행 승인")
    }

    private func acceptActiveSuggestion(source: InputSource, approvalText: String) {
        guard let suggestion = activeSuggestion else { return }
        activeSuggestion = nil
        guard suggestionSettings.mode != .disabled, Date() < suggestion.expiresAt else {
            speakAndFinish("제안이 만료되었거나 꺼져 있습니다. 다시 조회해주세요."); return
        }
        guard let intent = suggestion.proposedIntent else {
            suggestionSettings.record(suggestion, outcome: "advicePresented")
            speakAndFinish(suggestion.title)
            return
        }
        guard authorize(
            intent,
            originalText: approvalText,
            source: source,
            origin: .proactiveSuggestion
        ) else { return }
        suggestionSettings.record(suggestion, outcome: "requested")
        processingTask = Task { await execute(intent, text: approvalText, source: source, origin: .proactiveSuggestion) }
    }

    @discardableResult
    func handleIncomingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "jarvis",
              url.host?.lowercased() == "shortcut" else {
            return false
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let token = queryItems.first(where: { $0.name == "token" })?.value
        guard let pendingSongRecognition,
              token == pendingSongRecognition.token else {
            return true
        }
        self.pendingSongRecognition = nil

        switch url.path {
        case "/song-success":
            let result = queryItems
                .first(where: { $0.name == "result" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let result, !result.isEmpty {
                message = "찾은 노래는 \(result)입니다."
            } else {
                message = "노래는 찾았지만 결과 정보를 받지 못했습니다."
            }
            speakShortcutResult(
                message,
                remembering: pendingSongRecognition.userText,
                intent: pendingSongRecognition.intent
            )

        case "/song-cancel":
            speakShortcutResult("노래 찾기를 취소했습니다.")

        case "/song-error":
            let errorMessage = queryItems
                .first(where: { $0.name == "errorMessage" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorMessage.flatMap { $0.isEmpty ? nil : $0 }
            speakShortcutResult(detail ?? "노래를 찾지 못했습니다. 다시 시도해주세요.")

        default:
            return false
        }
        return true
    }

    private func prepareAndListenForCommand() async {
        guard await ensurePermissions() else { return }
        guard !Task.isCancelled else { return }
        listenForCommand()
    }

    private func ensurePermissions() async -> Bool {
        state = .preparing
        let allowed = await speechRecognition.requestPermissions()
        guard !Task.isCancelled else { return false }
        if !allowed {
            state = .error("설정에서 마이크와 음성 인식 권한을 허용해주세요.")
        }
        return allowed
    }

    private func listenForCommand() {
        speechSynthesis.stop()
        recognitionID = UUID()
        let sessionID = recognitionID
        latestCommand = ""
        isFinalizingCommand = false
        transcript = ""
        voiceActivityLevel = 0
        state = .listeningForCommand

        do {
            try speechRecognition.start(
                onAudioLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.recognitionID == sessionID,
                              self.state == .listeningForCommand else { return }
                        self.voiceActivityLevel = level
                    }
                },
                onPartial: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.recognitionID == sessionID else { return }
                        self.receivedCommandText(text, isFinal: false)
                    }
                },
                onFinal: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.recognitionID == sessionID else { return }
                        self.receivedCommandText(text, isFinal: true)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.recognitionID == sessionID else { return }
                        self.handleRecognitionError(error)
                    }
                }
            )
        } catch {
            handleRecognitionError(error)
        }
    }

    private func receivedCommandText(_ text: String, isFinal: Bool) {
        guard state == .listeningForCommand, !isFinalizingCommand else { return }
        recognitionRetryCount = 0
        latestCommand = text
        transcript = text
        silenceTask?.cancel()

        if isFinal {
            finalizeCommand()
        } else {
            silenceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                self?.finalizeCommand()
            }
        }
    }

    private func finalizeCommand() {
        guard !isFinalizingCommand else { return }
        let command = latestCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        isFinalizingCommand = true
        silenceTask?.cancel()
        // Release the recording route before any response TTS configures its
        // playback route. Keeping playAndRecord active here can leave the
        // synthesizer silent while the UI remains in the speaking state.
        speechRecognition.stop(deactivateSession: true)
        voiceActivityLevel = 0
        state = .transcribing
        appendMessage(role: .user, text: command)
        startProcessing(command, source: .voice)
    }

    private func startProcessing(_ text: String, source: InputSource) {
        cancelCurrentWork()
        processingTask = Task { await process(text, source: source) }
    }

    private func process(_ text: String, source: InputSource) async {
        state = .thinking
        if let previousAnswerIndex = messages.lastIndex(where: { $0.role == .assistant }),
           let question = messages[..<previousAnswerIndex].last(where: { $0.role == .user }) {
            improvementReview.considerCorrection(question: question.text,
                answer: messages[previousAnswerIndex].text, correction: text)
        }
        if handleActiveSuggestionCommand(text, source: source) {
            return
        }
        // A new unrelated request invalidates the visible proposal so an old
        // target cannot be approved by a later response.
        activeSuggestion = nil
        if await handlePendingDialogue(text, source: source) {
            return
        }
        projectStore.cancelProposal()
        let relevantMemories = longTermMemoryStore.relevantRecords(for: text)
        let managedContext = contextManager.context(
            for: text,
            longTermMemories: relevantMemories.map(\.content)
        )
        let resolution = await agentOrchestrator.resolve(
            text,
            previousIntent: contextManager.latestIntent,
            context: managedContext.semanticResolutionContext,
            semanticResolver: aiClient
        )
        guard !Task.isCancelled else { return }

        let resolved: AgentIntentResolution
        switch resolution {
        case .intent(let intentResolution):
            resolved = intentResolution
        case .clarification(let prompt):
            if source == .voice {
                speakAndResumeListening(prompt)
            } else {
                speakAndFinish(prompt)
            }
            return
        }

        let intent = resolved.intent
        if case .generalConversation = intent {} else { lastReferencedMemories = [] }
        CommandPracticeStore.shared.observe(intent)
        if source == .voice {
            SpeechEvaluationStore.shared.consider(text, intent: intent)
        }
        let executionOrigin: SafetyExecutionOrigin
        switch (source, resolved.source) {
        case (.automation, _):
            executionOrigin = .backgroundAutomation
        case (_, .semanticModel):
            executionOrigin = .modelProposed
        case (_, .deterministic):
            executionOrigin = .directUserRequest
        }

        guard authorize(
            intent,
            originalText: text,
            source: source,
            origin: executionOrigin
        ) else {
            return
        }
        await execute(intent, text: text, source: source, origin: executionOrigin)
    }

    private func execute(
        _ intent: AssistantIntent,
        text: String,
        source: InputSource,
        origin: SafetyExecutionOrigin = .directUserRequest
    ) async {
        guard !Task.isCancelled else { return }
        switch intent {
        case .codexLocal:
            speakAndFinish("Codex 로컬 연결은 Mac 앱의 개발 공간, 멀티 에이전트 화면에서 직접 확인하고 승인해주세요.")
        case .projectWorkflow(let workflow):
            await handleProjectWorkflow(workflow, source: source, origin: origin)
        case .calendarWorkflow(let command):
            await handleCalendarWorkflow(command, source: source, origin: origin)
        case .prepareOuting(let dayOffset):
            await prepareOuting(dayOffset: dayOffset, source: source)
        case .resolveMemoryConflict:
            speakAndFinish("기억 충돌 해결은 설정의 장기 기억 화면에서 선택해주세요.")
        case .macWorkspace:
            speakAndFinish("Mac 개발 공간은 현재 사용을 보류한 상태입니다.")
        case .sharedProject:
            speakAndFinish("공유 폴더는 메인 화면의 개발 공간에서 직접 선택하고 조작해주세요.")
        case .localData, .configureCloudAI, .disableCloudAI, .configureImprovementCollection, .reviewImprovementData,
             .deleteImprovementData, .assistImprovementData, .runResponseEvaluation,
             .configureCommandPractice, .runCommandPractice, .applyCommandPractice, .removeCommandPractice:
            speakAndFinish("OpenAI 연결은 설정의 사용·비사용 버튼에서 직접 변경해주세요.")

        case .dismissConversation:
            contextManager.reset()
            let address = UserProfileStore.load().addressForGreeting
            let message = address.map { "알겠습니다. \($0)." } ?? "알겠습니다."
            speakAndFinish(message)

        case .identifySong:
            let listeningMessage = "노래를 찾아볼게요."
            response = listeningMessage
            appendMessage(role: .assistant, text: listeningMessage)
            state = .speaking

            await speakBeforeAction(listeningMessage)
            guard !Task.isCancelled else { return }
            state = .thinking

            // Music Recognition needs exclusive microphone access. Do not play a
            // second prompt here: release JARVIS's recognition/TTS session after
            // this message finishes and let the music return to normal volume.
            speechRecognition.stop(deactivateSession: true)
            speechSynthesis.stop()
            speechSynthesis.deactivateAudioSession()
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else {
                finishInteraction()
                return
            }

            guard canContinueAction(intent) else { return }
            let request = musicRecognitionShortcut.makeRequest()
            // Store this before opening Shortcuts. iOS can suspend JARVIS as soon
            // as the other app appears, so setting it afterward creates a race.
            pendingSongRecognition = PendingSongRecognition(
                token: request.token,
                userText: text,
                intent: intent
            )
            let launchResult = await toolExecutionCoordinator.execute(
                key: "music-recognition",
                timeout: .seconds(8)
            ) { @MainActor [musicRecognitionShortcut] in
                await musicRecognitionShortcut.run(request)
            }
            guard !Task.isCancelled else { return }
            if launchResult.accepted {
                finishInteraction()
            } else {
                pendingSongRecognition = nil
                speakAndFinish(
                    executionFailureMessage(
                        launchResult,
                        fallback: "노래 찾기 단축어를 열지 못했습니다. 단축어 이름을 확인해주세요."
                    ),
                    remembering: text,
                    intent: intent
                )
            }

        case .playYouTube(let query):
            let destinationResult = await toolExecutionCoordinator.execute(
                key: "youtube-resolve", timeout: .seconds(18), retryPolicy: .once
            ) { @MainActor [youtube] in
                guard let destination = await youtube.resolveDestination(query: query) else {
                    return ToolExecutionResult<YouTubeDestination>.failed(
                        message: "유튜브 주소를 만들지 못했습니다.", retryable: false
                    )
                }
                return .succeeded(destination)
            }
            guard !Task.isCancelled else { return }
            guard case .succeeded(let destination) = destinationResult else {
                speakAndFinish(executionFailureMessage(destinationResult, fallback: "유튜브 검색을 준비하지 못했습니다."))
                return
            }

            let message = destination.opensVideoDirectly
                ? "\(query) 재생 화면을 유튜브에서 열겠습니다."
                : "\(query) 검색 결과를 유튜브에서 열겠습니다."
            rememberInteraction(userText: text, intent: intent, response: message)
            response = message
            appendMessage(role: .assistant, text: message)
            state = .speaking
            await speakBeforeAction(message)
            guard canContinueAction(intent) else { return }
            let result = await toolExecutionCoordinator.execute(key: "youtube-open", timeout: .seconds(8)) { @MainActor [youtube] in
                await youtube.open(destination)
            }
            guard !Task.isCancelled else { return }
            finishExternalExecution(result, fallback: "YouTube를 열지 못했습니다.")

        case .playYouTubePlaylist(let name):
            let destinationResult = await toolExecutionCoordinator.execute(
                key: "youtube-playlist-resolve", timeout: .seconds(18), retryPolicy: .once
            ) { @MainActor [youtube] in
                guard let destination = await youtube.resolvePlaylistDestination(named: name) else {
                    return ToolExecutionResult<YouTubeDestination>.failed(
                        message: "\(name) 재생목록을 찾지 못했습니다. 설정에서 Google 계정을 연결하고 내 재생목록을 동기화해주세요.",
                        retryable: false
                    )
                }
                return .succeeded(destination)
            }
            guard !Task.isCancelled else { return }
            guard case .succeeded(let destination) = destinationResult else {
                let message = executionFailureMessage(destinationResult, fallback: "재생목록을 확인하지 못했습니다.")
                if source == .voice {
                    speakAndResumeListening(message)
                } else {
                    speakAndFinish(message)
                }
                return
            }

            let message = "\(name) 재생목록을 유튜브에서 열겠습니다."
            rememberInteraction(userText: text, intent: intent, response: message)
            response = message
            appendMessage(role: .assistant, text: message)
            state = .speaking
            await speakBeforeAction(message)
            guard canContinueAction(intent) else { return }
            let result = await toolExecutionCoordinator.execute(key: "youtube-open", timeout: .seconds(8)) { @MainActor [youtube] in
                await youtube.open(destination)
            }
            guard !Task.isCancelled else { return }
            finishExternalExecution(result, fallback: "YouTube 재생목록을 열지 못했습니다.")

        case .pauseMedia:
            guard let destination = appLauncher.shortcut(named: "미디어 일시 정지") else {
                speakAndFinish("미디어 중지 단축어 주소를 만들지 못했습니다.")
                return
            }
            let message = "미디어 중지 단축어를 실행하겠습니다."
            rememberInteraction(userText: text, intent: intent, response: message)
            response = message
            appendMessage(role: .assistant, text: message)
            state = .speaking
            await speakBeforeAction(message)
            guard canContinueAction(intent) else { return }
            speechSynthesis.deactivateAudioSession()
            try? await Task.sleep(for: .milliseconds(500))
            guard canContinueAction(intent) else { return }
            let result = await toolExecutionCoordinator.execute(key: "media-pause", timeout: .seconds(8)) { @MainActor [appLauncher] in
                await appLauncher.open(destination)
            }
            guard !Task.isCancelled else { return }
            finishExternalExecution(result, fallback: "미디어 중지 단축어를 열지 못했습니다.")

        case .setVolume(let percent):
            let result = await toolExecutionCoordinator.execute(
                key: "volume-change",
                timeout: .seconds(3)
            ) { @MainActor [systemVolumeService] in
                await systemVolumeService.setVolume(percent: percent)
            }
            switch result {
            case .succeeded(let applied):
                speakAndFinish(
                    "볼륨을 \(applied)퍼센트로 조절했습니다.",
                    remembering: text,
                    intent: intent
                )
            case .handedOff:
                speakAndFinish("볼륨 조절 요청을 시스템에 전달했습니다.")
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                speakAndFinish(message)
            }

        case .adjustVolume(let delta):
            let result = await toolExecutionCoordinator.execute(
                key: "volume-change",
                timeout: .seconds(3)
            ) { @MainActor [systemVolumeService] in
                await systemVolumeService.adjustVolume(delta: delta)
            }
            switch result {
            case .succeeded(let applied):
                speakAndFinish(
                    "볼륨을 \(applied)퍼센트로 조절했습니다.",
                    remembering: text,
                    intent: intent
                )
            case .handedOff:
                speakAndFinish("볼륨 조절 요청을 시스템에 전달했습니다.")
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                speakAndFinish(message)
            }

        case .stopActiveAlarm:
            let result = await toolExecutionCoordinator.executeThrowing(
                key: "alarm-stop-active",
                timeout: .seconds(8),
                operation: { @MainActor [alarmService] in
                    try await alarmService.stopCurrentlyAlertingAlarms()
                },
                mapError: { Self.toolFailure(from: $0, fallback: "현재 울리고 있는 JARVIS 알람을 찾지 못했습니다.") }
            )
            switch result {
            case .succeeded(let stopped):
                let name = stopped.count == 1
                    ? stopped[0].effectiveLabel
                    : "\(stopped[0].effectiveLabel) 외 \(stopped.count - 1)개"
                speakAndFinish(
                    "현재 구동 중인 \(name) 알람을 종료했습니다.",
                    remembering: text,
                    intent: intent
                )
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                speakAndFinish(message, remembering: text, intent: intent)
            case .handedOff:
                speakAndFinish("알람 정지 요청을 시스템에 전달했습니다.", remembering: text, intent: intent)
            }

        case .setAlarm(let request, let label, let message, let delivery):
            let result = await toolExecutionCoordinator.executeThrowing(
                key: "alarm-create",
                timeout: .seconds(15),
                operation: { @MainActor [alarmService] in
                    try await alarmService.schedule(
                        request,
                        label: label,
                        message: message,
                        delivery: delivery
                    )
                },
                mapError: { Self.toolFailure(from: $0, fallback: "알람을 설정하지 못했습니다.") }
            )
            switch result {
            case .succeeded(let alarm):
                speakAndFinish(
                    alarmService.spokenConfirmation(for: alarm, request: request),
                    remembering: text,
                    intent: intent
                )
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                speakAndFinish(message, remembering: text, intent: intent)
            case .handedOff:
                speakAndFinish("알람 설정 요청을 시스템에 전달했습니다.", remembering: text, intent: intent)
            }

        case .listAlarms(let filter):
            let result = await toolExecutionCoordinator.execute(
                key: "alarm-list",
                timeout: .seconds(8),
                retryPolicy: .once
            ) { @MainActor [alarmService] in
                await alarmService.refresh()
                return .succeeded(alarmService.list(filter: filter))
            }
            switch result {
            case .succeeded(let alarms):
                speakAndFinish(alarmListResponse(alarms), remembering: text, intent: intent)
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                speakAndFinish(message, remembering: text, intent: intent)
            case .handedOff:
                speakAndFinish("알람 목록 요청을 시스템에 전달했습니다.", remembering: text, intent: intent)
            }

        case .cancelAlarm(let query):
            let refreshResult: ToolExecutionResult<Void> = await toolExecutionCoordinator.execute(
                key: "alarm-refresh", timeout: .seconds(8)
            ) { @MainActor [alarmService] in
                await alarmService.refresh()
                return .succeeded(())
            }
            guard !Task.isCancelled else { return }
            guard case .succeeded = refreshResult else {
                speakAndFinish(executionFailureMessage(refreshResult, fallback: "알람 목록을 확인하지 못했습니다."))
                return
            }
            let matches = alarmService.matches(for: query)
            if matches.isEmpty {
                speakAndFinish("취소할 알람을 찾지 못했습니다.", remembering: text, intent: intent)
            } else if case .all = query {
                let result: ToolExecutionResult<Void> = await toolExecutionCoordinator.executeThrowing(
                    key: "alarm-delete-all",
                    timeout: .seconds(15),
                    operation: { @MainActor [alarmService] in try await alarmService.deleteAll(confirmed: true) },
                    mapError: { Self.toolFailure(from: $0, fallback: "알람을 취소하지 못했습니다.") }
                )
                switch result {
                case .succeeded:
                    speakAndFinish("모든 알람을 취소했습니다.", remembering: text, intent: intent)
                case .needsPermission(let message), .needsConfirmation(let message),
                        .failed(let message, _), .unverifiable(let message):
                    speakAndFinish(message)
                case .handedOff:
                    speakAndFinish("알람 취소 요청을 시스템에 전달했습니다.")
                }
            } else if matches.count > 1 {
                dialogueManager.begin(
                    .alarmSelection(.init(
                        candidateIDs: matches.map(\.id),
                        operation: .cancel
                    ))
                )
                speakAndResumeListening(alarmClarificationMessage(matches, action: "취소"))
            } else if let alarm = matches.first {
                await cancelAlarm(alarm, userText: text, intent: intent)
            }

        case .updateAlarm(let query, let update):
            let refreshResult: ToolExecutionResult<Void> = await toolExecutionCoordinator.execute(
                key: "alarm-refresh", timeout: .seconds(8)
            ) { @MainActor [alarmService] in
                await alarmService.refresh()
                return .succeeded(())
            }
            guard !Task.isCancelled else { return }
            guard case .succeeded = refreshResult else {
                speakAndFinish(executionFailureMessage(refreshResult, fallback: "알람 목록을 확인하지 못했습니다."))
                return
            }
            let matches = alarmService.matches(for: query)
            if matches.isEmpty {
                speakAndFinish("수정할 알람을 찾지 못했습니다.", remembering: text, intent: intent)
            } else if matches.count > 1 {
                dialogueManager.begin(
                    .alarmSelection(.init(
                        candidateIDs: matches.map(\.id),
                        operation: .update(update)
                    ))
                )
                speakAndResumeListening(alarmClarificationMessage(matches, action: "수정"))
            } else if let alarm = matches.first {
                await updateAlarm(alarm, update: update, userText: text, intent: intent)
            }

        case .fullBriefing:
            let result = await toolExecutionCoordinator.execute(
                key: "briefing-full",
                timeout: .seconds(20),
                retryPolicy: .once
            ) { @MainActor [briefingService] in
                .succeeded(await briefingService.makeFullBriefing())
            }
            finishInformationalResult(result, userText: text, intent: intent)

        case .weather(let request):
            weatherAdviceFacts = nil
            if let weatherResultOverride {
                let result = await weatherResultOverride(request)
                guard !Task.isCancelled else { return }
                weatherAdviceFacts = result.1
                finishInformationalResult(result.0, userText: text, intent: intent)
                return
            }
            let result: ToolExecutionResult<String> = await toolExecutionCoordinator.execute(
                key: "weather-read",
                timeout: .seconds(15),
                retryPolicy: .once
            ) { @MainActor [briefingService] in
                await briefingService.weatherResult(for: request)
            }
            guard !Task.isCancelled else { return }
            weatherAdviceFacts = briefingService.latestWeatherAdviceFacts
            finishInformationalResult(result, userText: text, intent: intent)

        case .calendar(let request):
            let result: ToolExecutionResult<String> = await toolExecutionCoordinator.execute(
                key: "calendar-read",
                timeout: .seconds(15),
                retryPolicy: .once
            ) { @MainActor [briefingService] in
                await briefingService.calendarResult(for: request)
            }
            finishInformationalResult(result, userText: text, intent: intent)

        case .time(let request):
            let message: String
            switch request {
            case .currentTime:
                message = briefingService.makeCurrentTimeResponse()
            case .todayDate:
                message = briefingService.makeTodayDateResponse()
            case .currentDateAndTime:
                message = briefingService.makeCurrentDateAndTimeResponse()
            }
            speakAndFinish(message, remembering: text, intent: intent)

        case .recommendRestaurants(let query):
            let excludePrevious = requestsDifferentRestaurant(text)
            let result = await toolExecutionCoordinator.execute(
                key: "restaurant-read",
                timeout: .seconds(20),
                retryPolicy: .once
            ) { @MainActor [restaurantService] in
                .succeeded(await restaurantService.makeRecommendation(
                    query: query,
                    excludingPrevious: excludePrevious
                ))
            }
            finishInformationalResult(result, userText: text, intent: intent)

        case .webSearch(let query):
            let searchResult = await toolExecutionCoordinator.executeThrowing(
                key: "web-search",
                timeout: .seconds(20),
                retryPolicy: .once,
                operation: { [webSearchService] in try await webSearchService.search(query: query) },
                mapError: {
                    Self.toolFailure(
                        from: $0,
                        fallback: "인터넷 검색 중에 문제가 발생했습니다.",
                        retryable: Self.isTransientToolError($0)
                    )
                }
            )
            guard !Task.isCancelled else { return }
            switch searchResult {
            case .succeeded(let result):
                let clearAnswer: String
                do {
                    clearAnswer = try await aiClient.summarizeWebSearch(
                        query: query,
                        answer: result.text
                    )
                } catch is CancellationError {
                    return
                } catch {
                    clearAnswer = SpokenWebSearchFormatter.clean(result.text)
                }
                guard !Task.isCancelled else { return }
                let spokenPresentation = responsePresenter.make(answer: clearAnswer, for: query)
                let detailedResult = ScreenWebSearchFormatter.clean(result.text)
                let screenAnswer = detailedResult.isEmpty || detailedResult == clearAnswer
                    ? clearAnswer
                    : clearAnswer + "\n\n자세한 내용\n" + detailedResult
                let sourceContext = result.sources.isEmpty
                    ? ""
                    : "\n검색 출처: " + result.sources.map(\.title).joined(separator: ", ")
                rememberInteraction(
                    userText: text,
                    intent: intent,
                    response: screenAnswer + sourceContext
                )
                response = screenAnswer
                appendMessage(role: .assistant, text: screenAnswer, sources: result.sources)
                state = .speaking
                // URL과 출처 제목은 채팅에만 표시한다. TTS에는 듣기 쉽게
                // 다시 작성한 짧은 본문만 전달한다.
                offerSuggestion(after: intent, response: clearAnswer)
                speakCurrent(spokenPresentation.spokenText) { [weak self] in self?.finishInteraction() }
            case .needsPermission(let message), .needsConfirmation(let message),
                    .failed(let message, _), .unverifiable(let message):
                if source == .voice {
                    speakAndResumeListening(message)
                } else {
                    speakAndFinish(message)
                }
            case .handedOff:
                speakAndFinish("검색 요청을 웹 서비스에 전달했습니다.")
            }

        case .remember(let content):
            if longTermMemoryStore.containsSimilar(content) {
                speakAndFinish(
                    "이미 비슷한 내용을 기억하고 있습니다.",
                    remembering: text,
                    intent: intent
                )
            } else if longTermMemoryStore.requiresSensitiveConfirmation(content) {
                dialogueManager.begin(.sensitiveMemoryRequest(content))
                let prompt = "민감한 정보가 포함될 수 있습니다. 이 내용을 장기 기억에 저장할까요?"
                if source == .voice { speakAndResumeListening(prompt) }
                else { speakAndFinish(prompt) }
            } else {
                let result: ToolExecutionResult<Bool> = await toolExecutionCoordinator.execute(
                    key: "memory-create",
                    timeout: .seconds(3)
                ) { @MainActor [longTermMemoryStore] in
                    .succeeded(longTermMemoryStore.add(content, source: .explicitCommand) != nil)
                }
                switch result {
                case .succeeded(true):
                    speakAndFinish("알겠습니다. \(content), 기억하겠습니다.", remembering: text, intent: intent)
                case .succeeded(false), .failed, .unverifiable:
                    speakAndFinish(longTermMemoryStore.storageError ?? "기억할 내용을 확인하지 못했습니다.")
                case .needsPermission(let message), .needsConfirmation(let message):
                    speakAndFinish(message)
                case .handedOff:
                    speakAndFinish("기억 저장 요청을 전달했지만 결과를 확인하지 못했습니다.")
                }
            }

        case .forgetMemory(let scope):
            let result: ToolExecutionResult<String> = await toolExecutionCoordinator.execute(
                key: "memory-delete",
                timeout: .seconds(3)
            ) { @MainActor [longTermMemoryStore] in
                let message: String
                switch scope {
                case .all:
                    let count = longTermMemoryStore.memories.count
                    if count == 0 {
                        message = "삭제할 장기 기억이 없습니다."
                    } else {
                        guard longTermMemoryStore.deleteAll(confirmed: true) else { return .failed(message: "안전 잠금으로 기억 삭제를 중단했습니다.", retryable: false) }
                        message = "저장된 장기 기억 \(count)개를 모두 삭제했습니다."
                    }
                case .latest:
                    if let removed = longTermMemoryStore.deleteLatest() {
                        message = "\(removed.content), 이 기억을 삭제했습니다."
                    } else {
                        message = "삭제할 장기 기억이 없습니다."
                    }
                case .matching(let query):
                    if let removed = longTermMemoryStore.deleteBestMatch(for: query) {
                        message = "\(removed.content), 이 기억을 삭제했습니다."
                    } else {
                        message = "\(query)와 관련된 장기 기억을 찾지 못했습니다."
                    }
                }
                return .succeeded(message)
            }
            finishInformationalResult(result, userText: text, intent: intent)

        case .listMemories:
            let memories = longTermMemoryStore.memories
            guard !memories.isEmpty else {
                speakAndFinish("저장된 장기 기억이 없습니다.")
                return
            }
            let preview = memories.suffix(5).map(\.content).joined(separator: ", ")
            let remainder = memories.count > 5 ? " 그 외 \(memories.count - 5)개는 설정에서 확인할 수 있습니다." : ""
            speakAndFinish("현재 기억하고 있는 내용은 \(preview)입니다.\(remainder)")

        case .navigate(let destination, let mode):
            // Keep public transit as the default for legacy shortcuts that do
            // not include a travel mode, then resolve the place separately.
            await resolveNavigationDestination(
                destination,
                mode: mode ?? .publicTransit,
                userText: text,
                source: source
            )

        case .nearbyPlaces(let category, let wantsNavigation, let mode):
            await searchNearbyPlaces(category, navigate: wantsNavigation, mode: mode, source: source, origin: origin)

        case .call(let recipient, let speakerRequested):
            let resolution = await toolExecutionCoordinator.executeThrowing(
                key: "phone-resolve",
                timeout: .seconds(8),
                operation: { @MainActor [phoneCallService] in
                    try await phoneCallService.resolve(recipient: recipient)
                },
                mapError: { Self.toolFailure(from: $0, fallback: "연락처를 확인하지 못했습니다.") }
            )
            guard !Task.isCancelled else { return }
            switch resolution {
            case .succeeded(let target):
                let speakerNotice = speakerRequested
                    ? " 통화가 시작되면 화면의 스피커 버튼을 눌러주세요."
                    : ""
                let message = "전화 앱에서 \(target.displayName)에게 거는 화면을 열겠습니다.\(speakerNotice)"
                rememberInteraction(userText: text, intent: intent, response: message)
                response = message
                appendMessage(role: .assistant, text: message)
                state = .speaking
                await speakBeforeAction(message)
                guard canContinueAction(intent) else { return }
                speechSynthesis.deactivateAudioSession()
                let result = await toolExecutionCoordinator.execute(key: "phone-call", timeout: .seconds(8)) { @MainActor [phoneCallService] in
                    await phoneCallService.call(target)
                }
                guard !Task.isCancelled else { return }
                finishExternalExecution(result, fallback: "전화 앱을 열지 못했습니다.")
            case .needsPermission(let errorMessage), .needsConfirmation(let errorMessage),
                    .failed(let errorMessage, _), .unverifiable(let errorMessage):
                rememberInteraction(userText: text, intent: intent, response: errorMessage)
                response = errorMessage
                appendMessage(role: .assistant, text: errorMessage)
                state = .speaking
                speakCurrent(errorMessage) { [weak self] in self?.finishInteraction() }
            case .handedOff:
                speakAndFinish("연락처 확인 요청을 시스템에 전달했습니다.")
            }

        case .openApp(let name):
            guard let destination = appLauncher.destination(for: name) else {
                let errorMessage = "\(name) 실행 주소를 만들지 못했습니다."
                response = errorMessage
                appendMessage(role: .assistant, text: errorMessage)
                state = .error(errorMessage)
                return
            }

            let message = "\(name)\(objectParticle(for: name)) 열겠습니다."
            rememberInteraction(userText: text, intent: intent, response: message)
            response = message
            appendMessage(role: .assistant, text: message)
            state = .speaking
            await speakBeforeAction(message)
            guard canContinueAction(intent) else { return }
            let result = await toolExecutionCoordinator.execute(key: "app-open", timeout: .seconds(8)) { @MainActor [appLauncher] in
                await appLauncher.open(destination)
            }
            guard !Task.isCancelled else { return }
            finishExternalExecution(result, fallback: "\(name) 앱을 열지 못했습니다.")

        case .assistantCapabilities:
            speakAndFinish(
                "노래 찾기, 유튜브 재생과 중지, 볼륨 조절, 알람 설정, 앱 실행, 전화 연결, "
                    + "날씨와 일정 확인, 현재 위치 맛집 추천, 네이버 지도 길 안내, "
                    + "저장한 유튜브 재생목록 실행, 인터넷 검색, 날짜와 시간 안내, 기본 대화를 할 수 있습니다.",
                remembering: text,
                intent: intent
            )

        case .unknownCommand:
            let message = source == .voice
                ? "명령을 이해하지 못했습니다. 다시 말씀해주세요."
                : "명령을 이해하지 못했습니다. 대상과 할 일을 함께 입력해주세요."
            if source == .voice {
                speakAndResumeListening(message)
            } else {
                speakAndFinish(message)
            }

        case .generalConversation:
            if requestsMemoryExplanation(text) {
                let message: String
                if lastReferencedMemories.isEmpty {
                    message = "이전 답변에서 참고한 장기 기억은 없습니다."
                } else {
                    let details = lastReferencedMemories.prefix(3).map(\.content).joined(separator: ", ")
                    message = "이전 답변은 저장된 기억 ‘\(details)’을 관련 정보로 참고했습니다. 실행 권한이나 안전 판단에는 사용하지 않았습니다."
                }
                speakAndFinish(message, remembering: text, intent: intent)
                return
            }
            do {
                let relevantMemories = longTermMemoryStore.relevantRecords(for: text)
                longTermMemoryStore.markReferenced(ids: relevantMemories.map(\.id))
                let snapshot = contextManager.context(
                    for: text,
                    longTermMemories: relevantMemories.map(\.content)
                )
                let context = AIConversationContext(
                    summary: snapshot.summary,
                    recentTurns: snapshot.recentTurns.map {
                        AIConversationTurn(
                            userText: $0.userText,
                            assistantResponse: $0.assistantResponse
                        )
                    },
                    longTermMemories: snapshot.longTermMemories
                )
                let memoryToken = UUID()
                memoryAnswerID = memoryToken
                defer { if memoryAnswerID == memoryToken { memoryAnswerID = nil } }
                let answer = try await aiClient.reply(to: text, context: context)
                guard !Task.isCancelled else { return }
                lastReferencedMemories = relevantMemories
                let presentation = responsePresenter.make(answer: answer, for: text)
                let suggestion = rememberInteraction(
                    userText: text,
                    intent: intent,
                    response: presentation.screenText
                )
                let shouldSuggest = suggestion.map {
                    !longTermMemoryStore.containsSimilar($0.content) && longTermMemoryStore.maySuggest($0.content)
                } ?? false
                let deliveredAnswer: String
                if let suggestion, shouldSuggest {
                    dialogueManager.begin(.memorySuggestion(suggestion.content))
                    deliveredAnswer = presentation.screenText + " \(suggestion.content), 이 내용을 장기 기억에 저장할까요?"
                } else {
                    deliveredAnswer = presentation.screenText
                }
                response = deliveredAnswer
                appendMessage(role: .assistant, text: deliveredAnswer)
                state = .speaking
                let spokenAnswer = shouldSuggest
                    ? presentation.spokenText + " 이 내용을 장기 기억에 저장할까요?"
                    : presentation.spokenText
                guard speechOutputEnabled else {
                    finishInteraction()
                    return
                }
                speakCurrent(spokenAnswer) { [weak self] in
                    guard let self else { return }
                    if shouldSuggest, source == .voice { self.listenForCommand() }
                    else { self.finishInteraction() }
                }
            } catch is CancellationError {
                return
            } catch {
                let message = "답변을 만들지 못했습니다."
                if source == .voice {
                    speakAndResumeListening("\(message) 다시 말씀해주세요.")
                } else {
                    state = .error("\(message): \(error.localizedDescription)")
                }
            }
        }
    }

    private func authorize(
        _ intent: AssistantIntent,
        originalText: String,
        source: InputSource,
        origin: SafetyExecutionOrigin,
        wasExplicitlyConfirmed: Bool = false,
        navigationCandidate: NavigationDestinationCandidate? = nil
    ) -> Bool {
        let decision = safetyPolicy.evaluate(
            intent,
            context: SafetyEvaluationContext(
                origin: origin,
                externalActionsLocked: SafetyControlStore.externalActionsLocked,
                wasExplicitlyConfirmed: wasExplicitlyConfirmed
            )
        )

        switch decision {
        case .allow(let risk, let actionName):
            if risk != .informational {
                safetyAuditStore.record(
                    actionName: actionName,
                    risk: risk,
                    outcome: wasExplicitlyConfirmed ? .confirmed : .authorized
                )
            }
            return true

        case .requireConfirmation(let risk, let actionName, let prompt):
            let displayedPrompt: String
            if let navigationCandidate, case .navigate(_, let mode) = intent {
                let method = mode == .car ? "자가용" : "대중교통"
                displayedPrompt = "\(navigationCandidate.name), \(navigationCandidate.area)까지 \(method) 길 안내를 네이버 지도에 전달하도록 승인하시겠습니까?"
            } else { displayedPrompt = prompt }
            dialogueManager.begin(
                .safetyConfirmation(.init(
                    intent: intent,
                    originalText: originalText,
                    actionName: actionName,
                    risk: risk,
                    origin: origin,
                    navigationCandidate: navigationCandidate
                ))
            )
            safetyAuditStore.record(
                actionName: actionName,
                risk: risk,
                outcome: .awaitingConfirmation
            )
            if source == .voice {
                speakAndResumeListening(displayedPrompt)
            } else {
                speakAndFinish(displayedPrompt)
            }
            return false

        case .block(let risk, let actionName, let reason):
            safetyAuditStore.record(
                actionName: actionName,
                risk: risk,
                outcome: .blocked
            )
            speakAndFinish(reason)
            return false
        }
    }

    private func handlePendingDialogue(_ text: String, source: InputSource) async -> Bool {
        guard let dialogue = dialogueManager.current() else { return false }

        // A dismissal must always override the pending question. Otherwise a
        // phrase such as `아냐 됐어` can be mistaken for a place selection or
        // another follow-up before it reaches the main command router.
        if router.route(text) == .dismissConversation || ["취소", "그만", "하지마", "안할래", "취소해"].contains(compactDialogueText(text)) {
            dialogueManager.cancel()
            projectStore.cancelProposal()
            let address = UserProfileStore.load().addressForGreeting
            let message = address.map { "알겠습니다. \($0)." } ?? "알겠습니다."
            speakAndFinish(message)
            return true
        }

        switch dialogue.task {
        case .projectNote(let content, let session):
            guard projectStore.root != nil, projectStore.sessionID == session else {
                dialogueManager.cancel()
                speakAndFinish("공유 폴더 연결이 바뀌어 메모 작성을 취소했습니다. 폴더를 연결한 뒤 다시 요청해주세요.")
                return true
            }
            if startsNewCommand(text) { dialogueManager.cancel(); return false }
            if let request = SharedProjectCommandParser().noteDestination(text, text: content) {
                dialogueManager.complete()
                let intent = AssistantIntent.projectWorkflow(.prepare(request))
                guard authorize(intent, originalText: "공유 메모 경로 확인", source: source, origin: .directUserRequest) else { return true }
                await handleProjectWorkflow(.prepare(request), source: source, origin: .directUserRequest)
            } else if dialogueManager.registerRetry() != nil {
                speakAndFinish("공유 폴더 기준의 파일 경로를 말씀해주세요. 예: 메모/인사.txt. 아직 저장하지 않았습니다.")
            } else { speakAndFinish("저장 위치를 확인하지 못해 메모 작성을 취소했습니다.") }
            return true
        case .calendarEventSelection(let draft, let ids):
            if startsNewCommand(text) { dialogueManager.cancel(); return false }
            let compact = compactDialogueText(text)
            let choices = [["1", "1번", "첫번째"], ["2", "2번", "두번째"], ["3", "3번", "세번째"], ["4", "4번", "네번째"], ["5", "5번", "다섯번째"]]
            if let index = choices.firstIndex(where: { $0.contains(compact) }), ids.indices.contains(index) {
                dialogueManager.complete()
                await handleCalendarWorkflow(.draft(draft), source: source, origin: .directUserRequest, selectedID: ids[index])
            } else if dialogueManager.registerRetry() != nil {
                speakAndFinish("표시한 일정 번호 하나를 말씀해주세요.")
            } else { speakAndFinish("일정 선택을 취소했습니다.") }
            return true
        case .calendarDraft(let draft):
            if startsNewCommand(text) {
                dialogueManager.cancel(); return false
            }
            guard dialogueManager.registerRetry() != nil else {
                speakAndFinish("일정 입력을 취소했습니다. 제목과 날짜·시각을 함께 다시 요청해주세요."); return true
            }
            let refined = CalendarWorkflowParser().refining(draft, with: text)
            await handleCalendarWorkflow(.draft(refined), source: source, origin: .directUserRequest, continuing: true)
            return true
        case .nearbyPlaces(let browsing):
            return await handleNearbyPlaces(browsing, text: text, source: source)
        case .safetyConfirmation(let pending):
            return await handleSafetyConfirmation(pending, text: text, source: source)
        case .memorySuggestion(let content):
            return await handleMemorySuggestion(content, text: text, source: source)
        case .sensitiveMemoryRequest(let content):
            return await handleMemorySuggestion(content, text: text, source: source, memorySource: .explicitCommand)
        case .navigationMode(let navigation):
            return await handleNavigationMode(navigation, text: text, source: source)
        case .navigationDestinationSelection(let selection):
            return await handleNavigationDestinationSelection(
                selection,
                text: text,
                source: source
            )
        case .alarmSelection(let selection):
            return await handleAlarmSelection(selection, text: text, source: source)
        }
    }

    private func handleSafetyConfirmation(
        _ pending: SafetyConfirmationDialogue,
        text: String,
        source: InputSource
    ) async -> Bool {

        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let exactAccepts = ["네", "예", "응", "그래", "좋아", "승인", "확인"]
        let explicitActionAccepts = ["승인해", "진행해", "실행해", "삭제해", "허용해"]
        let rejects = ["아니", "아니야", "취소", "하지마", "됐어", "그만"]

        if exactAccepts.contains(compact)
            || explicitActionAccepts.contains(compact) {
            dialogueManager.complete()
            guard authorize(
                pending.intent,
                originalText: pending.originalText,
                source: source,
                origin: pending.origin,
                wasExplicitlyConfirmed: true
            ) else {
                return true
            }
            if let candidate = pending.navigationCandidate,
               case .navigate(_, let mode) = pending.intent, let mode {
                await openNavigation(PreparedNavigation(candidate: candidate), mode: mode,
                                     userText: pending.originalText, intent: pending.intent)
                return true
            }
            await execute(
                pending.intent,
                text: pending.originalText,
                source: source,
                origin: pending.origin
            )
            return true
        }

        if rejects.contains(compact) {
            dialogueManager.cancel()
            projectStore.cancelProposal()
            safetyAuditStore.record(
                actionName: pending.actionName,
                risk: pending.risk,
                outcome: .cancelled
            )
            speakAndFinish("알겠습니다. 실행하지 않겠습니다.")
            return true
        }

        // 확인 질문과 관계없는 새 명령은 정상 처리하고 이전 승인은 폐기한다.
        dialogueManager.cancel()
        safetyAuditStore.record(
            actionName: pending.actionName,
            risk: pending.risk,
            outcome: .cancelled
        )
        return false
    }

    private func finishInteraction() {
        guard !Task.isCancelled else { return }
        isFinalizingCommand = false
        if speechOutputEnabled { speechSynthesis.deactivateAudioSession() }
        voiceActivityLevel = 0
        state = .idle
        runPendingAutomaticSuggestionIfNeeded()
    }

    private func finishExternalExecution<Value: Sendable>(
        _ result: ToolExecutionResult<Value>,
        fallback: String
    ) {
        switch result {
        case .succeeded, .handedOff:
            finishInteraction()
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            speakAndFinish(message.isEmpty ? fallback : message)
        }
    }

    private func finishInformationalResult(
        _ result: ToolExecutionResult<String>,
        userText: String,
        intent: AssistantIntent
    ) {
        switch result {
        case .succeeded(let message):
            speakAndFinish(message, remembering: userText, intent: intent)
        case .handedOff:
            speakAndFinish("조회 요청을 외부 서비스에 전달했지만 결과는 확인할 수 없습니다.")
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            speakAndFinish(message)
        }
    }

    private func executionFailureMessage<Value: Sendable>(
        _ result: ToolExecutionResult<Value>,
        fallback: String
    ) -> String {
        switch result {
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            return message.isEmpty ? fallback : message
        case .succeeded, .handedOff:
            return fallback
        }
    }

    private nonisolated static func toolFailure<Value: Sendable>(
        from error: Error,
        fallback: String,
        retryable: Bool = false
    ) -> ToolExecutionResult<Value> {
        let localized = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let message = localized.isEmpty ? fallback : localized
        if case LocalDataError.recovery = error { return .unverifiable(message: message) }
        if case LocalDataError.unverified = error { return .unverifiable(message: message) }
        if case LocalDataError.confirmation = error { return .needsConfirmation(message: message) }
        if case LocalDataError.permission = error { return .needsPermission(message: message) }
        let compact = message.lowercased()
        if compact.contains("권한")
            || compact.contains("permission")
            || compact.contains("denied")
            || compact.contains("허용") {
            return .needsPermission(message: message)
        }
        return .failed(message: message, retryable: retryable)
    }

    private nonisolated static func isTransientToolError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed
            ].contains(nsError.code)
        }
        return false
    }

    private func handleMemorySuggestion(_ content: String, text: String, source: InputSource,
        memorySource: LongTermMemorySource = .repeatedConversation) async -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let accepts = ["응", "네", "그래", "좋아", "저장해", "저장해줘", "기억해", "기억해줘"]
        let rejects = ["아니", "아니야", "싫어", "저장하지마", "기억하지마", "취소", "됐어"]

        if accepts.contains(compact) {
            dialogueManager.complete()
            guard authorize(.remember(content: content), originalText: text, source: source, origin: .directUserRequest,
                            wasExplicitlyConfirmed: true) else { return true }
            let result: ToolExecutionResult<Bool> = await toolExecutionCoordinator.execute(
                key: "memory-create",
                timeout: .seconds(3)
            ) { @MainActor [longTermMemoryStore] in
                .succeeded(longTermMemoryStore.add(
                    content,
                    source: memorySource,
                    sensitiveConfirmed: true
                ) != nil)
            }
            if case .succeeded(true) = result {
                speakAndFinish("알겠습니다. 장기 기억에 저장했습니다.")
            } else {
                speakAndFinish(longTermMemoryStore.storageError ?? "장기 기억에 저장하지 못했습니다.")
            }
            return true
        }

        if rejects.contains(compact) {
            dialogueManager.cancel()
            speakAndFinish("알겠습니다. 저장하지 않겠습니다.")
            return true
        }

        // 제안과 관계없는 새 명령은 정상 처리하고 오래된 제안은 폐기한다.
        dialogueManager.cancel()
        return false
    }

    private func handleNavigationMode(
        _ navigation: NavigationModeDialogue,
        text: String,
        source: InputSource
    ) async -> Bool {
        let compactText = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        // Full new commands win even when they contain a transport keyword.
        if startsNewCommand(text) {
            dialogueManager.cancel()
            return false
        }
        if ["취소", "취소해", "그만", "안갈래"].contains(compactText) {
            dialogueManager.cancel()
            speakAndFinish("길 안내를 취소했습니다.")
            return true
        }

        guard let mode = router.navigationTravelMode(from: text) else {
            if startsNewCommand(text) {
                dialogueManager.cancel()
                return false
            }
            guard dialogueManager.registerRetry() != nil else {
                speakAndFinish("이동 방식을 확인하지 못해 길 안내를 취소했습니다.")
                return true
            }
            let message = "자가용 또는 대중교통 중 하나를 말씀해주세요."
            if source == .voice {
                speakAndResumeListening(message)
            } else {
                speakAndFinish(message)
            }
            return true
        }

        dialogueManager.complete()
        await resolveNavigationDestination(
            navigation.destination,
            mode: mode,
            userText: navigation.originalText,
            source: source
        )
        return true
    }

    private func searchNearbyPlaces(_ category: NearbyPlaceCategory, navigate: Bool,
                                    mode: NavigationTravelMode?, source: InputSource,
                                    origin: SafetyExecutionOrigin) async {
        let result = await toolExecutionCoordinator.execute(key: "nearby-places", timeout: .seconds(25)) {
            @MainActor [navigationService] in await navigationService.nearby(category: category)
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .succeeded(let places):
            guard !places.isEmpty else { speakAndFinish("주변 장소를 확인하지 못했습니다."); return }
            let candidates = Array(places.prefix(3))
            dialogueManager.begin(.nearbyPlaces(.init(category: category, candidates: candidates,
                mode: mode, navigationRequested: navigate, origin: origin)))
            let descriptions = candidates.enumerated().map { index, place in
                let distance = place.distance < 1_000 ? "약 \(Int(place.distance))미터" : String(format: "약 %.1f킬로미터", place.distance / 1_000)
                return "\(index + 1)번 \(place.name), 직선거리 \(distance)"
            }.joined(separator: ". ")
            let prompt = "주변 \(category.title)는 \(descriptions)입니다. "
                + (navigate ? "어느 곳으로 안내할까요?" : "영업 여부를 묻거나, 원하는 장소와 이동수단을 말씀해주세요.")
            rememberInteraction(userText: "주변 장소 검색", intent: .nearbyPlaces(category: category, navigate: navigate, mode: mode), response: "장소 후보 선택 대기")
            nearbyReply(prompt, source: source, places: candidates)
        case .needsPermission(let message), .needsConfirmation(let message), .failed(let message, _), .unverifiable(let message):
            nearbyReply(message, source: source)
        case .handedOff: speakAndFinish("주변 장소 검색 요청을 전달했지만 결과를 확인하지 못했습니다.")
        }
    }

    private func nearbyReply(_ text: String, source: InputSource, places: [NearbyPlace] = []) {
        let sources = places.compactMap { place -> WebSearchSource? in
            guard place.id.hasPrefix("google:") else { return nil }
            var url = URLComponents(string: "https://www.google.com/maps/search/")!
            url.queryItems = [.init(name: "api", value: "1"), .init(name: "query", value: place.name),
                              .init(name: "query_place_id", value: String(place.id.dropFirst(7)))]
            guard let link = url.url else { return nil }
            return .init(title: "Google Maps · \(place.name)", url: link)
        }
        if source == .voice { speakAndResumeListening(text, sources: sources) }
        else { speakAndFinish(text, sources: sources) }
    }

    private func handleNearbyPlaces(_ browsing: NearbyPlaceDialogue, text: String, source: InputSource) async -> Bool {
        // Explicit cancellation is handled before this method. A fresh complete
        // destination must never be overwritten by a previous search candidate.
        let resolution = NearbyPlaceFollowUpResolver().resolve(text, dialogue: browsing)
        switch resolution {
        case .unrelated:
            dialogueManager.cancel()
            return false
        case .ambiguous:
            guard dialogueManager.registerRetry() != nil else { speakAndFinish("장소 선택을 취소했습니다. 다시 검색해주세요."); return true }
            nearbyReply("어느 장소인지 번호나 정확한 지점명을 말씀해주세요.", source: source)
        case .details(let place):
            var next = browsing; next.selectedID = place.id
            dialogueManager.updateNearbyPlaces(next)
            nearbyReply("\(place.name)의 주소는 \(place.address)입니다. \(place.hoursDescription())", source: source, places: [place])
        case .select(let place):
            var next = browsing; next.selectedID = place.id
            dialogueManager.updateNearbyPlaces(next)
            if browsing.navigationRequested {
                await continueNearbyNavigation(place, browsing: next, mode: next.mode, text: text, source: source)
            } else {
                nearbyReply("\(place.name)을 선택했습니다. 자가용 또는 대중교통 중 어떻게 안내할까요?", source: source)
            }
        case .navigate(let place, let mode):
            await continueNearbyNavigation(place, browsing: browsing, mode: mode, text: text, source: source)
        }
        return true
    }

    private func continueNearbyNavigation(_ place: NearbyPlace, browsing: NearbyPlaceDialogue,
                                          mode: NavigationTravelMode?, text: String, source: InputSource) async {
        guard let mode else {
            var next = browsing; next.selectedID = place.id
            dialogueManager.updateNearbyPlaces(next)
            nearbyReply("\(place.name)까지 자가용과 대중교통 중 어떤 방법으로 안내할까요?", source: source)
            return
        }
        let intent = AssistantIntent.navigate(destination: place.name, mode: mode)
        dialogueManager.complete()
        let origin: SafetyExecutionOrigin = source == .automation ? .backgroundAutomation : browsing.origin
        guard authorize(intent, originalText: text, source: source, origin: origin,
                        navigationCandidate: place.navigationCandidate) else { return }
        await openNavigation(PreparedNavigation(candidate: place.navigationCandidate), mode: mode, userText: text, intent: intent)
    }

    private func resolveNavigationDestination(
        _ destination: String,
        mode: NavigationTravelMode,
        userText: String,
        source: InputSource
    ) async {
        let result = await toolExecutionCoordinator.executeThrowing(
            key: "navigation-search",
            timeout: .seconds(18),
            retryPolicy: .once,
            operation: { @MainActor [navigationService] in
                try await navigationService.search(destination: destination)
            },
            mapError: {
                Self.toolFailure(
                    from: $0,
                    fallback: "목적지를 확인하지 못했습니다. 지역명이나 지점명을 함께 말씀해주세요.",
                    retryable: Self.isTransientToolError($0)
                )
            }
        )
        guard !Task.isCancelled else { return }
        switch result {
        case .succeeded(let candidates):
            guard !candidates.isEmpty else {
                speakAndFinish("목적지를 찾지 못했습니다. 지역명이나 정확한 지점명을 말씀해주세요.")
                return
            }
            if candidates.count == 1, let candidate = candidates.first {
                await openNavigation(
                    candidate.route,
                    mode: mode,
                    userText: userText,
                    intent: .navigate(destination: candidate.route.destinationName, mode: mode)
                )
                return
            }

            let options = candidates.map {
                $0.route.dialogueCandidate(area: $0.area)
            }
            dialogueManager.begin(
                .navigationDestinationSelection(.init(
                    query: destination,
                    originalText: userText,
                    mode: mode,
                    candidates: options
                ))
            )
            let prompt = navigationCandidatePrompt(options)
            if source == .voice {
                speakAndResumeListening(prompt)
            } else {
                speakAndFinish(prompt)
            }
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            if source == .voice {
                speakAndResumeListening(message)
            } else {
                speakAndFinish(message)
            }
        case .handedOff:
            speakAndFinish("목적지 검색 요청을 지도 서비스에 전달했습니다.")
        }
    }

    private func handleNavigationDestinationSelection(
        _ selection: NavigationDestinationSelectionDialogue,
        text: String,
        source: InputSource
    ) async -> Bool {
        let compact = compactDialogueText(text)
        if ["취소", "취소해", "아니", "그만", "안갈래"].contains(compact) {
            dialogueManager.cancel()
            speakAndFinish("길 안내를 취소했습니다.")
            return true
        }

        if let candidate = NavigationDestinationSelectionResolver().resolve(
            text,
            candidates: selection.candidates
        ) {
            dialogueManager.complete()
            await openNavigation(
                PreparedNavigation(candidate: candidate),
                mode: router.navigationTravelMode(from: text) ?? selection.mode,
                userText: selection.originalText,
                intent: .navigate(destination: candidate.name, mode: selection.mode)
            )
            return true
        }

        if startsNewCommand(text) {
            dialogueManager.cancel()
            return false
        }
        guard dialogueManager.registerRetry() != nil else {
            speakAndFinish("목적지를 구분하지 못해 길 안내를 취소했습니다.")
            return true
        }
        let message = "몇 번 장소인지, 또는 지역과 지점명을 말씀해주세요."
        if source == .voice { speakAndResumeListening(message) }
        else { speakAndFinish(message) }
        return true
    }

    private func navigationCandidatePrompt(
        _ candidates: [NavigationDestinationCandidate]
    ) -> String {
        let choices = candidates.enumerated().map { index, candidate in
            "\(index + 1)번 \(candidate.name), \(candidate.area)"
        }.joined(separator: ". ")
        return "검색 결과가 여러 곳입니다. \(choices). 어디로 갈까요?"
    }

    private func compactDialogueText(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func openNavigation(
        _ route: PreparedNavigation,
        mode: NavigationTravelMode,
        userText: String,
        intent: AssistantIntent
    ) async {
        guard !Task.isCancelled else { return }
        let modeDescription = mode == .car ? "자가용 내비게이션" : "대중교통 경로"
        let message = navigationService.isNaverMapInstalled()
            ? "\(route.destinationName)까지 \(modeDescription)을 네이버 지도에서 열겠습니다."
            : "네이버 지도가 설치되어 있지 않아 설치 화면을 열겠습니다."

        rememberInteraction(userText: userText, intent: intent, response: message)
        response = message
        appendMessage(role: .assistant, text: message)
        state = .speaking
        await speakBeforeAction(message)
        guard !Task.isCancelled else { return }
        // Re-check the emergency lock after speech, before external handoff.
        guard case .allow = safetyPolicy.evaluate(intent, context: .init(
            externalActionsLocked: SafetyControlStore.externalActionsLocked, wasExplicitlyConfirmed: true)) else {
            speakAndFinish("안전 잠금으로 길 안내를 중단했습니다."); return
        }
        speechSynthesis.deactivateAudioSession()

        let result = await toolExecutionCoordinator.execute(
            key: "navigation-open",
            timeout: .seconds(8)
        ) { @MainActor [navigationService] in
            await navigationService.open(route, mode: mode)
        }
        switch result {
        case .succeeded, .handedOff:
            finishInteraction()
        case .needsPermission(let errorMessage), .needsConfirmation(let errorMessage),
                .failed(let errorMessage, _), .unverifiable(let errorMessage):
            speakAndFinish(errorMessage, remembering: userText, intent: intent)
        }
    }

    private func handleAlarmSelection(
        _ selection: AlarmSelectionDialogue,
        text: String,
        source: InputSource
    ) async -> Bool {
        let compactText = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        if startsNewCommand(text) {
            dialogueManager.cancel()
            return false
        }
        if ["취소", "취소해", "아니", "그만"].contains(compactText) {
            dialogueManager.cancel()
            speakAndFinish("알람 작업을 취소했습니다.")
            return true
        }

        let candidates = alarmService.alarms.filter { selection.candidateIDs.contains($0.id) }
        let matched = candidates.filter {
            let label = $0.label.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
            return !label.isEmpty && (compactText.contains(label) || label.contains(compactText))
        }
        guard matched.count == 1, let alarm = matched.first else {
            if startsNewCommand(text) {
                dialogueManager.cancel()
                return false
            }
            guard dialogueManager.registerRetry() != nil else {
                speakAndFinish("알람을 구분하지 못해 작업을 취소했습니다.")
                return true
            }
            let message = alarmClarificationMessage(candidates, action: "선택")
            if source == .voice { speakAndResumeListening(message) }
            else { speakAndFinish(message) }
            return true
        }

        dialogueManager.complete()
        switch selection.operation {
        case .cancel:
            guard authorize(.cancelAlarm(.named(alarm.label)), originalText: text, source: source, origin: .directUserRequest) else { return true }
            await cancelAlarm(alarm, userText: text, intent: .cancelAlarm(.named(alarm.label)))
        case .update(let update):
            guard authorize(.updateAlarm(query: .named(alarm.label), update: update), originalText: text, source: source, origin: .directUserRequest) else { return true }
            await updateAlarm(
                alarm,
                update: update,
                userText: text,
                intent: .updateAlarm(query: .named(alarm.label), update: update)
            )
        }
        return true
    }

    private func startsNewCommand(_ text: String) -> Bool {
        if case .replace = dialogueInputResolver.classify(text) { return true }
        return false
    }

    private func cancelAlarm(
        _ alarm: JarvisAlarmRecord,
        userText: String,
        intent: AssistantIntent
    ) async {
        let result: ToolExecutionResult<Void> = await toolExecutionCoordinator.executeThrowing(
            key: "alarm-delete-\(alarm.id.uuidString)",
            timeout: .seconds(12),
            operation: { @MainActor [alarmService] in
                try await alarmService.delete(id: alarm.id, expected: alarm)
            },
            mapError: { Self.toolFailure(from: $0, fallback: "알람을 취소하지 못했습니다.") }
        )
        switch result {
        case .succeeded:
            let name = alarm.label.isEmpty ? alarmService.formattedDate(alarm.date) : alarm.label
            speakAndFinish("\(name) 알람을 취소했습니다.", remembering: userText, intent: intent)
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            speakAndFinish(message)
        case .handedOff:
            speakAndFinish("알람 취소 요청을 시스템에 전달했습니다.")
        }
    }

    private func updateAlarm(
        _ alarm: JarvisAlarmRecord,
        update: AlarmUpdate,
        userText: String,
        intent: AssistantIntent
    ) async {
        let result = await toolExecutionCoordinator.executeThrowing(
            key: "alarm-update-\(alarm.id.uuidString)",
            timeout: .seconds(15),
            operation: { @MainActor [alarmService] in
                let date = try update.request.map { try alarmService.resolvedDate(for: $0) }
                let label = update.label
                let message = label.map(alarmService.message(forLabel:))
                return try await alarmService.update(
                    id: alarm.id,
                    date: date,
                    label: label,
                    message: message,
                    expected: alarm
                )
            },
            mapError: { Self.toolFailure(from: $0, fallback: "알람을 수정하지 못했습니다.") }
        )
        switch result {
        case .succeeded(let updated):
            let response = "\(updated.effectiveLabel) 알람을 \(alarmService.formattedDate(updated.date))로 변경했습니다."
            speakAndFinish(response, remembering: userText, intent: intent)
        case .needsPermission(let message), .needsConfirmation(let message),
                .failed(let message, _), .unverifiable(let message):
            speakAndFinish(message)
        case .handedOff:
            speakAndFinish("알람 수정 요청을 시스템에 전달했습니다.")
        }
    }

    private func alarmListResponse(_ alarms: [JarvisAlarmRecord]) -> String {
        guard !alarms.isEmpty else { return "등록된 알람이 없습니다." }
        return alarms.prefix(5).map {
            "\(alarmService.formattedDate($0.date)) \($0.effectiveLabel) 알람"
        }.joined(separator: ", ") + (alarms.count > 5 ? " 외 \(alarms.count - 5)개가 있습니다." : "이 있습니다.")
    }

    private func alarmClarificationMessage(
        _ alarms: [JarvisAlarmRecord],
        action: String
    ) -> String {
        let names = alarms.prefix(4).map {
            $0.label.isEmpty ? alarmService.formattedDate($0.date) : $0.label
        }.joined(separator: "과 ")
        return "일치하는 알람이 \(alarms.count)개 있습니다. \(names) 중 어떤 알람을 \(action)할까요?"
    }

    private func handleProjectWorkflow(_ workflow: SharedProjectWorkflow, source: InputSource, origin: SafetyExecutionOrigin) async {
        switch workflow {
        case .noteDraft(let content):
            guard projectStore.root != nil else {
                speakAndFinish("TXT 메모를 만들 수 있습니다. 먼저 개발 공간에서 저장할 공유 폴더를 선택하고 접근을 허용해주세요. 연결 후 다시 요청하면 파일 위치를 확인하고 승인받아 저장하겠습니다.")
                return
            }
            dialogueManager.begin(.projectNote(text: content, sessionID: projectStore.sessionID))
            let prompt = "어떤 파일 경로에 저장할까요? 공유 폴더 기준으로 메모/인사.txt처럼 말씀해주세요. 내용은 보관 중이며 아직 파일을 만들지 않았습니다."
            if source == .voice { speakAndResumeListening(prompt) } else { speakAndFinish(prompt) }
        case .clarify:
            speakAndFinish("공유 폴더 기준의 정확한 경로와 할 일을 말씀해주세요. 예를 들어 공유 폴더의 메모 폴더 만들어줘, 또는 공유 폴더의 메모/장보기.txt 메모 만들어줘 내용: 우유와 달걀이라고 요청할 수 있습니다. 모호한 위치는 추측하지 않습니다.")
        case .prepare(let request):
            let result = await projectStore.prepare(request)
            guard !Task.isCancelled else { projectStore.cancelProposal(); return }
            switch result {
            case .succeeded(let plan):
                let final = AssistantIntent.projectWorkflow(.commit(plan))
                guard authorize(final, originalText: "공유 프로젝트 작업", source: source, origin: origin) else { return }
                await handleProjectWorkflow(.commit(plan), source: source, origin: origin)
            case .needsPermission(let m), .needsConfirmation(let m), .failed(let m, _), .unverifiable(let m): speakAndFinish(m)
            case .handedOff: speakAndFinish("작업 준비 결과를 확인하지 못했습니다.")
            }
        case .commit(let plan):
            let result = await projectStore.commit(plan, confirmed: true)
            guard !Task.isCancelled else { return }
            switch result {
            case .succeeded(let m): speakAndFinish(m)
            case .needsPermission(let m), .needsConfirmation(let m), .failed(let m, _), .unverifiable(let m): speakAndFinish(m)
            case .handedOff: speakAndFinish("파일 제공자에게 요청을 전달했지만 실행을 확인하지 못했습니다.")
            }
        }
    }

    private func handleCalendarWorkflow(_ command: CalendarWorkflowCommand, source: InputSource,
        origin: SafetyExecutionOrigin, continuing: Bool = false, selectedID: UUID? = nil) async {
        switch command {
        case .day(let offset):
            let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            let events = calendarStore.events(on: date)
            let message = events.isEmpty ? "해당 날짜에 등록된 일정이 없습니다." : events.prefix(8).map {
                "\($0.startDate.formatted(date: .abbreviated, time: .shortened)) \($0.title)"
            }.joined(separator: ". ")
            speakAndFinish(message, remembering: "일정 조회", intent: .calendarWorkflow(command))
        case .draft(let draft):
            if let prompt = CalendarWorkflowParser().clarification(for: draft) {
                if continuing { dialogueManager.updateCalendarDraft(draft) }
                else { dialogueManager.begin(.calendarDraft(draft)) }
                if source == .voice { speakAndResumeListening(prompt) } else { speakAndFinish(prompt) }
                return
            }
            var existing: JarvisCalendarEvent?
            if draft.operation != .create {
                let matches = calendarStore.events.filter { $0.title == draft.title && (selectedID == nil || $0.id == selectedID) }
                guard !matches.isEmpty else { speakAndFinish("해당 제목의 일정을 찾지 못했습니다. 캘린더에서 제목을 확인해주세요."); return }
                if matches.count > 1 {
                    let options = Array(matches.prefix(5))
                    dialogueManager.begin(.calendarEventSelection(draft: draft, ids: options.map(\.id)))
                    let prompt = options.enumerated().map { "\($0.offset + 1)번 \($0.element.startDate.formatted(date: .abbreviated, time: .shortened)) \($0.element.title)" }.joined(separator: ". ")
                    if source == .voice { speakAndResumeListening(prompt + ". 몇 번 일정인가요?") } else { speakAndFinish(prompt + ". 몇 번 일정인가요?") }
                    return
                }
                existing = matches[0]
                if existing?.recurrence != JarvisCalendarRecurrence.none {
                    speakAndFinish("반복 일정은 한 번만 바꿀지 전체를 바꿀지 확인이 필요합니다. 캘린더 화면에서 수정·삭제해주세요.")
                    return
                }
            }
            let deleting = draft.operation == .delete
            guard let start = deleting ? existing?.startDate : CalendarWorkflowParser().date(for: draft, now: Date()) else {
                speakAndFinish("시작 시각이 지났거나 지원하지 않는 날짜입니다. 오늘 또는 내일의 미래 시각을 다시 말씀해주세요."); return
            }
            let duration = draft.operation == .move && !draft.durationWasExplicit
                ? existing.map { $0.endDate.timeIntervalSince($0.startDate) } ?? 3_600
                : Double(draft.durationMinutes) * 60
            let end = deleting ? (existing?.endDate ?? start) : start.addingTimeInterval(duration)
            let conflicts = deleting ? [] : calendarStore.conflicts(start: start, end: end, excluding: existing?.id)
            let change = CalendarEventChange(id: existing?.id, expectedUpdatedAt: existing?.updatedAt,
                title: draft.title, start: start, end: end, outdoor: existing?.isOutdoor ?? draft.outdoor,
                deleting: deleting, conflictIDs: conflicts.map(\.id))
            dialogueManager.complete()
            let final = AssistantIntent.calendarWorkflow(.commit(change))
            // Conflict information is part of the action-specific confirmation.
            let conflictText = conflicts.isEmpty ? "" : "겹치는 일정: " + conflicts.prefix(3).map(\.title).joined(separator: ", ") + ". 겹쳐도 진행할까요? "
            let original = conflictText + "일정 변경"
            guard authorize(final, originalText: original, source: source, origin: origin) else {
                if !conflictText.isEmpty { response = conflictText + response; if let last = messages.last, last.role == .assistant { messages[messages.count - 1] = ChatMessage(role: .assistant, text: response) } }
                return
            }
            await handleCalendarWorkflow(.commit(change), source: source, origin: origin)
        case .commit(let change):
            let result: ToolExecutionResult<String> = await toolExecutionCoordinator.execute(key: "calendar-mutation", timeout: .seconds(25)) { @MainActor [self] in
                guard !Task.isCancelled, !SafetyControlStore.externalActionsLocked else { return .failed(message: "일정 변경을 중단했습니다.", retryable: false) }
                let existing = change.id.flatMap { calendarStore.event(id: $0) }
                if change.id != nil, existing?.updatedAt != change.expectedUpdatedAt {
                    return .failed(message: "확인 중 일정이 변경되었거나 삭제됐습니다. 다시 요청해주세요.", retryable: false)
                }
                if !change.deleting {
                    guard TimeZone.current.identifier == change.timeZoneID else { return .needsConfirmation(message: "기기의 시간대가 바뀌었습니다. 날짜와 시각을 다시 확인해주세요.") }
                    let current = Set(calendarStore.conflicts(start: change.start, end: change.end, excluding: change.id).map(\.id))
                    guard current == Set(change.conflictIDs) else { return .needsConfirmation(message: "겹치는 일정이 바뀌었습니다. 다시 요청해 확인해주세요.") }
                    guard change.start > Date() else { return .failed(message: "시작 시각이 지났습니다. 다시 설정해주세요.", retryable: false) }
                }
                do {
                    if change.deleting, let existing {
                        try LocalDataExecution.value(await CalendarDataExecution.delete(existing, store: calendarStore,
                            confirmed: true, cancel: cancelCalendarEvent))
                        return .succeeded("\(change.title) 일정을 삭제했습니다.")
                    }
                    let saved: JarvisCalendarEvent
                    if var existing {
                        existing.startDate = change.start; existing.endDate = change.end
                        saved = existing
                    } else {
                        saved = JarvisCalendarEvent(id: UUID(), title: change.title, startDate: change.start,
                            endDate: change.end, isAllDay: false, isOutdoor: change.outdoor, location: "", notes: "",
                            urlString: "", recurrence: .none, reminderMinutesBefore: 0, createdAt: Date(), updatedAt: Date())
                    }
                    let mutation = await CalendarDataExecution.save(saved, store: calendarStore,
                        expectedUpdatedAt: existing?.updatedAt, confirmed: true, schedule: scheduleCalendarEvent)
                    switch mutation {
                    case .succeeded: break
                    case .unverifiable(let message): return .unverifiable(message: message)
                    case .needsPermission(let message): return .needsPermission(message: message)
                    case .needsConfirmation(let message): return .needsConfirmation(message: message)
                    case .failed(let message, let retry): return .failed(message: message, retryable: retry)
                    case .handedOff: return .unverifiable(message: "일정 변경 결과를 확인하지 못했습니다.")
                    }
                    return .succeeded("\(change.start.formatted(date: .abbreviated, time: .shortened))에 \(change.title) 일정을 저장했습니다. " + (saved.reminderMinutesBefore == nil ? "알림은 꺼져 있습니다." : "알림을 예약했습니다."))
                } catch { return .failed(message: "일정 변경에 실패했습니다. 날짜와 제목을 확인해주세요.", retryable: false) }
            }
            guard !Task.isCancelled else { return }
            finishInformationalResult(result, userText: "일정 작업", intent: .calendarWorkflow(command))
        }
    }

    private func prepareOuting(dayOffset: Int, source: InputSource) async {
        var budget = BoundedPlanBudget()
        guard budget.takeStep(), (0...1).contains(dayOffset) else { speakAndFinish("오늘 또는 내일의 외출 준비를 요청해주세요."); return }
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        let events = calendarStore.events(on: date).filter { $0.startDate > Date() }
        guard let event = events.first(where: { $0.isOutdoor }) ?? events.first else { speakAndFinish("해당 날짜에 앞으로 남은 일정이 없습니다. 외출할 시각과 장소를 먼저 일정에 등록해주세요."); return }
        var lines = ["\(event.startDate.formatted(date: .abbreviated, time: .shortened)) \(event.title) 일정이 있습니다."]
        if event.isOutdoor {
            guard budget.takeStep() else { speakAndFinish("외출 준비 조회를 중단했습니다."); return }
            let result: ToolExecutionResult<String> = await toolExecutionCoordinator.executeThrowing(key: "outing-weather", timeout: .seconds(15), operation: { @MainActor in
                if let override = self.outingForecastOverride { return try await override(event.startDate, event.location) }
                guard let summary = try await CalendarWeatherForecastService().summary(for: event.startDate, locationName: event.location) else {
                    throw URLError(.cannotParseResponse)
                }
                return summary
            }, mapError: { _ in .unverifiable(message: "날씨 조회에 실패해 옷차림·우산 필요 여부를 확정할 수 없습니다.") })
            guard !Task.isCancelled else { return }
            if case .succeeded(let weather) = result { lines.append(weather) }
            else {
                lines.append(executionFailureMessage(result, fallback: "날씨를 확인하지 못했습니다."))
                lines.append("준비 조회를 중단했으며 준비 알림은 만들지 않았습니다.")
                speakAndFinish(lines.joined(separator: " ")); return
            }
            if event.location.isEmpty { lines.append("장소가 없어 날씨는 현재 위치 기준입니다.") }
        } else { lines.append("야외 여부가 등록되지 않아 야외 날씨는 자동 조회하지 않았습니다.") }
        lines.append("이동 시간은 확인하지 않았으므로 출발 시각은 직접 정해주세요.")
        speakAndFinish(lines.joined(separator: " "))
        let reminderDate = event.startDate.addingTimeInterval(-15 * 60)
        if !event.isAllDay, reminderDate > Date(), budget.takeStep() {
            let c = Calendar.current.dateComponents([.hour, .minute], from: reminderDate)
            let hour = c.hour ?? 0
            let day: AlarmDaySelection = Calendar.current.isDateInToday(reminderDate) ? .today : .tomorrow
            let suggestion = ProactiveSuggestion(id: "outing.reminder", title: "일정 15분 전에 준비 알림을 설정할까요?",
                reason: "등록된 다음 일정 기준이며 이동 시간은 반영하지 않았습니다.",
                proposedIntent: .setAlarm(request: .atTime(hour: hour % 12 == 0 ? 12 : hour % 12,
                    minute: c.minute ?? 0, period: hour >= 12 ? .pm : .am, day: day),
                    label: "일정 준비", message: "일정을 준비하실 시간입니다.", delivery: .jarvisVoice))
            presentSuggestion(suggestion)
            if state == .idle { runPendingAutomaticSuggestionIfNeeded() }
        }
    }

    /// All non-awaiting callbacks are bound to the current interaction, including
    /// callbacks already queued by AVSpeechSynthesizer when Stop was pressed.
    private func speakCurrent(_ text: String, completion: @escaping @MainActor () -> Void) {
        guard !Task.isCancelled else { return }
        let token = interactionID
        let playback = UUID()
        speechPlaybackID = playback
        guard speechOutputEnabled else { completion(); return }
        speechSynthesis.speak(text) { [weak self] in
            Task { @MainActor in
                guard let self, self.interactionID == token, self.speechPlaybackID == playback else { return }
                self.speechPlaybackID = UUID() // Completion is single-use, even within one turn.
                completion()
            }
        }
    }

    /// Unlike a bare checked continuation, cancellation/Stop/new input releases
    /// the waiter even when the synthesizer omits its completion callback.
    private func speakBeforeAction(_ text: String) async {
        guard speechOutputEnabled, !Task.isCancelled else { return }
        let token = interactionID
        speechPlaybackID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiter = SpeechWaiter(continuation)
                speechWaiter = waiter
                speechSynthesis.speak(text) { waiter.finish() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.interactionID == token else { return }
                self.speechWaiter?.finish()
                self.speechWaiter = nil
                self.speechSynthesis.stop()
            }
        }
        if interactionID == token { speechWaiter = nil }
    }

    private func canContinueAction(_ intent: AssistantIntent) -> Bool {
        guard !Task.isCancelled else { return false }
        // This is a recheck of an already-authorized action, not new approval.
        guard case .allow = safetyPolicy.evaluate(intent, context: .init(
            externalActionsLocked: SafetyControlStore.externalActionsLocked,
            wasExplicitlyConfirmed: true)) else {
            speakAndFinish("안전 잠금으로 실행을 중단했습니다.")
            return false
        }
        return true
    }

    private func speakAndFinish(
        _ message: String,
        remembering userText: String? = nil,
        intent: AssistantIntent? = nil,
        sources: [WebSearchSource] = []
    ) {
        guard !Task.isCancelled else { return }
        if let userText, let intent {
            rememberInteraction(userText: userText, intent: intent, response: message)
            offerSuggestion(after: intent, response: message)
        }
        response = message
        appendMessage(role: .assistant, text: message, sources: sources)
        guard speechOutputEnabled else {
            finishInteraction()
            return
        }
        state = .speaking
        speakCurrent(message) { [weak self] in self?.finishInteraction() }
    }

    private func speakShortcutResult(
        _ message: String,
        remembering userText: String? = nil,
        intent: AssistantIntent? = nil
    ) {
        shortcutResponseTask?.cancel()
        speechSynthesis.stop()
        speechSynthesis.deactivateAudioSession()
        state = .thinking

        shortcutResponseTask = Task { [weak self] in
            // The Shortcuts/Shazam audio session can still own the route at the
            // exact moment JARVIS is reopened. Give iOS time to return it before TTS.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            self.speakAndFinish(message, remembering: userText, intent: intent)
            self.shortcutResponseTask = nil
        }
    }

    private func speakAndResumeListening(_ message: String, sources: [WebSearchSource] = []) {
        guard !Task.isCancelled else { return }
        response = message
        appendMessage(role: .assistant, text: message, sources: sources)
        guard speechOutputEnabled else {
            finishInteraction()
            return
        }
        state = .speaking
        speakCurrent(message) { [weak self] in self?.listenForCommand() }
    }

    @discardableResult
    private func rememberInteraction(
        userText: String,
        intent: AssistantIntent,
        response: String
    ) -> ConversationMemorySuggestion? {
        contextManager.record(
            userText: userText,
            assistantResponse: response,
            intent: intent
        )
    }

    private func handleRecognitionError(_ error: Error) {
        guard state == .listeningForCommand else { return }
        recognitionID = UUID()
        silenceTask?.cancel()
        SpeechDiagnosticsStore.shared.recognitionFailed()
        speechRecognition.stop(deactivateSession: true)

        if recognitionRetryCount == 0 {
            recognitionRetryCount += 1
            speakAndResumeListening("잘 듣지 못했습니다. 다시 말씀해주세요.")
        } else {
            speechSynthesis.deactivateAudioSession()
            state = .error("음성 인식 오류: \(error.localizedDescription)")
        }
    }

    private func appendMessage(
        role: ChatMessage.Role,
        text: String,
        sources: [WebSearchSource] = []
    ) {
        messages.append(ChatMessage(role: role, text: text, sources: sources))
    }

    private func offerSuggestion(after intent: AssistantIntent, response: String) {
        recentIntentKeys.append(intent.suggestionFamilyKey)
        if recentIntentKeys.count > 12 {
            recentIntentKeys.removeFirst(recentIntentKeys.count - 12)
        }
        let suggestion: ProactiveSuggestion?
        if case .weather = intent, let facts = weatherAdviceFacts {
            suggestion = WeatherAdviceEngine().suggestion(for: facts)
        } else {
            suggestion = suggestionEngine.suggestion(after: intent, response: response, recentIntentKeys: recentIntentKeys)
        }
        guard let suggestion else { return }
        presentSuggestion(suggestion)
    }

    private func presentSuggestion(_ suggestion: ProactiveSuggestion) {
        guard activeSuggestion == nil, pendingAutomaticSuggestion == nil,
              suggestionSettings.canPresent(suggestion) else { return }
        suggestionSettings.markPresented(suggestion)
        suggestionSettings.record(suggestion, outcome: "presented")
        if let intent = suggestion.proposedIntent,
           case .block(let risk, let name, _) = safetyPolicy.evaluate(intent, context: .init(
                origin: .proactiveSuggestion, externalActionsLocked: SafetyControlStore.externalActionsLocked)) {
            safetyAuditStore.record(actionName: name, risk: risk, outcome: .blocked)
            suggestionSettings.record(suggestion, outcome: "blocked")
            return
        }
        if suggestionSettings.mode == .automatic { pendingAutomaticSuggestion = suggestion }
        else { activeSuggestion = suggestion }
    }

    private func runPendingAutomaticSuggestionIfNeeded() {
        guard suggestionSettings.mode == .automatic,
              let suggestion = pendingAutomaticSuggestion else {
            pendingAutomaticSuggestion = nil
            return
        }
        pendingAutomaticSuggestion = nil
        guard Date() < suggestion.expiresAt else { suggestionSettings.record(suggestion, outcome: "expired"); return }
        guard let intent = suggestion.proposedIntent else {
            suggestionSettings.record(suggestion, outcome: "advicePresented")
            speakAndFinish(suggestion.title)
            return
        }
        let command = "능동 제안 자동 실행: \(suggestion.title)"
        guard authorize(
            intent,
            originalText: command,
            source: .automation,
            origin: .proactiveSuggestion
        ) else {
            suggestionSettings.record(suggestion, outcome: "confirmationOrBlock")
            return
        }
        suggestionSettings.record(suggestion, outcome: "autoRequested")
        processingTask = Task { await execute(intent, text: command, source: .automation, origin: .proactiveSuggestion) }
    }

    private func handleActiveSuggestionCommand(_ text: String, source: InputSource) -> Bool {
        guard activeSuggestion != nil else { return false }
        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let accepts = [
            "제안실행해", "제안대로해", "그제안실행해",
            "그거실행해", "그대로해줘", "진행해줘"
        ]
        if accepts.contains(compact) {
            acceptActiveSuggestion(source: source, approvalText: text)
            return true
        }
        let rejects = ["제안취소", "제안하지마", "그건되어", "안할래"]
        if rejects.contains(where: compact.contains) {
            activeSuggestion = nil
            speakAndFinish("알겠습니다. 해당 제안은 실행하지 않겠습니다.")
            return true
        }
        return false
    }

    private func requestsMemoryExplanation(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        return [
            "왜이렇게답했", "왜그렇게답했", "어떤기억을참고",
            "뭘참고했", "이답변은왜", "왜이렇게말했"
        ].contains(where: compact.contains)
    }

    private func objectParticle(for text: String) -> String {
        guard let scalar = text.unicodeScalars.last else { return "을" }
        let value = scalar.value
        guard (0xAC00...0xD7A3).contains(value) else { return "을" }
        return (value - 0xAC00).isMultiple(of: 28) ? "를" : "을"
    }

    private func requestsDifferentRestaurant(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        return ["다른곳", "다른집", "다른가게", "또다른", "또추천"]
            .contains(where: compact.contains)
    }

}
