import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var visibleDays = 30
    @State private var editing: JournalDraft?
    @State private var correction: CompletionDateDraft?
    @State private var search = PlannerSearch()
    @State private var scrolledToLatest = false

    private var cutoff: Date { PlannerDates.shifted(PlannerDates.calendar.startOfDay(for: Date()), .day, by: -visibleDays) }

    var body: some View {
        let term = JournalSearchIndex.normalized(search.term)
        let calendar = PlannerDates.calendar
        let entries = Dictionary(grouping: store.journalIndex.entries.values.compactMap { entry, text in
            (term.isEmpty ? entry.date >= cutoff : text.contains(term)) ? entry : nil
        }, by: { calendar.startOfDay(for: $0.date) })
        let visibleRecords = store.journalIndex.completions.values.compactMap { entry, text -> (Date, CompletionRecord)? in
            let day = calendar.startOfDay(for: entry.journalDate)
            return (term.isEmpty ? day >= cutoff : text.contains(term)) ? (day, entry) : nil
        }
        let records = Dictionary(grouping: visibleRecords, by: { $0.0 }).mapValues { $0.map { $0.1 } }
        let days = Set(entries.keys).union(records.keys).sorted()
        return NavigationStack {
            VStack(spacing: 0) {
                if search.isVisible {
                    PlannerSearchBar(search: $search, title: "搜尋日記與完成任務", identifier: "journalSearch", cancel: closeSearch)
                }
                journalList(days: days, entries: entries, records: records, term: term)
            }
            .navigationTitle("日記").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("搜尋", systemImage: "magnifyingglass") { revealSearch(focus: true) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = JournalDraft(entry: store.journalEntry(on: Date())) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("寫日記")
                }
            }
            .sheet(item: $editing) { JournalEditor(initial: $0.entry, completionID: $0.completionID) }
            .sheet(item: $correction) { CompletionDateEditor(draft: $0) }
        }
    }

    private func journalList(days: [Date], entries: [Date: [JournalEntry]], records: [Date: [CompletionRecord]], term: String) -> some View {
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
                            HStack {
                                Text("\(isRecent(day) ? "最近完成" : "完成紀錄") · \(finished.count) 項").foregroundStyle(.secondary)
                                Spacer()
                                Button("更正日期") { correction = CompletionDateDraft(day: day, records: finished) }
                                    .buttonStyle(.borderless)
                            }.font(.caption)
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
            .onChange(of: term) { _, value in
                if value.isEmpty { proxy.scrollTo("latest", anchor: .bottom) }
                else if let first = days.first { proxy.scrollTo(first, anchor: .top) }
            }
            .modifier(PlannerSearchPull(enabled: !search.isVisible) { revealSearch(focus: false) })
        }
    }

    private func revealSearch(focus: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { search.reveal(focus: focus) }
    }

    private func closeSearch() {
        withAnimation(.easeOut(duration: 0.2)) { search = PlannerSearch() }
    }

    private var hasEarlier: Bool {
        store.journalIndex.entries.values.contains { $0.0.date < cutoff }
            || store.journalIndex.completions.values.contains { $0.0.journalDate < cutoff }
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
            CompletionRow(record: record, showSymbol: false, usesJournalDate: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editing = JournalDraft(entry: store.journalEntry(adding: record), completionID: record.id)
            } label: { Image(systemName: "book.closed.fill").overlay(alignment: .topTrailing) {
                Image(systemName: "plus.circle.fill").font(.caption2).background(.background, in: Circle()).offset(x: 5, y: -3)
            }.frame(minWidth: 36, minHeight: 44) }
                .buttonStyle(.borderless).accessibilityLabel("加入日記：\(record.title)")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("刪除", role: .destructive) { store.hideJournalCompletion(record) }
        }
    }
}

private struct CompletionDateDraft: Identifiable {
    var id: Date { day }
    let day: Date
    let records: [CompletionRecord]
}

private struct CompletionDateEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var selected: Set<UUID> = []
    let draft: CompletionDateDraft

    init(draft: CompletionDateDraft) {
        self.draft = draft
        _date = State(initialValue: draft.day)
        if draft.records.count == 1 { _selected = State(initialValue: Set(draft.records.map(\.id))) }
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("完成日期", selection: $date, displayedComponents: .date)
                    .environment(\.calendar, PlannerDates.calendar)
                Section {
                    ForEach(draft.records) { record in
                        Button {
                            if !selected.insert(record.id).inserted { selected.remove(record.id) }
                        } label: {
                            HStack {
                                Text(record.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                            }.contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selected.contains(record.id) ? .isSelected : [])
                    }
                } header: {
                    HStack {
                        Text("已選 \(selected.count) 項")
                        Spacer()
                        if draft.records.count > 1 {
                            Button(selected.count == draft.records.count ? "取消全選" : "全選") {
                                selected = selected.count == draft.records.count ? [] : Set(draft.records.map(\.id))
                            }.textCase(nil)
                        }
                    }
                }
            }
            .plannerErrors()
            .navigationTitle("更正完成日期").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        if store.correctCompletionDate(selected, to: date) { dismiss() }
                    }.disabled(selected.isEmpty || PlannerDates.calendar.isDate(date, inSameDayAs: draft.day))
                }
            }
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
