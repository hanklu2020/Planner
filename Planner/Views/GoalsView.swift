import SwiftUI

struct GoalsView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var settings = false
    @State private var review = false
    @State private var newGoal = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("讓重要的事，\n有下一步。").font(.system(size: 29, weight: .semibold, design: .rounded))
                        Text("從一個領域開始，慢慢推進。").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(Domain.allCases) { domain in
                            NavigationLink { DomainGoalsView(domain: domain) } label: {
                                VStack(alignment: .leading, spacing: 18) {
                                    Image(systemName: domain.symbol).font(.title2).foregroundStyle(domain.color)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(domain.title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                        Text("\(store.data.goals.filter { $0.domain == domain && $0.status == .active }.count) 個進行中")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(18)
                                .background(domain.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain).accessibilityIdentifier("domain_\(domain.rawValue)")
                        }
                    }
                    let stalled = store.data.goals.filter { $0.status == .active && store.nextTask(for: $0.id)?.schedule == nil }
                    if !stalled.isEmpty {
                        Button { review = true } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("\(stalled.count) 個目標尚未安排下一步")
                                Spacer(); Image(systemName: "chevron.right")
                            }.font(.subheadline).padding(15).background(.background, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18).padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("目標").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("設定與備份") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { review = true } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("回顧目標")
                    Button { newGoal = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增目標")
                }
            }
            .sheet(isPresented: $settings) { SettingsView() }
            .sheet(isPresented: $review) { ReviewView() }
            .sheet(isPresented: $newGoal) { GoalEditor(initial: Goal()) }
        }
    }
}

struct DomainGoalsView: View {
    @EnvironmentObject private var store: PlannerStore
    let domain: Domain
    @State private var newGoal = false
    @State private var showPast = false
    private var active: [Goal] { store.data.goals.filter { $0.domain == domain && $0.status == .active } }
    private var past: [Goal] { store.data.goals.filter { $0.domain == domain && $0.status != .active } }
    var body: some View {
        List {
            if active.isEmpty { EmptyMessage(title: "從一個目標開始", symbol: domain.symbol, detail: "想在\(domain.title)方面達成什麼？點右上角新增。") }
            ForEach(active) { goal in goalRow(goal) }
            if !past.isEmpty {
                DisclosureGroup("已暫停與已結束（\(past.count)）", isExpanded: $showPast) {
                    ForEach(past) { goal in goalRow(goal) }
                }
            }
        }.listStyle(.insetGrouped)
        .navigationTitle(domain.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { newGoal = true } label: { Image(systemName: "plus") }.accessibilityLabel("新增目標") }
        .sheet(isPresented: $newGoal) { GoalEditor(initial: Goal(domain: domain)) }
    }
    private func goalRow(_ goal: Goal) -> some View {
        NavigationLink { GoalDetailView(goalID: goal.id) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(goal.title).font(.headline); Spacer(); if goal.status != .active { Text(goal.status.title).font(.caption).foregroundStyle(.secondary) } }
                Text(store.progress(for: goal.id)).font(.caption).foregroundStyle(.secondary)
                if let next = store.nextTask(for: goal.id) {
                    Text("下一步：\(next.title) · \(next.schedule?.label ?? "待安排")").font(.caption).foregroundStyle(domain.color).lineLimit(2)
                } else if goal.status == .active { Text("尚無下一步，或等待確認達成").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical, 5)
        }
    }
}

