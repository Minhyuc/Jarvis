import XCTest
import AVFoundation
import SwiftUI
import ImageIO
@testable import Jarvis

/// Exercise the actual SwiftUI hosts inside UIKit navigation, without picking
/// folders, reading DB contents, starting practice or calling external APIs.
@MainActor
final class WorkspaceTreeNavigationTests: XCTestCase {
    private final class PathState: ObservableObject {
        @Published var path = ["workspace"]
    }
    private struct Root: View {
        @ObservedObject var path: PathState
        let navigation: WorkspaceNavigation
        let model: AssistantViewModel?
        private var title: String {
            switch navigation.parent {
            case .home: "JARVIS"
            case .development: "개발 공간"
            case .sharedProject: "iCloud 공유 프로젝트"
            case .settings: "설정"
            }
        }
        var body: some View {
            NavigationStack(path: $path.path) {
                Text("작업 환경 루트")
                    .navigationTitle(title)
                    .navigationDestination(for: String.self) { value in
                        if value == "detail" { Text("상세 항목").navigationTitle("상세") }
                        else if navigation.parent == .home, let model { MainWorkspaceView(navigation: navigation, viewModel: model) }
                        else if navigation.parent == .development { DevelopmentWorkspaceView(navigation: navigation) }
                        else if navigation.parent == .sharedProject { SharedDataWorkspaceView(navigation: navigation) }
                        else { SettingsWorkspaceView(navigation: navigation) }
                    }
            }
        }
    }
    private func controller(in root: UIViewController) -> UINavigationController? {
        if let nav = root as? UINavigationController { return nav }
        return root.children.lazy.compactMap { self.controller(in: $0) }.first
    }
    private func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    private func verify(_ initial: WorkspacePage, siblings: [WorkspacePage]) async throws {
        let selection = WorkspaceNavigation(initial), path = PathState()
        let model = initial.parent == .home ? AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false) : nil
        let host = UIHostingController(rootView: Root(path: path, navigation: selection, model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.loadViewIfNeeded(); window.layoutIfNeeded(); host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKeyAndVisible() }
        try await wait { self.controller(in: host)?.viewControllers.count == 2 }
        let nav = try XCTUnwrap(controller(in: host))
        for _ in 0..<5 {
            for page in siblings {
                XCTAssertTrue(selection.select(page))
                try await Task.sleep(for: .milliseconds(30))
                host.view.layoutIfNeeded()
                XCTAssertEqual(path.path, ["workspace"])
                XCTAssertEqual(nav.viewControllers.count, 2, "Sibling features must replace, not push")
            }
        }
        // Real details remain child nodes and first go back to their feature.
        path.path.append("detail")
        try await wait { nav.viewControllers.count == 3 }
        nav.popViewController(animated: false)
        try await wait { path.path == ["workspace"] }
        nav.popViewController(animated: false)
        try await wait { path.path.isEmpty && nav.viewControllers.count == 1 }
    }
    func testDatabaseAndTransferStaySiblingsAndBackReturnsToICloudProject() async throws {
        try await verify(.database, siblings: [.transfer, .database])
    }
    func testSettingsFeaturesStaySiblingsAndDetailsKeepTheirParent() async throws {
        try await verify(.learning, siblings: [.review, .memories, .learning])
    }
    func testChatSettingsAndDevelopmentStaySiblingsBelowHome() async throws {
        try await verify(.chat, siblings: [.settings, .development, .chat])
    }
    func testICloudProjectAndMultiAgentAreSiblingsBelowDevelopmentHub() async throws {
        try await verify(.iCloudProject, siblings: [.multiAgent, .iCloudProject])
    }
    func testAgentSpaceDoesNotGrantFolderAccessOrMakeAPIRequests() async throws {
        let originalRoot = SharedProjectStore.shared.root
        let requests = OpenAIIntegrationStore.shared.usage.requests
        try await verify(.multiAgent, siblings: [.multiAgent])
        XCTAssertEqual(SharedProjectStore.shared.root, originalRoot)
        XCTAssertEqual(OpenAIIntegrationStore.shared.usage.requests, requests)
    }
    func testFeatureSelectionCannotCrossWorkspaceRootsOrRetainHistory() {
        let nav = WorkspaceNavigation(.database)
        for _ in 0..<100 {
            XCTAssertTrue(nav.select(.transfer)); XCTAssertTrue(nav.select(.database))
        }
        XCTAssertFalse(nav.select(.learning))
        XCTAssertEqual(nav.page, .database)
        XCTAssertEqual(nav.parent, .sharedProject)
        XCTAssertFalse(nav.select(.multiAgent))
        let development = WorkspaceNavigation(.iCloudProject)
        XCTAssertTrue(development.select(.multiAgent))
        XCTAssertFalse(development.select(.database))
        XCTAssertFalse(development.select(.transfer))
        let settings = WorkspaceNavigation(.openAI)
        for page in [WorkspacePage.learning, .practice, .review, .memories, .openAI] { XCTAssertTrue(settings.select(page)) }
        XCTAssertFalse(settings.select(.transfer))
        XCTAssertEqual(settings.page, .openAI)
    }
}

