import AVFoundation
import Speech

@MainActor
final class SpeechRecognitionService {
    enum RecognitionError: LocalizedError {
        case unavailable
        case permissionsDenied
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: return "한국어 음성 인식을 사용할 수 없습니다."
            case .permissionsDenied: return "마이크와 음성 인식 권한이 필요합니다."
            case .inputUnavailable: return "사용 가능한 마이크 입력이 없습니다. 이어폰 연결과 통화 상태를 확인해주세요."
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInstalledTap = false
    private var generation = 0
    private var ownsAudioSession = false

    func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechAllowed, !Task.isCancelled else { return false }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        return speechAllowed && microphoneAllowed && !Task.isCancelled
    }

    func start(
        onAudioLevel: @escaping (Double) -> Void,
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        stop(deactivateSession: false)
        generation += 1
        let currentGeneration = generation

        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionError.unavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .duckOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        ownsAudioSession = true

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = ["자비스", "자비스야", "유튜브"]
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw RecognitionError.inputUnavailable
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?.pointee else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            var sumOfSquares: Float = 0
            for index in 0..<frameCount {
                let sample = samples[index]
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / Float(frameCount))
            let decibels = 20 * log10(max(rms, 0.000_01))
            onAudioLevel(Double(min(max((decibels + 50) / 50, 0), 1)))
        }
        hasInstalledTap = true

        audioEngine.prepare()
        do { try audioEngine.start() }
        catch { stop(); throw error }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard self?.generation == currentGeneration else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    result.isFinal ? onFinal(text) : onPartial(text)
                    if result.isFinal { return }
                }
                if let error { onError(error) }
            }
        }
    }

    func stop(deactivateSession: Bool = true) {
        generation += 1
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if deactivateSession, ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}
