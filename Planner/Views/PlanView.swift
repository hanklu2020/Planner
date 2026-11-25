import SwiftUI

private enum PlanFilter: String {
    case scheduled = "目前期間", unplanned = "待安排", attention = "待處理", all = "全部"

    var title: String {
        switch self {
        case .scheduled: return "已安排"
        case .all: return "全部任務"
        case .unplanned, .attention: return rawValue
        }
    }
}

private struct PlanScope: Equatable {
    let anchor: Date
    let scale: TimeScale
    let filter: PlanFilter
    let domain: Domain?
    let goalID: UUID?
    let term: String
    let searchesAll: Bool

    func matchesScope(_ task: PlannerTask, goal: Goal?) -> Bool {
        guard goalID == nil || task.goalID == goalID else { return false }
        if let domain { return goal?.domains.contains(domain) ?? (task.domain == domain) }
        return true
    }

    func matchesPeriod(_ task: PlannerTask) -> Bool {
        switch filter {
        case .scheduled: return task.schedule?.appears(in: anchor, scale: scale) == true
        case .unplanned: return task.schedule == nil && !task.cancelled
        case .attention: return task.needsAttention()
        case .all: return true
        }
    }

    var isSearching: Bool { !term.isEmpty }
    var usesCalendar: Bool { filter == .scheduled && !(isSearching && searchesAll) }
}

private struct PlanRows {
    let active: [PlannerTask]
    let done: [PlannerTask]
    let cancelled: [PlannerTask]
    let pendingCount: Int
    let attentionCount: Int

    @MainActor init(store: PlannerStore, scope: PlanScope) {
        let goals = Dictionary(store.data.goals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var matching: [PlannerTask] = []
        var pending = 0, attention = 0
        for task in store.data.tasks {
            let goal = task.goalID.flatMap { goals[$0] }
            let scoped = scope.matchesScope(task, goal: goal)
            if scoped && task.isOpen {
                if task.schedule == nil { pending += 1 }
                if task.needsAttention() { attention += 1 }
            }
            if !(scope.isSearching && scope.searchesAll) {
                guard scoped && scope.matchesPeriod(task) else { continue }
            }
            if scope.isSearching {
                let fields = [task.title, task.notes, goal?.title ?? ""] + task.steps.map(\.title)
                guard fields.joined(separator: " ").localizedCaseInsensitiveContains(scope.term) else { continue }
            }
            matching.append(task)
        }
        matching.sort { a, b in
            let ad = a.schedule?.date ?? .distantFuture, bd = b.schedule?.date ?? .distantFuture
            if ad != bd { return ad < bd }
            if a.schedule?.scale != b.schedule?.scale { return (a.schedule?.scale.rank ?? 4) < (b.schedule?.scale.rank ?? 4) }
            return PlannerStore.planBefore(a, b)
        }
        active = matching.filter(\.isOpen)
        done = matching.filter(\.isDone)
        cancelled = matching.filter(\.cancelled)
        pendingCount = pending
        attentionCount = attention
    }
}

struct PlanView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var anchor = Date()
    @State private var scale: TimeScale = .day
    @State private var filter: PlanFilter = .scheduled
    @State private var domain: Domain?
    @State private var goalID: UUID?
    @State private var search = PlannerSearch()
    @State private var searchesAll = false
    @State private var showDone = false
    @State private var selected: Set<UUID> = []
    @State private var selecting = false
    @State private var editing: TaskPresentation?
    @State private var picker: TaskBatch?
    @State private var queue: TaskBatch?
    @State private var dateSheet = false
    @State private var review = false
    @State private var orderMode: EditMode = .inactive

    private var ordering: Bool { orderMode.isEditing }

    private var scope: PlanScope {
        PlanScope(anchor: anchor, scale: scale, filter: filter, domain: domain, goalID: goalID,
                  term: search.term, searchesAll: searchesAll)
    }

