import SwiftUI
import UIKit

/// Sibling tools share one destination immediately below Settings. Detail
/// records inside each feature continue to push normally beneath that feature.
struct SettingsWorkspaceView: View {
    @StateObject private var navigation: WorkspaceNavigation
    init(initial: WorkspacePage) {
        precondition(initial.parent == .settings)
        _navigation = StateObject(wrappedValue: WorkspaceNavigation(initial))
    }
    init(navigation: WorkspaceNavigation) {
        precondition(navigation.parent == .settings)
        _navigation = StateObject(wrappedValue: navigation)
    }
    var body: some View {
        Group {
            switch navigation.page {
            case .openAI: OpenAISettingsView()
            case .learning: LearningResultsView()
            case .practice: CommandPracticeView()
            case .review: ImprovementReviewView()
            case .memories: LongTermMemorySettingsView()
            case .database, .transfer, .chat, .settings, .development, .alarms, .calendar, .handsFree, .iCloudProject, .multiAgent: EmptyView()
            }
        }
        .id(navigation.page)
        .environment(\.workspaceNavigation, navigation)
    }
}

struct OpenAISettingsView: View {
    @ObservedObject private var store = OpenAIIntegrationStore.shared
    @State private var key = ""
    @State private var draft = OpenAIConfiguration()
    @State private var confirmation: PendingChange?
    @State private var message = ""

