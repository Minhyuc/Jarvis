import AVFoundation
import Foundation

@MainActor
final class AlarmSpeechRenderer {
    func render(message: String, alarmID: UUID) async -> String? {
        await render(message: message, fileToken: "alarm-\(alarmID.uuidString)")
    }

    func render(message: String, fileToken: String) async -> String? {
        let text = String(message.prefix(180))
        guard !text.isEmpty, let directory = soundsDirectory() else { return nil }

        let safeToken = fileToken.replacingOccurrences(
            of: "[^A-Za-z0-9-]",
            with: "-",
            options: .regularExpression
        )
        let fileName = "jarvis-\(safeToken).caf"
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechSynthesisService.preferredAssistantVoice(for: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.86
        utterance.pitchMultiplier = 0.90
        utterance.volume = 1.0

        let operation = SpeechFileRenderOperation(url: url, fileName: fileName)
        return await withTaskCancellationHandler {
            await operation.render(utterance)
        } onCancel: {
            Task { @MainActor in operation.finish(success: false) }
        }
    }

    func remove(fileName: String?) {
        guard let fileName, let directory = soundsDirectory() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    func remove(alarmID: UUID) {
        remove(fileName: "jarvis-alarm-\(alarmID.uuidString).caf")
    }

    func removeFiles(withPrefix prefix: String) {
        guard let directory = soundsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func soundsDirectory() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }
}

/// A cancelled render or a missing AVSpeech callback must release the waiter.
@MainActor
private final class SpeechFileRenderOperation {
    let url: URL
    let fileName: String
    let synthesizer = AVSpeechSynthesizer()
    var file: AVAudioFile?
    var continuation: CheckedContinuation<String?, Never>?
    var timer: Task<Void, Never>?
    var finished = false
    init(url: URL, fileName: String) { self.url = url; self.fileName = fileName }
    func render(_ utterance: AVSpeechUtterance) async -> String? {
        guard !Task.isCancelled, !finished else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finish(success: false)
            }
            synthesizer.write(utterance) { [weak self] buffer in
                DispatchQueue.main.async { self?.consume(buffer) }
            }
        }
    }
    func consume(_ buffer: AVAudioBuffer) {
        guard !finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finish(success: false); return }
        if pcm.frameLength == 0 {
            let duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            finish(success: duration > 0 && duration < 30); return
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
            try file?.write(from: pcm)
        } catch { finish(success: false) }
    }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true; timer?.cancel(); timer = nil; file = nil
        synthesizer.stopSpeaking(at: .immediate)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !success { try? FileManager.default.removeItem(at: url) }
        let waiter = continuation; continuation = nil
        waiter?.resume(returning: success && exists ? fileName : nil)
    }
}
