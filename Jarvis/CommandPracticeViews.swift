import SwiftUI

struct CommandPracticeView: View {
    @ObservedObject private var store = CommandPracticeStore.shared
    @State private var counting = false
    @State private var useExamples = false
    @State private var settingsConfirmation = false
    @State private var runConfirmation = false
    @State private var deletionConfirmation = false
    @State private var restoreSelection: PracticeLibraryRevision?
    @State private var inputRate = ""
    @State private var outputRate = ""

    var body: some View {
        List {
            Section("개인용 검토 범위 · 권리 확인") {
                Text("독창적인 짧은 가상 명령의 분류 검토만 지원합니다. 타인의 대화·기사·가사·개인정보는 연습 입력으로 보내지 않습니다. 모델 가중치 학습·증류·경쟁 모델 개발·자료 재배포는 지원하지 않습니다. 배포·상업화·목적 변경 전 별도 약관·권리 검토가 필요합니다. 법적 무위험을 보장하는 기능은 아닙니다.").font(.footnote)
                Link("OpenAI 공식 API 이용 조건", destination: URL(string: "https://openai.com/policies/services-agreement/")!)
                Link("API 데이터 보관 안내", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                if !store.personalUseAcknowledged { Text("아래 ‘설정 확인 후 적용’에서 위 범위를 확인해야 연습·적용을 사용할 수 있습니다.").foregroundStyle(.orange) }
                WorkspaceSiblingLink("사용자 정정·실패 후보 검토", page: .review)
            }
            Section("자동 학습 연습 · 최종 결정은 사용자") {
                Button("명령 변형 10문항 연습 시작") { runConfirmation = true }
                    .disabled(store.busy || store.availableSlots < 10)
                    .accessibilityIdentifier("practice.start-ten")
                if store.busy {
                    ProgressView(store.progress)
                    Button("연습·검증 중단", role: .cancel) { store.cancel() }
                }
                Text(store.message).font(.footnote)
                LabeledContent("선택 대기 결과", value: "\(store.pendingCount)/30개 · 빈 공간 \(store.availableSlots)개")
                if store.availableSlots < 10 { Text("10개를 추가할 공간이 부족합니다. 기존 결과를 적용하거나 폐기하면 다시 시작할 수 있습니다.").font(.footnote) }
                Text("한 번 누르면 10개 연습 슬롯을 생성합니다. OpenAI가 문장을 변형하고 별도로 검토하며, JARVIS는 기기 내 라우터·모델·승인 예제로 판단합니다. 전화·지도·알람 등 실제 도구는 실행하지 않습니다. 실패·중단은 완료로 집계하지 않고 자동 재시도하지 않습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("문항별 생성·검토 최대 2회, 전체 최대 20회의 API 요청이 필요합니다. 기기 내 모델을 지원하지 않으면 기본 명령 분류기를 검사합니다. 이 기능은 가중치 학습이 아니라 승인한 동일 문장의 해석 보완입니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("자주 쓰는 명령 선택") {
                Toggle("기능별 사용 횟수 집계", isOn: $counting)
                Toggle("승인한 문항을 명령 해석에 사용", isOn: $useExamples)
                Button("설정 확인 후 적용") { settingsConfirmation = true }.disabled(store.busy)
                Text("집계 기본 꺼짐. 명령 원문·지명·연락처·전화번호는 수집하지 않습니다. 지원하는 기능별 횟수로 자주 쓰는 상위 기능을 골라 고정 가상 예제를 변형합니다. 집계가 없으면 기본 예제로 연습합니다. 알람·기억·권한·자격 증명·안전 제어는 교육 적용 대상이 아닙니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(CommandPracticeSeed.standard.filter { store.counts[$0.id, default: 0] > 0 }
                    .sorted { store.counts[$0.id, default: 0] > store.counts[$1.id, default: 0] }) { seed in
                    LabeledContent(seed.command, value: "\(store.counts[seed.id, default: 0])회")
                }
            }
            Section("대기 결과와 연습 이력") {
                Text("실패·중단도 선택 전에는 대기 공간을 사용합니다. 적용·폐기하면 공간이 즉시 비워집니다. 미결정 결과는 자동 삭제하지 않고, 모두 검토한 묶음은 최근 10회까지 별도 이력으로 유지합니다.").font(.footnote)
                if store.batches.isEmpty { Text("아직 연습 기록이 없습니다.") }
                ForEach(store.batches.reversed()) { batch in
                    NavigationLink {
                        CommandPracticeBatchView(batchID: batch.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("평가 \(batch.evaluatedCount)/10 · 일치 \(batch.items.filter { $0.studentMatched == true && $0.phase == .evaluated }.count) · 적용 \(batch.items.filter { $0.decision == .applied }.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("현재 적용한 문항 · \(store.approved.count)/100") {
                ForEach(store.approved) { item in
                    VStack(alignment: .leading) {
                        Text(item.question)
                        Text(item.interpretation.label).font(.caption).foregroundStyle(.secondary)
                        Button("이 문항 적용 철회", role: .destructive) { store.revoke(item.id); refresh() }
                    }
                }
                Text("기존 라우터와 충돌하는 결과는 적용할 수 없습니다. 승인한 해석도 기기 실행 권한이 아니며, 중간·고위험 작업은 실행 직전에 기존 확인 절차를 따릅니다. 새 문장 전체를 이해하도록 모델이 일반화됐다는 뜻은 아닙니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("변경 전후 검증 · 최근 50회") {
                Text("기존 라우터 회귀 + 별도 보관한 12문장의 기기 내 라우터·모델 평가입니다. API 교사를 호출하지 않고 도구도 실행하지 않습니다. 기존 명령 95% 이상·새 실패 0개·안전 검사 통과 시에만 적용합니다. 반복 사용하는 고정 평가 세트의 점수이며 범용 지능·가중치 학습·일반화 성공의 증거는 아닙니다.").font(.footnote)
                ForEach(store.validations.reversed()) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.permitted ? "검증 통과 · 적용 가능" : "퇴보 또는 안전 검사 실패 · 적용 보류")
                        Text("기존 명령: \(result.beforePassed) → \(result.afterPassed)/\(result.regressionTotal)")
                        Text("별도 문장: \(result.holdoutBefore) → \(result.holdoutAfter)/\(result.holdoutTotal) · 새 실패 \(result.newFailures)")
                        Text("안전 검사 \(result.safetyPassed ? "통과" : "실패") · \(result.corpusVersion)")
                        Text(result.createdAt.formatted(date: .abbreviated, time: .shortened))
                        DisclosureGroup("별도 문장별 판단 확인") {
                            ForEach(result.observations ?? []) { observation in
                                if PracticeHoldout.cases.indices.contains(observation.id) {
                                    let test = PracticeHoldout.cases[observation.id]
                                    VStack(alignment: .leading) {
                                        Text(test.text)
                                        Text("고정 기준: " + test.target.label)
                                        Text("변경 전: " + observation.before + (observation.beforeMatched ? " · 일치" : " · 불일치"))
                                        Text("변경 후: " + observation.after + (observation.afterMatched ? " · 일치" : " · 불일치"))
                                    }
                                }
                            }
                        }
                    }.font(.caption)
                }
            }
            Section("명령 예제 이전 버전 · 최근 20개") {
                Text("복구도 현재 검증을 다시 거칩니다. 그 버전의 예제 전체를 복구하므로 이후 폐기·철회한 예제가 다시 포함될 수 있습니다. 전체 삭제 시 복구 기록도 제거합니다.").font(.footnote)
                ForEach(store.revisions.reversed()) { revision in
                    Button("\(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(revision.examples.count)개 복구") { restoreSelection = revision }.disabled(store.busy)
                }
            }
            Section("API 사용량·비용 추정") {
                TextField("입력 100만 토큰당 USD 단가", text: $inputRate).keyboardType(.decimalPad)
                TextField("출력 100만 토큰당 USD 단가", text: $outputRate).keyboardType(.decimalPad)
                Text("계정의 현재 모델 단가를 직접 확인해 입력한 뒤 ‘설정 확인 후 적용’으로 저장하세요. 다음 연습부터 단가를 함께 보관합니다. 미입력 시 금액은 미산정이며 요청·응답 토큰을 표시합니다. 실패·취소 요청의 청구 토큰은 확인하지 못하므로 OpenAI 청구 화면이 최종 기준입니다. 금액은 지출 상한이 아니며 기존 일일 요청 한도를 따릅니다.").font(.footnote)
            }
            Button("연습·적용·집계 기록 모두 삭제", role: .destructive) { deletionConfirmation = true }
        }
        .navigationTitle("명령 자동 학습 연습")
        .onAppear { refresh() }
        .alert("10문항 생성·평가 승인", isPresented: $runConfirmation) {
            Button("취소", role: .cancel) {}
            Button("최대 20회 요청으로 시작") { store.start(confirmed: true) }
        } message: {
            Text("가상 명령과 생성한 변형 문장을 OpenAI로 전송합니다. 실제 대화·연락처·목적지는 보내지 않습니다. API 비용과 하루 요청 한도가 적용됩니다. 결과는 자동 적용되지 않으며 각 문항에서 직접 승인해야 합니다. 앱을 닫거나 중단하면 자동 재개하지 않습니다.")
        }
        .alert("집계·적용 설정 확인", isPresented: $settingsConfirmation) {
            Button("취소", role: .cancel) { refresh() }
            Button("개인용·권리 범위 확인 후 적용") { store.configure(counting: counting, use: useExamples, confirmed: true, inputRate: inputRate, outputRate: outputRate); refresh() }
        } message: { Text("개인용 명령 분류 검토에 한정합니다. 입력 권리를 확인하며 타인의 저작물·대화는 전송하지 않습니다. 가중치 학습·증류·자료 재배포는 하지 않습니다. 집계는 기능별 횟수만 저장하며 실제 실행은 안전 정책을 거칩니다.") }
        .alert("이 명령 예제 버전으로 복구할까요?", isPresented: Binding(get: { restoreSelection != nil }, set: { if !$0 { restoreSelection = nil } })) {
            Button("취소", role: .cancel) { restoreSelection = nil }
            Button("검증 후 복구") {
                if let revision = restoreSelection { Task { await store.restore(revision.id, confirmed: true) } }
                restoreSelection = nil
            }
        } message: { Text("선택한 버전의 예제 전체로 교체합니다. 이후 철회한 예제도 포함될 수 있습니다. 권한·안전 정책·가중치는 복구 대상이 아닙니다.") }
        .alert("연습 기록 모두 삭제", isPresented: $deletionConfirmation) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { store.deleteAll(); refresh() }
        } message: { Text("진행 중인 연습을 중단하고 연습 이력·승인 예제·기능별 집계를 삭제합니다. 삭제한 문항은 다시 사용하지 않습니다.") }
    }
    private func refresh() {
        counting = store.usageCountingEnabled; useExamples = store.useApprovedExamples
        inputRate = store.configuredInputRate; outputRate = store.configuredOutputRate
    }
}

private struct CommandPracticeBatchView: View {
    @ObservedObject private var store = CommandPracticeStore.shared
    let batchID: UUID
    var body: some View {
        List {
            if let batch = store.batches.first(where: { $0.id == batchID }) {
                Section("실행 환경") {
                    Text("교사: " + batch.teacherModel)
                    Text("학생: " + batch.studentDescription)
                    Text("\(batch.version) · 평가 \(batch.evaluatedCount)/10")
                    Text("일치 여부는 고정 기준과 비교한 결과입니다. OpenAI도 틀릴 수 있으므로 문항과 해석을 직접 확인해주세요.").font(.footnote)
                    Text("API 요청 시도 \(batch.apiRequests ?? 0)회 · 확인된 입력 \(batch.inputTokens ?? 0), 출력 \(batch.outputTokens ?? 0) 토큰")
                    Text(batch.estimatedCostUSD.map { String(format: "확인된 토큰 예상 비용 $%.6f · 실패·취소 청구 제외", $0) } ?? "금액 미산정 · 토큰과 공식 청구 내역을 확인해주세요.").font(.caption)
                }
                ForEach(Array(batch.items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        CommandPracticeItemView(batchID: batch.id, itemID: item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). " + (item.question.isEmpty ? item.seedCommand : item.question))
                            Text(summary(item)).font(.caption).foregroundStyle(.secondary)
                            if let reply = item.studentReply {
                                Text("자비스: " + reply).font(.subheadline).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("10문항 결과")
    }
    private func summary(_ item: CommandPracticeItem) -> String {
        if item.phase == .failed { return "평가 실패 · 적용 안 됨" }
        if item.phase == .cancelled { return "중단 · 적용 안 됨" }
        if item.phase != .evaluated { return "평가 대기 또는 진행 중" }
        let result = item.studentMatched == true ? "JARVIS 기준 일치" : "JARVIS 교정 검토 필요"
        return result + " · " + decisionTitle(item.decision)
    }
}

private func decisionTitle(_ value: PracticeDecision) -> String {
    switch value {
    case .pending: "사용자 결정 대기"
    case .applied: "사용자 적용 승인"
    case .rejected: "사용자 적용 거절"
    case .revoked: "적용 철회"
    }
}

private struct CommandPracticeItemView: View {
    @ObservedObject private var store = CommandPracticeStore.shared
    let batchID: UUID
    let itemID: UUID
    @State private var confirmApply = false
    private var item: CommandPracticeItem? { store.batches.first { $0.id == batchID }?.items.first { $0.id == itemID } }
    var body: some View {
        Form {
            if let item {
                Section("어떤 연습인가요?") {
                    LabeledContent("기본 예제", value: item.seedCommand)
                    Text("변형: " + (item.question.isEmpty ? "생성되지 않음" : item.question))
                    Text("변형 방식: " + item.technique)
                    Text("고정 정답 기준: " + item.expected.label)
                }
                Section("자비스가 사용자에게 하는 응답") {
                    if let scenario = item.responseScenario {
                        Label("가상 상황 · 실제 기기 실행 아님", systemImage: "testtube.2").foregroundStyle(.orange)
                        Text(scenario).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let steps = item.studentTranscript, !steps.isEmpty {
                        ForEach(steps) { step in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(step.id + 1). \(stageTitle(step.stage))").font(.caption).foregroundStyle(.secondary)
                                Text(step.text).textSelection(.enabled)
                            }.padding(.vertical, 4)
                        }
                    } else {
                        Text(item.studentReply ?? "이전 연습 기록에는 대화 문장이 저장되어 있지 않습니다. 새 연습부터 기록됩니다.")
                            .textSelection(.enabled)
                    }
                    switch item.studentReplyKind {
                    case .simulatedTranscript:
                        Text("첫 안내뿐 아니라 가상 결과·후속 제안·재질문까지 표시합니다. 브리핑·날씨·일정 본문은 실제 앱과 같은 출력 포맷터를 사용합니다. 외부 앱 동작은 가상 결과이며, 승인이 필요한 경우 그 지점에서 멈춥니다. 실제 개인정보나 영업·재생 상태를 확인한 결과가 아닙니다.").font(.caption).foregroundStyle(.secondary)
                    case .localConversation:
                        Text("기기 내 대화 모델이 실제 생성한 답변입니다. 사실·실행 성공이 검증된 답변이라는 뜻은 아닙니다.").font(.caption).foregroundStyle(.secondary)
                    case .clarification:
                        Text("JARVIS가 실제로 반환한 재질문입니다.").font(.caption).foregroundStyle(.secondary)
                    case .executionPreview:
                        Text("JARVIS가 판단한 의도에 따른 실행 전 안내 미리보기입니다. 실제 사용자 화면의 최종 답변과 같다는 뜻은 아니며, 날씨·시간·검색 결과 조회나 기기 동작은 수행하지 않았습니다.").font(.caption).foregroundStyle(.secondary)
                    case .unavailable:
                        Text("대화 문장 생성 실패 · 학습 성공으로 집계하지 않음").font(.caption).foregroundStyle(.orange)
                    case nil: EmptyView()
                    }
                }
                Section("JARVIS 의도·인자 분석 결과") {
                    Text(item.studentConclusion)
                    if let matched = item.studentMatched { Text(matched ? "고정 기준과 일치" : "고정 기준과 불일치 또는 재질문") }
                }
                Section("OpenAI 교사 검토·교정 제안") {
                    Text(item.teacher?.label ?? "아직 교사 결론 없음")
                    Text(item.teacherReason)
                    if let confidence = item.teacherConfidence { Text("교사의 자체 확신: \(Int(confidence * 100))% · 실제 정확도 아님").font(.caption) }
                    if let failure = item.failureReason { Text(failure).foregroundStyle(.red) }
                    if let blocked = store.blockReason(for: item) { Text(blocked).font(.footnote).foregroundStyle(.orange) }
                }
                Section("최종 결정") {
                    Text(decisionTitle(item.decision))
                    if let date = item.reviewedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    if let after = item.postApplicationConclusion { Text(after).font(.footnote) }
                    Button("이 문항의 해석만 적용") { confirmApply = true }
                        .disabled(store.busy || item.decision != .pending || store.blockReason(for: item) != nil)
                    Button("이 문항 폐기 · 대기 공간 비우기") { store.reject(batchID: batchID, itemID: itemID) }.disabled(store.busy)
                    if item.decision == .applied { Button("이 문항 적용 철회", role: .destructive) { store.revoke(itemID) } }
                    Text(store.message).font(.footnote)
                }
            }
        }
        .navigationTitle("문항별 교육 검토")
        .alert("이 문항만 적용할까요?", isPresented: $confirmApply) {
            Button("취소", role: .cancel) {}
            Button("검증 후 이 문항만 적용") { Task { await store.apply(batchID: batchID, itemID: itemID, confirmed: true) } }
        } message: {
            Text("문장: \(item?.question ?? "")\n적용 해석: \(item?.expected.label ?? "")\n동일 문장만 보완하며 기존 명령이나 안전 정책을 덮어쓰지 않습니다. 실제 기기 동작은 실행하지 않습니다. 가중치 학습은 아닙니다.")
        }
    }
    private func stageTitle(_ stage: PracticeResponseStep.Stage) -> String {
        switch stage {
        case .progress: "첫 안내"
        case .result: "후속 결과 · 가상"
        case .suggestion: "추가 제안 · 가상"
        case .confirmation: "재질문·승인 대기"
        }
    }
}