    private enum PendingChange: String, Identifiable {
        case enable, save
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("OpenAI 모드") {
                Picker("사용 모드", selection: Binding(
                    get: { store.configuration.enabled },
                    set: { enabled in
                        if enabled {
                            if store.hasAPIKey { confirmation = .enable }
                            else { message = "먼저 API 키를 저장해주세요." }
                        } else { show(store.disable(), success: "OpenAI를 끄고 기기 내 AI로 전환했습니다.") }
                    }
                )) {
                    Text("비사용").tag(false)
                    Text("사용").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("openai.usage-mode")
                Text(store.status).font(.footnote).foregroundStyle(.secondary)
                Text("일반 대화와 인터넷 검색 결과 요약에 사용합니다. 기본 명령은 기기에서 처리하며, 학습 결과에서 미해결 명령의 추가 해석을 별도 승인할 수 있습니다.")
                    .font(.footnote)
            }

            Section("개인 API 키") {
                LabeledContent("키 상태", value: store.hasAPIKey ? "이 iPhone에 저장됨" : "등록되지 않음")
                SecureField(store.hasAPIKey ? "새 키를 입력하면 교체" : "OpenAI API 키", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("openai.api-key")
                Text("키는 iPhone Keychain에 보관합니다. 개인용 직접 연결이며, 앱에 공용 키를 넣어 배포하지 마세요.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("API 키 발급 페이지") {
                    Task { await openResource("https://platform.openai.com/api-keys") }
                }
                if store.hasAPIKey {
                    Button("키 삭제 및 OpenAI 사용 중지", role: .destructive) {
                        show(store.disable(removeKey: true), success: "키를 삭제하고 OpenAI 사용을 중지했습니다.")
                        key = ""
                    }
                }
            }

            Section("토큰 및 전송 범위") {
                LabeledContent("모델", value: OpenAIResponsesTransport.model)
                Picker("오늘 요청 한도", selection: $draft.dailyRequestLimit) {
                    ForEach([10, 30, 50, 100], id: \.self) { Text("\($0)회").tag($0) }
                }
                Picker("응답 최대 토큰", selection: $draft.maximumOutputTokens) {
                    ForEach([200, 400, 800], id: \.self) { Text("\($0)토큰").tag($0) }
                }
                Toggle("최근 대화 일부 함께 보내기", isOn: $draft.includeHistory)
                Toggle("관련 장기 기억·나의 정보 보내기", isOn: $draft.includePersonalContext)
                Text("현재 입력과 검색 요약 대상은 OpenAI로 전송됩니다. 최근 대화는 최대 4턴, 장기 기억은 관련 항목 최대 3개만 보냅니다. 장기 기억·프로필 전송 옵션은 기본적으로 꺼져 있습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("키 저장 및 설정 적용") { confirmation = .save }
                    .accessibilityIdentifier("openai.save")
                if !message.isEmpty { Text(message).font(.footnote) }
            }

            Section("오늘의 앱 내 사용량") {
                LabeledContent("요청 시도", value: "\(store.usage.requests)회")
                LabeledContent("확인된 입력 토큰", value: "\(store.usage.inputTokens)")
                LabeledContent("확인된 출력 토큰", value: "\(store.usage.outputTokens)")
                Text("응답을 받은 요청의 토큰만 집계합니다. 취소·통신 실패한 요청도 서버 처리에 따라 과금될 수 있습니다. 앱 요청 한도는 OpenAI 계정의 결제 한도와 별개입니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("OpenAI 사용량 확인") {
                    Task { await openResource("https://platform.openai.com/usage") }
                }
            }
            Section {
                WorkspaceSiblingLink("학습 결과", page: .learning)
                Text("API 응답은 자체 모델의 가중치를 자동으로 학습시키지 않습니다. 응답 저장을 요청하지 않는 store: false로 연결하며, OpenAI의 서비스 데이터 보관 정책은 별도로 적용됩니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("OpenAI 연결")
        .onAppear {
            draft = store.configuration
            store.refreshUsageDay()
        }
        .alert(item: $confirmation) { change in
            let settings = draft
            let scope = [
                "현재 입력과 검색 요약 대상 일부",
                settings.includeHistory ? "최근 대화 최대 4턴과 요약" : nil,
                settings.includePersonalContext ? "관련 장기 기억·프로필" : nil
            ].compactMap { $0 }.joined(separator: ", ")
            return Alert(
                title: Text(change == .enable ? "OpenAI를 사용할까요?" : "OpenAI 설정을 저장할까요?"),
                message: Text("\(scope)가 대화·요약 시 OpenAI로 전송됩니다. 하루 최대 \(settings.dailyRequestLimit)회, 응답 최대 \(settings.maximumOutputTokens)토큰으로 설정합니다."),
                primaryButton: .default(Text("확인")) {
                    var configuration = settings
                    configuration.enabled = change == .enable ? true : store.configuration.enabled
                    let result = store.apply(configuration, key: change == .save ? key : nil, confirmed: true)
                    show(result, success: change == .enable ? "OpenAI 사용 모드입니다." : "설정을 저장했습니다.")
                    if result.accepted { draft = store.configuration }
                    key = ""
                },
                secondaryButton: .cancel(Text("취소"))
            )
        }
        .onDisappear { key = "" }
    }

    private func show(_ result: ToolExecutionResult<Void>, success: String) {
        switch result {
        case .succeeded: message = success
        case .handedOff: message = "요청을 전달했습니다."
        case .needsPermission(let reason), .needsConfirmation(let reason), .failed(let reason, _), .unverifiable(let reason): message = reason
        }
    }

    private func openResource(_ address: String) async {
        let intent = AssistantIntent.openApp(name: "OpenAI 안내")
        let decision = SafetyPolicyEngine().evaluate(intent, context: .init(externalActionsLocked: SafetyControlStore.externalActionsLocked))
        switch decision {
        case .block(let risk, let name, let reason):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .blocked)
            message = reason
            return
        case .requireConfirmation(_, _, let prompt):
            message = prompt
            return
        case .allow(let risk, let name):
            SafetyAuditStore.shared.record(actionName: name, risk: risk, outcome: .authorized)
        }
        guard let url = URL(string: address) else { return }
        let result: ToolExecutionResult<Void> = await ToolExecutionCoordinator.shared.execute(key: "openai-resource-open", timeout: .seconds(8)) {
            @MainActor in
            await UIApplication.shared.open(url)
                ? .handedOff(()) : .failed(message: "OpenAI 안내 페이지를 열지 못했습니다.", retryable: false)
        }
        if !result.accepted { show(result, success: "") }
    }
}

struct LearningResultsView: View {
    @ObservedObject private var practice = CommandPracticeStore.shared
    @ObservedObject private var improvements = ImprovementReviewStore.shared
    @ObservedObject private var store = OpenAIIntegrationStore.shared
    @ObservedObject private var memories = LongTermMemoryStore.shared
    @State private var history = EvaluationHistoryStore.load()
    private let conversation = ConversationEvaluationRunner().run(ConversationEvaluationCorpus.standard)

    private var evidence: LearningProgressEvidence {
        let current = history.latest
        let baseline = history.snapshots.first {
            $0.createdAt != current?.createdAt && $0.corpusVersion == current?.corpusVersion && $0.totalCount == current?.totalCount
        }
        return .init(baseline: baseline, current: current)
    }

    var body: some View {
        List {
            Section("모델 학습 상태") {
                Label("자체 모델 학습은 아직 수행하지 않았습니다", systemImage: "brain")
                LabeledContent("사용자가 적용한 명령 연습", value: "\(practice.approved.count)문항")
                if let validation = practice.validations.last {
                    Text(validation.permitted ? "최근 명령 예제 변경: 회귀 검증 통과" : "최근 명령 예제 변경: 적용 보류")
                    Text("별도 문장 \(validation.holdoutBefore) → \(validation.holdoutAfter)/\(validation.holdoutTotal) · 새 실패 \(validation.newFailures)개. 일반화 성공이나 가중치 학습 완료를 뜻하지 않습니다.").font(.caption)
                }
                WorkspaceSiblingLink("명령 자동 학습 연습 · 한 번에 10문항", page: .practice)
                LabeledContent("검토·재검증한 답변 개선", value: "\(improvements.examples.filter(\.verifiedImprovement).count)개")
                ForEach(improvements.examples.filter(\.verifiedImprovement).suffix(5)) { item in
                    VStack(alignment: .leading) {
                        Text(item.question).lineLimit(2)
                        Text(item.status).font(.caption).foregroundStyle(.secondary)
                        if let date = item.verifiedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    }
                }
                WorkspaceSiblingLink("실제 답변 평가·정정 검토", page: .review)
                Text("OpenAI 사용 모드를 켜면 대화·요약에 도움을 받습니다. 모델 가중치 학습이나 미세 조정이 완료된 기록은 없습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("사용자가 승인한 개인화 기억") {
                let active = memories.memories.filter { !$0.isExpired }
                if active.isEmpty {
                    Text("저장된 개인화 기억이 없습니다.")
                }
                ForEach(LongTermMemoryCategory.allCases) { category in
                    let count = active.filter { $0.category == category }.count
                    if count > 0 { LabeledContent(category.title, value: "\(count)개 기억") }
                }
                WorkspaceSiblingLink("기억한 내용 확인·수정", page: .memories)
                Text("기억은 사용자가 저장을 승인한 정보입니다. 삭제하거나 만료된 항목은 집계에서 제외합니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("평가에서 확인된 개선") {
                switch evidence.status {
                case .needsBaseline:
                    Text("비교할 평가 기록이 필요합니다.")
                case .incomparable:
                    Text("평가 문장 버전이 달라 개선 여부를 비교하지 않았습니다.")
                case .regression:
                    Text("회귀 또는 안전 지표 확인이 필요합니다. 개선 성공으로 기록하지 않았습니다.")
                case .unchanged:
                    Text("같은 평가 기준에서 추가 개선은 확인되지 않았습니다.")
                case .improved:
                    Label("같은 평가 기준에서 개선 확인", systemImage: "checkmark.seal")
                    ForEach(evidence.improvedCategories.keys.sorted(), id: \.self) { category in
                        LabeledContent(RoutingEvaluationCategory(rawValue: category)?.title ?? category,
                                       value: "+\(((evidence.improvedCategories[category] ?? 0) * 100).formatted(.number.precision(.fractionLength(1))))%p")
                    }
                    LabeledContent("해결한 실패 사례", value: "\(evidence.resolvedFailures)개")
                }
                Text("설정 → 명령 이해 평가에서 결과를 저장하면 같은 버전의 이전 결과와 비교합니다. 이 수치는 명령 처리의 개선 근거이며 모델 학습 완료를 뜻하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("OpenAI 활용 결과 · 누적") {
                LabeledContent("일반 대화 응답 수신", value: "\(store.observedResults.conversationResponses)회")
                LabeledContent("검색 결과 요약 수신", value: "\(store.observedResults.searchSummaries)회")
                LabeledContent("응답 실패", value: "\(store.observedResults.failedRequests)회")
                if let date = store.observedResults.lastSuccess {
                    LabeledContent("마지막 응답 수신", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Text("응답을 받은 횟수입니다. 내용의 정확성이나 학습 성공을 판정한 수치는 아닙니다. 원문은 이 기록에 저장하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("일반 대화 기반 검사") {
                LabeledContent("질문 분류·음성 형식", value: "\(conversation.passed)/\(conversation.total)개 통과")
                Text("미리 작성된 예시 답변으로 검사합니다. 실제 API 모델의 지식이나 대화 품질은 별도 검증이 필요합니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("학습 결과")
        .onAppear { history = EvaluationHistoryStore.load() }
    }
}