    var body: some View {
        let scope = scope
        let rows = PlanRows(store: store, scope: scope)
        let visibleIDs = rows.active.map(\.id)
        let selectedTasks = visibleIDs.filter { selected.contains($0) }
        NavigationStack {
            VStack(spacing: 0) {
                if search.isVisible {
                    PlannerSearchBar(search: $search, title: "搜尋任務、目標或步驟", identifier: "planSearch", cancel: closeSearch)
                }
                filterHeader(rows)
                activeFilters
                taskList(rows, scope: scope)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    PlannerNotice()
                    if selecting {
                        selectionBar(visible: visibleIDs, selectedTasks: selectedTasks)
                    } else if filter == .unplanned && !rows.active.isEmpty && !ordering && !scope.isSearching {
                        Button("連續安排這 \(rows.active.count) 項任務", systemImage: "calendar.badge.plus") {
                            queue = TaskBatch(taskIDs: visibleIDs)
                        }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(13).background(.regularMaterial)
                    }
                }
            }
            .onChange(of: scope) { _, _ in
                selected.removeAll()
                orderMode = .inactive
                showDone = false
            }
            .onChange(of: rows.active.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .sheet(item: $editing) { TaskEditor(initial: $0.task) }
            .sheet(item: $picker, onDismiss: endSelecting) { SchedulePicker(taskIDs: $0.taskIDs) }
            .sheet(item: $queue, onDismiss: endSelecting) { SequentialScheduleView(taskIDs: $0.taskIDs) }
            .sheet(isPresented: $dateSheet) { periodPicker }
            .sheet(isPresented: $review, onDismiss: { store.pendingGoalID = nil }) { ReviewView() }
        }
    }

