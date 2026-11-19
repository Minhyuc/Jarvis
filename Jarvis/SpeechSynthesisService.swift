import AVFoundation
import Combine

struct SpeechVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let language: String
    let quality: String

    var displayName: String {
        quality.isEmpty ? name : "\(name) · \(quality)"
    }
}

extension Notification.Name {
    static let jarvisSpeechVoiceChanged = Notification.Name("com.minhyuc.jarvis.speechVoiceChanged")
    static let jarvisSpeechPreviewRequested = Notification.Name("com.minhyuc.jarvis.speechPreviewRequested")
    static let jarvisSpeechPreviewStopRequested = Notification.Name("com.minhyuc.jarvis.speechPreviewStopRequested")
}

@MainActor
enum SpeechVoicePreferenceStore {
    private static let selectedVoiceKey = "jarvis.selectedSpeechVoiceIdentifier"

    static var selectedVoiceIdentifier: String {
        UserDefaults.standard.string(forKey: selectedVoiceKey) ?? ""
    }

    static func save(_ identifier: String) {
        guard identifier != selectedVoiceIdentifier else { return }
        if identifier.isEmpty {
            UserDefaults.standard.removeObject(forKey: selectedVoiceKey)
        } else {
            UserDefaults.standard.set(identifier, forKey: selectedVoiceKey)
        }
        NotificationCenter.default.post(name: .jarvisSpeechVoiceChanged, object: nil)
    }

    static func availableKoreanVoices() -> [SpeechVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("ko") }
            .map {
                SpeechVoiceOption(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: qualityName(for: $0.quality)
                )
            }
            .sorted {
                if $0.quality != $1.quality {
                    return qualityRank($0.quality) > qualityRank($1.quality)
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static func qualityName(for quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "프리미엄"
        case .enhanced: return "고품질"
        default: return "기본"
        }
    }

    private static func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "프리미엄": return 3
        case "고품질": return 2
        default: return 1
        }
    }
}

@MainActor
final class SpeechVoicePreviewPlayer: ObservableObject {
    private let output: SpeechSynthesisService
    private var stopObserver: NSObjectProtocol?

    init(output: SpeechSynthesisService? = nil) {
        self.output = output ?? SpeechSynthesisService()
        stopObserver = NotificationCenter.default.addObserver(forName: .jarvisSpeechPreviewStopRequested,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }
    deinit { if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) } }

    func play(voiceIdentifier: String) {
        // The VM releases recognition/action waiters before a preview starts.
        NotificationCenter.default.post(name: .jarvisSpeechPreviewRequested, object: nil)
        output.speak("안녕하세요. 선택하신 자비스 음성입니다.", preferredVoiceIdentifier: voiceIdentifier)
    }

    func stop() { output.stop() }
}

/// Injectable transport so lifecycle/voice retries can be tested without audio.
@MainActor
protocol SpeechSynthesizerDriving: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var usesApplicationAudioSession: Bool { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}
extension AVSpeechSynthesizer: SpeechSynthesizerDriving {}

@MainActor
protocol SpeechOutputServing: AnyObject {
    func speak(_ text: String, completion: @escaping () -> Void)
    func stop()
    func deactivateAudioSession()
}

/// Session-only counters: no utterances, audio, destinations or device names.
/// A delegate start is not evidence that the user actually heard the audio.
@MainActor
final class SpeechDiagnosticsStore: ObservableObject {
    static let shared = SpeechDiagnosticsStore()
    @Published private(set) var requests = 0
    @Published private(set) var starts = 0
    @Published private(set) var completions = 0
    @Published private(set) var retries = 0
    @Published private(set) var startTimeouts = 0
    @Published private(set) var finishTimeouts = 0
    @Published private(set) var interruptions = 0
    @Published private(set) var routeChanges = 0
    @Published private(set) var recognitionFailures = 0
    @Published private(set) var unavailablePreferredVoices = 0
    @Published private(set) var lastStartLatencyMilliseconds: Int?
    func requested() { requests += 1 }
    func started(after seconds: TimeInterval) {
        starts += 1; lastStartLatencyMilliseconds = Int(max(0, seconds) * 1_000)
    }
    func completed() { completions += 1 }
    func retried() { retries += 1 }
    func timedOut(start: Bool) { if start { startTimeouts += 1 } else { finishTimeouts += 1 } }
    func interrupted() { interruptions += 1 }
    func routeChanged() { routeChanges += 1 }
    func recognitionFailed() { recognitionFailures += 1 }
    func preferredVoiceUnavailable() { unavailablePreferredVoices += 1 }
}