struct GoalEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: Goal
    @State private var hasDate: Bool
    @State private var target: Date
    init(initial: Goal) {
        _value = State(initialValue: initial)
        _hasDate = State(initialValue: initial.targetDate != nil)
        _target = State(initialValue: initial.targetDate ?? Date())
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("想達成什麼？", text: $value.title).accessibilityIdentifier("goalTitle")
                    Picker("領域", selection: $value.domain) { ForEach(Domain.allCases) { Text($0.title).tag($0) } }
                }
                Section {
                    TextField("怎樣才算達成？（可稍後補上）", text: $value.criteria, axis: .vertical).lineLimit(2...5).accessibilityIdentifier("goalCriteria")
                } header: { Text("達成條件") } footer: { Text("例如：不看稿，用日文介紹姓名、工作與興趣一分鐘。") }
                Section {
                    Toggle("設定預計達成日", isOn: $hasDate)
                    if hasDate { DatePicker("預計達成日", selection: $target, displayedComponents: .date) }
                }
                if store.goal(value.id) != nil {
                    Section { Picker("狀態", selection: $value.status) { ForEach(GoalStatus.allCases) { Text($0.title).tag($0) } } }
                }
            }
            .plannerErrors()
            .navigationTitle(store.goal(value.id) == nil ? "新增目標" : "編輯目標").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        value.targetDate = hasDate ? PlannerDates.calendar.startOfDay(for: target) : nil
                        if store.saveGoal(value) { dismiss() }
                    }.disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveGoal")
                }
            }
        }
    }
}

