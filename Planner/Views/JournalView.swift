import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var visibleDays = 30
    @State private var editing: JournalEntry?
    @State private var search = ""
    @State private var scrolledToLatest = false
    private var cutoff: Date { PlannerDates.shifted(PlannerDates.calendar.startOfDay(for: Date()), .day, by: -visibleDays) }
    private var entries: [JournalEntry] { store.data.journal.filter { $0.date >= cutoff && (search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)) } }
    private var tasks: [CompletionRecord] { store.data.completions.filter { $0.date >= cutoff && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) } }
    private var days: [Date] { Set(entries.map { PlannerDates.calendar.startOfDay(for: $0.date) } + tasks.map { PlannerDates.calendar.startOfDay(for: $0.date) }).sorted() }
    private var hasEarlier: Bool { store.data.journal.contains { $0.date < cutoff } || store.data.completions.contains { $0.date < cutoff } }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if hasEarlier {
                        Button("載入更早的紀錄") { visibleDays += 90 }
                            .onAppear { if scrolledToLatest { visibleDays += 90 } }
                    }
                    if days.isEmpty { EmptyMessage(title: "留下今天的一點記錄", symbol: "book.closed", detail: "可以寫日記；完成的任務也會出現在這裡。") }
                    ForEach(days, id: \.self) { day in
                        Section(PlannerDates.text(day, "yyyy年 M月d日 EEEE")) {
                            ForEach(entries.filter { PlannerDates.calendar.isDate($0.date, inSameDayAs: day) }.sorted { $0.date < $1.date }) { entry in
                                Button { editing = entry } label: {
                                    Text(entry.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }.buttonStyle(.plain)
                                .swipeActions { Button("刪除", role: .destructive) { _ = store.commit { $0.journal.removeAll { $0.id == entry.id } } } }
                            }
                            let finished = tasks.filter { PlannerDates.calendar.isDate($0.date, inSameDayAs: day) }
                            if !finished.isEmpty {
                                DisclosureGroup("\(isRecent(day) ? "最近完成" : "完成紀錄") · \(finished.count) 項") {
                                    ForEach(finished) { CompletionRow(record: $0) }
                                }
                            }
                        }.id(day)
                    }
                    Color.clear.frame(height: 1).listRowBackground(Color.clear).id("latest")
                }.listStyle(.insetGrouped)
                    .onAppear {
                        proxy.scrollTo("latest", anchor: .bottom)
                        DispatchQueue.main.async { scrolledToLatest = true }
                    }
            }
            .navigationTitle("日記").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜尋日記與完成任務")
            .toolbar { Button { editing = JournalEntry() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("寫日記") }
            .sheet(item: $editing) { JournalEditor(initial: $0) }
        }
    }
    private func isRecent(_ date: Date) -> Bool { date >= PlannerDates.shifted(PlannerDates.calendar.startOfDay(for: Date()), .day, by: -1) }
}

struct JournalEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: JournalEntry
    init(initial: JournalEntry) { _value = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $value.date, displayedComponents: .date)
                Picker("內容語言", selection: $value.language) { Text("中文").tag("zh"); Text("English").tag("en") }
                Section { TextEditor(text: $value.text).frame(minHeight: 250).accessibilityIdentifier("journalText") }
            }
            .plannerErrors()
            .navigationTitle("寫日記").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { Task { if store.saveJournal(value) { await store.flush(); if !store.saveFailed { dismiss() } } } }.disabled(value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveJournal") }
            }
        }
    }
}
