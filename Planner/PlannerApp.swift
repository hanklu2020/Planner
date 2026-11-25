import SwiftUI

@main
struct PlannerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView(title: "計畫", hint: "新增今日任務", key: "tasks", checklist: true)
                .tabItem { Label("計畫", systemImage: "calendar") }
            RecordView(title: "日記", hint: "新增日記", key: "journal", checklist: false)
                .tabItem { Label("日記", systemImage: "book") }
            RecordView(title: "人脈", hint: "新增聯絡人", key: "contacts", checklist: false)
                .tabItem { Label("人脈", systemImage: "person.2") }
        }
    }
}

struct Record: Codable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

struct RecordView: View {
    let title: String
    let hint: String
    let checklist: Bool
    @AppStorage private var saved: Data
    @State private var draft = ""

    init(title: String, hint: String, key: String, checklist: Bool) {
        self.title = title
        self.hint = hint
        self.checklist = checklist
        _saved = AppStorage(wrappedValue: Data(), key)
    }

    private var records: [Record] {
        (try? JSONDecoder().decode([Record].self, from: saved)) ?? []
    }
    private func store(_ rows: [Record]) {
        if let data = try? JSONEncoder().encode(rows) { saved = data }
    }
    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store(records + [Record(text: value)])
        draft = ""
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(hint, text: $draft).onSubmit(add)
                        Button(action: add) { Image(systemName: "plus.circle.fill") }
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    ForEach(records) { record in
                        HStack {
                            if checklist {
                                Button {
                                    store(records.map { item in
                                        var copy = item
                                        if copy.id == record.id { copy.done.toggle() }
                                        return copy
                                    })
                                } label: {
                                    Image(systemName: record.done ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless)
                            }
                            Text(record.text).strikethrough(record.done)
                        }
                    }.onDelete { offsets in
                        var rows = records
                        rows.remove(atOffsets: offsets)
                        store(rows)
                    }
                } header: { Text(checklist ? "今日任務" : "紀錄") }
            }
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .bottomBar) { Text("Planner MVP · 0.0.1").font(.caption).foregroundStyle(.secondary) } }
        }
    }
}
