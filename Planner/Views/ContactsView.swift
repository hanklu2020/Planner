import SwiftUI

struct ContactDetailView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID
    @State private var edit = false
    @State private var entry: Interaction?
    @State private var task: TaskPresentation?
    @State private var showCleanup = false
    @State private var cleanupDate = PlannerDates.shifted(Date(), .year, by: -1)
    @State private var confirmCleanup = false
    @State private var confirmDeletion = false
    @State private var birthdayEditor = false
    @State private var tagPicker: TagBatch?
    @State private var editingTags = false
    var body: some View {
        if let contact = store.contact(contactID) {
            List {
                Section {
                    if !contact.details.isEmpty { Text(contact.details) }
                    Button { birthdayEditor = true } label: {
                        LabeledContent("生日", value: contact.birthday?.title ?? "未填寫")
                    }
                }
                let pending = store.data.tasks.filter { $0.isOpen && $0.contactIDs.contains(contactID) }
                Section("待辦事項") {
                    ForEach(pending) { TaskRow(task: $0) }
                    Button("新增相關任務", systemImage: "plus") { task = TaskPresentation(task: PlannerTask(contactIDs: [contactID])) }
                }
                Section("往來紀錄") {
                    Button("記錄往來", systemImage: "square.and.pencil") { entry = Interaction(contactID: contactID) }
                    let manual = store.data.interactions.filter { $0.contactID == contactID }.sorted { $0.date > $1.date }
                    let completed = store.data.completions.filter { $0.isVisible && $0.contactIDs.contains(contactID) }.sorted { $0.date > $1.date }
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
                                Text(PlannerDates.text(value.date, "yyyy/M/d") + " · 已完成任務").font(.caption).foregroundStyle(.secondary)
                                CompletionRow(record: value)
                            }
                        }
                    }
                }
                if !contact.keepHistory { Section { Button("清理舊往來紀錄") { showCleanup = true } } }
                Section {
                    ForEach(store.tags.tags.filter { contact.tagIDs?.contains($0.id) == true }) { tag in
                        HStack {
                            NavigationLink(value: ContactRoute.members(tag.id, ContactCriteria(scope: contact.archived ? .archived : .active))) { ContactTagLabel(tag: tag) }
                            if editingTags {
                                Button(role: .destructive) { store.changeTags([tag.id], for: [contactID], adding: false) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.borderless).accessibilityLabel("移除標籤 \(tag.name)")
                            }
                        }
                    }
                    Button("加標籤", systemImage: "plus") { tagPicker = TagBatch(people: [contactID], adding: true) }
                } header: {
                    HStack {
                        Text("標籤")
                        Spacer()
                        if store.tags.tags.contains(where: { contact.tagIDs?.contains($0.id) == true }) {
                            Button(editingTags ? "完成" : "編輯標籤") { editingTags.toggle() }.textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle(contact.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("編輯") { edit = true }
                    Menu {
                        NavigationLink("在全圖查看", value: ContactRoute.focusMap(contactID))
                        if contact.birthday != nil { NavigationLink("在生日查看", value: ContactRoute.focusBirthday(contactID)) }
                        else { Button("填寫生日") { birthdayEditor = true } }
                        Button("刪除聯絡人", role: .destructive) { confirmDeletion = true }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("聯絡人操作")
                }
            }
            .confirmationDialog("刪除 \(contact.name)？", isPresented: $confirmDeletion, titleVisibility: .visible) {
                Button("刪除聯絡人", role: .destructive) {
                    if store.deleteContact(contactID) {
                        Task { await store.flush(); if !store.saveFailed { dismiss() } }
                    }
                }
            } message: { Text("將刪除此人的 Markdown 與往來，並從任務解除聯絡人連結。") }
            .sheet(isPresented: $edit) { ContactEditor(initial: contact) }
            .sheet(isPresented: $birthdayEditor) { BirthdayQueue(ids: [contactID]) }
            .sheet(item: $tagPicker) { TagBatchPicker(batch: $0) }
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
    case interaction(Interaction), task(CompletionRecord)
    var id: String { switch self { case .interaction(let v): return "interaction-\(v.id)"; case .task(let v): return "task-\(v.id)" } }
    var date: Date { switch self { case .interaction(let v): return v.date; case .task(let v): return v.date } }
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
            .plannerErrors()
            .navigationTitle("記錄往來").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { Task { if store.saveInteraction(value) { await store.flush(); if !store.saveFailed { dismiss() } } } }.disabled(value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
