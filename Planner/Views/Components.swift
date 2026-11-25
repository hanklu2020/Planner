import SwiftUI

private struct PlannerErrorBanner: View {
    @EnvironmentObject private var store: PlannerStore
    var body: some View {
        if let error = store.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(error).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                Button { store.error = nil } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.accessibilityLabel("關閉錯誤提示")
            }.foregroundStyle(.red).padding(12).background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

extension View {
    func plannerErrors() -> some View { safeAreaInset(edge: .top, spacing: 0) { PlannerErrorBanner() } }
}

extension Color {
    static let plannerAccent = Color(red: 0.18, green: 0.43, blue: 0.35)
}
extension Domain {
    var color: Color {
        switch self {
        case .spiritual: return .purple
        case .social: return .pink
        case .physical: return .orange
        case .intellectual: return .blue
        case .family: return .teal
        case .work: return .indigo
        }
    }
}

struct TaskPresentation: Identifiable {
    var id: UUID { task.id }
    var task: PlannerTask
}
struct TaskBatch: Identifiable {
    let id = UUID()
    let taskIDs: [UUID]
}
struct GoalPresentation: Identifiable {
    var id: UUID { goal.id }
    var goal: Goal
}

struct EmptyMessage: View {
    let title: String
    let symbol: String
    let detail: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity).listRowBackground(Color.clear)
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: PlannerStore
    let task: PlannerTask
    var selecting = false
    var selected = false
    var onSelect: (() -> Void)?
    var onLongPress: (() -> Void)?
    @State private var editing: TaskPresentation?
    @State private var scheduling = false
    @State private var expanded = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                Button {
                    if selecting { onSelect?() } else { store.toggleDone(task.id) }
                } label: {
                    Image(systemName: selecting ? (selected ? "checkmark.circle.fill" : "circle") : (task.isDone ? "checkmark.circle.fill" : "circle"))
                        .font(.title3).foregroundStyle(task.cancelled ? Color.secondary : .plannerAccent)
                        .frame(width: 32, height: 40)
                }
                .buttonStyle(.borderless).disabled(task.cancelled && !selecting)
                .accessibilityLabel(selecting ? "選取：\(task.title)" : "完成：\(task.title)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).foregroundStyle(task.cancelled ? .secondary : .primary)
                        .strikethrough(task.isDone || task.cancelled).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        if let domain = task.domain { Text(domain.title).foregroundStyle(domain.color) }
                        if let goal = store.goal(task.goalID) { Text(goal.title).lineLimit(1) }
                        if !task.steps.isEmpty { Text(task.stepProgress).monospacedDigit() }
                        if task.focusDate.map({ PlannerDates.calendar.isDateInToday($0) }) == true && task.isOpen && task.schedule?.appears(in: Date(), scale: .day) == true {
                            Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("今日重點")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let deadline = task.deadline {
                        Text("截止 \(PlannerDates.text(deadline))").font(.caption2)
                            .foregroundStyle(task.isOverdue() ? Color.red : .secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if selecting { onSelect?() } else { editing = TaskPresentation(task: task) } }
                .onLongPressGesture { onLongPress?() }
                if !selecting {
                    if task.isOpen {
                        Button { scheduling = true } label: {
                            Text(task.schedule?.label ?? "待安排").font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .background(Color.plannerAccent.opacity(0.08), in: Capsule())
                        }.buttonStyle(.borderless).accessibilityLabel("安排日期：\(task.title)")
                    }
                    if !task.steps.isEmpty {
                        Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).frame(width: 28, height: 40) }
                            .buttonStyle(.borderless).accessibilityLabel("展開步驟：\(task.title)")
                    }
                }
            }
            if expanded && !selecting {
                ForEach(task.steps) { step in
                    Button { store.toggleStep(task.id, stepID: step.id) } label: {
                        Label(step.title, systemImage: step.done ? "checkmark.square.fill" : "square")
                            .font(.subheadline).foregroundStyle(step.done ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }.buttonStyle(.borderless).disabled(task.cancelled)
                }.padding(.leading, 43)
            }
        }
        .contextMenu {
            if task.isOpen {
                Button("安排日期", systemImage: "calendar") { scheduling = true }
                if let schedule = task.schedule, schedule.scale == .day {
                    Button("切換當日重點", systemImage: "star") { store.toggleFocus(task.id, on: schedule.date) }
                }
            }
            Button("編輯任務", systemImage: "pencil") { editing = TaskPresentation(task: task) }
            Button(role: .destructive) { confirmDelete = true } label: { Label("刪除任務", systemImage: "trash") }
        }
        .swipeActions(allowsFullSwipe: false) {
            if !selecting { Button("刪除", role: .destructive) { confirmDelete = true } }
        }
        .alert("刪除任務？", isPresented: $confirmDelete) {
            Button("刪除任務", role: .destructive) { store.deleteTask(task.id) }
            Button("取消", role: .cancel) { }
        }
        .sheet(item: $editing) { TaskEditor(initial: $0.task) }
        .sheet(isPresented: $scheduling) { SchedulePicker(taskIDs: [task.id]) }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: PlannerTask
    @FocusState private var focusedStep: UUID?
    @State private var confirmDelete = false
    @State private var hasSchedule: Bool
    @State private var hasDeadline: Bool
    @State private var plannedDate: Date
    @State private var scale: TimeScale
    @State private var deadline: Date
    @State private var showHistory = false
    @State private var sortingSteps = false
    private let originalSteps: [Step]
    init(initial: PlannerTask) {
        originalSteps = initial.steps
        _value = State(initialValue: initial)
        _hasSchedule = State(initialValue: initial.schedule != nil)
        _hasDeadline = State(initialValue: initial.deadline != nil)
        _plannedDate = State(initialValue: initial.schedule?.date ?? Date())
        _scale = State(initialValue: initial.schedule?.scale ?? .day)
        _deadline = State(initialValue: initial.deadline ?? Date())
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("任務名稱", text: $value.title).accessibilityIdentifier("taskTitle")
                    TextField("補充說明（選填）", text: $value.notes, axis: .vertical).lineLimit(2...6)
                }
                Section("歸屬") {
                    Picker("目標", selection: $value.goalID) {
                        Text("獨立任務").tag(nil as UUID?)
                        ForEach(store.data.goals.filter { $0.status == .active || $0.id == value.goalID }) { goal in
                            Text("\(goal.domainTitle) · \(goal.title)").tag(Optional(goal.id))
                        }
                    }
                    if let goal = store.goal(value.goalID) { LabeledContent("領域", value: goal.domainTitle) }
                    else {
                        Picker("領域", selection: $value.domain) {
                            Text("未分類").tag(nil as Domain?)
                            ForEach(Domain.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                    }
                }
                Section("日期") {
                    Toggle("安排時間", isOn: $hasSchedule)
                    if hasSchedule {
                        Picker("安排到", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        DatePicker("安排日期", selection: $plannedDate, displayedComponents: .date)
                        if scale != .day { Text("先安排到這\(scale.title)，尚未指定某一天。").font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("設定截止日期", isOn: $hasDeadline)
                    if hasDeadline { DatePicker("截止日期", selection: $deadline, displayedComponents: .date) }
                }
                Section {
                    ForEach($value.steps) { $step in
                        HStack {
                            Button { step.done.toggle() } label: { Image(systemName: step.done ? "checkmark.square.fill" : "square") }.buttonStyle(.borderless)
                            TextField("步驟內容", text: $step.title)
                                .focused($focusedStep, equals: step.id)
                                .onSubmit { focusedStep = nil }
                                .accessibilityIdentifier("stepTitle")
                        }
                    }.onDelete { value.steps.remove(atOffsets: $0) }.onMove { value.steps.move(fromOffsets: $0, toOffset: $1) }
                    Button("新增步驟", systemImage: "plus") {
                        let step = Step(title: "")
                        value.steps.append(step)
                        focusedStep = step.id
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    HStack { Text("步驟"); Spacer(); if value.steps.count > 1 { Button(sortingSteps ? "完成排序" : "排序") { sortingSteps.toggle() }.textCase(nil) } }
                }
                if !store.data.contacts.isEmpty {
                    Section("相關聯絡人") {
                        ForEach(store.data.contacts.filter { !$0.archived || value.contactIDs.contains($0.id) }) { contact in
                            Toggle(contact.name, isOn: Binding(get: { value.contactIDs.contains(contact.id) }, set: { selected in
                                if selected { value.contactIDs.append(contact.id) } else { value.contactIDs.removeAll { $0 == contact.id } }
                            }))
                        }
                    }
                }
                if let completed = value.completedAt { Section { LabeledContent("完成日期", value: PlannerDates.text(completed, "yyyy/M/d HH:mm")) } }
                if !value.planningHistory.isEmpty {
                    Section {
                        DisclosureGroup("安排歷史（\(value.planningHistory.count)）", isExpanded: $showHistory) {
                            ForEach(Array(value.planningHistory.enumerated()), id: \.offset) { _, change in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(change.previous?.label ?? "待安排") → \(change.next?.label ?? "待安排")")
                                    Text(PlannerDates.text(change.at, "M/d HH:mm")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if store.task(value.id) != nil {
                    Section {
                        Button(value.isDone ? "重新開啟任務" : "標記完成") {
                            if save(completing: !value.isDone) { dismiss() }
                        }.disabled(value.cancelled)
                        Button(value.cancelled ? "恢復任務" : "取消任務", role: value.cancelled ? nil : .destructive) {
                            value.cancelled.toggle(); if save() { dismiss() }
                        }
                        Button("刪除任務", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .alert("刪除任務？", isPresented: $confirmDelete) {
                Button("刪除任務", role: .destructive) { store.deleteTask(value.id); dismiss() }
                Button("取消", role: .cancel) { }
            }
            .environment(\.editMode, .constant(sortingSteps ? .active : .inactive))
            .plannerErrors()
            .navigationTitle(store.task(value.id) == nil ? "新增任務" : "編輯任務").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { if save() { dismiss() } }.fontWeight(.semibold)
                        .disabled(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveTask")
                }
            }
        }
    }
    private func save(completing: Bool? = nil) -> Bool {
        value.steps.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        value.schedule = hasSchedule ? Schedule(plannedDate, scale: scale) : nil
        value.deadline = hasDeadline ? PlannerDates.calendar.startOfDay(for: deadline) : nil
        // Editing an unchecked step must reopen a previously completed task.
        if value.steps != originalSteps && !value.steps.isEmpty {
            value.completedAt = value.steps.allSatisfy(\.done) ? (value.completedAt ?? Date()) : nil
        }
        if let completing {
            value.completedAt = completing ? (value.completedAt ?? Date()) : nil
            if completing { for index in value.steps.indices { value.steps[index].done = true } }
        }
        return store.saveTask(value)
    }
}
