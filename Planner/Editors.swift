import SwiftUI

struct EditorSheet<Fields: View>: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PlannerStore
    let title: String
    let canSave: Bool
    let save: () -> Bool
    var delete: (() -> Bool)? = nil
    @ViewBuilder var fields: () -> Fields
    @State private var confirmDelete = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                fields()
                if delete != nil {
                    Section {
                        Button("刪除", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { finish(save) }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("確定刪除這筆資料？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    if let delete { finish(delete) }
                }
            }
            .alert("無法儲存", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("好", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }

    private func finish(_ action: () -> Bool) {
        if action() { dismiss() }
        else {
            failure = store.errorMessage ?? "請確認輸入內容。"
            store.errorMessage = nil
        }
    }
}

struct TaskEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @State var draft: PlanTask
    @FocusState private var focusTitle: Bool

    private var existing: Bool { store.tasks.contains { $0.id == draft.id } }
    private var priorityAvailable: Bool {
        TaskRules.priorityCount(in: store.tasks, for: draft) < 3
    }

    var body: some View {
        EditorSheet(
            title: existing ? "編輯\(draft.scale.noun)" : "新增\(draft.scale.noun)",
            canSave: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: { store.save(draft) },
            delete: existing ? { store.deleteTask(draft.id) } : nil
        ) {
            Section {
                TextField("要做什麼？", text: $draft.text, axis: .vertical)
                    .focused($focusTitle)
                    .lineLimit(1...5)
                    .accessibilityIdentifier("taskTitle")
            }
            Section {
                Picker("期間", selection: $draft.scale) {
                    ForEach(PlanScale.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("日期", selection: $draft.date, displayedComponents: .date)
                if draft.scale != .day {
                    Text(PlannerDates.title(for: draft.scale, at: draft.date))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.scale == .day {
                    Toggle("今日重點", isOn: $draft.isPriority)
                        .disabled(!draft.isPriority && !priorityAvailable)
                    if !priorityAvailable && !draft.isPriority {
                        Text("這一天已有三件未完成的重點。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if existing { Toggle("已完成", isOn: $draft.done) }
            }
            if !store.contacts.isEmpty {
                Section {
                    DisclosureGroup("關聯人脈（\(draft.contactIDs.filter { id in store.contacts.contains { $0.id == id } }.count)）") {
                        ForEach(store.contacts.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }) { contact in
                            Toggle(contact.text, isOn: Binding(
                                get: { draft.contactIDs.contains(contact.id) },
                                set: { selected in
                                    draft.contactIDs.removeAll { $0 == contact.id }
                                    if selected { draft.contactIDs.append(contact.id) }
                                }
                            ))
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("備註") {
                    TextField("補充內容", text: $draft.notes, axis: .vertical).lineLimit(3...10)
                }
            }
        }
        .onAppear { focusTitle = !existing }
    }
}

struct JournalEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @State var draft: JournalEntry
    @FocusState private var focusText: Bool
    private var existing: Bool { store.journal.contains { $0.id == draft.id } }

    var body: some View {
        EditorSheet(
            title: existing ? "編輯日記" : "新增日記",
            canSave: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: { store.save(draft) },
            delete: existing ? { store.deleteEntry(draft.id) } : nil
        ) {
            Section {
                DatePicker("日期", selection: $draft.date, displayedComponents: .date)
            }
            Section {
                TextField("寫下今天的事……", text: $draft.text, axis: .vertical)
                    .lineLimit(10...30)
                    .focused($focusText)
            }
        }
        .onAppear { focusText = !existing }
    }
}

struct ContactEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @State var draft: PlannerContact
    @FocusState private var focusName: Bool
    private var existing: Bool { store.contacts.contains { $0.id == draft.id } }

    var body: some View {
        EditorSheet(
            title: existing ? "編輯聯絡人" : "新增聯絡人",
            canSave: !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: {
                // Preserve interactions added since this editor was opened.
                var value = draft
                if let current = store.contacts.first(where: { $0.id == draft.id }) {
                    value.interactions = current.interactions
                }
                return store.save(value)
            },
            delete: existing ? { store.deleteContact(draft.id) } : nil
        ) {
            Section {
                TextField("姓名", text: $draft.text).focused($focusName)
            }
            Section("聯絡方式與備註（選填）") {
                TextField("電話、Email 或其他說明", text: $draft.details, axis: .vertical)
                    .lineLimit(4...12)
            }
        }
        .onAppear { focusName = !existing }
    }
}

struct InteractionEditor: View {
    @EnvironmentObject private var store: PlannerStore
    let contactID: UUID
    @State var draft: Interaction

    private var contact: PlannerContact? { store.contacts.first { $0.id == contactID } }
    private var existing: Bool { contact?.interactions.contains { $0.id == draft.id } ?? false }

    var body: some View {
        EditorSheet(
            title: existing ? "編輯互動紀錄" : "新增互動紀錄",
            canSave: contact != nil && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            save: { update(deleting: false) },
            delete: existing ? { update(deleting: true) } : nil
        ) {
            Section {
                DatePicker("日期", selection: $draft.date, displayedComponents: .date)
                TextField("記錄互動內容", text: $draft.text, axis: .vertical).lineLimit(5...20)
            }
        }
    }

    private func update(deleting: Bool) -> Bool {
        guard var value = contact else { return false }
        value.interactions.removeAll { $0.id == draft.id }
        if !deleting {
            var entry = draft
            entry.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            value.interactions.append(entry)
        }
        return store.save(value)
    }
}
