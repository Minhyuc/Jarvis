import SwiftUI

struct ImprovementReviewView: View {
    @ObservedObject private var store = ImprovementReviewStore.shared
    @State private var confirmSettings = false
    @State private var collect = false
    @State private var semantic = false
    @State private var confirmEvaluation = false
    @State private var confirmDelete = false
    @State private var work: Task<Void, Never>?

    var body: some View {
        List {
            Section("개선 자료와 명령 이해") {
                Toggle("정정 후보 수집·검증된 수정안 참고", isOn: $collect)
                Toggle("미해결 명령에 OpenAI 해석 사용", isOn: $semantic)
                Button("동의 범위 확인 후 적용") { confirmSettings = true }
                Button("수집·수정안 참고·추가 해석 중지") { store.disable(); refresh() }
                Text("기본 꺼짐. 정정 후보는 최대 10개를 메모리에만 보관하고, 검토·저장한 자료 최대 100개만 이 기기에 저장합니다. 원문에 개인정보가 있을 수 있으므로 저장 전 삭제·수정하세요. 장기 기억이나 모델 가중치로 자동 저장하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("OpenAI 해석은 기본 분류와 기기 내 해석이 해결하지 못한 경우에만 추가 요청합니다. 알람·기억·권한·설정 변경은 제외하고 기존 안전 정책을 유지합니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("정정 후보 · 아직 저장되지 않음") {
                if store.pending.isEmpty { Text("검토할 후보가 없습니다.") }
                ForEach(store.pending) { item in
                    NavigationLink(item.question) { ImprovementExampleView(initial: item, pending: true) }
                }
            }
            Section("검토한 개선 자료") {
                ForEach(store.examples.reversed()) { item in
                    NavigationLink {
                        ImprovementExampleView(initial: item, pending: false)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.question).lineLimit(2)
                            Text(item.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("OpenAI 수정안도 오류가 있을 수 있습니다. 승인한 수정안을 참고해 동일 질문에 재응답한 뒤, 사용자가 확인한 사례만 개선으로 표시합니다. 이는 가중치 학습이나 일반화 성능의 증거가 아닙니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("실제 모델 답변 평가") {
                ForEach(store.dataNeeds, id: \.self) { Text($0).font(.footnote) }
                Button("고정 질문 8개 실제 API 평가") { confirmEvaluation = true }.disabled(store.busy)
                if store.busy { ProgressView("처리 중") }
                Button("진행 작업 취소") { work?.cancel() }.disabled(!store.busy)
                if !store.message.isEmpty { Text(store.message).font(.footnote) }
                if store.runs.count >= 2, let latest = store.runs.last,
                   let previous = store.runs.dropLast().last,
                   let change = latest.changes(from: previous) {
                    Text("동일 기준 비교: 개선 \(change.improved.count)개 · 퇴보 \(change.regressed.count)개")
                    if !change.regressed.isEmpty { Text("퇴보: " + change.regressed.sorted().joined(separator: ", ")).foregroundStyle(.red) }
                } else { Text("동일 질문·기준으로 두 번 평가하고 모든 항목을 검토하면 개선과 퇴보를 비교합니다.").font(.footnote) }
                ForEach(store.runs.reversed()) { run in
                    NavigationLink {
                        ResponseQualityRunView(runID: run.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(run.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(run.model) · 검토 \(run.reviewedCount)/\(run.observations.count)").font(.caption)
                        }
                    }
                }
            }
            Section {
                Button("개선 자료·평가 기록 모두 삭제", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle("답변 평가·정정 검토")
        .onAppear { refresh() }
        .onDisappear { work?.cancel() }
        .alert("수집·추가 API 해석 동의", isPresented: $confirmSettings) {
            Button("취소", role: .cancel) {}
            Button("동의 후 적용") { store.configure(collection: collect, semantic: semantic, confirmed: true); refresh() }
        } message: {
            Text("정정 후보는 명시적으로 저장하기 전까지 영구 보관하지 않습니다. 검증된 수정안은 동일 질문의 대화 참고 자료로만 사용합니다. 추가 해석을 켜면 미해결 입력과 허용된 대화 일부가 OpenAI로 전송되며 요청 한도가 적용됩니다. 자동 학습·자동 도구 실행은 하지 않습니다.")
        }
        .alert("실제 API 평가 실행", isPresented: $confirmEvaluation) {
            Button("취소", role: .cancel) {}
            Button("최대 13회 요청 승인") { work = Task { await store.runEvaluation(confirmed: true) } }
        } message: {
            Text("개인 대화가 아닌 고정 질문 8개·총 13턴을 OpenAI로 보냅니다. 토큰 비용이 발생할 수 있으며 하루 요청 한도를 공유합니다. 실제 답변은 이 기기에 저장되고 정확성은 직접 평가해야 합니다. 미완료 평가는 성공으로 기록하지 않습니다.")
        }
        .alert("개선 자료 모두 삭제", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { work?.cancel(); store.deleteAll() }
        } message: { Text("정정 후보, 저장한 수정안과 평가 기록을 삭제합니다. 삭제한 수정안은 이후 대화에 사용하지 않습니다.") }
    }

    private func refresh() { collect = store.collectionEnabled; semantic = store.semanticAssistanceEnabled }
}

private struct ImprovementExampleView: View {
    @ObservedObject private var store = ImprovementReviewStore.shared
    @Environment(\.dismiss) private var dismiss
    let initial: ImprovementExample
    let pending: Bool
    @State private var question = ""
    @State private var previousAnswer = ""
    @State private var correction = ""
    @State private var accepted = ""
    @State private var action: ReviewAction?
    @State private var work: Task<Void, Never>?
    private enum ReviewAction: String, Identifiable { case assist, retest, approve, verify; var id: String { rawValue } }
    private var current: ImprovementExample { store.examples.first { $0.id == initial.id } ?? initial }

    var body: some View {
        Form {
            if pending {
                Section("저장 전에 개인정보를 지워주세요") {
                    TextField("질문", text: $question, axis: .vertical)
                    TextField("잘못된 이전 답변", text: $previousAnswer, axis: .vertical)
                    TextField("사용자 정정", text: $correction, axis: .vertical)
                    Button("검토한 자료를 이 기기에 저장") {
                        var item = initial; item.question = question; item.previousAnswer = previousAnswer; item.correction = correction
                        store.saveCandidate(item); dismiss()
                    }
                }
            } else {
                Section("기존 판단과 정정") {
                    Text(current.question); Text(current.previousAnswer).foregroundStyle(.secondary); Text(current.correction)
                    Text(current.status).font(.caption)
                }
                Section("OpenAI 도움 · 자동 정답 판정 아님") {
                    Button("OpenAI에 수정안 요청") { action = .assist }.disabled(store.busy)
                    if let suggestion = current.assistedAnswer {
                        Text(suggestion)
                        TextField("사실을 확인한 수정 답변", text: $accepted, axis: .vertical)
                        Button("확인한 수정안 승인") { action = .approve }
                    }
                    if let approved = current.approvedAnswer {
                        Text("승인한 참고 답변: \(approved)")
                        Button("동일 질문 재검증 요청") { action = .retest }.disabled(store.busy)
                    }
                    if let retest = current.retestAnswer {
                        Text("재응답: \(retest)")
                        Button("재응답을 확인했고 개선 사례로 기록") { action = .verify }
                    }
                    Text(store.message).font(.footnote)
                }
            }
            Button("이 자료 삭제", role: .destructive) { work?.cancel(); store.delete(initial.id); dismiss() }
        }
        .navigationTitle("정정 검토")
        .onAppear {
            question = initial.question; previousAnswer = initial.previousAnswer; correction = initial.correction
            accepted = current.approvedAnswer ?? current.assistedAnswer ?? ""
        }
        .onChange(of: current.assistedAnswer) { _, value in accepted = value ?? "" }
        .onDisappear { work?.cancel() }
        .alert(item: $action) { selected in
            switch selected {
            case .assist, .retest:
                return Alert(title: Text("OpenAI 전송·비용 확인"),
                    message: Text("화면의 질문과 \(selected == .assist ? "이전 답변·사용자 정정" : "승인한 참고 답변")을 OpenAI에 보냅니다. 개인정보를 확인해주세요. 1회 요청 비용이 발생할 수 있고, 검색이나 가중치 학습은 수행하지 않습니다."),
                    primaryButton: .default(Text("전송 승인")) { work = Task { await store.assist(id: initial.id, retest: selected == .retest, confirmed: true) } },
                    secondaryButton: .cancel(Text("취소")))
            case .approve:
                return Alert(title: Text("수정안 승인"), message: Text("외부 근거와 사실을 확인했나요? 승인한 내용은 재검증 후 동일 질문의 참고 자료로만 사용합니다. 안전 정책이나 도구 실행 권한에는 사용하지 않습니다."),
                    primaryButton: .default(Text("확인 후 승인")) { store.approveAnswer(id: initial.id, answer: accepted) }, secondaryButton: .cancel(Text("취소")))
            case .verify:
                return Alert(title: Text("개선 사례 확인"), message: Text("이전 답변은 틀렸으며, 수정안과 재응답이 올바른지 확인했나요? 이는 사용자 검토·참고 자료 적용 성공이며 모델 가중치 학습 성공이 아닙니다."),
                    primaryButton: .default(Text("검토 완료")) { store.verifyRetest(id: initial.id) }, secondaryButton: .cancel(Text("취소")))
            }
        }
    }
}

private struct ResponseQualityRunView: View {
    @ObservedObject private var store = ImprovementReviewStore.shared
    let runID: UUID
    var body: some View {
        List {
            if let run = store.runs.first(where: { $0.id == runID }) {
                Section { Text("\(run.model) · \(run.promptVersion) · \(run.suiteVersion)") }
                ForEach(run.observations) { observation in
                    Section(observation.id) {
                        ForEach(Array(observation.turns.enumerated()), id: \.offset) { index, question in
                            Text(question).font(.headline)
                            if observation.answers.indices.contains(index) { Text(observation.answers[index]) }
                        }
                        Text("기준: " + observation.rubric).font(.footnote)
                        Text("자동 형식·키워드 검사: \(observation.automaticChecksPassed ? "통과" : "확인 필요") · 사실 정확성 판정 아님").font(.caption)
                        ForEach(ResponseQualityDimension.allCases, id: \.self) { dimension in
                            Picker(dimension.title, selection: Binding(get: { observation.ratings[dimension] ?? -1 }, set: {
                                store.rate(runID: runID, observationID: observation.id, dimension: dimension, value: $0)
                            })) {
                                Text("미검토").tag(-1); Text("실패").tag(0); Text("보완 필요").tag(1); Text("충족").tag(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("실제 답변 검토")
    }
}
