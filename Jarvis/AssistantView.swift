import Foundation
import SwiftUI

/// Main tools are siblings below Home too (not Chat -> Settings -> ...).
struct MainWorkspaceView: View {
    @ObservedObject var viewModel: AssistantViewModel
    @StateObject private var navigation: WorkspaceNavigation
    init(initial: WorkspacePage, viewModel: AssistantViewModel) {
        precondition(initial.parent == .home)
        self.viewModel = viewModel
        _navigation = StateObject(wrappedValue: WorkspaceNavigation(initial))
    }
    init(navigation: WorkspaceNavigation, viewModel: AssistantViewModel) {
        precondition(navigation.parent == .home)
        self.viewModel = viewModel
        _navigation = StateObject(wrappedValue: navigation)
    }
    var body: some View {
        Group {
            switch navigation.page {
            case .chat: ChatView(viewModel: viewModel)
            case .settings: JarvisSettingsView(aiModeDescription: viewModel.aiModeDescription)
            case .development: DevelopmentHubView()
            case .alarms: AlarmListView()
            case .calendar: JarvisCalendarListView()
            case .handsFree: HandsFreeSetupView()
            case .database, .transfer, .openAI, .learning, .practice, .review, .memories, .iCloudProject, .multiAgent: EmptyView()
            }
        }
        .id(navigation.page)
        .environment(\.workspaceNavigation, navigation)
    }
}

struct AssistantView: View {
    @ObservedObject var viewModel: AssistantViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                statusOrb

