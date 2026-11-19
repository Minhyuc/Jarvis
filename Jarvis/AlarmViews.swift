import SwiftUI

struct AlarmListView: View {
    @ObservedObject private var service = AlarmService.shared
    @State private var showingNewAlarm = false
    @State private var editingAlarm: JarvisAlarmRecord?
    @State private var showingDeleteAll = false
    @State private var errorMessage = ""
    @State private var showingRecovery = false

    var body: some View {
        List {
            StorageRecoveryNotice(message: service.storageIssue, canRestore: service.canRestore) {
                try await service.restoreStorage(confirmed: true)
            }
            if let message = service.statusMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
                Button("중단된 변경 확인·복구") { showingRecovery = true }
            }
            if service.alarms.isEmpty {
                ContentUnavailableView(
                    service.storageIssue == nil ? "등록된 알람이 없습니다" : "알람 목록을 확인하지 못했습니다",
                    systemImage: "alarm",
                    description: Text(service.storageIssue == nil ? "오른쪽 위의 추가 버튼을 누르거나 JARVIS에게 말해보세요." : "저장 상태 경고를 확인해주세요. 기존 시스템 알람은 목록과 별개로 남아 있을 수 있습니다.")
                )
            } else {
                ForEach(service.alarms) { alarm in
                    AlarmRow(alarm: alarm) { enabled in
                        Task { await setEnabled(enabled, for: alarm) }
                    }
                    .listRowBackground(alarm.delivery == .system
                        ? Color.orange.opacity(0.12)
                        : Color.blue.opacity(0.12))
                    .contentShape(Rectangle())
                    .onTapGesture { editingAlarm = alarm }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await delete(alarm) }
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("알람")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !service.alarms.isEmpty {
                    Button(role: .destructive) { showingDeleteAll = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("모든 알람 삭제")
                }
                Button { showingNewAlarm = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("알람 추가")
            }
        }
        .refreshable { await service.refresh() }
        .task { await service.refresh() }
        .sheet(isPresented: $showingNewAlarm) {
            NavigationStack { AlarmEditorView() }
        }
        .sheet(item: $editingAlarm) { alarm in
            NavigationStack { AlarmEditorView(alarm: alarm) }
        }
        .confirmationDialog(
            "모든 JARVIS 알람을 삭제할까요?",
            isPresented: $showingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("모두 삭제", role: .destructive) {
                Task {
                    do { try await service.deleteAll(confirmed: true) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("이전 알람 변경을 취소하고 변경 전 예약으로 복구할까요?", isPresented: $showingRecovery, titleVisibility: .visible) {
            Button("이전 예약 복구") {
                Task { do { try await service.recoverPendingChange(confirmed: true) }
                    catch { errorMessage = error.localizedDescription } }
            }
        } message: { Text(service.pendingRecoveryDescription) }
        .alert("알람 작업 실패", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func setEnabled(_ enabled: Bool, for alarm: JarvisAlarmRecord) async {
        do { try await service.setEnabled(enabled, id: alarm.id, expected: alarm) }
        catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ alarm: JarvisAlarmRecord) async {
        do { try await service.delete(id: alarm.id, expected: alarm) }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct AlarmRow: View {
    let alarm: JarvisAlarmRecord
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(accentColor)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(alarm.date, format: .dateTime.hour().minute())
                    .font(.system(size: 38, weight: .light, design: .rounded))
                    .foregroundStyle(accentColor)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { alarm.isEnabled },
                    set: onToggle
                ))
                .labelsHidden()
            }
            Text(alarm.effectiveLabel)
                .font(.headline)
            Text(alarm.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(deliveryTitle, systemImage: deliveryIcon)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentColor)
                Label(dayDescription, systemImage: "calendar")
                Text("·")
                Text(alarm.backend == .alarmKit ? "AlarmKit" : "로컬 알림")
                Text("· 반복 없음")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var accentColor: Color { alarm.delivery == .system ? .orange : .blue }
    private var deliveryTitle: String {
        alarm.delivery == .system ? "시스템 알람" : "JARVIS TTS"
    }
    private var deliveryIcon: String {
        alarm.delivery == .system ? "alarm.fill" : "waveform"
    }

    private var dayDescription: String {
        if Calendar.current.isDateInToday(alarm.date) { return "오늘" }
        if Calendar.current.isDateInTomorrow(alarm.date) { return "내일" }
        return alarm.date.formatted(.dateTime.month().day())
    }
}

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = AlarmService.shared

    private let alarm: JarvisAlarmRecord?
    @State private var date: Date
    @State private var label: String
    @State private var message: String
    @State private var delivery: AlarmDeliveryMode
    @State private var isSaving = false
    @State private var savingTask: Task<Void, Never>?
    @State private var errorMessage = ""

    init(alarm: JarvisAlarmRecord? = nil) {
        self.alarm = alarm
        let initialDate = alarm?.date
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: Date())
            ?? Date().addingTimeInterval(3_600)
        _date = State(initialValue: initialDate)
        _label = State(initialValue: alarm?.label ?? "")
        _message = State(initialValue: alarm?.message ?? "설정한 알람 시간입니다.")
        _delivery = State(initialValue: alarm?.delivery ?? .system)
    }

    var body: some View {
        Form {
            Section("알람 유형") {
                Picker("알람 유형", selection: $delivery) {
                    Text("시스템 알람").tag(AlarmDeliveryMode.system)
                    Text("JARVIS TTS").tag(AlarmDeliveryMode.jarvisVoice)
                }
                .pickerStyle(.segmented)

                Label(
                    delivery == .system
                        ? "시스템 알람음으로 알립니다."
                        : "시스템 알람음 대신 선택한 JARVIS 음성이 문구를 읽습니다.",
                    systemImage: delivery == .system ? "alarm.fill" : "waveform"
                )
                .font(.footnote)
                .foregroundStyle(delivery == .system ? .orange : .blue)
            }
            Section("알람 시각") {
                DatePicker(
                    "날짜와 시간",
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            Section("알람 내용") {
                TextField("알람 이름", text: $label)
                TextField("울릴 때 표시할 문구", text: $message, axis: .vertical)
                    .lineLimit(2...5)
            }
            Section {
                Text("JARVIS TTS 알림은 문구를 음성 파일로 미리 만들어 재생합니다. iPhone의 무음 모드, 집중 모드 및 알림 설정에 따라 소리가 제한될 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(alarm == nil ? "새 알람" : "알람 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") { savingTask?.cancel(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") { savingTask = Task { await save() } }
                    .disabled(isSaving || date <= Date())
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onDisappear { savingTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in savingTask?.cancel() }
        .alert("알람을 저장하지 못했습니다", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let finalLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let alarm {
                _ = try await service.update(
                    id: alarm.id,
                    date: date,
                    label: finalLabel,
                    message: finalMessage.isEmpty ? "설정한 알람 시간입니다." : finalMessage,
                    delivery: delivery,
                    expected: alarm
                )
            } else {
                _ = try await service.schedule(
                    at: date,
                    label: finalLabel,
                    message: finalMessage.isEmpty ? "설정한 알람 시간입니다." : finalMessage,
                    delivery: delivery
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