/// Fake drivers never synthesize or record audio. They expose exactly the
/// cancellation/timeout paths that used to discard the saved voice choice.
@MainActor
final class SpeechVoiceLifecycleTests: XCTestCase {
    private final class Driver: SpeechSynthesizerDriving {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        var usesApplicationAudioSession = true
        var isSpeaking = false
        var isPaused = false
        var utterances: [AVSpeechUtterance] = []
        func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance); isSpeaking = true }
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { isSpeaking = false; return true }
    }
    @MainActor private final class Harness {
        var drivers: [Driver] = []
        var resolved: [String] = []
        let callbackSource = AVSpeechSynthesizer()
        var utterances: [AVSpeechUtterance] { drivers.flatMap(\.utterances) }
        func make(timeout: Duration = .seconds(2.5)) -> SpeechSynthesisService {
            SpeechSynthesisService(makeSynthesizer: {
                let driver = Driver(); self.drivers.append(driver); return driver
            }, resolveVoice: { _, identifier in
                self.resolved.append(identifier)
                return AVSpeechSynthesisVoice(language: "ko-KR")
            }, initialDelay: .milliseconds(1), retryDelay: .milliseconds(1), startTimeout: timeout)
        }
    }
    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected speech lifecycle transition", file: file, line: line)
    }

    func testRetryKeepsTheExactRequestVoiceAndResolvesOnlyOnce() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        var completed = 0
        service.speak("네.", preferredVoiceIdentifier: "chosen-voice") { completed += 1 }
        try await wait { h.utterances.count == 1 }
        let first = h.utterances[0]
        service.speechSynthesizer(h.callbackSource, didCancel: first)
        try await wait { h.utterances.count == 2 }
        XCTAssertEqual(h.resolved, ["chosen-voice"])
        XCTAssertEqual(h.utterances[1].voice?.identifier, first.voice?.identifier)
        XCTAssertTrue(h.drivers.allSatisfy { !$0.usesApplicationAudioSession })
        service.speechSynthesizer(h.callbackSource, didFinish: h.utterances[1])
        try await wait { completed == 1 }
        service.speechSynthesizer(h.callbackSource, didFinish: first)
        service.speechSynthesizer(h.callbackSource, didFinish: h.utterances[1])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(completed, 1)
    }

    func testStartTimeoutDoesNotSwitchVoiceAndRetryIsBounded() async throws {
        let h = Harness(), service = h.make(timeout: .milliseconds(30)); defer { service.stop() }
        var completed = 0
        service.speak("네.", preferredVoiceIdentifier: "chosen-voice") { completed += 1 }
        try await wait { completed == 1 }
        XCTAssertEqual(h.utterances.count, 2)
        XCTAssertEqual(h.resolved, ["chosen-voice"])
        XCTAssertEqual(h.utterances[0].voice?.identifier, h.utterances[1].voice?.identifier)
    }

    func testCancellationAfterStartDoesNotReplayAlreadySpokenWords() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        var completed = 0
        service.speak("이미 읽기 시작한 문장", preferredVoiceIdentifier: "chosen") { completed += 1 }
        try await wait { h.utterances.count == 1 }
        service.speechSynthesizer(h.callbackSource, didStart: h.utterances[0])
        service.speechSynthesizer(h.callbackSource, didCancel: h.utterances[0])
        try await wait { completed == 1 }
        XCTAssertEqual(h.utterances.count, 1)
    }

    func testNewRequestInvalidatesOldVoiceRetryAndOldDelegateCompletion() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        var oldCompletion = 0, newCompletion = 0
        service.speak("이전 목소리", preferredVoiceIdentifier: "old") { oldCompletion += 1 }
        try await wait { h.utterances.count == 1 }
        let old = h.utterances[0]
        service.speechSynthesizer(h.callbackSource, didCancel: old)
        service.speak("새 목소리", preferredVoiceIdentifier: "new") { newCompletion += 1 }
        try await wait { h.utterances.count == 2 }
        service.speechSynthesizer(h.callbackSource, didFinish: old)
        service.speechSynthesizer(h.callbackSource, didFinish: h.utterances[1])
        try await wait { newCompletion == 1 }
        XCTAssertEqual(oldCompletion, 0)
        XCTAssertEqual(h.resolved, ["old", "new"])
        XCTAssertEqual(h.utterances.map(\.speechString), ["이전 목소리", "새 목소리"])
    }

    func testStopAndPreviewExitCancelQueuedPlayback() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        service.speak("취소된 호출", preferredVoiceIdentifier: "old")
        service.stop()
        let preview = SpeechVoicePreviewPlayer(output: service)
        preview.play(voiceIdentifier: "new")
        preview.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(h.utterances.isEmpty)
    }

    func testVoiceChangeCancelsInFlightRetryWithoutFinishingOldTurn() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        var completed = 0
        service.speak("네.", preferredVoiceIdentifier: "old") { completed += 1 }
        try await wait { h.utterances.count == 1 }
        NotificationCenter.default.post(name: .jarvisSpeechVoiceChanged, object: nil)
        service.speechSynthesizer(h.callbackSource, didCancel: h.utterances[0])
        service.speechSynthesizer(h.callbackSource, didFinish: h.utterances[0])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.utterances.count, 1); XCTAssertEqual(completed, 0)
    }

    func testNewAssistantCommandStopsPendingSettingsPreview() async throws {
        let h = Harness(), service = h.make(); defer { service.stop() }
        let preview = SpeechVoicePreviewPlayer(output: service)
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false)
        preview.play(voiceIdentifier: "preview-voice")
        model.textInput = "지금 몇 시야?"; model.submitText()
        try await wait { model.state == .idle && model.response.contains("시각") }
        XCTAssertTrue(h.utterances.isEmpty)
        model.stopAll()
    }
}