@MainActor
final class SpeechSynthesisService: NSObject, AVSpeechSynthesizerDelegate, SpeechOutputServing {
    private var synthesizer: any SpeechSynthesizerDriving
    private let makeSynthesizer: @MainActor () -> any SpeechSynthesizerDriving
    private let resolveVoice: @MainActor (String, String) -> AVSpeechSynthesisVoice?
    private let initialDelay: Duration
    private let retryDelay: Duration
    private let startTimeout: Duration
    private var requestVoice: AVSpeechSynthesisVoice?
    private var completion: (() -> Void)?
    private var activeUtterance: AVSpeechUtterance?
    private var speechStartTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var finishWatchdog: Task<Void, Never>?
    private var generation = 0
    private var retryCount = 0
    private var didStartCurrentUtterance = false
    private var requestedAt = Date()
    private let diagnostics = SpeechDiagnosticsStore.shared
    private var audioObservers: [NSObjectProtocol] = []

    init(makeSynthesizer: @escaping @MainActor () -> any SpeechSynthesizerDriving = { AVSpeechSynthesizer() },
         resolveVoice: (@MainActor (String, String) -> AVSpeechSynthesisVoice?)? = nil,
         initialDelay: Duration = .milliseconds(180), retryDelay: Duration = .milliseconds(350),
         startTimeout: Duration = .milliseconds(2_500)) {
        self.makeSynthesizer = makeSynthesizer
        self.synthesizer = makeSynthesizer()
        self.resolveVoice = resolveVoice ?? { text, identifier in Self.preferredAssistantVoice(for: text, preferredIdentifier: identifier) }
        self.initialDelay = initialDelay; self.retryDelay = retryDelay
        self.startTimeout = startTimeout
        super.init()
        configureSynthesizer()
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.diagnostics.routeChanged() }
        })
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: .jarvisSpeechVoiceChanged, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
    }

    deinit { audioObservers.forEach(NotificationCenter.default.removeObserver) }

    func speak(_ text: String, completion: @escaping () -> Void = {}) {
        speak(text, preferredVoiceIdentifier: SpeechVoicePreferenceStore.selectedVoiceIdentifier, completion: completion)
    }

    func speak(_ text: String, preferredVoiceIdentifier: String, completion: @escaping () -> Void = {}) {
        stop()
        let spokenText = Self.removingURLs(from: text)
        guard !spokenText.isEmpty else {
            completion()
            return
        }
        self.completion = completion
        // Freeze voice identity once per request. Retry MUST NOT resolve a
        // different voice or ignore the user's choice after a start timeout.
        requestVoice = resolveVoice(spokenText, preferredVoiceIdentifier)
        requestedAt = Date()
        diagnostics.requested()
        retryCount = 0
        generation += 1
        scheduleSpeechAttempt(
            spokenText,
            generation: generation,
            delay: initialDelay
        )
    }

    func stop() {
        generation += 1
        speechStartTask?.cancel()
        speechStartTask = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        finishWatchdog?.cancel()
        finishWatchdog = nil
        activeUtterance = nil
        didStartCurrentUtterance = false
        completion = nil
        requestVoice = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            guard !self.didStartCurrentUtterance else { return }
            self.didStartCurrentUtterance = true
            self.diagnostics.started(after: Date().timeIntervalSince(self.requestedAt))
            self.startWatchdog?.cancel()
            self.startWatchdog = nil
            self.scheduleFinishWatchdog(for: utterance, generation: self.generation)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            self.diagnostics.completed()
            self.completeSpeech()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance === utterance else { return }
            if self.didStartCurrentUtterance {
                self.diagnostics.interrupted()
                self.completeSpeech() // Never replay words already started.
            } else {
                self.retryOrComplete(utterance.speechString, generation: self.generation)
            }
        }
    }

    private func startSpeechAttempt(
        _ spokenText: String,
        generation expectedGeneration: Int
    ) {
        guard expectedGeneration == generation else { return }

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = requestVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.86
        utterance.pitchMultiplier = 0.90
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.04
        utterance.postUtteranceDelay = 0.08
        activeUtterance = utterance
        didStartCurrentUtterance = false
        synthesizer.speak(utterance)

        startWatchdog?.cancel()
        let timeout = startTimeout
        startWatchdog = Task { [weak self, weak utterance] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let utterance,
                  self.generation == expectedGeneration,
                  self.activeUtterance === utterance,
                  !self.didStartCurrentUtterance else { return }
            self.diagnostics.timedOut(start: true)
            self.retryOrComplete(spokenText, generation: expectedGeneration)
        }
    }

    private func completeSpeech() {
        speechStartTask?.cancel()
        speechStartTask = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        finishWatchdog?.cancel()
        finishWatchdog = nil
        activeUtterance = nil
        didStartCurrentUtterance = false
        let action = completion
        completion = nil
        requestVoice = nil
        action?()
    }

    private func retryOrComplete(_ spokenText: String, generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        speechStartTask?.cancel()
        speechStartTask = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        finishWatchdog?.cancel()
        finishWatchdog = nil
        activeUtterance = nil
        didStartCurrentUtterance = false
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard retryCount == 0 else {
            completeSpeech()
            return
        }
        retryCount = 1
        diagnostics.retried()
        resetSynthesizer()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        scheduleSpeechAttempt(
            spokenText,
            generation: expectedGeneration,
            delay: retryDelay
        )
    }

    private func scheduleFinishWatchdog(
        for utterance: AVSpeechUtterance,
        generation expectedGeneration: Int
    ) {
        finishWatchdog?.cancel()
        let estimatedSeconds = min(
            60.0,
            max(8.0, Double(utterance.speechString.count) * 0.35 + 6.0)
        )
        finishWatchdog = Task { [weak self, weak utterance] in
            try? await Task.sleep(for: .seconds(estimatedSeconds))
            guard !Task.isCancelled, let self, let utterance,
                  self.generation == expectedGeneration,
                  self.activeUtterance === utterance else { return }
            self.diagnostics.timedOut(start: false)
            // Even if AVSpeechSynthesizer omits its terminal delegate callback,
            // never leave the UI permanently in the speaking state.
            self.activeUtterance = nil
            if self.synthesizer.isSpeaking || self.synthesizer.isPaused {
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            self.completeSpeech()
        }
    }

    private func scheduleSpeechAttempt(
        _ spokenText: String,
        generation expectedGeneration: Int,
        delay: Duration
    ) {
        speechStartTask?.cancel()
        speechStartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  self.generation == expectedGeneration else { return }
            self.speechStartTask = nil
            self.startSpeechAttempt(
                spokenText,
                generation: expectedGeneration
            )
        }
    }

    private func configureSynthesizer() {
        // This dedicated system-managed session avoids inheriting the
        // microphone/measurement route and always follows the current media
        // output (speaker, Bluetooth, or headphones) at full utterance volume.
        synthesizer.usesApplicationAudioSession = false
        synthesizer.delegate = self
    }

    private func resetSynthesizer() {
        synthesizer.delegate = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer = makeSynthesizer()
        configureSynthesizer()
    }

    private static func removingURLs(from text: String) -> String {
        let markdownPattern = #"\[([^\]]+)\]\(https?://[^\s)]+\)"#
        let urlPattern = #"(?i)\b(?:https?://|www\.)[^\s]+"#

        let withoutMarkdownURLs = text.replacingOccurrences(
            of: markdownPattern,
            with: "$1",
            options: .regularExpression
        )
        let withoutPlainURLs = withoutMarkdownURLs.replacingOccurrences(
            of: urlPattern,
            with: "",
            options: .regularExpression
        )
        return withoutPlainURLs
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preferredAssistantVoice(
        for text: String,
        preferredIdentifier: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        let containsKorean = text.range(
            of: #"[\u{AC00}-\u{D7A3}]"#,
            options: .regularExpression
        ) != nil
        let identifier = preferredIdentifier ?? SpeechVoicePreferenceStore.selectedVoiceIdentifier
        if containsKorean, !identifier.isEmpty,
           let selectedVoice = AVSpeechSynthesisVoice(
               identifier: identifier
           ), selectedVoice.language.lowercased().hasPrefix("ko") {
            return selectedVoice
        }
        if containsKorean, !identifier.isEmpty { SpeechDiagnosticsStore.shared.preferredVoiceUnavailable() }

        let language = containsKorean ? "ko-KR" : "en-GB"
        let matchingVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare(language) == .orderedSame
        }

        return matchingVoices.sorted {
            voiceScore($0) == voiceScore($1) ? $0.identifier < $1.identifier : voiceScore($0) > voiceScore($1)
        }.first
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "ko-KR")
    }

    private static func voiceScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        let malePreference = voice.gender == .male ? 1_000 : 0
        return malePreference + voice.quality.rawValue
    }
}
