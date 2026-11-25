import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var editing: JournalEntry?
    @State private var editingTask: PlanTask?

    private var days: [Date] {
        let calendar = PlannerDates.calendar
        let entries = store.journal.map { calendar.startOfDay(for: $0.date) }
        let completions = store.tasks.filter(\.done).compactMap { $0.completedAt }
            .map { calendar.startOfDay(for: $0) }
        return Array(Set(entries + completions)).sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView(
                        "還沒有日記",
                        systemImage: "book",
                        description: Text("點右上角 ＋ 寫下第一篇。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(days, id: \.self) { day in
                                journalDay(day)
                            }
                        }
                        .padding(16)
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("日記")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = JournalEntry() } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("新增日記")
                }
            }
            .sheet(item: $editing) { JournalEditor(draft: $0) }
            .sheet(item: $editingTask) { TaskEditor(draft: $0) }
        }
    }

    private func journalDay(_ day: Date) -> some View {
        let calendar = PlannerDates.calendar
        let entries = store.journal.filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
        let completed = store.tasks.filter {
            $0.done && calendar.isDate($0.completedAt ?? $0.date, inSameDayAs: day)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(PlannerDates.text(day, "yyyy/M/d（EEE）"))
                .font(.subheadline.bold()).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if !completed.isEmpty {
                DisclosureGroup("完成事項（\(completed.count)）") {
                    TaskGroup(rows: completed, edit: { editingTask = $0 })
                }
                .font(.subheadline)
            }
            ForEach(entries) { entry in
                Button { editing = entry } label: {
                    Text(entry.text)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("點兩下編輯日記")
            }
            Divider()
        }
    }
}