@MainActor
final class AtomRenderingTests: XCTestCase {
    func testMotionKeepsNucleusAndElectronsIndependent() {
        for state in [AssistantState.speaking] {
            let start = AtomMotion(state: state, time: 0, inputLevel: 0, reduceMotion: false)
            let later = AtomMotion(state: state, time: 0.5, inputLevel: 0, reduceMotion: false)
            XCTAssertNotEqual(start.nucleusScale, later.nucleusScale)
            XCTAssertEqual(start.electronPhase, later.electronPhase)
        }
        let thinking = AtomMotion(state: .thinking, time: 0.5, inputLevel: 1, reduceMotion: false)
        XCTAssertEqual(thinking.nucleusScale, 1)
        XCTAssertGreaterThan(thinking.electronPhase, 0)
        for state in [AssistantState.idle, .interrupted, .error("test")] {
            let stopped = AtomMotion(state: state, time: 5, inputLevel: 1, reduceMotion: false)
            XCTAssertTrue(stopped.isIdle)
            XCTAssertEqual(stopped.electronPhase, 0)
            XCTAssertEqual(stopped.nucleusScale, 1)
        }
        for state in [AssistantState.thinking, .speaking, .listeningForCommand] {
            let reduced = AtomMotion(state: state, time: 5, inputLevel: 1, reduceMotion: true)
            XCTAssertEqual(reduced.electronPhase, 0)
            XCTAssertEqual(reduced.nucleusScale, 1)
        }
    }

    func testListeningNucleusFollowsMicrophoneInsteadOfTime() {
        let silence = AtomMotion(state: .listeningForCommand, time: 0, inputLevel: 0, reduceMotion: false)
        let noise = AtomMotion(state: .listeningForCommand, time: 1, inputLevel: 0.04, reduceMotion: false)
        let quiet = AtomMotion(state: .listeningForCommand, time: 0, inputLevel: 0.3, reduceMotion: false)
        let loud = AtomMotion(state: .listeningForCommand, time: 0, inputLevel: 0.8, reduceMotion: false)
        let later = AtomMotion(state: .listeningForCommand, time: 2, inputLevel: 0.8, reduceMotion: false)
        XCTAssertEqual(silence.nucleusScale, 1)
        XCTAssertEqual(noise.nucleusScale, 1)
        XCTAssertGreaterThan(quiet.nucleusScale, silence.nucleusScale)
        XCTAssertGreaterThan(loud.nucleusScale, quiet.nucleusScale)
        XCTAssertEqual(loud.nucleusScale, later.nucleusScale)
        XCTAssertEqual(loud.electronPhase, 0)
        for input in [Double.nan, .infinity, -1, 2] {
            let motion = AtomMotion(state: .listeningForCommand, time: 0, inputLevel: input, reduceMotion: false)
            XCTAssertTrue((1...1.28).contains(motion.nucleusScale))
        }
    }

