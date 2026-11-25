import SwiftUI

private struct DateFrames: PreferenceKey {
    static var defaultValue: [Date: CGRect] = [:]
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct DateTarget: ViewModifier {
    let date: Date
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DateFrames.self,
                    value: [date: proxy.frame(in: .named("plannerCanvas"))]
                )
            }
        }
    }
}

struct PlanView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var scale = PlanScale.day
    @State private var selectedDate = Date()
    @State private var showDates = false
    @State private var editing: PlanTask?
    @State private var dateFrames: [Date: CGRect] = [:]
    @AppStorage("pinchHintSeen") private var pinchHintSeen = false

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !pinchHintSeen {
                            HStack(alignment: .top) {
                                Text("雙指合攏看全局，張開看細節。\n也可以點上方日期切換。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button {
                                    pinchHintSeen = true
                                } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                    .accessibilityLabel("關閉手勢提示")
                            }
                        }
                        switch scale {
                        case .day:
                            dayContent(selectedDate)
                        case .week:
                            goals(.week)
                            weekContent
                        case .month:
                            goals(.month)
                            monthContent
                            dayContent(selectedDate)
                        case .year:
                            goals(.year)
                            yearContent
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
                }
                .coordinateSpace(name: "plannerCanvas")
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(DateFrames.self) { dateFrames = $0 }
                .simultaneousGesture(
                    MagnifyGesture(minimumScaleDelta: 0.08)
                        .onEnded { value in
                            let next = scale.zoomed(by: value.magnification)
                            guard next != scale else { return }
                            let point = CGPoint(
                                x: value.startAnchor.x * viewport.size.width,
                                y: value.startAnchor.y * viewport.size.height
                            )
                            // Smallest hit region wins if a nested date target overlaps.
                            if let hit = dateFrames.filter({ $0.value.contains(point) })
                                .min(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height }) {
                                selectedDate = hit.key
                            }
                            scale = next
                        }
                )
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { showDates = true } label: {
                        HStack(spacing: 5) {
                            Text(PlannerDates.title(for: scale, at: selectedDate))
                                .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                            Text("· \(scale.title)").font(.subheadline)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("選擇日期與期間，目前\(scale.title)視圖")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = PlanTask(date: selectedDate, scale: scale) } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("新增\(scale.noun)")
                }
            }
            .sheet(isPresented: $showDates) {
                DatePanel(date: $selectedDate, scale: $scale)
            }
            .sheet(item: $editing) { TaskEditor(draft: $0) }
        }
    }

    @ViewBuilder
    private func goals(_ period: PlanScale) -> some View {
        let rows = store.tasks(in: period, at: selectedDate)
        TaskGroup(
            title: "本\(period.title)目標",
            rows: rows,
            empty: "尚未安排目標",
            edit: { editing = $0 }
        )
    }

    @ViewBuilder
    private func dayContent(_ date: Date) -> some View {
        let rows = store.tasks(in: .day, at: date)
        let pending = rows.filter { !$0.done }
        let priority = pending.filter(\.isPriority)
        let ordinary = pending.filter { !$0.isPriority }
        VStack(alignment: .leading, spacing: 16) {
            if !priority.isEmpty {
                TaskGroup(title: "今日重點 \(priority.count)/3", rows: priority, edit: { editing = $0 })
            }
            TaskGroup(
                title: scale == .month ? PlannerDates.text(date, "M/d（EEE）") : "任務",
                rows: ordinary,
                empty: priority.isEmpty ? "沒有待辦，點右上角 ＋ 新增。" : nil,
                edit: { editing = $0 }
            )
            if rows.contains(where: \.done) {
                DisclosureGroup("已完成（\(rows.filter(\.done).count)）") {
                    TaskGroup(rows: rows.filter(\.done), edit: { editing = $0 })
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .modifier(DateTarget(date: date))
    }

    private var weekContent: some View {
        ForEach(PlannerDates.days(of: .week, at: selectedDate), id: \.self) { day in
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    selectedDate = day
                    scale = .day
                } label: {
                    HStack {
                        Text(PlannerDates.text(day, "EEE M/d")).font(.subheadline.bold())
                        if PlannerDates.calendar.isDateInToday(day) {
                            Text("今天").font(.caption).foregroundStyle(Color.accentColor)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .frame(minHeight: 44)
                }
                .foregroundStyle(.primary)
                TaskGroup(rows: store.tasks(in: .day, at: day), edit: { editing = $0 })
            }
            .modifier(DateTarget(date: day))
            Divider()
        }
    }

    private var monthContent: some View {
        let cells = PlannerDates.monthCells(at: selectedDate)
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(cells.indices, id: \.self) { index in
                    if let day = cells[index] {
                        monthDay(day)
                    } else {
                        Color.clear.frame(minHeight: 48).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func monthDay(_ day: Date) -> some View {
        let selected = PlannerDates.calendar.isDate(day, inSameDayAs: selectedDate)
        let today = PlannerDates.calendar.isDateInToday(day)
        let count = store.tasks(in: .day, at: day).filter { !$0.done }.count
        return Button { selectedDate = day } label: {
            VStack(spacing: 2) {
                Text(PlannerDates.text(day, "d"))
                    .font(.body.weight(selected || today ? .bold : .regular))
                Text(count == 0 ? " " : "\(count) 件")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if today && !selected {
                    RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DateTarget(date: day))
        .accessibilityLabel("\(PlannerDates.text(day, "M月d日"))，\(count) 件待辦\(today ? "，今天" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var yearContent: some View {
        let first = PlannerDates.start(of: .year, at: selectedDate)
        return VStack(spacing: 0) {
            ForEach(0..<12, id: \.self) { offset in
                let month = PlannerDates.adding(offset, .month, to: first)
                let goals = store.tasks(in: .month, at: month)
                let pending = store.tasks.filter {
                    $0.scale == .day && !$0.done && PlannerDates.contains($0.date, in: .month, at: month)
                }.count
                Button {
                    selectedDate = month
                    scale = .month
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(PlannerDates.text(month, "M 月"))
                            .font(.body.bold()).frame(minWidth: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            if !goals.isEmpty {
                                Text(goals.prefix(2).map(\.text).joined(separator: "、")).lineLimit(2)
                            }
                            Text("\(goals.count) 個目標 · \(pending) 件待辦")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DateTarget(date: month))
                Divider()
            }
        }
    }
}

struct TaskGroup: View {
    var title: String? = nil
    let rows: [PlanTask]
    var empty: String? = nil
    let edit: (PlanTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            if rows.isEmpty, let empty {
                Text(empty).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(rows) { task in
                TaskRow(task: task, edit: { edit(task) })
                Divider()
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: PlannerStore
    let task: PlanTask
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { store.toggle(task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(task.done ? "標為未完成：\(task.text)" : "完成：\(task.text)")
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(task.text).strikethrough(task.done)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if task.isPriority {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                                .accessibilityLabel("今日重點")
                        }
                    }
                    let names = store.contactNames(for: task)
                    if !names.isEmpty {
                        Text(names).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DatePanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var date: Date
    @Binding var scale: PlanScale

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("時間尺度", selection: $scale) {
                        ForEach(PlanScale.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("選擇日期", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, PlannerDates.calendar)
                }
                Section {
                    Button("回到今天") {
                        date = Date()
                        dismiss()
                    }
                }
            }
            .navigationTitle("日期與期間")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
