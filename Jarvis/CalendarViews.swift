import SwiftUI

struct JarvisCalendarListView: View {
    @ObservedObject private var store = JarvisCalendarStore.shared
    @State private var showingNewEvent = false
    @State private var showingSearch = false
    @State private var showingDeleteAll = false
    @State private var showingDayView = false
    @State private var showingYearPicker = false
    @State private var showingMonthPicker = false
    @State private var errorMessage = ""
    @State private var selectedDate = Date()
    @State private var visibleMonth = Calendar.current.startOfMonth(containing: Date())
    @State private var scrollMonthIndex: Int?
    @State private var draftYear = Calendar.current.component(.year, from: Date())
    @State private var draftMonth = Calendar.current.component(.month, from: Date())
    @ObservedObject private var notificationService = JarvisCalendarNotificationService.shared
    @State private var showingNotificationRepair = false

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        calendarContent
        .navigationTitle("JARVIS 캘린더")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("일정 검색")

                if !store.events.isEmpty {
                    Button(role: .destructive) { showingDeleteAll = true } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("모든 일정 삭제")
                }
                Button { showingNewEvent = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("일정 추가")
            }
        }
        .sheet(isPresented: $showingNewEvent) {
            NavigationStack { JarvisCalendarEditorView(initialDate: selectedDate) }
        }
        .sheet(isPresented: $showingYearPicker) {
            CalendarYearPickerView(year: $draftYear) {
                apply(year: draftYear)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingMonthPicker) {
            CalendarMonthPickerView(month: $draftMonth) {
                apply(month: draftMonth)
            }
            .presentationDetents([.medium])
        }
        .navigationDestination(isPresented: $showingDayView) {
            JarvisCalendarDayView(date: selectedDate)
        }
        .navigationDestination(isPresented: $showingSearch) {
            JarvisCalendarSearchView { date in
                move(to: date)
            }
        }
        .confirmationDialog(
            "모든 JARVIS 일정을 삭제할까요?",
            isPresented: $showingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("모두 삭제", role: .destructive) { deleteAll() }
        } message: {
            Text("삭제한 일정은 복구할 수 없습니다.")
        }
        .alert("캘린더 작업 실패", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog("저장된 일정 기준으로 알림을 다시 예약할까요?", isPresented: $showingNotificationRepair, titleVisibility: .visible) {
            Button("알림 재예약") { Task {
                let result = await CalendarDataExecution.repair(store: store, confirmed: true)
                do { try LocalDataExecution.value(result) } catch { errorMessage = error.localizedDescription }
            } }
        }
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            StorageRecoveryNotice(message: store.storageIssue, canRestore: store.canRestore) {
                try await CalendarDataExecution.restoreStore(store, confirmed: true)
            }
            if let issue = store.notificationIssue ?? notificationService.statusMessage {
                VStack(alignment: .leading) {
                    Text(issue).font(.footnote).foregroundStyle(.orange)
                    if let date = notificationService.coverageEnd {
                        Text("마지막 예약 시각: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    }
                    Button("알림 재예약·상태 확인") { showingNotificationRepair = true }
                }.padding(.horizontal)
            }
            monthNavigation
            weekdayHeader

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(monthIndexRange, id: \.self) { index in
                        monthSection(for: index)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 30)
            }
            .scrollPosition(id: $scrollMonthIndex, anchor: .top)
            .onAppear {
                scrollMonthIndex = monthIndex(for: visibleMonth)
            }
            .onChange(of: scrollMonthIndex) { _, newIndex in
                guard let newIndex, let month = monthDate(for: newIndex) else { return }
                visibleMonth = month
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func monthSection(for index: Int) -> some View {
        let month = monthDate(for: index) ?? visibleMonth
        let year = calendar.component(.year, from: month)
        let monthNumber = calendar.component(.month, from: month)

        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(year)년 \(monthNumber)월")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(monthDates(for: month), id: \.self) { date in
                    MonthDayCell(
                        date: date,
                        displayedMonth: month,
                        selectedDate: selectedDate,
                        events: store.events(on: date),
                        calendar: calendar
                    ) {
                        select(date)
                    }
                }
            }
        }
    }

    private var monthNavigation: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    draftYear = calendar.component(.year, from: visibleMonth)
                    showingYearPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(calendar.component(.year, from: visibleMonth))년")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.28), lineWidth: 1)
                    }
                }
                .accessibilityLabel(Text(verbatim: "연도 선택, 현재 \(calendar.component(.year, from: visibleMonth))년"))
                .accessibilityHint("두 번 눌러 연도 선택기를 엽니다")

                Button {
                    draftMonth = calendar.component(.month, from: visibleMonth)
                    showingMonthPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(calendar.component(.month, from: visibleMonth))월")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.28), lineWidth: 1)
                    }
                }
                .accessibilityLabel(Text(verbatim: "월 선택, 현재 \(calendar.component(.month, from: visibleMonth))월"))
                .accessibilityHint("두 번 눌러 월 선택기를 엽니다")
            }
            .font(.system(size: 23, weight: .bold, design: .rounded))
            .buttonStyle(.plain)

            Spacer()

            Button("오늘") { moveToToday() }
                .lineLimit(1)
                .buttonStyle(.bordered)
                .disabled(
                    calendar.isDateInToday(selectedDate)
                        && calendar.isDate(visibleMonth, equalTo: Date(), toGranularity: .month)
                )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(symbol == weekdaySymbols.first ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var monthIndexRange: ClosedRange<Int> {
        (1900 * 12)...(2100 * 12 + 11)
    }

    private func monthIndex(for date: Date) -> Int {
        let components = calendar.dateComponents([.year, .month], from: date)
        return (components.year ?? 1900) * 12 + (components.month ?? 1) - 1
    }

    private func monthDate(for index: Int) -> Date? {
        let year = index / 12
        let month = index % 12 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    private func monthDates(for month: Date) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let dayRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }
        let weekday = calendar.component(.weekday, from: monthInterval.start)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthInterval.start) else {
            return []
        }
        let occupiedCells = leadingDays + dayRange.count
        let cellCount = Int(ceil(Double(occupiedCells) / 7.0)) * 7
        return (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let offset = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private func select(_ date: Date) {
        selectedDate = date
        if !calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month) {
            move(to: date, updateSelection: false)
        }
        showingDayView = true
    }

    private func move(to date: Date, updateSelection: Bool = true) {
        let month = calendar.startOfMonth(containing: date)
        visibleMonth = month
        if updateSelection {
            selectedDate = date
        }
        withAnimation(.easeInOut) {
            scrollMonthIndex = monthIndex(for: month)
        }
    }

    private func moveToToday() {
        move(to: Date())
    }

    private func apply(year: Int) {
        var components = calendar.dateComponents([.year, .month], from: visibleMonth)
        components.year = year
        guard let date = calendar.date(from: components) else { return }
        move(to: date)
    }

    private func apply(month: Int) {
        var components = calendar.dateComponents([.year, .month], from: visibleMonth)
        components.month = month
        guard let date = calendar.date(from: components) else { return }
        move(to: date)
    }

    private func deleteAll() {
        Task {
            let result = await CalendarDataExecution.deleteAll(store: store, confirmed: true)
            do { try LocalDataExecution.value(result) } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct JarvisCalendarSearchView: View {
    private enum SearchScope: String, CaseIterable, Identifiable {
        case past
        case upcoming

        var id: Self { self }

        var title: String {
            switch self {
            case .past: "지난 일정"
            case .upcoming: "앞으로 있을 일정"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = JarvisCalendarStore.shared
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .upcoming
    @FocusState private var isSearchFieldFocused: Bool
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            searchScopePicker
            Divider()
            searchContent
        }
        .navigationTitle("일정 검색")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("제목, 장소, 메모 검색", text: $searchText)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchScopePicker: some View {
        Picker("일정 분류", selection: $searchScope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var searchContent: some View {
        if trimmedSearchText.isEmpty {
            ContentUnavailableView(
                "일정 검색",
                systemImage: "calendar.badge.magnifyingglass",
                description: Text("일정 제목, 장소 또는 메모를 입력하세요.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEvents.isEmpty {
            ContentUnavailableView.search(text: trimmedSearchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section("검색 결과 \(filteredEvents.count)개") {
                    ForEach(filteredEvents) { event in
                        Button {
                            isSearchFieldFocused = false
                            onSelect(event.startDate)
                            dismiss()
                        } label: {
                            JarvisCalendarRow(event: event)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredEvents: [JarvisCalendarEvent] {
        let now = Date()
        return store.events.filter {
            let matchesQuery = $0.title.localizedCaseInsensitiveContains(trimmedSearchText)
                || $0.location.localizedCaseInsensitiveContains(trimmedSearchText)
                || $0.notes.localizedCaseInsensitiveContains(trimmedSearchText)
            let matchesScope: Bool
            switch searchScope {
            case .past:
                matchesScope = $0.endDate < now
            case .upcoming:
                matchesScope = $0.endDate >= now
            }
            return matchesQuery && matchesScope
        }
        .sorted { $0.startDate < $1.startDate }
    }
}

private struct CalendarYearPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var year: Int
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            Picker("연도", selection: $year) {
                ForEach(1900...2100, id: \.self) { value in
                    Text(verbatim: "\(value)년").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .navigationTitle("연도 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이동") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct CalendarMonthPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var month: Int
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            Picker("월", selection: $month) {
                ForEach(1...12, id: \.self) { value in
                    Text(verbatim: "\(value)월").tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .navigationTitle("월 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이동") {
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct JarvisCalendarDayView: View {
    @State private var errorMessage = ""
    @ObservedObject private var store = JarvisCalendarStore.shared
    @State private var displayedDate: Date
    @State private var showingNewEvent = false
    @State private var newEventStart: Date?
    @State private var editingEvent: JarvisCalendarEvent?
    @State private var deleteCandidate: JarvisCalendarEvent?
    @State private var showingDeleteConfirmation = false

    private let calendar = Calendar.current
    private let hourHeight: CGFloat = 72

    init(date: Date) {
        _displayedDate = State(initialValue: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            if !allDayEvents.isEmpty {
                allDaySection
            }
            timeline
        }
        .navigationTitle("일정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newEventStart = defaultNewEventStart
                    showingNewEvent = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("선택한 날짜에 일정 추가")
            }
        }
        .sheet(isPresented: $showingNewEvent) {
            NavigationStack {
                JarvisCalendarEditorView(
                    initialDate: displayedDate,
                    initialStartDate: newEventStart
                )
            }
        }
        .sheet(item: $editingEvent) { event in
            NavigationStack { JarvisCalendarEditorView(event: event) }
        }
        .confirmationDialog(
            deleteCandidate?.recurrence == JarvisCalendarRecurrence.none
                ? "이 일정을 삭제할까요?"
                : "반복 일정을 모두 삭제할까요?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let deleteCandidate {
                    delete(deleteCandidate)
                }
                deleteCandidate = nil
            }
        } message: {
            Text("삭제한 일정은 복구할 수 없습니다.")
        }
        .alert("일정 변경 실패", isPresented: Binding(get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private var dayHeader: some View {
        VStack(spacing: 12) {
            Text(displayedDate.formatted(.dateTime.year().month().day().weekday(.wide)))
                .font(.headline)

            HStack(spacing: 4) {
                ForEach(weekDates, id: \.self) { date in
                    Button {
                        displayedDate = date
                    } label: {
                        VStack(spacing: 5) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(calendar.component(.day, from: date)))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(dayNumberColor(for: date))
                                .frame(width: 40, height: 40)
                                .background {
                                    if calendar.isDate(date, inSameDayAs: displayedDate) {
                                        Circle().fill(Color.primary)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(date.formatted(.dateTime.month().day().weekday(.wide)))
                    .accessibilityAddTraits(calendar.isDate(date, inSameDayAs: displayedDate) ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(allDayEvents) { event in
                Button {
                    editingEvent = store.event(id: event.id) ?? event
                } label: {
                    HStack(spacing: 8) {
                        Text("하루 종일")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Label(event.title, systemImage: event.isOutdoor ? "cloud.sun" : "calendar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(event.isOutdoor ? Color.blue : Color.indigo)
                            .lineLimit(1)
                        Spacer()
                        if event.recurrence != .none {
                            Image(systemName: "repeat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background((event.isOutdoor ? Color.blue : Color.indigo).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .contextMenu { eventContextMenu(event) }
            }
        }
        .padding(8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Button {
                                newEventStart = date(atHour: hour)
                                showingNewEvent = true
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 54, alignment: .trailing)
                                    Rectangle()
                                        .fill(Color(uiColor: .separator))
                                        .frame(height: 1)
                                        .padding(.top, 7)
                                }
                                .frame(maxWidth: .infinity, minHeight: hourHeight, maxHeight: hourHeight, alignment: .topLeading)
                            }
                            .buttonStyle(.plain)
                            .id(hour)
                            .accessibilityLabel("\(hour)시 일정 추가")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(timedEvents) { event in
                        timelineEvent(event)
                    }

                    if calendar.isDateInToday(displayedDate) {
                        currentTimeIndicator
                    }
                }
                .padding(.horizontal, 8)
            }
            .onAppear { scrollToUsefulHour(using: proxy, animated: false) }
            .onChange(of: displayedDate) { _, _ in
                scrollToUsefulHour(using: proxy, animated: true)
            }
        }
    }

    private func timelineEvent(_ event: JarvisCalendarEvent) -> some View {
        let placement = placementForEvent(event)
        return Button {
            editingEvent = store.event(id: event.id) ?? event
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(event.title)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    if event.isOutdoor {
                        Image(systemName: "cloud.sun")
                            .font(.caption2)
                    }
                    if event.recurrence != .none {
                        Image(systemName: "repeat")
                            .font(.caption2)
                    }
                }
                Text(eventTimeDescription(event))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                if placement.height >= 58, !event.location.isEmpty {
                    Text(event.location)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: placement.height, maxHeight: placement.height, alignment: .topLeading)
            .background(event.isOutdoor ? Color.blue : Color.indigo, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.leading, 66)
        .padding(.trailing, 8)
        .offset(y: placement.offset)
        .contextMenu { eventContextMenu(event) }
        .accessibilityLabel("\(event.title), \(eventTimeDescription(event)), 눌러서 수정")
    }

    @ViewBuilder
    private func eventContextMenu(_ event: JarvisCalendarEvent) -> some View {
        Button {
            editingEvent = store.event(id: event.id) ?? event
        } label: {
            Label("수정", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteCandidate = event
            showingDeleteConfirmation = true
        } label: {
            Label(event.recurrence == .none ? "삭제" : "반복 일정 전체 삭제", systemImage: "trash")
        }
    }

    private var currentTimeIndicator: some View {
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        let minutes = CGFloat((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return HStack(spacing: 0) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 1)
        }
        .padding(.leading, 62)
        .offset(y: minutes / 60 * hourHeight - 4)
        .accessibilityHidden(true)
    }

    private var dayEvents: [JarvisCalendarEvent] {
        store.events(on: displayedDate)
    }

    private var allDayEvents: [JarvisCalendarEvent] {
        dayEvents.filter(\.isAllDay)
    }

    private var timedEvents: [JarvisCalendarEvent] {
        dayEvents.filter { !$0.isAllDay }
    }

    private var weekDates: [Date] {
        let start = calendar.startOfWeek(containing: displayedDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var defaultNewEventStart: Date {
        if calendar.isDateInToday(displayedDate) {
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
            return calendar.date(
                bySettingHour: calendar.component(.hour, from: nextHour),
                minute: 0,
                second: 0,
                of: displayedDate
            ) ?? nextHour
        }
        return date(atHour: 9)
    }

    private func date(atHour hour: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: displayedDate)
            ?? displayedDate
    }

    private func dayNumberColor(for date: Date) -> Color {
        if calendar.isDate(date, inSameDayAs: displayedDate) { return Color(uiColor: .systemBackground) }
        if calendar.isDateInToday(date) { return .red }
        return .primary
    }

    private func eventTimeDescription(_ event: JarvisCalendarEvent) -> String {
        "\(event.startDate.formatted(.dateTime.hour().minute()))–\(event.endDate.formatted(.dateTime.hour().minute()))"
    }

    private func placementForEvent(_ event: JarvisCalendarEvent) -> (offset: CGFloat, height: CGFloat) {
        let dayStart = calendar.startOfDay(for: displayedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        let visibleStart = max(event.startDate, dayStart)
        let visibleEnd = min(event.endDate, dayEnd)
        let startMinutes = CGFloat(max(0, visibleStart.timeIntervalSince(dayStart) / 60))
        let durationMinutes = CGFloat(max(15, visibleEnd.timeIntervalSince(visibleStart) / 60))
        return (startMinutes / 60 * hourHeight, max(34, durationMinutes / 60 * hourHeight))
    }

    private func scrollToUsefulHour(using proxy: ScrollViewProxy, animated: Bool) {
        let hour = calendar.isDateInToday(displayedDate)
            ? max(0, calendar.component(.hour, from: Date()) - 1)
            : 8
        let action = { proxy.scrollTo(hour, anchor: .top) }
        if animated {
            withAnimation(.easeInOut) { action() }
        } else {
            action()
        }
    }

    private func delete(_ event: JarvisCalendarEvent) {
        Task {
            let original = store.event(id: event.id) ?? event
            let result = await CalendarDataExecution.delete(original, store: store, confirmed: true)
            do { try LocalDataExecution.value(result) } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct MonthDayCell: View {
    let date: Date
    let displayedMonth: Date
    let selectedDate: Date
    let events: [JarvisCalendarEvent]
    let calendar: Calendar
    let action: () -> Void

    private var isInDisplayedMonth: Bool {
        calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
    }

    var body: some View {
        Group {
            if isInDisplayedMonth {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(calendar.component(.day, from: date)))
                                .font(.subheadline.weight(calendar.isDateInToday(date) ? .bold : .medium))
                                .foregroundStyle(dayForeground)
                                .frame(width: 28, height: 28)
                                .background {
                                    if calendar.isDateInToday(date) {
                                        Circle().fill(Color.red)
                                    } else if calendar.isDate(date, inSameDayAs: selectedDate) {
                                        Circle().stroke(Color.blue, lineWidth: 2)
                                    }
                                }
                            Spacer(minLength: 0)
                        }

                        ForEach(Array(events.prefix(2))) { event in
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(event.isOutdoor ? Color.blue : Color.indigo)
                                    .frame(width: 4, height: 4)
                                Text(event.title)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.primary)
                        }

                        if events.count > 2 {
                            Text("+\(events.count - 2)개")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(5)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    .background(calendar.isDate(date, inSameDayAs: selectedDate)
                        ? Color.blue.opacity(0.08)
                        : Color(uiColor: .systemBackground))
                }
                .buttonStyle(.plain)
                .overlay {
                    Rectangle()
                        .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityDescription)
            } else {
                Color(uiColor: .systemBackground)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .accessibilityHidden(true)
            }
        }
    }

    private var dayForeground: Color {
        if calendar.isDateInToday(date) { return .white }
        return .primary
    }

    private var accessibilityDescription: String {
        let dateText = date.formatted(.dateTime.year().month().day().weekday(.wide))
        guard !events.isEmpty else { return "\(dateText), 일정 없음" }
        return "\(dateText), 일정 \(events.count)개, \(events.prefix(2).map(\.title).joined(separator: ", "))"
    }
}

private extension Calendar {
    func startOfMonth(containing date: Date) -> Date {
        dateInterval(of: .month, for: date)?.start ?? startOfDay(for: date)
    }

    func startOfWeek(containing date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }
}

private struct JarvisCalendarRow: View {
    let event: JarvisCalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.indigo)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.title)
                    .font(.headline)
                Text(timeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if event.isOutdoor {
                    Label("야외 일정 · 날씨 포함 알림", systemImage: "cloud.sun")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                if event.recurrence != .none {
                    Label(event.recurrence.displayName, systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reminder = event.reminderMinutesBefore {
                    Label(reminder.displayName, systemImage: "bell")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var timeDescription: String {
        let startDate = event.startDate.formatted(.dateTime.year().month().day())
        if event.isAllDay { return "\(startDate) · 하루 종일" }

        let startTime = event.startDate.formatted(.dateTime.hour().minute())
        let endTime = event.endDate.formatted(.dateTime.hour().minute())
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            return "\(startDate) · \(startTime)–\(endTime)"
        }

        let endDate = event.endDate.formatted(.dateTime.year().month().day())
        return "\(startDate) \(startTime)–\(endDate) \(endTime)"
    }
}

struct JarvisCalendarEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = JarvisCalendarStore.shared

    private let event: JarvisCalendarEvent?
    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isAllDay: Bool
    @State private var isOutdoor: Bool
    @State private var location: String
    @State private var notes: String
    @State private var urlString: String
    @State private var recurrence: JarvisCalendarRecurrence
    @State private var reminderMinutesBefore: Int
    @State private var errorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingConflictConfirmation = false
    @State private var conflictMessage = ""
    @State private var isSaving = false
    @State private var savingTask: Task<Void, Never>?

    init(
        event: JarvisCalendarEvent? = nil,
        initialDate: Date? = nil,
        initialStartDate: Date? = nil
    ) {
        self.event = event
        let calendar = Calendar.current
        let defaultStart: Date
        if let event {
            defaultStart = event.startDate
        } else if let initialStartDate {
            defaultStart = initialStartDate
        } else if let initialDate, !calendar.isDateInToday(initialDate) {
            defaultStart = calendar.date(
                bySettingHour: 9,
                minute: 0,
                second: 0,
                of: initialDate
            ) ?? initialDate
        } else {
            defaultStart = calendar.date(byAdding: .hour, value: 1, to: Date())
                ?? Date().addingTimeInterval(3_600)
        }
        let defaultEnd = event?.endDate
            ?? calendar.date(byAdding: .hour, value: 1, to: defaultStart)
            ?? defaultStart.addingTimeInterval(3_600)
        _title = State(initialValue: event?.title ?? "")
        _startDate = State(initialValue: defaultStart)
        _endDate = State(initialValue: defaultEnd)
        _isAllDay = State(initialValue: event?.isAllDay ?? false)
        _isOutdoor = State(initialValue: event?.isOutdoor ?? false)
        _location = State(initialValue: event?.location ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _urlString = State(initialValue: event?.urlString ?? "")
        _recurrence = State(initialValue: event?.recurrence ?? .none)
        _reminderMinutesBefore = State(initialValue: event?.reminderMinutesBefore ?? -1)
    }

    var body: some View {
        Form {
            Section("일정") {
                TextField("제목", text: $title)
                Toggle("하루 종일", isOn: $isAllDay)
                Toggle("야외 일정", isOn: $isOutdoor)
            }
            Section("날짜와 시간") {
                DatePicker(
                    "시작",
                    selection: $startDate,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                DatePicker(
                    "종료",
                    selection: $endDate,
                    in: startDate...,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
            }
            Section("반복과 알림") {
                Picker("반복", selection: $recurrence) {
                    ForEach(JarvisCalendarRecurrence.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                Picker("알림", selection: $reminderMinutesBefore) {
                    ForEach(Self.reminderOptions, id: \.minutes) { option in
                        Text(option.name).tag(option.minutes)
                    }
                }
            }
            Section("추가 정보") {
                TextField("장소", text: $location)
                TextField("URL", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("메모", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
            if event != nil {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label(
                            event?.recurrence == JarvisCalendarRecurrence.none ? "일정 삭제" : "반복 일정 전체 삭제",
                            systemImage: "trash"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            Section {
                Label("선택한 알림 시각에 팝업과 JARVIS 음성으로 알려드립니다.", systemImage: "speaker.wave.2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if isOutdoor {
                    Label("앱이 활성화될 때 받아둔 해당 시각의 날씨 예보를 함께 안내합니다.", systemImage: "cloud.sun")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Label("Apple 캘린더와 동기화되지 않고 JARVIS 앱에만 저장됩니다.", systemImage: "lock.iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onDisappear { savingTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in savingTask?.cancel() }
        .navigationTitle(event == nil ? "새 일정" : "일정 편집")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("취소") { savingTask?.cancel(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") { savingTask = Task { await save() } }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: startDate) { _, newStart in
            if endDate <= newStart {
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: newStart)
                    ?? newStart.addingTimeInterval(3_600)
            }
        }
        .alert("일정을 저장하지 못했습니다", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            event?.recurrence == JarvisCalendarRecurrence.none ? "이 일정을 삭제할까요?" : "반복 일정을 모두 삭제할까요?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                savingTask = Task { await deleteEvent() }
            }
        } message: {
            Text("삭제한 일정은 복구할 수 없습니다.")
        }
        .confirmationDialog("겹치는 일정이 있습니다. 저장할까요?", isPresented: $showingConflictConfirmation, titleVisibility: .visible) {
            Button("겹쳐도 저장") { savingTask = Task { await save(confirmedConflict: true) } }
            Button("취소", role: .cancel) {}
        } message: { Text(conflictMessage) }
    }

    private func save(confirmedConflict: Bool = false) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let finalStart: Date
            let finalEnd: Date
            if isAllDay {
                finalStart = Calendar.current.startOfDay(for: startDate)
                let selectedEnd = Calendar.current.startOfDay(for: endDate)
                finalEnd = Calendar.current.date(
                    byAdding: .day,
                    value: selectedEnd <= finalStart ? 1 : 0,
                    to: selectedEnd <= finalStart ? finalStart : selectedEnd
                ) ?? finalStart.addingTimeInterval(86_400)
            } else {
                finalStart = startDate
                finalEnd = endDate
            }

            let overlaps = store.conflicts(start: finalStart, end: finalEnd, excluding: event?.id)
            if !overlaps.isEmpty, !confirmedConflict {
                conflictMessage = overlaps.prefix(5).map { "\($0.title) · \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n")
                showingConflictConfirmation = true
                return
            }
            let change = CalendarEventChange(id: event?.id, expectedUpdatedAt: event?.updatedAt, title: title,
                start: finalStart, end: finalEnd, outdoor: isOutdoor, conflictIDs: overlaps.map(\.id))
            guard case .allow = SafetyPolicyEngine().evaluate(.calendarWorkflow(.commit(change)), context: .init(
                externalActionsLocked: SafetyControlStore.externalActionsLocked, wasExplicitlyConfirmed: true)) else {
                errorMessage = "안전 잠금으로 일정 변경을 중단했습니다."; return
            }
            if var event {
                event.title = title
                event.startDate = finalStart
                event.endDate = finalEnd
                event.isAllDay = isAllDay
                event.isOutdoor = isOutdoor
                event.location = location
                event.notes = notes
                event.urlString = urlString
                event.recurrence = recurrence
                event.reminderMinutesBefore = normalizedReminder
                let result = await CalendarDataExecution.save(event, store: store,
                    expectedUpdatedAt: self.event?.updatedAt, confirmed: true)
                _ = try LocalDataExecution.value(result)
            } else {
                let created = JarvisCalendarEvent(id: UUID(), title: title, startDate: finalStart,
                    endDate: finalEnd, isAllDay: isAllDay, isOutdoor: isOutdoor, location: location,
                    notes: notes, urlString: urlString, recurrence: recurrence,
                    reminderMinutesBefore: normalizedReminder, createdAt: Date(), updatedAt: Date())
                let result = await CalendarDataExecution.save(created, store: store, expectedUpdatedAt: nil, confirmed: true)
                _ = try LocalDataExecution.value(result)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var normalizedReminder: Int? {
        reminderMinutesBefore < 0 ? nil : reminderMinutesBefore
    }

    private func deleteEvent() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        guard let event else { return }
        let change = CalendarEventChange(id: event.id, expectedUpdatedAt: event.updatedAt, title: event.title,
            start: event.startDate, end: event.endDate, outdoor: event.isOutdoor, deleting: true)
        guard case .allow = SafetyPolicyEngine().evaluate(.calendarWorkflow(.commit(change)), context: .init(
            externalActionsLocked: SafetyControlStore.externalActionsLocked, wasExplicitlyConfirmed: true)) else {
            errorMessage = "안전 잠금으로 일정 삭제를 중단했습니다."; return
        }
        let result = await CalendarDataExecution.delete(event, store: store, confirmed: true)
        do { try LocalDataExecution.value(result); dismiss() } catch { errorMessage = error.localizedDescription }
    }

    private static let reminderOptions: [(name: String, minutes: Int)] = [
        ("없음", -1),
        ("일정 시각", 0),
        ("5분 전", 5),
        ("10분 전", 10),
        ("30분 전", 30),
        ("1시간 전", 60),
        ("1일 전", 1_440)
    ]
}

private extension JarvisCalendarRecurrence {
    var displayName: String {
        switch self {
        case .none: "안 함"
        case .daily: "매일"
        case .weekly: "매주"
        case .monthly: "매월"
        case .yearly: "매년"
        }
    }
}

private extension Int {
    var displayName: String {
        switch self {
        case 0: "일정 시각에 알림"
        case 1..<60: "\(self)분 전 알림"
        case 60: "1시간 전 알림"
        case 1_440: "1일 전 알림"
        default: "\(self)분 전 알림"
        }
    }
}
