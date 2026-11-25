import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var visibleDays = 30
    @State private var editing: JournalDraft?
    @State private var search = ""
    @State private var scrolledToLatest = false

    private var cutoff: Date { PlannerDates.shifted(PlannerDates.calendar.startOfDay(for: Date()), .day, by: -visibleDays) }

    var body: some View {
        let term = JournalSearchIndex.normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        let calendar = PlannerDates.calendar
        let entries = Dictionary(grouping: store.journalIndex.entries.values.compactMap { entry, text in
            (term.isEmpty ? entry.date >= cutoff : text.contains(term)) ? entry : nil
        }, by: { calendar.startOfDay(for: $0.date) })
        let records = Dictionary(grouping: store.journalIndex.completions.values.compactMap { entry, text in
            (term.isEmpty ? entry.date >= cutoff : text.contains(term)) ? entry : nil
        }, by: { calendar.startOfDay(for: $0.date) })
        let days = Set(entries.keys).union(records.keys).sorted()
        return NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if term.isEmpty && hasEarlier {
                        Button("載入更早的紀錄") { visibleDays += 90 }
                            .onAppear { if scrolledToLatest { visibleDays += 90 } }
                    }
                    if days.isEmpty {
                        EmptyMessage(title: term.isEmpty ? "留下今天的一點記錄" : "沒有搜尋結果",
                                     symbol: "book.closed", detail: term.isEmpty ? "完成的任務也會出現在這裡。" : "試試其他關鍵字。")
                    }
                    ForEach(days, id: \.self) { day in
                        Section(PlannerDates.text(day, "yyyy年 M月d日 EEEE")) {
                            ForEach((entries[day] ?? []).sorted { $0.date < $1.date }) { entry in
                                Button { editing = JournalDraft(entry: entry) } label: {
                                    Text(entry.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }.buttonStyle(.plain)
                                .swipeActions { Button("刪除", role: .destructive) { _ = store.commit { $0.journal.removeAll { $0.id == entry.id } } } }
                            }
                            let finished = (records[day] ?? []).sorted { $0.date < $1.date }
                            if !finished.isEmpty {
                                Text("\(isRecent(day) ? "最近完成" : "完成紀錄") · \(finished.count) 項").font(.caption).foregroundStyle(.secondary)
                                ForEach(finished) { record in completionRow(record) }
                            }
                        }.id(day)
                    }
                    Color.clear.frame(height: 1).listRowBackground(Color.clear).id("latest")
                }
                .listStyle(.insetGrouped)
                .onAppear {
                    guard !scrolledToLatest else { return }
                    proxy.scrollTo("latest", anchor: .bottom)
                    DispatchQueue.main.async { scrolledToLatest = true }
                }
                .onChange(of: term) { _, value in if !value.isEmpty, let first = days.first { proxy.scrollTo(first, anchor: .top) } }
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜尋日記與完成任務")
            }
            .navigationTitle("日記").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button { editing = JournalDraft(entry: store.journalEntry(on: Date())) } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("寫日記")
            }
            .sheet(item: $editing) { JournalEditor(initial: $0.entry, completionID: $0.completionID) }
        }
    }

    private var hasEarlier: Bool {
        store.journalIndex.entries.values.contains { $0.0.date < cutoff }
            || store.journalIndex.completions.values.contains { $0.0.date < cutoff }
    }

    private func isRecent(_ date: Date) -> Bool {
        date >= PlannerDates.shifted(PlannerDates.calendar.startOfDay(for: Date()), .day, by: -1)
    }

    private func completionRow(_ record: CompletionRecord) -> some View {
        HStack(spacing: 10) {
            if store.canReopen(record) {
                Button { store.withdrawCompletion(record) } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(minWidth: 34, minHeight: 44)
                }.buttonStyle(.borderless).accessibilityLabel("取消完成：\(record.title)")
            }
            CompletionRow(record: record, showSymbol: false).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editing = JournalDraft(entry: store.journalEntry(on: record.date, adding: record), completionID: record.id)
            } label: { Image(systemName: "book.closed.fill").overlay(alignment: .topTrailing) {
                Image(systemName: "plus.circle.fill").font(.caption2).background(.background, in: Circle()).offset(x: 5, y: -3)
            }.frame(minWidth: 36, minHeight: 44) }
                .buttonStyle(.borderless).accessibilityLabel("加入日記：\(record.title)")
        }
    }
}

private struct JournalDraft: Identifiable {
    var id: UUID { entry.id }
    let entry: JournalEntry
    var completionID: UUID?
}

struct JournalEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: JournalEntry
    @State private var saving = false
    private let completionID: UUID?
    init(initial: JournalEntry, completionID: UUID? = nil) {
        _value = State(initialValue: initial)
        self.completionID = completionID
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $value.date, displayedComponents: .date).disabled(completionID != nil)
                Picker("內容語言", selection: $value.language) { Text("中文").tag("zh"); Text("English").tag("en") }
                Section { TextEditor(text: $value.text).frame(minHeight: 250).accessibilityIdentifier("journalText") }
            }
            .plannerErrors()
            .navigationTitle("寫日記").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        saving = true
                        Task {
                            defer { saving = false }
                            guard store.saveJournal(value) else { return }
                            await store.flush()
                            guard !store.saveFailed else { return }
                            if let completionID { store.finishJournalAddition(completionID) }
                            dismiss()
                        }
                    }.disabled(saving || value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveJournal")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