    private func taskList(_ rows: PlanRows, scope: PlanScope) -> some View {
        List {
            if scope.usesCalendar && !ordering && !scope.isSearching {
                if scale == .month { MonthGrid(anchor: anchor) { anchor = $0; scale = .day } }
                if scale == .year { yearGrid }
                if scale == .week { weekStrip }
            }
            if rows.active.isEmpty && (selecting || rows.done.isEmpty)
                && (selecting || rows.cancelled.isEmpty || (filter != .all && !scope.isSearching)) {
                emptyState(rows, scope: scope)
            }
            if ordering {
                orderSections(rows.active)
            } else {
                if !rows.active.isEmpty { openSections(rows.active, scope: scope) }
                if !selecting {
                    if !rows.done.isEmpty { completedSection(rows.done, scope: scope) }
                    if !rows.cancelled.isEmpty && (filter == .all || scope.isSearching) {
                        if scope.isSearching { Section("已取消") { ForEach(rows.cancelled) { TaskRow(task: $0) } } }
                        else { DisclosureGroup("已取消 · \(rows.cancelled.count)") { ForEach(rows.cancelled) { TaskRow(task: $0) } } }
                    }
                    if !scope.isSearching, let id = store.pendingGoalID, let goal = store.goal(id) {
                        Section {
                            Text("「\(goal.title)」的任務已全部完成。").font(.subheadline)
                            Button("確認目標是否達成") { review = true }
                            Button("稍後確認") { store.pendingGoalID = nil }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).listSectionSpacing(.compact).contentMargins(.top, 4)
        .environment(\.editMode, $orderMode)
        .modifier(PlannerSearchPull(enabled: !search.isVisible && !ordering && !selecting) {
            withAnimation(.easeOut(duration: 0.2)) { search.reveal(focus: false) }
        })
        .simultaneousGesture(MagnificationGesture().onEnded { factor in
            guard scope.usesCalendar, !ordering, !selecting else { return }
            let next = scale.rank + (factor < 0.85 ? 1 : factor > 1.15 ? -1 : 0)
            scale = TimeScale.allCases[min(3, max(0, next))]
        })
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if scope.usesCalendar { dateHeader }
            else {
                Text(scope.isSearching && searchesAll ? "搜尋全部任務" : filter.title)
                    .font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if ordering {
                Button("完成") { withAnimation { orderMode = .inactive } }
            } else if selecting {
                Button("取消選取", action: endSelecting)
            } else {
                Menu {
                    Button("搜尋", systemImage: "magnifyingglass") {
                        withAnimation(.easeOut(duration: 0.2)) { search.reveal(focus: true) }
                    }
                    Picker("領域", selection: $domain) {
                        Text("全部領域").tag(nil as Domain?)
                        ForEach(Domain.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("目標", selection: $goalID) {
                        Text("全部目標").tag(nil as UUID?)
                        ForEach(store.data.goals) { Text($0.title).tag(Optional($0.id)) }
                    }
                    Button("選取", systemImage: "checkmark.circle") { selecting = true }
                    Button("全部任務", systemImage: "list.bullet") { changeFilter(.all) }
                    Button("回顧目標", systemImage: "arrow.clockwise") { review = true }
                    if domain != nil || goalID != nil || search.isVisible {
                        Button("清除篩選") { domain = nil; goalID = nil; closeSearch() }
                    }
                } label: {
                    Image(systemName: domain == nil && goalID == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }.accessibilityLabel("搜尋、篩選與選取").accessibilityIdentifier("planActions")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { addTask() } label: { Image(systemName: "plus") }
                .accessibilityLabel("新增任務").disabled(ordering || selecting)
        }
    }

    @ViewBuilder private var dateHeader: some View {
        if typeSize.isAccessibilitySize || ordering || selecting {
            dateMenu(includesPaging: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 1) {
                    periodArrow(-1)
                    dateMenu(includesPaging: false).fixedSize()
                    periodArrow(1)
                }.fixedSize()
                dateMenu(includesPaging: true)
            }
        }
    }

    private func periodArrow(_ direction: Int) -> some View {
        Button { shift(direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Color.plannerAccent)
            .accessibilityLabel(direction < 0 ? "上一期間" : "下一期間")
    }

    private func dateMenu(includesPaging: Bool) -> some View {
        Menu {
            Picker("檢視", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }
            Button("選擇日期", systemImage: "calendar") { dateSheet = true }
            if includesPaging {
                Button("上一期間", systemImage: "chevron.left") { shift(-1) }
                Button("下一期間", systemImage: "chevron.right") { shift(1) }
            }
            if !PlannerDates.calendar.isDateInToday(anchor) {
                Button("回到今天") { anchor = Date(); scale = .day }
            }
        } label: {
            HStack(spacing: 5) {
                Text(dateTitle).font(.headline).lineLimit(1).minimumScaleFactor(0.72)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }.foregroundStyle(Color.plannerAccent)
        }.accessibilityLabel("\(dateTitle)，切換期間").disabled(ordering || selecting)
    }

    private var dateTitle: String {
        guard scale == .day else { return PlannerDates.heading(anchor, scale: scale) }
        let weekday = PlannerDates.calendar.component(.weekday, from: anchor)
        return PlannerDates.text(anchor, "M月d日") + "（" + ["日", "一", "二", "三", "四", "五", "六"][weekday - 1] + "）"
    }

    private func filterHeader(_ rows: PlanRows) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                filterButton(.scheduled, title: "已安排")
                filterButton(.unplanned, title: "待安排 \(rows.pendingCount)")
                filterButton(.attention, title: "待處理 \(rows.attentionCount)")
            }.padding(.horizontal, 16).padding(.vertical, 4)
        }.scrollIndicators(.hidden)
    }

    private func filterButton(_ value: PlanFilter, title: String) -> some View {
        let isSelected = filter == value && !(scope.isSearching && searchesAll)
        return Button { changeFilter(value) } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.plannerAccent : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("filter_\(value.rawValue)")
    }

    @ViewBuilder private var activeFilters: some View {
        if domain != nil || goalID != nil {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if let domain { filterChip(domain.title, color: domain.color) { self.domain = nil } }
                    if let goal = store.goal(goalID) { filterChip(goal.title, color: .plannerAccent) { goalID = nil } }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
        }
    }

    private func filterChip(_ title: String, color: Color, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            Label(title, systemImage: "xmark.circle.fill").font(.caption.weight(.medium)).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
        }.buttonStyle(.plain).accessibilityLabel("清除篩選，\(title)")
    }

    @ViewBuilder private func openSections(_ tasks: [PlannerTask], scope: PlanScope) -> some View {
        if scope.usesCalendar && scale == .week {
            let weekly = tasks.filter { $0.schedule?.scale == .week }
            if !weekly.isEmpty { taskSection(weekly, title: "本週待排日期", scope: scope) }
            ForEach(0..<7) { offset in
                let date = PlannerDates.shifted(PlannerDates.start(anchor, .week), .day, by: offset)
                let daily = tasks.filter { $0.schedule?.appears(in: date, scale: .day) == true }
                if !daily.isEmpty { taskSection(daily, title: PlannerDates.text(date, "M/d EEEE"), scope: scope) }
            }
        } else {
            let title = scope.isSearching ? "待辦結果" : scope.usesCalendar ? (scale == .day ? "當日任務" : "期間任務") : filter.title
            taskSection(tasks, title: "\(title) · \(tasks.count)", scope: scope)
        }
    }

    private func taskSection(_ tasks: [PlannerTask], title: String, scope: PlanScope) -> some View {
        let canOrder = Dictionary(grouping: tasks, by: \.schedule).values.contains { $0.count > 1 }
        let style: TaskScheduleDisplay = scope.filter == .attention && !scope.searchesAll ? .attention
            : scope.usesCalendar && scope.scale == .day ? .compact : .standard
        return Section {
            ForEach(tasks) { task in
                TaskRow(task: task, selecting: selecting, selected: selected.contains(task.id),
                        onSelect: { toggle(task.id) }, onLongPress: { selecting = true; selected.insert(task.id) },
                        scheduleDisplay: style)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if canOrder && !selecting {
                    Button("排序") { beginOrdering() }
                        .textCase(nil).font(.subheadline.weight(.medium))
                }
            }
        }
    }

    private func completedSection(_ tasks: [PlannerTask], scope: PlanScope) -> some View {
        Section {
            if !scope.isSearching {
                Button {
                    withAnimation { showDone.toggle() }
                } label: {
                    HStack {
                        Text("已完成 · \(tasks.count)")
                        Spacer()
                        Image(systemName: showDone ? "chevron.up" : "chevron.down")
                    }.font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                     .contentShape(Rectangle())
                }.buttonStyle(.plain).listRowBackground(Color.clear)
            }
            if scope.isSearching || showDone {
                ForEach(tasks) { TaskRow(task: $0) }
            }
        } header: {
            if scope.isSearching { Text("已完成 · \(tasks.count)") }
        }
    }

    private func emptyState(_ rows: PlanRows, scope: PlanScope) -> some View {
        let title: String, action: String, perform: () -> Void
        if scope.isSearching {
            title = "沒有符合的任務"
            if !searchesAll && (filter != .all || domain != nil || goalID != nil) {
                action = "搜尋全部任務"
                perform = { searchesAll = true }
            } else {
                action = "清除搜尋"
                perform = closeSearch
            }
        } else if filter == .attention {
            title = "沒有待處理的任務"
            action = "查看已安排"
            perform = { changeFilter(.scheduled) }
        } else if filter == .scheduled && rows.pendingCount > 0 {
            title = scale == .day ? "這天還沒有安排" : "這段期間還沒有安排"
            action = "從待安排挑任務"
            perform = { changeFilter(.unplanned) }
        } else {
            title = filter == .unplanned ? "暫無待安排任務" : "這裡還沒有任務"
            action = "新增任務"
            perform = addTask
        }
        return ContentUnavailableView {
            Label(title, systemImage: scope.isSearching ? "magnifyingglass" : "checklist")
        } actions: {
            Button(action, action: perform).buttonStyle(.bordered)
        }.listRowBackground(Color.clear)
    }

    private func selectionBar(visible: [UUID], selectedTasks: [UUID]) -> some View {
        HStack(spacing: 14) {
            Menu("已選 \(selectedTasks.count) 項") {
                Button("全選目前 \(visible.count) 項") { selected = Set(visible) }
                Button("清除選取") { selected.removeAll() }.disabled(selectedTasks.isEmpty)
            }
            Spacer(minLength: 0)
            Button("安排日期") { picker = TaskBatch(taskIDs: selectedTasks) }.disabled(selectedTasks.isEmpty)
            Menu("更多") {
                Button("逐項安排") { queue = TaskBatch(taskIDs: selectedTasks) }
            }.disabled(selectedTasks.isEmpty)
        }.font(.subheadline.weight(.medium)).padding(14).background(.regularMaterial)
    }

    private func orderSections(_ tasks: [PlannerTask]) -> some View {
        let groups = Dictionary(grouping: tasks, by: \.schedule)
        var seen: Set<Schedule?> = []
        let schedules = tasks.map(\.schedule).filter { seen.insert($0).inserted }
        return ForEach(schedules, id: \.self) { schedule in
            let group = groups[schedule] ?? []
            Section(schedules.count == 1 && scope.usesCalendar && scale == .day ? "當日任務 · \(group.count)" : schedule?.label ?? "待安排") {
                ForEach(group) { task in
                    Text(task.title).padding(.vertical, 6).moveDisabled(group.count < 2)
                }.onMove { store.movePlanTasks(group, from: $0, to: $1) }
            }
        }
    }

    private func beginOrdering() {
        endSelecting()
        withAnimation { orderMode = .active }
    }

    private func endSelecting() { selecting = false; selected.removeAll() }

    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    private func changeFilter(_ value: PlanFilter) {
        filter = value
        searchesAll = false
    }

    private func closeSearch() {
        searchesAll = false
        withAnimation(.easeOut(duration: 0.2)) { search = PlannerSearch() }
    }

    private func shift(_ value: Int) { anchor = PlannerDates.shifted(anchor, scale, by: value) }

    private func addTask() {
        var value = PlannerTask(domain: domain, goalID: goalID)
        if scope.usesCalendar { value.schedule = Schedule(anchor, scale: scale) }
        editing = TaskPresentation(task: value)
    }

    private var periodPicker: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $anchor, displayedComponents: .date).datePickerStyle(.graphical)
            }.navigationTitle("選擇日期").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dateSheet = false } } }
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
