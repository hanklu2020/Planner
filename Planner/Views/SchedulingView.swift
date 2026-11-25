import SwiftUI

struct SchedulePicker: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let taskIDs: [UUID]
    @State private var date = Date()
    @State private var scale: TimeScale = .day
    var body: some View {
        NavigationStack {
            Form {
                Section("快速安排") {
                    HStack {
                        shortcut("今天", date: Date(), scale: .day)
                        Spacer()
                        shortcut("明天", date: PlannerDates.shifted(Date(), .day, by: 1), scale: .day)
                        Spacer()
                        shortcut("本週", date: Date(), scale: .week)
                        Spacer()
                        shortcut("下週", date: PlannerDates.shifted(Date(), .week, by: 1), scale: .week)
                    }.padding(.vertical, 6)
                }
                Section("選擇時間") {
                    Picker("安排到", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    DatePicker("安排日期", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                    if scale != .day { Text("將放入這\(scale.title)的待排日期，不會自動指定某一天。").font(.caption).foregroundStyle(.secondary) }
                }
                if scale == .day { DayLoadView(date: date, excluding: Set(taskIDs)) }
                Section {
                    Button("安排至 \(Schedule(date, scale: scale).label)") { apply(Schedule(date, scale: scale)) }
                        .fontWeight(.semibold).accessibilityIdentifier("applySchedule")
                    Button("放回待安排") { apply(nil) }
                }
            }
            .plannerErrors()
            .navigationTitle("安排日期 · \(taskIDs.count) 項").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func shortcut(_ title: String, date: Date, scale: TimeScale) -> some View {
        Button(title) { apply(Schedule(date, scale: scale)) }.buttonStyle(.borderless).accessibilityIdentifier("schedule_\(title)")
    }
    private func apply(_ schedule: Schedule?) { if store.schedule(taskIDs, to: schedule) { dismiss() } }
}

struct DayLoadView: View {
    @EnvironmentObject private var store: PlannerStore
    let date: Date
    var excluding: Set<UUID> = []
    private var tasks: [PlannerTask] {
        store.data.tasks.filter { $0.isOpen && !excluding.contains($0.id) && $0.schedule?.appears(in: date, scale: .day) == true }
    }
    var body: some View {
        Section("\(PlannerDates.text(date)) 已有 \(tasks.count) 項任務") {
            if tasks.isEmpty { Text("目前沒有其他安排").font(.caption).foregroundStyle(.secondary) }
            ForEach(tasks) { task in
                HStack {
                    Text(task.title).font(.subheadline)
                    Spacer()
                    if let deadline = task.deadline { Text("截止 \(PlannerDates.text(deadline))").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

private struct QueueChange {
    let id: UUID
    let previous: Schedule?
    let skipped: Bool
}

struct SequentialScheduleView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let taskIDs: [UUID]
    @State private var index = 0
    @State private var history: [QueueChange] = []
    @State private var week = PlannerDates.start(Date(), .week)
    @State private var date = Date()
    @State private var scale: TimeScale = .day
    private var current: PlannerTask? { index < taskIDs.count ? store.task(taskIDs[index]) : nil }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProgressView(value: Double(index), total: Double(max(1, taskIDs.count)))
                    Text("已處理 \(index)/\(taskIDs.count) 項").font(.caption).foregroundStyle(.secondary)
                }
                if let task = current {
                    Section {
                        Text(task.title).font(.title3.weight(.semibold))
                        if let domain = task.domain { Label(domain.title, systemImage: domain.symbol).font(.caption).foregroundStyle(domain.color) }
                        if let goal = store.goal(task.goalID) { Text(goal.title).font(.subheadline).foregroundStyle(.secondary) }
                        if let deadline = task.deadline { Text("截止 \(PlannerDates.text(deadline, "yyyy/M/d"))").font(.caption).foregroundStyle(task.isOverdue() ? Color.red : .secondary) }
                        Text("目前：\(task.schedule?.label ?? "待安排")").font(.caption).foregroundStyle(.secondary)
                    } header: { Text("正在安排") }
                    Section {
                        HStack {
                            Button("今天") { apply(Schedule(Date())) }
                            Spacer(); Button("明天") { apply(Schedule(PlannerDates.shifted(Date(), .day, by: 1))) }
                            Spacer(); Button("本週") { apply(Schedule(Date(), scale: .week)) }
                            Spacer(); Button("下週") { apply(Schedule(PlannerDates.shifted(Date(), .week, by: 1), scale: .week)) }
                        }.buttonStyle(.borderless).padding(.vertical, 7)
                        HStack {
                            Button { week = PlannerDates.shifted(week, .week, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 36) }.accessibilityLabel("上一週")
                            Spacer(); Text(PlannerDates.heading(week, scale: .week)).font(.subheadline); Spacer()
                            Button { week = PlannerDates.shifted(week, .week, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 36) }.accessibilityLabel("下一週")
                        }.buttonStyle(.borderless)
                        HStack(spacing: 2) {
                            ForEach(0..<7) { offset in
                                let day = PlannerDates.shifted(week, .day, by: offset)
                                let count = store.data.tasks.filter { $0.isOpen && $0.id != task.id && $0.schedule?.appears(in: day, scale: .day) == true }.count
                                Button { apply(Schedule(day)) } label: {
                                    VStack(spacing: 8) {
                                        Text(PlannerDates.text(day, "EEEEE")).font(.caption)
                                        Text(PlannerDates.text(day, "d")).font(.headline)
                                        Text("\(count)項").font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                }.buttonStyle(.borderless)
                            }
                        }
                        Picker("其他時間", selection: $scale) { ForEach(TimeScale.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        DatePicker("選擇日期", selection: $date, displayedComponents: .date)
                        Button("安排至 \(Schedule(date, scale: scale).label)，繼續下一項") { apply(Schedule(date, scale: scale)) }
                        Button("略過這項") { history.append(QueueChange(id: task.id, previous: task.schedule, skipped: true)); index += 1 }
                    } header: { Text("點日期即安排，並接著處理下一項") }
                    if scale == .day { DayLoadView(date: date, excluding: [task.id]) }
                } else {
                    Section { EmptyMessage(title: "這一輪安排完成", symbol: "checkmark.circle", detail: "略過的項目會保留原本安排。") }
                }
                if !history.isEmpty { Section { Button("復原上一項") { undo() } } }
            }
            .plannerErrors()
            .navigationTitle("連續安排").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.clearUndo(); dismiss() } } }
        }
    }
    private func apply(_ schedule: Schedule?) {
        guard let task = current, store.schedule([task.id], to: schedule) else { return }
        history.append(QueueChange(id: task.id, previous: task.schedule, skipped: false))
        store.notice = nil; store.clearUndo(); index += 1
    }
    private func undo() {
        guard let last = history.last else { return }
        if last.skipped || store.schedule([last.id], to: last.previous) {
            history.removeLast(); index = max(0, index - 1); store.notice = nil; store.clearUndo()
        }
    }
}