    func testApprovedArtworkAndAllStatesRender() throws {
        XCTAssertNotNil(AtomStatusView.referenceArtwork)
        let nucleus = try XCTUnwrap(AtomStatusView.nucleusArtwork)
        XCTAssertGreaterThan(nucleus.size.width, 200)
        for (name, state) in [("idle", AssistantState.idle), ("listening", .listeningForCommand),
                              ("thinking", .thinking), ("speaking", .speaking)] {
            let initial = try render(state: state, time: 0)
            let later = try render(state: state, time: 0.65)
            if state == .idle {
                XCTAssertEqual(initial.pngData(), later.pngData())
            } else {
                XCTAssertNotEqual(initial.pngData(), later.pngData(), name)
            }
            let attachment = XCTAttachment(image: later)
            attachment.name = "Atom - \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAtomAnimationPreviews() throws {
        for (name, state) in [("listening", AssistantState.listeningForCommand),
                              ("thinking", .thinking), ("speaking", .speaking)] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                data, "com.compuserve.gif" as CFString, 40, nil))
            CGImageDestinationSetProperties(destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in 0..<40 {
                let image = try XCTUnwrap(render(state: state, time: Double(frame) / 10).cgImage)
                CGImageDestinationAddImage(destination, image,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let attachment = XCTAttachment(data: data as Data, uniformTypeIdentifier: "com.compuserve.gif")
            attachment.name = state == .listeningForCommand
                ? "Atom listening simulated microphone preview.gif" : "Atom \(name) preview.gif"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render(state: AssistantState, time: TimeInterval) throws -> UIImage {
        // Preview input only: production uses the existing microphone RMS meter.
        let level = state == .listeningForCommand
            ? abs(sin(time * 7)) * max(0, sin(time * 2.2)) : 0.5
        let view = AtomStatusView(state: state, inputLevel: level)
            .artworkFrame(time: time)
            .frame(width: 320, height: 320)
            .background(Color.black)
        return try XCTUnwrap(ImageRenderer(content: view).uiImage)
    }
}

@MainActor
final class AssistantViewModelE2ETests: XCTestCase {
    func testCalendarFollowUpThenNewTopicDoesNotReuseOldTask() async throws {
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false)

        try await send("오늘 일정 알려줘", to: model, expecting: 2)
        XCTAssertTrue(model.response.contains("일정"))

        try await send("그럼 다음은?", to: model, expecting: 4)
        XCTAssertTrue(model.response.contains("일정"))

        try await send("지금 몇 시야?", to: model, expecting: 6)
        XCTAssertTrue(model.response.contains("시각"))

        try await send("오늘 일정 몇 개야?", to: model, expecting: 8)
        XCTAssertTrue(model.response.contains("일정"))
        XCTAssertEqual(model.messages.filter { $0.role == .user }.count, 4)
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.count, 4)
    }

    func testNewCommandReplacesAmbiguousTextWithoutExecutingOldTarget() async throws {
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false)
        try await send("지금 몇 시야?", to: model, expecting: 2)
        try await send("오늘 날짜 알려줘", to: model, expecting: 4)
        XCTAssertTrue(model.response.contains("오늘은"))
        XCTAssertFalse(model.response.contains("현재 시각"))
    }

    private func send(
        _ text: String,
        to model: AssistantViewModel,
        expecting messageCount: Int
    ) async throws {
        model.textInput = text
        model.submitText()
        let deadline = Date().addingTimeInterval(5)
        while model.messages.count < messageCount && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.messages.count, messageCount)
    }
}