                VStack(spacing: 8) {
                    Text(viewModel.state.displayText)
                        .font(.title2.bold())
                    Text(viewModel.isActivelyListening ? "명령을 듣는 중" : "호출할 때만 마이크 사용")
                        .font(.subheadline)
                        .foregroundStyle(viewModel.isActivelyListening ? .green : .secondary)
                    Text(viewModel.aiModeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("음성으로 명령하거나 채팅방에서 텍스트로 대화할 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
                controls
            }
            .padding()
            .navigationTitle("JARVIS")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { MainWorkspaceView(initial: .development, viewModel: viewModel) } label: {
                        Label("개발 공간", systemImage: "hammer")
                    }.accessibilityLabel("개발 공간 · iCloud 공유 프로젝트 및 멀티 에이전트")
                }
                // Mac 개발 공간 보류: 복원 시 뷰·저장소의 #if false도 함께 해제합니다.
                #if false
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        MacWorkspaceView()
                    } label: {
                        Label("개발 공간", systemImage: "desktopcomputer")
                    }
                    .accessibilityLabel("개발 공간 · Mac 파일 읽기")
                }
                #endif
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        MainWorkspaceView(initial: .settings, viewModel: viewModel)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("설정")
                }
            }
        }
    }

    private var statusOrb: some View {
        AtomStatusView(
            state: viewModel.state,
            inputLevel: viewModel.voiceActivityLevel
        )
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.state.displayText)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            NavigationLink {
                MainWorkspaceView(initial: .chat, viewModel: viewModel)
            } label: {
                Label("채팅으로 대화하기", systemImage: "bubble.left.and.bubble.right.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            NavigationLink {
                MainWorkspaceView(initial: .alarms, viewModel: viewModel)
            } label: {
                Label("알람 관리", systemImage: "alarm.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            NavigationLink {
                MainWorkspaceView(initial: .calendar, viewModel: viewModel)
            } label: {
                Label("캘린더 관리", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.startOneShotConversation()
            } label: {
                Label("한 번만 음성 대화하기", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            NavigationLink {
                MainWorkspaceView(initial: .handsFree, viewModel: viewModel)
            } label: {
                Label("백그라운드 호출 설정", systemImage: "waveform.badge.mic")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Stateful atom built from the approved image's nucleus and independent orbit layers.
struct AtomStatusView: View {
    let state: AssistantState
    let inputLevel: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartedAt = Date()

    static let referenceArtwork: UIImage? = Bundle.main
        .url(forResource: "JarvisAtomReference", withExtension: "png")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    // Normalized crop of the approved 1254px artwork. No generated substitute:
    // the same neural nucleus is retained while the electrons can move separately.
    static let nucleusArtwork: UIImage? = {
        guard let source = referenceArtwork?.cgImage else { return nil }
        let side = CGFloat(source.width) * 0.225
        let rect = CGRect(x: CGFloat(source.width) * 0.5 - side / 2,
                          y: CGFloat(source.height) * 0.481 - side / 2,
                          width: side, height: side).integral
        return source.cropping(to: rect).map { UIImage(cgImage: $0) }
    }()

    var body: some View {
        let motion = AtomMotion(state: state, time: 0, inputLevel: inputLevel, reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || motion.isIdle)) { timeline in
            artworkFrame(time: max(0, timeline.date.timeIntervalSince(animationStartedAt)),
                         reduceMotion: reduceMotion)
        }
        .onChange(of: state) { _, _ in animationStartedAt = Date() }
    }

    func artworkFrame(time: TimeInterval, reduceMotion: Bool = false) -> some View {
        let motion = AtomMotion(state: state, time: time, inputLevel: inputLevel, reduceMotion: reduceMotion)
        return GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                AtomOrbitalLayer(phase: motion.electronPhase, foreground: false, isIdle: motion.isIdle)
                Image(uiImage: Self.nucleusArtwork ?? UIImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.23, height: side * 0.23)
                    .clipShape(Circle())
                    .saturation(motion.isIdle ? 0.15 : 1)
                    .opacity(motion.isIdle ? 0.45 : 1)
                    .scaleEffect(motion.nucleusScale)
                    .animation(state == .listeningForCommand && !reduceMotion
                               ? .easeOut(duration: 0.1) : nil, value: motion.nucleusScale)
                    .shadow(color: .cyan.opacity(motion.isIdle ? 0 : 0.65),
                            radius: side * 0.025)
                AtomOrbitalLayer(phase: motion.electronPhase, foreground: true, isIdle: motion.isIdle)
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// Presentation-only state: never starts audio or changes assistant execution.
struct AtomMotion {
    let isIdle: Bool
    let nucleusScale: Double
    let electronPhase: Double

    init(state: AssistantState, time: TimeInterval, inputLevel: Double, reduceMotion: Bool) {
        switch state {
        case .idle, .waitingForWakeWord, .interrupted, .error:
            isIdle = true
        default:
            isIdle = false
        }
        let elapsed = time.isFinite ? max(0, time) : 0
        let level = inputLevel.isFinite ? min(max(inputLevel, 0), 1) : 0
        let thinking = state == .thinking || state == .transcribing
        if reduceMotion {
            nucleusScale = 1
        } else if state == .listeningForCommand {
            // Follow actual microphone energy even at a sine wave's zero crossing.
            // Ignore the lowest meter values so silence does not look like speech.
            let activity = max(0, (level - 0.06) / 0.94)
            nucleusScale = 1 + 0.28 * pow(activity, 0.75)
        } else if state == .speaking || state == .wakeWordDetected {
            nucleusScale = 1 + 0.1 * sin(elapsed * 2.8)
        } else {
            nucleusScale = 1
        }
        electronPhase = thinking && !reduceMotion ? elapsed * .pi / 2 : 0
    }
}

/// Ellipses are projected into three planes. Back arcs/electrons are drawn before
/// the nucleus, front arcs after it, with depth-dependent size, brightness and trails.
private struct AtomOrbitalLayer: View {
    let phase: Double
    let foreground: Bool
    let isIdle: Bool

    private struct Orbit {
        let minorRadius: Double
        let tilt: Double
        let offset: Double
        let speed: Double

        func point(_ angle: Double, side: CGFloat) -> CGPoint {
            let x = 0.395 * cos(angle)
            let y = minorRadius * sin(angle)
            let rotation = tilt * .pi / 180
            return CGPoint(x: side * (0.5 + x * cos(rotation) - y * sin(rotation)),
                           y: side * (0.5 + x * sin(rotation) + y * cos(rotation)))
        }

        func arc(from start: Double, to end: Double, side: CGFloat) -> Path {
            var path = Path()
            for sample in 0...96 {
                let angle = start + (end - start) * Double(sample) / 96
                let point = point(angle, side: side)
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    private static let orbits = [
        Orbit(minorRadius: 0.17, tilt: 10, offset: 0.1, speed: 1),
        Orbit(minorRadius: 0.14, tilt: -38, offset: 2.1, speed: 0.85),
        Orbit(minorRadius: 0.16, tilt: 80, offset: 4.2, speed: 0.7)
    ]

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let blue = Color(red: 0.35, green: 0.78, blue: 1)
            for orbit in Self.orbits {
                let arc = orbit.arc(from: foreground ? 0 : .pi,
                                    to: foreground ? .pi : 2 * .pi, side: side)
                let brightness = isIdle ? 0.2 : (foreground ? 0.9 : 0.32)
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: side * 0.008))
                    glow.stroke(arc, with: .color(blue.opacity(brightness * 0.6)),
                                lineWidth: side * 0.013)
                }
                context.stroke(arc, with: .color(blue.opacity(brightness)), lineWidth: side * 0.004)
                context.stroke(arc, with: .color(.white.opacity(brightness * 0.55)),
                               lineWidth: side * 0.0015)

                let angle = orbit.offset + phase * orbit.speed
                // Each trail segment is depth-sorted too, so it does not jump
                // from the front plane to the back plane as the electron crosses.
                if phase > 0 && !isIdle {
                    for sample in 1...16 {
                        let tailAngle = angle - Double(sample) * 0.018
                        guard (sin(tailAngle) >= 0) == foreground else { continue }
                        let tail = orbit.arc(from: tailAngle - 0.02, to: tailAngle, side: side)
                        let alpha = (1 - Double(sample) / 17) * 0.4
                        context.stroke(tail, with: .color(blue.opacity(alpha)),
                                       style: StrokeStyle(lineWidth: side * 0.006, lineCap: .round))
                    }
                }
                guard (sin(angle) >= 0) == foreground else { continue }
                let center = orbit.point(angle, side: side)
                let radius = side * (0.013 + 0.003 * sin(angle))
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.drawLayer { glow in
                    glow.addFilter(.shadow(color: blue.opacity(isIdle ? 0 : 0.85), radius: side * 0.02))
                    glow.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [.white.opacity(isIdle ? 0.35 : 1),
                                          blue.opacity(isIdle ? 0.3 : 1)]),
                        center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3),
                        startRadius: 0, endRadius: radius * 1.5))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HandsFreeSetupView: View {
    var body: some View {
        List {
            Section("권장 방식") {
                Label("평소에는 JARVIS가 마이크를 사용하지 않습니다.", systemImage: "speaker.wave.2")
                Label("호출되면 그때만 앱을 열고 명령을 듣습니다.", systemImage: "mic")
                Text("이 방식은 YouTube·음악 재생을 평소에 방해하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Siri로 호출") {
                Text("1. ‘Siri야’라고 부릅니다.")
                Text("2. ‘JARVIS에게 말하기’라고 말합니다.")
                Text("3. JARVIS가 열리면 바로 명령을 말합니다.")
            }

            Section("‘자비스’ 한마디로 호출") {
                Text("1. iPhone 설정 → 손쉬운 사용 → 음성 단축어로 이동합니다.")
                Text("2. 음성 단축어 설정 또는 동작 추가를 누릅니다.")
                Text("3. JARVIS의 ‘자비스에게 말하기’ 동작을 선택합니다.")
                Text("4. 호출 문구를 ‘자비스’로 등록합니다.")
                Text("동작이 보이지 않으면 ‘Siri 요청’을 선택하고 요청 문구로 ‘JARVIS에게 말하기’를 입력하세요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("iOS에서 시스템 음성 단축어를 켜면 상태 표시줄에 마이크 사용 표시가 나타날 수 있습니다. 음성 처리는 iPhone에서 수행됩니다.")
            }
        }
        .navigationTitle("백그라운드 호출")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChatView: View {
    @Environment(\.workspaceNavigation) private var navigation
    @ObservedObject var viewModel: AssistantViewModel
    @ObservedObject private var suggestionSettings = ProactiveSuggestionSettingsStore.shared
    @ObservedObject private var cloudSettings = OpenAIIntegrationStore.shared

    var body: some View {
        conversationArea
            .navigationTitle("자비스 채팅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        navigation?.select(.settings)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("설정")
                    .disabled(navigation?.parent != .home)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if cloudSettings.configuration.enabled {
                        Text(cloudSettings.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 6)
                    }
                    composer
                }
            }
    }

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyConversation
                    }

                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }

                    if suggestionSettings.mode != .disabled,
                       let suggestion = viewModel.activeSuggestion {
                        ProactiveSuggestionCard(
                            suggestion: suggestion,
                            accept: viewModel.acceptActiveSuggestion,
                            dismiss: viewModel.dismissActiveSuggestion
                        )
                        .id("suggestion-\(suggestion.id)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyConversation: some View {
        ContentUnavailableView {
            Label("새로운 대화", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("아래 입력창에 메시지를 입력해 자비스와 대화를 시작하세요.")
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("메시지를 입력하세요", text: $viewModel.textInput, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 19))
                .submitLabel(.send)
                .onSubmit(viewModel.submitText)

            Button(action: viewModel.submitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 36))
            }
            .disabled(viewModel.textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("메시지 보내기")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct JarvisSettingsView: View {
    let aiModeDescription: String
    @Environment(\.scenePhase) private var scenePhase

    @State private var youtubeAPIKey = ""
    @State private var saveMessage = ""
    @State private var placesAPIKey = ""
    @State private var placesSaveMessage = ""
    @State private var webSearchAPIKey = ""
    @State private var webSearchSaveMessage = ""
    @State private var selectedVoiceIdentifier = ""
    @State private var availableVoiceOptions: [SpeechVoiceOption] = []
    @StateObject private var voicePreview = SpeechVoicePreviewPlayer()

    var body: some View {
        Form {
            Section("대화 AI") {
                LabeledContent("현재 엔진", value: aiModeDescription)
                NavigationLink {
                    SettingsWorkspaceView(initial: .openAI)
                } label: {
                    Label("OpenAI 연결 · 사용 모드", systemImage: "network")
                }
                NavigationLink {
                    SettingsWorkspaceView(initial: .learning)
                } label: {
                    Label("학습 결과", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    CommandEvaluationView()
                } label: {
                    Label("명령 이해 평가", systemImage: "checklist.checked")
                }
                NavigationLink {
                    SpeechEvaluationReviewView()
                } label: {
                    Label("음성 평가 문장 검토", systemImage: "waveform.badge.magnifyingglass")
                }
                NavigationLink {
                    SpeechDiagnosticsView()
                } label: {
                    Label("음성 안정성 진단", systemImage: "waveform.path.ecg")
                }
                Text("Apple 온디바이스 AI가 작동하면 기본 엔진으로 사용하고, 지원하지 않으면 자비스가 직접 관리하는 기본 응답을 사용합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("안전") {
                NavigationLink {
                    SafetySettingsView()
                } label: {
                    Label("안전 및 실행 기록", systemImage: "checkmark.shield.fill")
                }
                Text("외부 실행을 즉시 잠그고, 자비스가 어떤 종류의 작업을 허용하거나 차단했는지 확인할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("인터넷 검색") {
                SecureField("Tavily API 키", text: $webSearchAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("API 키 저장") {
                    webSearchSaveMessage = WebSearchAPIKeyStore.save(webSearchAPIKey)
                        ? "API 키를 Keychain에 저장했습니다."
                        : "API 키를 저장하지 못했습니다."
                }

                Button("API 키 삭제", role: .destructive) {
                    if WebSearchAPIKeyStore.delete() {
                        webSearchAPIKey = ""
                        webSearchSaveMessage = "API 키를 삭제했습니다."
                    } else {
                        webSearchSaveMessage = "API 키를 삭제하지 못했습니다."
                    }
                }

                if !webSearchSaveMessage.isEmpty {
                    Text(webSearchSaveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Link(
                    "Tavily에서 무료 API 키 만들기",
                    destination: URL(string: "https://app.tavily.com/home")!
                )

                Text("‘인터넷에 검색해서 알려줘’라고 말하면 답변은 음성으로 안내하고, 출처 URL은 채팅창에만 표시합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("개인화") {
                NavigationLink {
                    PersonalizationSettingsView()
                } label: {
                    Label("나의 정보 및 AI 스타일", systemImage: "person.crop.circle.badge.checkmark")
                }
                NavigationLink {
                    SettingsWorkspaceView(initial: .memories)
                } label: {
                    Label("장기 기억 관리", systemImage: "brain.head.profile")
                }
                NavigationLink {
                    ProactiveSuggestionSettingsView()
                } label: {
                    Label("능동 제안 설정", systemImage: "lightbulb.max.fill")
                }
                Text("저장한 정보는 다음 대화부터 답변을 개인화하는 데 사용됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("앱 실행") {
                NavigationLink {
                    AppLaunchSetupView()
                } label: {
                    Label("다른 앱 실행 연결", systemImage: "square.grid.2x2")
                }
                Text("‘카카오톡 열어줘’처럼 앱 이름으로 실행할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("미디어와 알람") {
                NavigationLink {
                    MediaAndAlarmSetupView()
                } label: {
                    Label("재생 중지·볼륨·알람", systemImage: "speaker.wave.2.bubble")
                }
                Text("유튜브 재생 중지, 시스템 볼륨 조절, 지정 시각 알람을 사용합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("자비스 목소리") {
                Picker("한국어 음성", selection: $selectedVoiceIdentifier) {
                    Text("자동 선택").tag("")
                    if !selectedVoiceIdentifier.isEmpty && !availableVoiceOptions.contains(where: { $0.id == selectedVoiceIdentifier }) {
                        Text("저장한 음성 · 현재 사용할 수 없음").tag(selectedVoiceIdentifier)
                    }
                    ForEach(availableVoiceOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .onChange(of: selectedVoiceIdentifier) { _, newValue in
                    voicePreview.stop()
                    SpeechVoicePreferenceStore.save(newValue)
                }

                Button {
                    voicePreview.play(voiceIdentifier: selectedVoiceIdentifier)
                } label: {
                    Label("선택한 음성 미리 듣기", systemImage: "speaker.wave.2.fill")
                }
                .disabled(availableVoiceOptions.isEmpty && selectedVoiceIdentifier.isEmpty)

                if availableVoiceOptions.isEmpty {
                    Text("현재 사용할 수 있는 한국어 음성을 찾지 못했습니다.")
                        .foregroundStyle(.secondary)
                }

                Text("자동 선택은 기기에 설치된 고품질 남성 음성을 우선합니다. 직접 선택한 음성은 다음 한국어 응답부터 바로 사용됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("재시도 중에는 같은 목소리를 유지합니다. 저장한 음성을 사용할 수 없으면 설정은 보존하고 대체 음성을 사용합니다. 미리 듣기·음성 변경은 진행 중인 대화를 중지하며 기존에 예약한 TTS 알림 파일은 자동 재생성하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("추가 음성은 설정 → 손쉬운 사용 → 읽기 및 말하기 → 음성 → 한국어에서 다운로드한 뒤 이 화면을 다시 여세요.")
                    .font(.footnote)
            }

            Section("YouTube 첫 영상 실행") {
                SecureField("YouTube Data API 키", text: $youtubeAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("API 키 저장") {
                    saveMessage = YouTubeAPIKeyStore.save(youtubeAPIKey)
                        ? "API 키를 Keychain에 저장했습니다."
                        : "API 키를 저장하지 못했습니다."
                }

                Button("API 키 삭제", role: .destructive) {
                    if YouTubeAPIKeyStore.delete() {
                        youtubeAPIKey = ""
                        saveMessage = "API 키를 삭제했습니다."
                    } else {
                        saveMessage = "API 키를 삭제하지 못했습니다."
                    }
                }

                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Link(
                    "Google Cloud Console에서 API 키 만들기",
                    destination: URL(string: "https://console.cloud.google.com/apis/credentials")!
                )

                Text("Google Cloud 프로젝트에서 YouTube Data API v3를 활성화한 뒤 API 키를 만드세요. 키가 있으면 첫 번째 영상을 바로 열고, 없으면 검색 결과만 엽니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube 재생목록") {
                NavigationLink {
                    YouTubePlaylistSettingsView()
                } label: {
                    Label("내 재생목록 관리", systemImage: "music.note.list")
                }

                Text("Google 계정을 연결하면 사용자가 직접 만든 YouTube 재생목록을 자동으로 동기화합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("현재 위치 맛집 추천") {
                SecureField("Google Places API 키", text: $placesAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Places API 키 저장") {
                    placesSaveMessage = PlacesAPIKeyStore.save(placesAPIKey)
                        ? "API 키를 Keychain에 저장했습니다."
                        : "API 키를 저장하지 못했습니다."
                }

                Button("Places API 키 삭제", role: .destructive) {
                    if PlacesAPIKeyStore.delete() {
                        placesAPIKey = ""
                        placesSaveMessage = "API 키를 삭제했습니다."
                    } else {
                        placesSaveMessage = "API 키를 삭제하지 못했습니다."
                    }
                }

                if !placesSaveMessage.isEmpty {
                    Text(placesSaveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Link(
                    "Google Cloud Console에서 Places API 설정",
                    destination: URL(string: "https://console.cloud.google.com/google/maps-apis/api-list")!
                )

                Text("Places API(New)를 활성화하고 결제 계정을 연결한 뒤, 이 앱전용 API 키를 등록하세요. 평점과 리뷰 수를 함께 고려해 주변 상위 3곳을 안내합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            youtubeAPIKey = YouTubeAPIKeyStore.load()
            placesAPIKey = PlacesAPIKeyStore.load()
            webSearchAPIKey = WebSearchAPIKeyStore.load()
            availableVoiceOptions = SpeechVoicePreferenceStore.availableKoreanVoices()
            let savedIdentifier = SpeechVoicePreferenceStore.selectedVoiceIdentifier
            selectedVoiceIdentifier = savedIdentifier // Never erase a temporarily unavailable voice.
        }
        .onDisappear { voicePreview.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { voicePreview.stop() } }
    }
}

private struct ProactiveSuggestionCard: View {
    let suggestion: ProactiveSuggestion
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("자비스 제안", systemImage: "lightbulb.fill")
                .font(.headline)
                .foregroundStyle(.yellow)
            Text(suggestion.title)
                .font(.subheadline.weight(.semibold))
            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("정보 확인: \(suggestion.observedAt.formatted(date: .omitted, time: .shortened)) · 유효기간 안에서만 실행")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("도움 됨") { ProactiveSuggestionSettingsStore.shared.record(suggestion, outcome: "helpful") }
                Button("도움 안 됨") { ProactiveSuggestionSettingsStore.shared.record(suggestion, outcome: "notHelpful") }
            }.font(.caption)
            HStack {
                Button("나중에", action: dismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Button(suggestion.proposedIntent == nil ? "확인" : "실행", action: accept)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.yellow.opacity(0.35), lineWidth: 1)
        }
    }
}

private struct ProactiveSuggestionSettingsView: View {
    @ObservedObject private var store = ProactiveSuggestionSettingsStore.shared

    var body: some View {
        Form {
            Section("제안 방식") {
                Picker("능동 제안 모드", selection: $store.mode) {
                    ForEach(ProactiveSuggestionMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.title)
                            Text(mode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.inline)
            }
            Section("반복 방지") {
                Text("같은 제안은 24시간 동안 다시 표시하지 않습니다.")
                Button("제안 반복 기록 초기화") {
                    store.resetHistory()
                }
            }
            Section {
                Label("자동 모드: 정보 안내·낮은 위험은 실행, 보통 위험은 확인, 높은 위험은 차단합니다. 장기 기억 저장은 별도 동의가 필요하며 안전 잠금이 우선합니다.", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("최근 제안 평가 · 내용은 저장하지 않음") {
                ForEach(store.events.prefix(20)) { event in
                    VStack(alignment: .leading) {
                        Text(event.kind).font(.caption)
                        Text("\(event.outcome) · \(event.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("능동 제안")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpeechDiagnosticsView: View {
    @ObservedObject private var diagnostics = SpeechDiagnosticsStore.shared
    var body: some View {
        Form {
            Section("현재 앱 실행 중 · TTS") {
                LabeledContent("발화 요청", value: "\(diagnostics.requests)")
                LabeledContent("시작 콜백", value: "\(diagnostics.starts)")
                LabeledContent("완료 콜백", value: "\(diagnostics.completions)")
                LabeledContent("자동 재시도", value: "\(diagnostics.retries)")
                LabeledContent("저장한 음성 사용 불가", value: "\(diagnostics.unavailablePreferredVoices)")
                LabeledContent("시작 시간 초과", value: "\(diagnostics.startTimeouts)")
                LabeledContent("완료 시간 초과", value: "\(diagnostics.finishTimeouts)")
                LabeledContent("최근 요청→시작", value: diagnostics.lastStartLatencyMilliseconds.map { "\($0) ms" } ?? "측정 전")
            }
            Section("오디오 환경") {
                LabeledContent("음성 사용 중 인터럽트", value: "\(diagnostics.interruptions)")
                LabeledContent("출력 경로 변경 알림", value: "\(diagnostics.routeChanges)")
                LabeledContent("음성 인식 오류", value: "\(diagnostics.recognitionFailures)")
            }
            Section {
                Text("횟수와 시간만 메모리에 보관하며 앱 재시작 시 초기화됩니다. 대화·음성·기기 이름은 저장하거나 전송하지 않습니다. 시작·완료 콜백은 실제로 소리가 들렸다는 증거가 아닙니다. 음량 0이나 이어폰 출력은 실제 기기에서 확인해주세요.")
                Text("통화 등으로 중단되면 대기 중 실행도 취소하며 자동으로 마이크를 다시 켜지 않습니다. 사용자가 다시 요청해야 합니다.")
            }
        }
        .navigationTitle("음성 안정성 진단")
    }
}

private struct SpeechEvaluationReviewView: View {
    @ObservedObject private var store = SpeechEvaluationStore.shared

    private var result: ApprovedSpeechEvaluationReport {
        ApprovedSpeechEvaluationRunner().run(store.approved)
    }

    var body: some View {
        Form {
            Section("수집 설정") {
                Toggle("음성 평가 후보 모으기", isOn: $store.collectionEnabled)
                Text("기본적으로 꺼져 있습니다. 전화·장소·기억·검색·알람처럼 개인 정보가 들어갈 수 있는 명령은 수집하지 않습니다. 허용된 문장도 검토 전에는 앱을 종료하면 사라집니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("검토 대기 · \(store.pending.count)개") {
                if store.pending.isEmpty {
                    Text("검토할 문장이 없습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.pending) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.input)
                        Text("예상 명령: \(item.expectedIntentDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("정확하고 개인 정보 없음 · 추가") { store.approve(item.id) }
                                .buttonStyle(.borderedProminent)
                            Button("버리기", role: .destructive) { store.reject(item.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("승인한 평가 문장") {
                LabeledContent("문장", value: "\(result.total)개")
                LabeledContent("현재 라우터 일치", value: "\(result.passed)개")
                if result.total > 0 {
                    LabeledContent("일치율", value: result.passRate.formatted(.percent.precision(.fractionLength(1))))
                }
                ForEach(store.approved) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.input)
                            Text(item.expectedIntentDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { store.deleteApproved(item.id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                if !store.approved.isEmpty {
                    Button("승인 문장 모두 삭제", role: .destructive) { store.deleteAll() }
                }
            }
            Section {
                Text("승인한 문장은 이 iPhone에만 저장합니다. 자동 익명화는 완벽할 수 없으므로 추가하기 전에 이름·장소 등 개인 정보가 없는지 직접 확인해주세요. 이는 음성 인식 결과의 명령 분류 평가이며 실제 음향 인식 품질을 재측정하지는 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("음성 평가 문장")
    }
}

private struct CommandEvaluationView: View {
    private let report: EvaluationReportV2
    private let conversationReport: ConversationEvaluationReport
    private let scenarioReport: ConversationScenarioReport
    private let dialogueStateReport: DialogueStateScenarioReport
    private let currentSnapshot: EvaluationSnapshot
    @State private var history: EvaluationHistory
    @State private var selectedBaselineDate: Date?

    init() {
        let currentReport = EvaluationRunner().runV2(
            CommandEvaluationCorpus.realisticV2,
            requiredPassRate: CommandEvaluationCorpus.minimumPassRate
        )
        report = currentReport
        conversationReport = ConversationEvaluationRunner().run(ConversationEvaluationCorpus.standard)
        scenarioReport = ConversationScenarioRunner().run(ConversationScenarioCorpus.standard)
        dialogueStateReport = DialogueStateScenarioRunner().run(DialogueStateScenarioCorpus.standard)
        currentSnapshot = EvaluationSnapshot(
            report: report,
            corpusVersion: CommandEvaluationCorpus.realisticV2Version
        )
        let loadedHistory = EvaluationHistoryStore.load()
        _history = State(initialValue: loadedHistory)
        _selectedBaselineDate = State(initialValue: loadedHistory.latest?.createdAt)
    }

    private var selectedBaseline: EvaluationSnapshot? {
        guard let selectedBaselineDate else { return history.latest }
        return history.snapshots.first { $0.createdAt == selectedBaselineDate }
    }

    var body: some View {
        Form {
            Section("전체 결과") {
                LabeledContent("평가 문장", value: "\(report.totalCount)개")
                LabeledContent("정확히 이해", value: "\(report.passedCount)개")
                LabeledContent("정확도", value: report.passRate.formatted(.percent.precision(.fractionLength(1))))
                LabeledContent("음성 인식 변형", value: report.speechVariationPassRate.formatted(.percent.precision(.fractionLength(1))))
                LabeledContent("위험 오작동", value: "\(report.dangerousMisfireCount)건")
                LabeledContent("평균 분류 시간", value: String(format: "%.3f ms", report.averageCaseMilliseconds))
                LabeledContent("최장 분류 시간", value: String(format: "%.3f ms", report.slowestCaseMilliseconds))
                ProgressView(value: report.passRate)
                    .tint(report.passed ? .green : .orange)
                Label(
                    report.passed ? "기준 통과" : "개선 필요",
                    systemImage: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(report.passed ? .green : .orange)
                Text("통과 기준은 전체 정확도 \(report.requiredPassRate.formatted(.percent)) 이상, 음성 인식 변형 90% 이상, 위험·모호 명령 오작동 0건입니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("이전 평가와 비교") {
                if let baseline = selectedBaseline {
                    let comparison = EvaluationComparison(
                        baseline: baseline,
                        current: currentSnapshot
                    )
                    Picker("비교할 평가", selection: $selectedBaselineDate) {
                        ForEach(history.snapshots.reversed(), id: \.createdAt) { snapshot in
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .tag(Optional(snapshot.createdAt))
                        }
                    }
                    LabeledContent("저장된 평가", value: "\(history.snapshots.count)개")
                    LabeledContent("기준 버전", value: baseline.corpusVersion)
                    LabeledContent("정확도 변화") {
                        Text(comparison.passRateDelta.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always())))
                            .foregroundStyle(comparison.passRateDelta < 0 ? .red : .green)
                    }
                    LabeledContent("새 실패", value: "\(comparison.newFailureCaseIDs.count)건")
                    LabeledContent("해결한 실패", value: "\(comparison.resolvedFailureCaseIDs.count)건")
                    Label(
                        comparison.hasRegression ? "회귀가 감지되었습니다" : "회귀가 없습니다",
                        systemImage: comparison.hasRegression ? "arrow.down.circle.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(comparison.hasRegression ? .red : .green)
                } else {
                    Text("아직 비교 기준이 없습니다. 현재 결과를 저장하면 다음 평가부터 정확도 변화와 새 실패를 비교합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("현재 결과를 평가 이력에 저장") {
                    let snapshot = EvaluationSnapshot(
                        report: report,
                        corpusVersion: CommandEvaluationCorpus.realisticV2Version
                    )
                    history.append(snapshot)
                    EvaluationHistoryStore.save(history)
                    selectedBaselineDate = snapshot.createdAt
                }
                if !history.snapshots.isEmpty {
                    Button("평가 이력 전체 삭제", role: .destructive) {
                        history.removeAll()
                        EvaluationHistoryStore.clear()
                        selectedBaselineDate = nil
                    }
                }
            }

            Section("기능별 결과") {
                ForEach(report.categoryResults, id: \.category) { result in
                    LabeledContent(result.category.title) {
                        Text("\(result.passedCount)/\(result.totalCount) · \(result.passRate.formatted(.percent))")
                    }
                }
            }

            Section("음성·문맥 변형") {
                ForEach(report.tagResults, id: \.tag) { result in
                    LabeledContent(result.tag.title) {
                        Text("\(result.passedCount)/\(result.totalCount) · \(result.passRate.formatted(.percent))")
                    }
                }
            }

            Section("다단계 대화") {
                LabeledContent("문장 문맥 시나리오", value: "\(scenarioReport.scenarioCount)개")
                LabeledContent("문장 문맥 턴", value: "\(scenarioReport.turnCount)개")
                LabeledContent("문장 문맥 성공률", value: scenarioReport.passRate.formatted(.percent.precision(.fractionLength(1))))
                ProgressView(value: scenarioReport.passRate)
                    .tint(scenarioReport.passed ? .green : .orange)
                LabeledContent("상태 관리 시나리오", value: "\(dialogueStateReport.scenarioCount)개")
                LabeledContent("상태 관리 단계", value: "\(dialogueStateReport.stepCount)개")
                LabeledContent("상태 관리 성공률", value: dialogueStateReport.passRate.formatted(.percent.precision(.fractionLength(1))))
                ProgressView(value: dialogueStateReport.passRate)
                    .tint(dialogueStateReport.passed ? .green : .orange)
            }

            Section("일반 대화 평가 · 별도 데이터") {
                LabeledContent("평가 문장", value: "\(conversationReport.total)개")
                LabeledContent("질문 유형·응답 형식 통과", value: "\(conversationReport.passed)개")
                LabeledContent("통과율", value: conversationReport.passRate.formatted(.percent.precision(.fractionLength(1))))
                if !conversationReport.failureIDs.isEmpty {
                    Text("실패 ID: \(conversationReport.failureIDs.joined(separator: ", "))")
                        .font(.caption)
                }
                Text("이 평가는 질문 유형, 최신 정보 판단, 화면·음성 형식만 검사합니다. 생성 답변의 사실 정확도는 자동으로 검증하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !report.failures.isEmpty {
                Section("실패 사례") {
                    ForEach(Array(report.failures.prefix(30).enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(failure.caseID) · \(failure.type.title)")
                            Text(failure.input)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("평가 문장은 개인정보를 포함하지 않습니다. 저장되는 비교 기준에는 문장 원문이 아닌 집계와 실패 ID만 포함됩니다. 온디바이스 AI의 확률적 응답 품질은 별도 실기 평가가 필요합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("명령 이해 평가")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum EvaluationHistoryStore {
    private static let historyKey = "jarvis.command-evaluation.v2.history"
    private static let legacyBaselineKey = "jarvis.command-evaluation.v2.baseline"

    static func load() -> EvaluationHistory {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let history = try? JSONDecoder().decode(EvaluationHistory.self, from: data) {
            return history
        }
        if let data = UserDefaults.standard.data(forKey: legacyBaselineKey),
           let snapshot = try? JSONDecoder().decode(EvaluationSnapshot.self, from: data) {
            let history = EvaluationHistory(snapshots: [snapshot])
            save(history)
            UserDefaults.standard.removeObject(forKey: legacyBaselineKey)
            return history
        }
        return EvaluationHistory()
    }

    static func save(_ history: EvaluationHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: legacyBaselineKey)
    }
}

private extension EvaluationTag {
    var title: String {
        switch self {
        case .naturalSpeech: "자연스러운 표현"
        case .speechRecognitionVariation: "음성 인식 변형"
        case .spacingVariation: "띄어쓰기 변형"
        case .followUp: "후속 질문"
        case .pronoun: "대명사"
        case .topicChange: "주제 전환"
        case .ambiguous: "모호한 명령"
        case .safetyCritical: "안전 중요 명령"
        }
    }
}

extension RoutingEvaluationCategory {
    var title: String {
        switch self {
        case .conversation: "대화·기능 안내"
        case .media: "미디어"
        case .volume: "볼륨"
        case .alarm: "알람"
        case .briefing: "브리핑"
        case .weather: "날씨"
        case .calendar: "일정"
        case .time: "시간"
        case .navigation: "길 안내"
        case .communication: "전화·연락"
        case .application: "앱 실행"
        case .search: "검색"
        case .memory: "기억"
        case .safety: "안전·취소"
        }
    }
}

private struct SafetySettingsView: View {
    @AppStorage(SafetyControlStore.externalActionsLockKey)
    private var externalActionsLocked = false
    @ObservedObject private var auditStore = SafetyAuditStore.shared
    @State private var showsClearConfirmation = false

    var body: some View {
        Form {
            Section("긴급 안전 잠금") {
                Toggle(isOn: $externalActionsLocked) {
                    Label(
                        externalActionsLocked ? "외부 실행 잠김" : "외부 실행 허용",
                        systemImage: externalActionsLocked ? "lock.shield.fill" : "lock.open.fill"
                    )
                }
                .tint(.red)

                if !externalActionsLocked {
                    Button(role: .destructive) {
                        externalActionsLocked = true
                    } label: {
                        Label("지금 외부 실행 모두 잠그기", systemImage: "exclamationmark.shield.fill")
                    }
                }

                Text("잠그면 전화, 앱·지도·YouTube 실행과 데이터 변경이 차단됩니다. 날씨·시간·일정 조회와 현재 울리는 알람 정지, 미디어 정지, 음량 조절은 계속 사용할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("고정 안전 원칙") {
                Label("모델은 실행 권한을 스스로 늘릴 수 없음", systemImage: "person.badge.key")
                Label("모든 알람·기억 삭제는 반드시 재확인", systemImage: "checkmark.bubble")
                Label("외부 콘텐츠와 기억은 명령이 아닌 참고 자료", systemImage: "doc.text.magnifyingglass")
                Label("실행 기록에는 개인정보와 명령 원문을 저장하지 않음", systemImage: "hand.raised.fill")
            }

            Section("최근 안전 판단") {
                if auditStore.events.isEmpty {
                    ContentUnavailableView(
                        "실행 기록 없음",
                        systemImage: "checkmark.shield",
                        description: Text("명령을 사용하면 개인정보를 제외한 판단 기록이 여기에 표시됩니다.")
                    )
                } else {
                    ForEach(Array(auditStore.events.prefix(50))) { event in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.actionName)
                                Text(event.date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(event.outcome.title)
                                    .foregroundStyle(event.outcome.color)
                                Text(event.risk.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("실행 기록 지우기", role: .destructive) {
                        showsClearConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("안전 및 실행 기록")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "개인정보가 없는 안전 판단 기록을 모두 지울까요?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("기록 지우기", role: .destructive) {
                auditStore.clear()
            }
            Button("취소", role: .cancel) {}
        }
    }
}

private extension ActionRiskLevel {
    var title: String {
        switch self {
        case .informational: "조회"
        case .low: "낮은 위험"
        case .medium: "주의"
        case .high: "높은 위험"
        }
    }
}

private extension SafetyAuditOutcome {
    var title: String {
        switch self {
        case .authorized: "허용"
        case .awaitingConfirmation: "확인 대기"
        case .blocked: "차단"
        case .confirmed: "확인 후 허용"
        case .cancelled: "취소"
        }
    }

    var color: Color {
        switch self {
        case .authorized, .confirmed: .green
        case .awaitingConfirmation: .orange
        case .blocked, .cancelled: .red
        }
    }
}

struct LongTermMemorySettingsView: View {
    @ObservedObject private var store = LongTermMemoryStore.shared
    @State private var newMemory = ""
    @State private var statusMessage = ""
    @State private var showsDeleteAllConfirmation = false
    @State private var category: LongTermMemoryCategory = .other
    @State private var importance: LongTermMemoryImportance = .normal
    @State private var hasExpiration = false
    @State private var expirationDate = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var pendingSensitiveMemory: String?
    @State private var conflictToKeep: LongTermMemoryRecord?

    var body: some View {
        Form {
            Section("새 기억 추가") {
                TextField("예: 나는 매운 음식을 좋아한다", text: $newMemory, axis: .vertical)
                    .lineLimit(2...4)
                Picker("분류", selection: $category) {
                    ForEach(LongTermMemoryCategory.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Picker("중요도", selection: $importance) {
                    ForEach(LongTermMemoryImportance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("만료일 설정", isOn: $hasExpiration)
                if hasExpiration {
                    DatePicker("만료일", selection: $expirationDate, in: Date()..., displayedComponents: .date)
                }
                Button {
                    if store.requiresSensitiveConfirmation(newMemory) {
                        pendingSensitiveMemory = newMemory
                    } else {
                        saveNewMemory(newMemory)
                    }
                } label: {
                    Label("기억 추가", systemImage: "plus.circle.fill")
                }
                .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.conflictingMemoryIDs().isEmpty {
                Section("충돌 해결 · 해결 전 답변에서 제외") {
                    ForEach(store.memories.filter { store.conflictingMemoryIDs().contains($0.id) }) { memory in
                        VStack(alignment: .leading) {
                            Text(memory.content)
                            Button("이 기억을 유지하고 관련 충돌 기억 삭제") { conflictToKeep = memory }
                        }
                    }
                }
            }
            if let error = store.storageError { Section { Text(error).foregroundStyle(.red) } }
            Section("저장된 기억 \(store.memories.count)개") {
                if store.memories.isEmpty {
                    ContentUnavailableView(
                        "저장된 기억 없음",
                        systemImage: "brain.head.profile",
                        description: Text("‘기억해줘’라고 말하거나 이 화면에서 직접 추가할 수 있습니다.")
                    )
                } else {
                    ForEach(store.memories.reversed()) { memory in
                        NavigationLink {
                            LongTermMemoryEditorView(memoryID: memory.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(memory.content)
                                    .lineLimit(3)
                                HStack {
                                    Text(memory.category.title)
                                    Text("·")
                                    Text(memory.importance.title)
                                    Text("·")
                                    Text(memory.source.title)
                                }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if memory.isExpired {
                                    Label("만료된 기억 · AI 문맥에서 제외됨", systemImage: "clock.badge.exclamationmark")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if store.conflictingMemoryIDs().contains(memory.id) {
                                    Label("다른 기억과 충돌 가능성", systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .swipeActions {
                            Button("삭제", role: .destructive) {
                                store.delete(id: memory.id)
                            }
                        }
                    }
                }
            }

            if !store.memories.isEmpty {
                Section {
                    Button("모든 장기 기억 삭제", role: .destructive) {
                        showsDeleteAllConfirmation = true
                    }
                }
            }

            Section {
                Text("삭제·수정된 기억의 표식 \(store.deletionMarkers.count)개를 내용 없이 보관합니다. 같은 내용의 자동 재제안을 줄이며, 삭제·수정 시 이전 대화 문맥도 초기화합니다. 유사 문장 전체를 탐지하는 것은 아닙니다.")
                Text("반복된 내용은 자동 저장하지 않습니다. 자비스가 저장 여부를 물었을 때 동의한 내용과 사용자가 직접 요청한 내용만 보관합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("장기 기억")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "저장된 장기 기억을 모두 삭제할까요?",
            isPresented: $showsDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("모두 삭제", role: .destructive) {
                statusMessage = store.deleteAll(confirmed: true) ? "모든 장기 기억을 삭제했습니다." : "안전 잠금으로 삭제하지 않았습니다."
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog(
            "민감한 정보를 저장할까요?",
            isPresented: Binding(
                get: { pendingSensitiveMemory != nil },
                set: { if !$0 { pendingSensitiveMemory = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("별도 확인 후 저장", role: .destructive) {
                if let pendingSensitiveMemory { saveNewMemory(pendingSensitiveMemory, sensitiveConfirmed: true) }
                pendingSensitiveMemory = nil
            }
            Button("취소", role: .cancel) { pendingSensitiveMemory = nil }
        } message: {
            Text("계좌·주소·의료 정보 등은 장기 기억에 보관하지 않는 것을 권장합니다.")
        }
        .confirmationDialog("선택한 기억만 유지할까요?", isPresented: Binding(
            get: { conflictToKeep != nil }, set: { if !$0 { conflictToKeep = nil } }
        ), titleVisibility: .visible) {
            Button("관련 충돌 기억 삭제", role: .destructive) {
                if let memory = conflictToKeep {
                    let ids = store.conflicts(with: memory.id).map(\.id)
                    statusMessage = store.resolveConflict(keeping: memory.id, removing: ids, confirmed: true)
                        ? "충돌을 해결했습니다." : "안전 잠금 또는 변경된 기억을 확인해주세요."
                }
                conflictToKeep = nil
            }
            Button("취소", role: .cancel) { conflictToKeep = nil }
        } message: {
            if let memory = conflictToKeep {
                Text("유지: \(memory.content)\n삭제: \(store.conflicts(with: memory.id).map(\.content).joined(separator: " / "))")
            }
        }
    }

    private func saveNewMemory(_ content: String, sensitiveConfirmed: Bool = false) {
        if store.add(
            content,
            source: .manual,
            category: category,
            importance: importance,
            expiresAt: hasExpiration ? expirationDate : nil,
            sensitiveConfirmed: sensitiveConfirmed
        ) != nil {
            newMemory = ""
            statusMessage = "장기 기억에 저장했습니다."
        } else {
            statusMessage = "저장할 내용을 입력해주세요."
        }
    }
}

private struct LongTermMemoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LongTermMemoryStore.shared
    let memoryID: UUID

    @State private var content = ""
    @State private var showsDeleteConfirmation = false
    @State private var showsSensitiveConfirmation = false
    @State private var saveError = ""
    @State private var category: LongTermMemoryCategory = .other
    @State private var importance: LongTermMemoryImportance = .normal
    @State private var hasExpiration = false
    @State private var expirationDate = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()

    var body: some View {
        Form {
            Section("기억 내용") {
                TextEditor(text: $content)
                    .frame(minHeight: 140)
            }

            Section("기억 관리") {
                Picker("분류", selection: $category) {
                    ForEach(LongTermMemoryCategory.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Picker("중요도", selection: $importance) {
                    ForEach(LongTermMemoryImportance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("만료일 설정", isOn: $hasExpiration)
                if hasExpiration {
                    DatePicker("만료일", selection: $expirationDate, displayedComponents: .date)
                }
                if let memory = store.memories.first(where: { $0.id == memoryID }) {
                    LabeledContent("출처", value: memory.source.title)
                    LabeledContent("저장 시각", value: memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let lastUsedAt = memory.lastUsedAt {
                        LabeledContent("마지막 참고", value: lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section {
                Button("수정 내용 저장") {
                    if store.requiresSensitiveConfirmation(content) { showsSensitiveConfirmation = true }
                    else { saveMemory(sensitiveConfirmed: false) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !saveError.isEmpty { Text(saveError).foregroundStyle(.red) }

                Button("이 기억 삭제", role: .destructive) {
                    showsDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("기억 수정")
        .confirmationDialog("민감한 정보를 저장할까요?", isPresented: $showsSensitiveConfirmation, titleVisibility: .visible) {
            Button("확인 후 저장", role: .destructive) { saveMemory(sensitiveConfirmed: true) }
            Button("취소", role: .cancel) {}
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let memory = store.memories.first(where: { $0.id == memoryID }) else { return }
            content = memory.content
            category = memory.category
            importance = memory.importance
            hasExpiration = memory.expiresAt != nil
            if let expiresAt = memory.expiresAt { expirationDate = expiresAt }
        }
        .confirmationDialog(
            "이 장기 기억을 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                store.delete(id: memoryID)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        }
    }

    private func saveMemory(sensitiveConfirmed: Bool) {
        if store.update(id: memoryID, content: content, category: category, importance: importance,
            expiresAt: .some(hasExpiration ? expirationDate : nil), sensitiveConfirmed: sensitiveConfirmed) { dismiss() }
        else { saveError = "안전 잠금 또는 저장할 내용을 확인해주세요." }
    }
}

private struct YouTubePlaylistSettingsView: View {
    @StateObject private var account = YouTubeAccountService.shared

    var body: some View {
        Form {
            Section("Google 계정 재생목록") {
                if let accountName = account.accountName {
                    LabeledContent("연결된 계정", value: accountName)
                }

                if account.isSignedIn {
                    Button {
                        account.synchronize()
                    } label: {
                        Label("내 재생목록 다시 동기화", systemImage: "arrow.clockwise")
                    }
                    .disabled(account.isWorking)

                    Button("계정 연결 해제", role: .destructive) {
                        account.signOut()
                    }
                    .disabled(account.isWorking)
                } else {
                    Button {
                        account.signIn()
                    } label: {
                        Label("Google 계정 연결", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(account.isWorking)
                }

                if account.isWorking {
                    ProgressView("재생목록을 동기화하는 중입니다.")
                } else {
                    Text(account.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("직접 만든 재생목록") {
                if account.playlists.isEmpty {
                    Text("동기화된 재생목록이 없습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(account.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.title)
                            Text("영상 \(playlist.itemCount)개")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("사용 방법") {
                Text("1. Google 계정 연결을 누르고 YouTube 읽기 전용 권한을 허용합니다.")
                Text("2. 사용자가 직접 만든 재생목록이 자동으로 동기화됩니다.")
                Text("3. 자비스에게 ‘운동 재생목록 틀어줘’라고 말합니다.")
            }

            Section {
                Text("사용자가 직접 만든 재생목록만 조회합니다. YouTube에서 저장한 타인의 재생목록과 나중에 볼 동영상은 동기화하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("YouTube 재생목록")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Google 계정 연결 확인",
            isPresented: Binding(
                get: { account.connectionAlertMessage != nil },
                set: { if !$0 { account.connectionAlertMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {
                account.connectionAlertMessage = nil
            }
        } message: {
            Text(account.connectionAlertMessage ?? "Google 계정 연결 설정을 확인해주세요.")
        }
        .onAppear {
            account.restoreSession()
        }
    }
}

private struct AppLaunchSetupView: View {
    var body: some View {
        List {
            Section("바로 실행되는 앱") {
                Text("유튜브, 사파리, 지도, 메시지, 메일, FaceTime, 단축어는 별도 설정 없이 열 수 있습니다.")
            }

            Section("나머지 모든 앱 연결") {
                Text("1. 단축어 앱에서 +를 눌러 새 단축어를 만듭니다.")
                Text("2. ‘앱 열기’ 동작을 추가하고 원하는 앱을 선택합니다.")
                Text("3. 단축어 이름을 정확히 ‘앱이름 열기’로 저장합니다.")
                Text("4. JARVIS에게 ‘앱이름 열어줘’라고 말합니다.")

                Link(
                    "새 단축어 만들기",
                    destination: URL(string: "shortcuts://create-shortcut")!
                )
            }

            Section("예시") {
                LabeledContent("단축어 이름", value: "카카오톡 열기")
                LabeledContent("동작", value: "앱 열기 → 카카오톡")
                LabeledContent("음성 명령", value: "카카오톡 열어줘")
            }

            Section {
                Text("iOS는 일반 앱이 설치된 모든 앱을 이름만으로 직접 실행하는 기능을 제공하지 않습니다. 이 방식은 Apple 단축어를 안전한 연결 계층으로 사용합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("앱 실행 연결")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MediaAndAlarmSetupView: View {
    var body: some View {
        List {
            Section("유튜브·미디어 재생 중지") {
                Text("1. 단축어 앱에서 +를 눌러 새 단축어를 만듭니다.")
                Text("2. ‘재생/일시 정지’ 동작을 추가합니다.")
                Text("3. 동작을 ‘일시 정지’로 선택합니다.")
                Text("4. 단축어 이름을 정확히 ‘미디어 일시 정지’로 저장합니다.")
                Text("5. JARVIS에게 ‘노래 꺼줘’ 또는 ‘재생 멈춰줘’라고 말합니다.")

                Link(
                    "새 단축어 만들기",
                    destination: URL(string: "shortcuts://create-shortcut")!
                )
            }

            Section("볼륨 명령") {
                Text("‘볼륨 40퍼센트로 해줘’")
                Text("‘볼륨 올려줘’ 또는 ‘볼륨 내려줘’")
                Text("‘음소거해줘’")
            }

            Section("알람 명령") {
                Text("‘내일 오전 7시 30분에 알람 맞춰줘’")
                Text("‘10분 뒤에 알람 울려줘’")
                Text("‘10분 뒤에 불 끄라고 해줘’")
                Text("앱 사용 중: ‘알람 꺼줘’")
                Text("잠금 상태: ‘Siri야, JARVIS 알람 꺼줘’")
                Text("첫 실행 시 알람 또는 알림 권한을 허용해야 합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("‘알람/알림 맞춰줘’는 시스템 알람음을, 다른 자연어 시간 요청은 JARVIS TTS 음성을 사용합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("잠금 화면에서는 AlarmKit 알람의 중지 버튼을 누르거나 Siri로 JARVIS 알람 끄기를 실행할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("미디어·볼륨·알람")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonalizationSettingsView: View {
    @State private var profile = UserProfileStore.load()
    @State private var statusMessage = ""
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Form {
            Section("나의 정보") {
                TextField("이름", text: $profile.name)
                TextField("자비스가 나를 부를 호칭", text: $profile.preferredAddress)
                TextField("직업 또는 현재 상황", text: $profile.occupationOrSituation)
                TextField("관심사", text: $profile.interests, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("AI 답변 스타일") {
                Picker("기본 말투", selection: $profile.responseStyle) {
                    ForEach(AssistantResponseStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }

                Text("추가 지침")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $profile.additionalInformation)
                    .frame(minHeight: 120)
                Text("예: 설명은 한국어로, 결론부터 말해줘. 코드는 Swift를 우선해줘.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("나의 정보 저장") {
                    statusMessage = UserProfileStore.save(profile)
                        ? "저장했습니다. 다음 대화부터 반영됩니다."
                        : "저장하지 못했습니다."
                }
                .buttonStyle(.borderedProminent)

                Button("저장된 개인화 정보 삭제", role: .destructive) {
                    showsDeleteConfirmation = true
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("이 정보는 해당 iPhone의 Keychain에만 저장됩니다. 주민등록번호, 비밀번호, 결제 정보는 입력하지 마세요.")
            }
        }
        .navigationTitle("나의 정보·AI 스타일")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            profile = UserProfileStore.load()
        }
        .confirmationDialog(
            "개인화 정보를 모두 삭제할까요?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if UserProfileStore.delete() {
                    profile = UserProfile()
                    statusMessage = "개인화 정보를 삭제했습니다."
                } else {
                    statusMessage = "삭제하지 못했습니다."
                }
            }
            Button("취소", role: .cancel) {}
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 52)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                Text(message.text)
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .textSelection(.enabled)
                if !message.sources.isEmpty {
                    Divider()
                    Text("출처")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(Array(message.sources.enumerated()), id: \.offset) { _, source in
                        Link(destination: source.url) {
                            Label(source.title, systemImage: "arrow.up.right.square")
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                Text(message.role == .user ? "나" : "자비스")
                    .font(.caption2)
                    .foregroundStyle(message.role == .user ? .white.opacity(0.72) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == .user ? Color.blue : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )

            if message.role == .assistant {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
