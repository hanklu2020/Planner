import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var search = ""
    @State private var editing: Contact?
    @State private var showArchived = false
    private var contacts: [Contact] {
        store.data.contacts.filter { (showArchived || !$0.archived) && (search.isEmpty || ($0.name + $0.details).localizedCaseInsensitiveContains(search)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                if contacts.isEmpty { EmptyMessage(title: "記住重要的人", symbol: "person.2", detail: "新增聯絡人，保留往來與相關任務。") }
                ForEach(contacts) { contact in
                    NavigationLink { ContactDetailView(contactID: contact.id) } label: {
                        HStack(spacing: 12) {
                            Text(String(contact.name.prefix(1))).font(.headline).frame(width: 40, height: 40).background(Color.plannerAccent.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(contact.name)
                                if !contact.details.isEmpty { Text(contact.details).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if contact.keepHistory { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                            if contact.archived { Text("已封存").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("人脈").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜尋聯絡人")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Menu { Toggle("顯示已封存", isOn: $showArchived) } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("篩選聯絡人") }
                ToolbarItem(placement: .topBarTrailing) { Button { editing = Contact() } label: { Image(systemName: "plus") }.accessibilityLabel("新增聯絡人") }
            }
            .sheet(item: $editing) { ContactEditor(initial: $0) }
        }
    }
}

struct ContactEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: Contact
    init(initial: Contact) { _value = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名", text: $value.name).accessibilityIdentifier("contactName")
                    TextField("聯絡方式或備註（選填）", text: $value.details, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Toggle("保留長期紀錄", isOn: $value.keepHistory)
                    Toggle("封存聯絡人", isOn: $value.archived)
                } footer: { Text("封存後仍保留往來與任務關聯。保留長期紀錄可避免手動清理舊往來。") }
            }
            .navigationTitle("聯絡人").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { if store.saveContact(value) { dismiss() } }.disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveContact") }
            }
        }
    }
}

struct ContactDetailView: View {
    @EnvironmentObject private var store: PlannerStore
    let contactID: UUID
    @State private var edit = false
    @State private var entry: Interaction?
    @State private var task: TaskPresentation?
    @State private var showCleanup = false
    @State private var cleanupDate = PlannerDates.shifted(Date(), .year, by: -1)
    @State private var confirmCleanup = false
    var body: some View {
        if let contact = store.contact(contactID) {
            List {
                if !contact.details.isEmpty { Section { Text(contact.details) } }
                let pending = store.data.tasks.filter { $0.isOpen && $0.contactIDs.contains(contactID) }
                Section("待辦事項") {
                    ForEach(pending) { TaskRow(task: $0) }
                    Button("新增相關任務", systemImage: "plus") { task = TaskPresentation(task: PlannerTask(contactIDs: [contactID])) }
                }
                Section("往來紀錄") {
                    Button("記錄往來", systemImage: "square.and.pencil") { entry = Interaction(contactID: contactID) }
                    let manual = store.data.interactions.filter { $0.contactID == contactID }.sorted { $0.date > $1.date }
                    let completed = store.data.tasks.filter { $0.isDone && $0.contactIDs.contains(contactID) }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    let events = (manual.map { ContactEvent.interaction($0) } + completed.map { ContactEvent.task($0) }).sorted { $0.date > $1.date }
                    if events.isEmpty { Text("目前沒有往來紀錄").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(events) { event in
                        switch event {
                        case .interaction(let value):
                            Button { entry = value } label: {
                                VStack(alignment: .leading, spacing: 6) { Text(value.text).foregroundStyle(.primary); Text(PlannerDates.text(value.date, "yyyy/M/d")).font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                            .swipeActions { Button("刪除", role: .destructive) { _ = store.commit { $0.interactions.removeAll { $0.id == value.id } } } }
                        case .task(let value):
                            VStack(alignment: .leading, spacing: 5) {
                                Text(PlannerDates.text(value.completedAt!, "yyyy/M/d") + " · 已完成任務").font(.caption).foregroundStyle(.secondary)
                                TaskRow(task: value)
                            }
                        }
                    }
                }
                if !contact.keepHistory { Section { Button("清理舊往來紀錄") { showCleanup = true } } }
            }
            .navigationTitle(contact.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("編輯") { edit = true } }
            .sheet(isPresented: $edit) { ContactEditor(initial: contact) }
            .sheet(item: $entry) { InteractionEditor(initial: $0) }
            .sheet(item: $task) { TaskEditor(initial: $0.task) }
            .sheet(isPresented: $showCleanup) {
                NavigationStack {
                    Form {
                        DatePicker("刪除此日期以前的往來", selection: $cleanupDate, displayedComponents: .date)
                        Text("僅刪除手動填寫的往來文字；已完成任務仍會保留。建議先匯出備份。").font(.caption).foregroundStyle(.secondary)
                        Button("清理", role: .destructive) { confirmCleanup = true }
                    }.navigationTitle("清理往來")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showCleanup = false } } }
                        .confirmationDialog("刪除舊往來文字？此操作無法復原。", isPresented: $confirmCleanup, titleVisibility: .visible) {
                            Button("刪除", role: .destructive) {
                                if store.commit({ $0.interactions.removeAll { $0.contactID == contactID && $0.date < PlannerDates.calendar.startOfDay(for: cleanupDate) } }) { showCleanup = false }
                            }
                        }
                }
            }
        } else { ContentUnavailableView("找不到聯絡人", systemImage: "person") }
    }
}

private enum ContactEvent: Identifiable {
    case interaction(Interaction), task(PlannerTask)
    var id: String { switch self { case .interaction(let v): return "interaction-\(v.id)"; case .task(let v): return "task-\(v.id)" } }
    var date: Date { switch self { case .interaction(let v): return v.date; case .task(let v): return v.completedAt ?? .distantPast } }
}

struct InteractionEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var value: Interaction
    init(initial: Interaction) { _value = State(initialValue: initial) }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $value.date, displayedComponents: .date)
                TextEditor(text: $value.text).frame(minHeight: 220).accessibilityIdentifier("interactionText")
            }
            .navigationTitle("記錄往來").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { if store.saveInteraction(value) { dismiss() } }.disabled(value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