/// Real VM -> router -> dialogue confirmation -> shared-folder executor.
/// Uses only disposable app-container fixtures, never a real iCloud grant/API.
@MainActor
final class ProjectCommandE2ETests: XCTestCase {
    private var root: URL!
    private var previousLock = false
    override func setUpWithError() throws {
        previousLock = SafetyControlStore.externalActionsLocked
        SafetyControlStore.externalActionsLocked = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-command-e2e-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        SafetyControlStore.externalActionsLocked = previousLock
        try FileManager.default.removeItem(at: root)
    }
    private func connected() async throws -> (AssistantViewModel, SharedProjectStore) {
        let store = SharedProjectStore(startAccess: { _ in true }, stopAccess: { _ in })
        store.run(.connect, folder: root, confirmed: true)
        let deadline = Date().addingTimeInterval(5)
        while store.root == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(store.root)
        return (AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, projectStore: store), store)
    }
    private func send(_ text: String, _ model: AssistantViewModel) async throws {
        let count = model.messages.count + 2
        model.textInput = text; model.submitText()
        let deadline = Date().addingTimeInterval(5)
        while model.messages.count < count && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(model.messages.count, count)
    }
    func testLiteralNoteAsksPathThenApprovalBeforeCreatingExactContent() async throws {
        let (model, _) = try await connected()
        try await send("안녕이라는 문구가 적혀있는 txt 파일을 만들어줘", model)
        XCTAssertTrue(model.response.contains("파일 경로"))
        try await send("인사.txt", model)
        let note = root.appendingPathComponent("인사.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(model.response.contains("안녕"))
        try await send("승인", model)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "안녕")
    }
    func testLiteralNoteCancellationNewTopicAndRootChangeDiscardDraft() async throws {
        let (model, store) = try await connected()
        try await send("안녕이라고 적혀있는 메모를 만들어줘", model)
        try await send("취소", model)
        try await send("인사.txt", model)
        try await send("네", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("인사.txt").path))
        try await send("안녕이라고 적혀있는 메모를 만들어줘", model)
        try await send("지금 몇 시야?", model)
        try await send("인사.txt", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("인사.txt").path))
        try await send("안녕이라고 적혀있는 메모를 만들어줘", model)
        store.disconnect()
        try await send("인사.txt", model)
        XCTAssertTrue(model.response.contains("연결이 바뀌어"))
    }
    func testLiteralNoteWithoutFolderReportsRequiredConnection() async throws {
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false,
            projectStore: SharedProjectStore(startAccess: { _ in false }, stopAccess: { _ in }))
        try await send("안녕이라고 적혀있는 메모를 만들어줘", model)
        XCTAssertTrue(model.response.contains("공유 폴더를 선택"))
    }
    func testFolderAndMemoVoiceEquivalentCommandsRequireApprovalAndEditExactLocation() async throws {
        let (model, _) = try await connected()
        try await send("공유 폴더의 \"메모\" 폴더 만들어줘", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("메모").path))
        XCTAssertTrue(model.response.contains("메모"))
        try await send("네", model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("메모").path))
        try await send("공유 폴더의 메모 폴더에 장보기 메모 만들어줘 내용은 우유", model)
        try await send("승인", model)
        let note = root.appendingPathComponent("메모/장보기.txt")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "우유")
        try await send("공유 폴더의 \"메모/장보기.txt\" 메모 수정해줘 내용: 달걀", model)
        try await send("아니야", model)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "우유")
        try await send("공유 폴더의 \"메모/장보기.txt\" 메모 수정해줘 내용: 달걀", model)
        try await send("네", model)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "달걀")
    }
    func testNewTopicAndUnrelatedYesNeverExecuteOldFolderTask() async throws {
        let (model, _) = try await connected()
        try await send("공유 폴더의 \"보류\" 폴더 만들어줘", model)
        try await send("지금 몇 시야?", model)
        try await send("네", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("보류").path))
    }
    func testLockWinsOverApprovalAndChangedFileRefusesStaleDelete() async throws {
        let (model, _) = try await connected()
        let note = root.appendingPathComponent("note.txt")
        try Data("first".utf8).write(to: note)
        try await send("공유 폴더의 \"note.txt\" 파일 삭제해줘", model)
        try Data("changed".utf8).write(to: note)
        try await send("네", model)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "changed")
        try await send("공유 폴더의 \"막힌폴더\" 폴더 만들어줘", model)
        SafetyControlStore.externalActionsLocked = true
        try await send("네", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("막힌폴더").path))
    }
    func testDeleteIsRecoverableAndApprovalCannotBeReused() async throws {
        let (model, store) = try await connected()
        let note = root.appendingPathComponent("note.txt")
        try Data("preserved".utf8).write(to: note)
        try await send("공유 폴더의 \"note.txt\" 파일 삭제해줘", model)
        try await send("승인", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        let recovery = try XCTUnwrap(store.recoveries.first)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(recovery.recoveryPath), encoding: .utf8), "preserved")
        try await send("네", model)
        XCTAssertEqual(store.recoveries.count, 1)
        guard case .succeeded(let restore) = await store.prepare(.init(.move, path: recovery.recoveryPath, destination: recovery.originalPath)) else { return XCTFail() }
        let restored = await store.commit(restore, confirmed: true)
        XCTAssertEqual(restored.status, .succeeded)
        XCTAssertTrue(store.recoveries.isEmpty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "preserved")
    }
    func testNoPermissionAndExpiredOrCancelledPlansNeverWrite() async throws {
        let store = SharedProjectStore(startAccess: { _ in false }, stopAccess: { _ in })
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, projectStore: store)
        try await send("공유 폴더의 \"메모\" 폴더 만들어줘", model)
        XCTAssertTrue(model.response.contains("폴더를 선택"))
        let (_, connectedStore) = try await connected()
        guard case .succeeded(let plan) = await connectedStore.prepare(.init(.folder, path: "cancelled")) else { return XCTFail() }
        connectedStore.cancelProposal()
        let cancelled = await connectedStore.commit(plan, confirmed: true)
        XCTAssertEqual(cancelled.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path))
    }
    func testChangingSelectedRootInvalidatesEarlierVoiceApproval() async throws {
        let (model, store) = try await connected()
        try await send("공유 폴더의 \"wrong-place\" 폴더 만들어줘", model)
        let other = root.appendingPathComponent("other-root")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        store.run(.connect, folder: other, confirmed: true)
        let deadline = Date().addingTimeInterval(5)
        while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.root, other)
        try await send("네", model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("wrong-place").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("wrong-place").path))
    }
}