struct GoalDetailView: View {
    @EnvironmentObject private var store: PlannerStore
    let goalID: UUID
    @State private var editGoal = false
    @State private var editingTask: TaskPresentation?
    @State private var showDone = false
    @State private var review = false
    @State private var taskOrder: EditMode = .inactive
    var body: some View {
        if let goal = store.goal(goalID) {
            List {
                Section {
                    Text(goal.title).font(.title2.weight(.semibold))
                    Label(goal.domain.title, systemImage: goal.domain.symbol).font(.caption).foregroundStyle(goal.domain.color)
                    LabeledContent("狀態", value: goal.status.title)
                    if let date = goal.targetDate { LabeledContent("預計達成日", value: PlannerDates.text(date, "yyyy/M/d")) }
                }
                Section("達成條件") { Text(goal.criteria.isEmpty ? "尚未填寫，點右上角編輯。" : goal.criteria).foregroundStyle(goal.criteria.isEmpty ? .secondary : .primary) }
                Section {
                    Text(store.progress(for: goalID)).font(.subheadline)
                    ForEach(store.tasks(for: goalID).filter(\.isOpen)) { TaskRow(task: $0) }
                        .onMove { store.moveTasks(for: goalID, from: $0, to: $1) }
                    Button("加入任務", systemImage: "plus") { addTask(goal) }.accessibilityIdentifier("addGoalTask")
                } header: { Text("下一步與任務") }
                let done = store.tasks(for: goalID).filter(\.isDone)
                if !done.isEmpty && store.tasks(for: goalID).allSatisfy(\.isDone) && goal.status == .active {
                    Section {
                        Text("任務已全部完成，目標是否達成？").font(.subheadline)
                        Button("確認達成") { _ = store.review(goalID, decision: "確認達成", note: "", status: .achieved); store.pendingGoalID = nil }
                        Button("新增下一步") { addTask(goal) }
                    }
                }
                if !done.isEmpty {
                    DisclosureGroup("已完成（\(done.count)）", isExpanded: $showDone) { ForEach(done) { TaskRow(task: $0) } }
                }
                let cancelled = store.data.tasks.filter { $0.goalID == goalID && $0.cancelled }
                if !cancelled.isEmpty { DisclosureGroup("已取消（\(cancelled.count)）") { ForEach(cancelled) { TaskRow(task: $0) } } }
                Section { Button("回顧並決定下一步", systemImage: "arrow.clockwise") { review = true } }
                let reviews = store.data.reviews.filter { $0.goalID == goalID }.sorted { $0.date > $1.date }
                if !reviews.isEmpty {
                    Section("回顧紀錄") {
                        ForEach(reviews) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.decision).font(.subheadline.weight(.medium))
                                if !entry.note.isEmpty { Text(entry.note).font(.subheadline) }
                                Text(PlannerDates.text(entry.date, "yyyy/M/d")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $taskOrder)
            .navigationTitle("目標內容").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Button("編輯目標") { editGoal = true }
                    Button(taskOrder == .active ? "完成排序" : "調整任務順序") { taskOrder = taskOrder == .active ? .inactive : .active }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("目標選項")
            }
            .sheet(isPresented: $editGoal) { GoalEditor(initial: goal) }
            .sheet(item: $editingTask) { TaskEditor(initial: $0.task) }
            .sheet(isPresented: $review) { ReviewView(onlyGoalID: goalID) }
        } else { ContentUnavailableView("找不到目標", systemImage: "scope") }
    }
    private func addTask(_ goal: Goal) { editingTask = TaskPresentation(task: PlannerTask(domain: goal.domain, goalID: goal.id)) }
}

struct ReviewView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    var onlyGoalID: UUID?
    @State private var notes: [UUID: String] = [:]
    @State private var reviewed: Set<UUID> = []
    @State private var editingTask: TaskPresentation?
    @State private var scheduleBatch: TaskBatch?
    @State private var editingGoal: GoalPresentation?
    private var goals: [Goal] {
        store.data.goals.filter { goal in
            if let onlyGoalID { return goal.id == onlyGoalID }
            return goal.status == .active
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Text("看看成果與阻礙，再決定下一步。心得可以留白。").font(.subheadline).foregroundStyle(.secondary) }
                if goals.isEmpty { EmptyMessage(title: "目前沒有需要回顧的目標", symbol: "checkmark.circle", detail: "建立目標後，可以在這裡安排下一步。") }
                ForEach(goals) { goal in
                    Section {
                        Text(goal.title).font(.headline)
                        if !goal.criteria.isEmpty { Text("達成條件：\(goal.criteria)").font(.subheadline) }
                        Text(store.progress(for: goal.id)).font(.caption).foregroundStyle(.secondary)
                        let tasks = store.tasks(for: goal.id).filter(\.isOpen)
                        if tasks.isEmpty { Label("尚無下一步，請確認達成或加入任務", systemImage: "arrow.right.circle").font(.caption) }
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                TaskRow(task: task)
                                if task.planningHistory.count >= 3 { Text("已調整過多次安排，可以考慮拆小或換方法。").font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        TextField("成果或阻礙（選填）", text: Binding(get: { notes[goal.id] ?? "" }, set: { notes[goal.id] = $0 }), axis: .vertical)
                        if reviewed.contains(goal.id) { Label("已記錄這次決定", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.plannerAccent) }
                        Button("新增下一步", systemImage: "plus") {
                            editingTask = TaskPresentation(task: PlannerTask(domain: goal.domain, goalID: goal.id))
                        }
                        if !tasks.isEmpty {
                            Button("安排現有任務", systemImage: "calendar") { scheduleBatch = TaskBatch(taskIDs: tasks.map(\.id)) }
                        }
                        Menu("記錄決定") {
                            Button("繼續推進") { decide(goal, "繼續推進") }
                            Button("已達成") { decide(goal, "確認達成", status: .achieved) }
                            Button("暫停目標") { decide(goal, "暫停目標", status: .paused) }
                            Button("結束目標") { decide(goal, "結束目標", status: .ended) }
                        }
                        Button("修正目標與達成條件") { editingGoal = GoalPresentation(goal: goal) }
                    } header: { Text(goal.domain.title) }
                }
            }
            .plannerErrors()
            .navigationTitle("回顧").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $editingTask) { TaskEditor(initial: $0.task) }
            .sheet(item: $scheduleBatch) { SchedulePicker(taskIDs: $0.taskIDs) }
            .sheet(item: $editingGoal) { GoalEditor(initial: $0.goal) }
        }
    }
    private func decide(_ goal: Goal, _ decision: String, status: GoalStatus? = nil) {
        if store.review(goal.id, decision: decision, note: notes[goal.id] ?? "", status: status) { reviewed.insert(goal.id) }
    }
}
