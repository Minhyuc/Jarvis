import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class SystemVolumeService {
    private let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))

    var currentPercent: Int {
        Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded())
    }

    func setVolume(percent: Int) async -> ToolExecutionResult<Int> {
        let clamped = min(max(percent, 0), 100)
        attachVolumeViewIfNeeded()
        await Task.yield()

        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            return .failed(
                message: "볼륨을 조절하지 못했습니다. 기기의 음량 버튼을 이용해주세요.",
                retryable: true
            )
        }
        slider.setValue(Float(clamped) / 100, animated: false)
        slider.sendActions(for: .valueChanged)
        return .succeeded(clamped)
    }

    func adjustVolume(delta: Int) async -> ToolExecutionResult<Int> {
        await setVolume(percent: currentPercent + delta)
    }

    private func attachVolumeViewIfNeeded() {
        guard volumeView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first
        volumeView.alpha = 0.01
        window?.addSubview(volumeView)
    }
}