/// Exercises the real VM but never opens an app, records audio or calls an API.
@MainActor
final class AssistantTurnLifecycleTests: XCTestCase {
    private final class Speech: SpeechOutputServing {
        var callbacks: [() -> Void] = []
        var texts: [String] = []
        var stops = 0
        var deactivations = 0
        func speak(_ text: String, completion: @escaping () -> Void) {
            texts.append(text); callbacks.append(completion)
        }
        func stop() { stops += 1 } // Deliberately retain stale callbacks.
        func deactivateAudioSession() { deactivations += 1 }
    }

    private final class Navigation: NavigationServing {
        var searched: [String] = []
        var opened: [PreparedNavigation] = []
        var modes: [NavigationTravelMode] = []
        var delay = false
        var result: ToolExecutionResult<NavigationLaunchResult> = .handedOff(.naverMap)
        func search(destination: String) async throws -> [NavigationSearchCandidate] {
            searched.append(destination)
            if delay { try? await Task.sleep(for: .milliseconds(200)) }
            let names = destination == "서울역" ? ["서울역"] : ["가게 강남점", "가게 종로점"]
            return names.enumerated().map { index, name in
                .init(route: .init(destinationName: name, destinationLatitude: 37.5,
                    destinationLongitude: 127 + Double(index) / 100, sourceLatitude: 37.4,
                    sourceLongitude: 127, straightLineDistance: 100),
                      area: index == 0 ? "서울 강남구" : "서울 종로구")
            }
        }
        func nearby(category: NearbyPlaceCategory) async -> ToolExecutionResult<[NearbyPlace]> { .succeeded([]) }
        func isNaverMapInstalled() -> Bool { true }
        func open(_ route: PreparedNavigation, mode: NavigationTravelMode) async -> ToolExecutionResult<NavigationLaunchResult> {
            opened.append(route); modes.append(mode); return result
        }
    }

