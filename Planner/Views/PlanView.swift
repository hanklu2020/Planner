import SwiftUI

private enum PlanFilter: String, CaseIterable {
    case scheduled = "目前期間", unplanned = "待安排", attention = "待處理", all = "全部"
}

struct PlanView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var anchor = Date()
    @State private var scale: TimeScale = .day
    @State private var filter: PlanFilter = .scheduled
    @State private var domain: Domain?
    @State private var goalID: UUID?
    @State private var search = ""
    @State private var showDone = false
    @State private var selected: Set<UUID> = []
    @State private var selecting = false
    @State private var editing: TaskPresentation?
    @State private var picker: TaskBatch?
    @State private var queue: TaskBatch?
    @State private var dateSheet = false
    @State private var review = false

    private var matching: [PlannerTask] {
        store.data.tasks.filter { task in
            guard domain == nil || task.domain == domain, goalID == nil || task.goalID == goalID else { return false }
            if !search.isEmpty {
                let text = [task.title, task.notes, store.goal(task.goalID)?.title ?? ""] + task.steps.map(\.title)
                guard text.joined(separator: " ").localizedCaseInsensitiveContains(search) else { return false }
            }
            switch filter {
            case .scheduled: return task.schedule?.appears(in: anchor, scale: scale) == true
            case .unplanned: return task.schedule == nil && !task.cancelled
            case .attention: return task.needsAttention()
            case .all: return true
            }
        }.sorted { a, b in
            let af = a.focusDate.map { PlannerDates.calendar.isDate($0, inSameDayAs: anchor) } == true
            let bf = b.focusDate.map { PlannerDates.calendar.isDate($0, inSameDayAs: anchor) } == true
            if af != bf { return af }
            if a.isOverdue() != b.isOverdue() { return a.isOverdue() }
            let ad = a.schedule?.date ?? .distantFuture, bd = b.schedule?.date ?? .distantFuture
            return ad == bd ? a.createdAt < b.createdAt : ad < bd
        }
    }
    private var active: [PlannerTask] { matching.filter(\.isOpen) }
    private var done: [PlannerTask] { matching.filter(\.isDone) }
    private var unplannedCount: Int { store.data.tasks.filter { $0.isOpen && $0.schedule == nil }.count }
    private var attentionCount: Int { store.data.tasks.filter { $0.needsAttention() }.count }
    private var eligibleSelection: [UUID] { store.data.tasks.filter { selected.contains($0.id) && $0.isOpen }.map(\.id) }

    var body: some View {
        let rows = matching
        let active = rows.filter(\.isOpen)
        let done = rows.filter(\.isDone)
        NavigationStack {
            VStack(spacing: 0) {
                dateHeader
                filterHeader
                List {
                    if filter == .scheduled {
                        if scale == .month { MonthGrid(anchor: anchor) { anchor = $0; scale = .day }.listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)) }
                        if scale == .year { yearGrid }
                        if scale == .week { weekStrip }
                    }
                    if active.isEmpty {
                        EmptyMessage(title: filter == .unplanned ? "暫無待安排任務" : "這裡還沒有任務", symbol: "checklist", detail: "點右上角新增，或切換期間與篩選。")
                    }
                    if filter == .scheduled && scale == .week {
                        let loose = active.filter { $0.schedule?.scale == .week }
                        if !loose.isEmpty { Section("本週待排日期") { ForEach(loose) { row($0) } } }
                        ForEach(0..<7) { offset in
                            let date = PlannerDates.shifted(PlannerDates.start(anchor, .week), .day, by: offset)
                            let tasks = active.filter { $0.schedule?.appears(in: date, scale: .day) == true }
                            if !tasks.isEmpty { Section(PlannerDates.text(date, "M/d EEEE")) { ForEach(tasks) { row($0) } } }
                        }
                    } else {
                        Section(filter == .scheduled ? "\(scale == .day ? "當日" : "期間")任務 · \(active.count)" : "\(filter.rawValue) · \(active.count)") {
                            ForEach(active) { row($0) }
                        }
                    }
                    if !done.isEmpty && !selecting {
                        DisclosureGroup("已完成（\(done.count)）", isExpanded: $showDone) { ForEach(done) { TaskRow(task: $0) } }
                    }
                    if filter == .all && !selecting {
                        let cancelled = matching.filter(\.cancelled)
                        if !cancelled.isEmpty { DisclosureGroup("已取消（\(cancelled.count)）") { ForEach(cancelled) { TaskRow(task: $0) } } }
                    }
                    if let id = store.pendingGoalID, let goal = store.goal(id) {
                        Section {
                            Text("「\(goal.title)」的任務已全部完成。").font(.subheadline)
                            Button("確認目標是否達成") { review = true }
                            Button("稍後確認") { store.pendingGoalID = nil }
                        }
                    }
                }
                .listStyle(.insetGrouped).contentMargins(.top, 4)
                .simultaneousGesture(MagnificationGesture().onEnded { factor in
                    let next = scale.rank + (factor < 0.85 ? 1 : factor > 1.15 ? -1 : 0)
                    scale = TimeScale.allCases[min(3, max(0, next))]
                })
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("計畫").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜尋任務、目標或步驟")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "取消選取" : "選取") { selecting.toggle(); selected.removeAll() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("領域", selection: $domain) {
                            Text("全部領域").tag(nil as Domain?)
                            ForEach(Domain.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        Picker("目標", selection: $goalID) {
                            Text("全部目標").tag(nil as UUID?)
                            ForEach(store.data.goals) { Text($0.title).tag(Optional($0.id)) }
                        }
                        Button("回顧目標", systemImage: "arrow.clockwise") { review = true }
                        Button("清除篩選") { domain = nil; goalID = nil; search = ""; filter = .scheduled }
                    } label: { Image(systemName: domain == nil && goalID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") }
                    .accessibilityLabel("篩選與回顧")
                    Button { addTask() } label: { Image(systemName: "plus") }.accessibilityLabel("新增任務")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting {
                    HStack {
                        Menu("已選 \(eligibleSelection.count) 項") {
                            Button("選取目前全部任務") { selected.formUnion(active.map(\.id)) }
                            Button("清除選取") { selected.removeAll() }
                        }
                        Spacer()
                        Button("安排日期") { picker = TaskBatch(taskIDs: eligibleSelection) }.disabled(eligibleSelection.isEmpty)
                        Button("逐項安排") { queue = TaskBatch(taskIDs: eligibleSelection) }.disabled(eligibleSelection.isEmpty)
                    }.font(.subheadline).padding(14).background(.regularMaterial)
                } else if filter == .unplanned && !active.isEmpty {
                    Button("連續安排這 \(active.count) 項任務", systemImage: "calendar.badge.plus") {
                        queue = TaskBatch(taskIDs: active.map(\.id))
                    }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(13).background(.regularMaterial)
                }
            }
            .sheet(item: $editing) { TaskEditor(initial: $0.task) }
            .sheet(item: $picker, onDismiss: { selecting = false; selected.removeAll() }) { SchedulePicker(taskIDs: $0.taskIDs) }
            .sheet(item: $queue, onDismiss: { selecting = false; selected.removeAll() }) { SequentialScheduleView(taskIDs: $0.taskIDs) }
            .sheet(isPresented: $dateSheet) { periodPicker }
            .sheet(isPresented: $review, onDismiss: { store.pendingGoalID = nil }) { ReviewView() }
        }
    }
    private var dateHeader: some View {
        HStack(spacing: 10) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 40) }.accessibilityLabel("上一期間")
            Menu {
                Picker("檢視", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }
                Button("選擇日期") { dateSheet = true }
            } label: {
                HStack(spacing: 5) { Text(PlannerDates.heading(anchor, scale: scale)).font(.subheadline.weight(.semibold)); Text(scale.title).font(.caption).foregroundStyle(.secondary); Image(systemName: "chevron.down").font(.caption2) }
                    .frame(maxWidth: .infinity)
            }.accessibilityLabel("切換日週月年")
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 40) }.accessibilityLabel("下一期間")
            Button("今天") { anchor = Date(); scale = .day; filter = .scheduled }.font(.caption.weight(.semibold)).padding(.trailing, 14)
        }.foregroundStyle(Color.plannerAccent)
    }
    private var filterHeader: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(.scheduled, title: "\(scale.title)安排")
                filterButton(.unplanned, title: "待安排 \(unplannedCount)")
                filterButton(.attention, title: "待處理 \(attentionCount)")
                filterButton(.all, title: "全部")
                if let domain { Text(domain.title).font(.caption).foregroundStyle(domain.color) }
            }.padding(.horizontal, 16).padding(.bottom, 9)
        }
    }
    private func filterButton(_ value: PlanFilter, title: String) -> some View {
        Button { filter = value; selected.removeAll(); selecting = false } label: {
            Text(title).font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(filter == value ? Color.white : .secondary)
                .background(filter == value ? Color.plannerAccent : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }.accessibilityIdentifier("filter_\(value.rawValue)")
    }
    private func row(_ task: PlannerTask) -> some View {
        TaskRow(task: task, selecting: selecting, selected: selected.contains(task.id), onSelect: { toggle(task.id) }, onLongPress: { selecting = true; selected.insert(task.id) })
    }
    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    private func shift(_ value: Int) { anchor = PlannerDates.shifted(anchor, scale, by: value); filter = .scheduled }
    private func addTask() {
        var value = PlannerTask(domain: domain, goalID: goalID)
        if filter == .scheduled { value.schedule = Schedule(anchor, scale: scale) }
        editing = TaskPresentation(task: value)
    }
    private var periodPicker: some View {
        NavigationStack {
            Form {
                Picker("檢視", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                DatePicker("日期", selection: $anchor, displayedComponents: .date).datePickerStyle(.graphical)
            }.navigationTitle("選擇期間").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filter = .scheduled; dateSheet = false } } }
        }.presentationDetents([.medium, .large])
    }
    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<7) { index in
                let date = PlannerDates.shifted(PlannerDates.start(anchor, .week), .day, by: index)
                let count = store.data.tasks.filter { $0.isOpen && $0.schedule?.appears(in: date, scale: .day) == true }.count
                Button { anchor = date; scale = .day } label: {
                    VStack(spacing: 6) { Text(PlannerDates.text(date, "EEEEE")).font(.caption); Text(PlannerDates.text(date, "d")).font(.headline); Text("\(count)").font(.caption2).foregroundStyle(.secondary) }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 7)
    }
    private var yearGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
            ForEach(0..<12) { index in
                let month = PlannerDates.shifted(PlannerDates.start(anchor, .year), .month, by: index)
                let count = store.data.tasks.filter { $0.isOpen && $0.schedule?.appears(in: month, scale: .month) == true }.count
                let goals = store.data.goals.filter { goal in goal.targetDate.map { PlannerDates.calendar.isDate($0, equalTo: month, toGranularity: .month) } == true }.count
                Button { anchor = month; scale = .month } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(index + 1)月").font(.headline)
                        Text("\(count) 項任務").font(.caption).foregroundStyle(.secondary)
                        if goals > 0 { Text("\(goals) 個目標預計達成").font(.caption2) }
                    }.frame(maxWidth: .infinity, minHeight: 75, alignment: .leading).padding(9).background(Color.plannerAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 6)
    }
}