    private func submit(_ text: String, to model: AssistantViewModel) {
        model.textInput = text; model.submitText()
    }
    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for the expected lifecycle transition", file: file, line: line)
    }
    private func unlock() -> Bool {
        let old = SafetyControlStore.externalActionsLocked
        UserDefaults.standard.set(false, forKey: SafetyControlStore.externalActionsLockKey)
        return old
    }
    private func restore(_ locked: Bool) {
        UserDefaults.standard.set(locked, forKey: SafetyControlStore.externalActionsLockKey)
    }

    func testStopReleasesSpeechWaitAndLateCompletionCannotOpenMap() async throws {
        let old = unlock(); defer { restore(old) }
        let speech = Speech(), navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), navigationService: navigation, speechOutput: speech)
        submit("서울역까지 자가용으로 안내해줘", to: model)
        try await wait { speech.callbacks.count == 1 }
        model.stopAll()
        speech.callbacks[0](); speech.callbacks[0]() // Also prove resume is once-only.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(navigation.opened.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testNewTextCancelsAwaitedHandoffAndOldAudioCannotFinishNewTurn() async throws {
        let old = unlock(); defer { restore(old) }
        let speech = Speech(), navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), navigationService: navigation, speechOutput: speech)
        submit("서울역까지 자가용으로 안내해줘", to: model)
        try await wait { speech.callbacks.count == 1 }
        submit("지금 몇 시야?", to: model)
        try await wait { speech.callbacks.count == 2 }
        speech.callbacks[0]()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(navigation.opened.isEmpty)
        XCTAssertTrue(model.response.contains("시각"))
        XCTAssertEqual(model.state, .speaking)
        speech.callbacks[1]()
        try await wait { model.state == .idle }
    }

    func testOrdinaryQueuedSpeechCompletionCannotOverrideNewResponse() async throws {
        let speech = Speech()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutput: speech)
        submit("지금 몇 시야?", to: model)
        try await wait { speech.callbacks.count == 1 }
        submit("오늘 날짜 알려줘", to: model)
        try await wait { speech.callbacks.count == 2 }
        speech.callbacks[0]()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.state, .speaking)
        XCTAssertTrue(model.response.contains("오늘은"))
        model.stopAll()
    }
    func testTextOnlyCompletionDoesNotDeactivateAnUnownedAudioSession() async throws {
        let speech = Speech()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, speechOutput: speech)
        submit("지금 몇 시야?", to: model)
        try await wait { model.response.contains("시각") && model.state == .idle }
        XCTAssertEqual(speech.deactivations, 0)
        XCTAssertTrue(speech.texts.isEmpty)
        model.stopAll()
    }

    func testEmergencyLockDuringSpeechBlocksHandoff() async throws {
        let old = unlock(); defer { restore(old) }
        let speech = Speech(), navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), navigationService: navigation, speechOutput: speech)
        submit("서울역까지 자가용으로 안내해줘", to: model)
        try await wait { speech.callbacks.count == 1 }
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        speech.callbacks[0]()
        try await wait { model.response.contains("안전 잠금") }
        XCTAssertTrue(navigation.opened.isEmpty)
        model.stopAll()
    }

    func testAudioInterruptionCancelsPendingActionWithoutAutoResume() async throws {
        let old = unlock(); defer { restore(old) }
        let speech = Speech(), navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), navigationService: navigation, speechOutput: speech)
        submit("서울역까지 자가용으로 안내해줘", to: model)
        try await wait { speech.callbacks.count == 1 }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await wait { if case .error = model.state { return true }; return false }
        speech.callbacks[0]()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(navigation.opened.isEmpty)
        XCTAssertFalse(model.isActivelyListening)
        model.stopAll()
    }

    func testCancelledSearchCannotInstallStaleSelectionDialogue() async throws {
        let old = unlock(); defer { restore(old) }
        let navigation = Navigation(); navigation.delay = true
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        submit("가게까지 자가용으로 안내해줘", to: model)
        try await wait { navigation.searched.count == 1 }
        submit("지금 몇 시야?", to: model)
        try await wait { model.response.contains("시각") }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.count, 1)
        submit("2번", to: model)
        try await wait { model.state != .thinking }
        XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testNewDestinationDoesNotReuseOldAreaOrOrdinalPrefix() async throws {
        let old = unlock(); defer { restore(old) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        submit("가게까지 자가용으로 안내해줘", to: model)
        try await wait { model.response.contains("여러 곳") }
        submit("강남구청까지 자가용으로 안내해줘", to: model)
        try await wait { navigation.searched.count == 2 && model.state == .idle }
        XCTAssertEqual(navigation.searched.last, "강남구청")
        XCTAssertTrue(navigation.opened.isEmpty)
        submit("2호선 강남역으로 안내해줘", to: model)
        try await wait { navigation.searched.count == 3 && model.state == .idle }
        XCTAssertTrue(navigation.opened.isEmpty)
    }

    func testSelectedCandidateHonorsCurrentTransportAndReportsPermissionFailure() async throws {
        let old = unlock(); defer { restore(old) }
        let navigation = Navigation(); navigation.result = .needsPermission(message: "지도 접근 권한이 필요합니다.")
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        submit("가게까지 대중교통으로 안내해줘", to: model)
        try await wait { model.response.contains("여러 곳") }
        submit("가게 종로점까지 자가용으로 안내해줘", to: model)
        try await wait { model.response.contains("권한") }
        XCTAssertEqual(navigation.opened.count, 1)
        XCTAssertEqual(navigation.modes, [.car])
        XCTAssertFalse(model.response.contains("완료"))
    }

    func testCorrectionPrefixSelectsNewBranchInsteadOfCancelling() async throws {
        let old = unlock(); defer { restore(old) }
        let navigation = Navigation()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutputEnabled: false, navigationService: navigation)
        submit("가게까지 자가용으로 안내해줘", to: model)
        try await wait { model.response.contains("여러 곳") }
        submit("아니 종로점", to: model)
        try await wait { navigation.opened.count == 1 }
        XCTAssertEqual(navigation.opened.first?.destinationName, "가게 종로점")
    }

    func testSpeechDiagnosticCountersContainOnlyNumbers() {
        let diagnostics = SpeechDiagnosticsStore()
        diagnostics.requested(); diagnostics.started(after: 0.25); diagnostics.completed()
        diagnostics.timedOut(start: true); diagnostics.timedOut(start: false)
        diagnostics.interrupted(); diagnostics.routeChanged(); diagnostics.recognitionFailed()
        XCTAssertEqual(diagnostics.requests, 1)
        XCTAssertEqual(diagnostics.lastStartLatencyMilliseconds, 250)
        XCTAssertEqual(diagnostics.startTimeouts, 1)
        XCTAssertEqual(diagnostics.finishTimeouts, 1)
        XCTAssertEqual(diagnostics.recognitionFailures, 1)
    }

    func testVoiceSettingsOrPreviewStopsPendingActionAndInvalidatesOldCallback() async throws {
        let old = unlock(); defer { restore(old) }
        for name in [Notification.Name.jarvisSpeechVoiceChanged, .jarvisSpeechPreviewRequested] {
            let speech = Speech(), navigation = Navigation()
            let model = AssistantViewModel(aiClient: MockAIClient(), navigationService: navigation, speechOutput: speech)
            submit("서울역까지 자가용으로 안내해줘", to: model)
            try await wait { speech.callbacks.count == 1 }
            NotificationCenter.default.post(name: name, object: nil)
            XCTAssertEqual(model.state, .idle)
            speech.callbacks[0]()
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertTrue(navigation.opened.isEmpty)
            model.stopAll()
        }
    }

    func testDuplicateSpeechCompletionDoesNotFinishSameTurnTwice() async throws {
        let speech = Speech()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutput: speech)
        submit("지금 몇 시야?", to: model)
        try await wait { speech.callbacks.count == 1 }
        let initial = speech.deactivations
        speech.callbacks[0](); speech.callbacks[0]()
        try await wait { model.state == .idle }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(speech.deactivations - initial, 1)
        model.stopAll()
    }

    func testInactiveInvocationIsRetainedAndCommandClearsStaleWakeFlag() async throws {
        let suite = "jarvis-invocation-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = Speech()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutput: speech)
        defaults.set(true, forKey: "jarvis.startConversation")
        defaults.set("지금 몇 시야?", forKey: "jarvis.pendingCommand")
        model.consumePendingIntent(defaults: defaults, isForeground: false)
        XCTAssertTrue(defaults.bool(forKey: "jarvis.startConversation"))
        XCTAssertNotNil(defaults.string(forKey: "jarvis.pendingCommand"))
        XCTAssertTrue(speech.texts.isEmpty)
        model.consumePendingIntent(defaults: defaults, isForeground: true)
        try await wait { speech.callbacks.count == 1 }
        XCTAssertFalse(defaults.bool(forKey: "jarvis.startConversation"))
        XCTAssertNil(defaults.string(forKey: "jarvis.pendingCommand"))
        model.consumePendingIntent(defaults: defaults, isForeground: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(speech.texts.count, 1)
        XCTAssertFalse(speech.texts.contains("네."))
        model.stopAll()
    }

    func testOldInterruptionCannotArriveLateAndCancelNewTurn() async throws {
        let speech = Speech()
        let model = AssistantViewModel(aiClient: MockAIClient(), speechOutput: speech)
        submit("지금 몇 시야?", to: model)
        try await wait { speech.callbacks.count == 1 }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        submit("오늘 날짜 알려줘", to: model)
        try await wait { speech.callbacks.count == 2 }
        XCTAssertEqual(model.state, .speaking)
        XCTAssertTrue(model.response.contains("오늘은"))
        model.stopAll()
    }

    func testMusicShortcutCannotLaunchUnderEmergencyLock() async {
        let old = unlock(); defer { restore(old) }
        UserDefaults.standard.set(true, forKey: SafetyControlStore.externalActionsLockKey)
        let service = MusicRecognitionShortcutService()
        let result = await service.run(service.makeRequest())
        guard case .failed = result else { return XCTFail("Shortcut must be blocked before opening an external app") }
    }
}