struct MonthGrid: View {
    @EnvironmentObject private var store: PlannerStore
    let anchor: Date
    var select: (Date) -> Void
    private var calendar: Calendar { PlannerDates.calendar }
    private var first: Date { PlannerDates.start(anchor, .month) }
    private var offset: Int { (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7 }
    private var days: Int { calendar.range(of: .day, in: .month, for: first)!.count }
    var body: some View {
        let counts = Dictionary(grouping: store.data.tasks.filter { $0.isOpen && $0.schedule?.scale == .day }, by: { calendar.startOfDay(for: $0.schedule!.date) }).mapValues(\.count)
        let goalDays = Set(store.data.goals.compactMap { $0.targetDate.map { calendar.startOfDay(for: $0) } })
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 5) {
            ForEach(Array(["一", "二", "三", "四", "五", "六", "日"].enumerated()), id: \.offset) { _, day in Text(day).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            ForEach(0..<(offset + days), id: \.self) { index in
                if index < offset { Color.clear.frame(height: 43) }
                else {
                    let date = PlannerDates.shifted(first, .day, by: index - offset)
                    let count = counts[calendar.startOfDay(for: date)] ?? 0
                    let target = goalDays.contains(calendar.startOfDay(for: date))
                    Button { select(date) } label: {
                        VStack(spacing: 3) {
                            Text("\(index - offset + 1)").font(.subheadline.weight(calendar.isDateInToday(date) ? .bold : .regular))
                            HStack(spacing: 2) {
                                if count > 0 { Text("\(count)").font(.system(size: 9)).foregroundStyle(.secondary) }
                                if target { Image(systemName: "scope").font(.system(size: 8)).foregroundStyle(.orange) }
                            }.frame(height: 10)
                        }.frame(maxWidth: .infinity, minHeight: 43)
                            .background(calendar.isDateInToday(date) ? Color.plannerAccent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.borderless).accessibilityLabel("\(PlannerDates.text(date))，\(count)項任務")
                }
            }
        }
    }
}
