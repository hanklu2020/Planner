import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var search = ""
    @State private var editing: Contact?
    @State private var showArchived = false
    @State private var mode: ContactMode = .list
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var batch: TagBatch?
    @State private var newCategory = false
    @State private var graphMember: ContactTag?
    @State private var categoryFilter: String?

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: contactList
                case .tags: categories
                case .map:
                    ContactCircleMap(categories: store.tags.categories, tags: store.tags.tags.filter {
                        categoryFilter == nil || categoryFilter == $0.categoryID
                    }) { graphMember = $0 }
                }
            }
            .navigationTitle("人脈").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if mode == .list {
                        Menu {
                            Button(selecting ? "取消選取" : "選取聯絡人") { selecting.toggle(); selected.removeAll() }
                            Toggle("顯示已封存", isOn: $showArchived)
                        } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "line.3.horizontal.decrease") }
                            .accessibilityLabel("選取與篩選聯絡人")
                    }
                    if mode == .map {
                        Menu {
                            Picker("分類", selection: $categoryFilter) {
                                Text("全部分類").tag(nil as String?)
                                ForEach(store.tags.categories) { Text($0.name).tag(Optional($0.id)) }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("篩選圈子")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("人脈檢視", selection: $mode) {
                            ForEach(ContactMode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                        }
                    } label: { Image(systemName: mode.symbol) }.accessibilityLabel("切換人脈檢視")
                    Button { editing = Contact() } label: { Image(systemName: "plus") }.accessibilityLabel("新增聯絡人")
                }
            }
            .sheet(item: $editing) { ContactEditor(initial: $0) }
            .sheet(item: $batch) { TagBatchPicker(batch: $0) }
            .sheet(isPresented: $newCategory) { TagCategoryEditor() }
            .sheet(item: $graphMember) { tag in
                NavigationStack { TagMembers(tagID: tag.id, modal: true) }
            }
        }
    }

    private var contactList: some View {
        let contacts = store.contactIndex.byID.values.filter {
            (showArchived || !$0.archived) && (search.isEmpty || ($0.name + " " + $0.details).localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return List {
            if contacts.isEmpty { EmptyMessage(title: "沒有聯絡人", symbol: "person.2", detail: "新增聯絡人，或試試其他搜尋文字。") }
            ForEach(contacts) { contact in
                if selecting {
                    Button {
                        if selected.contains(contact.id) { selected.remove(contact.id) } else { selected.insert(contact.id) }
                    } label: {
                        Label(contact.name, systemImage: selected.contains(contact.id) ? "checkmark.circle.fill" : "circle")
                    }
                } else {
                    NavigationLink { ContactDetailView(contactID: contact.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.name)
                            if let summary = store.contactIndex.latest[contact.id] {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else if !contact.details.isEmpty {
                                Text(contact.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜尋聯絡人")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                HStack {
                    Menu("已選 \(selected.count) 人") {
                        Button("全選這 \(contacts.count) 筆結果") { selected.formUnion(contacts.map(\.id)) }
                        Button("清除選取") { selected.removeAll() }
                    }
                    Spacer()
                    Button("加標籤") { batch = TagBatch(people: selected, adding: true) }.disabled(selected.isEmpty)
                    Button("移除標籤") { batch = TagBatch(people: selected, adding: false) }.disabled(selected.isEmpty)
                }.font(.subheadline).padding(13).background(.regularMaterial)
            }
        }
    }

    private var categories: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                ForEach(store.tags.categories) { category in
                    NavigationLink { TagCategoryView(categoryID: category.id) } label: {
                        categoryCard(category.name, icon: "tag", color: TagPalette.color(category.color))
                    }.buttonStyle(.plain)
                }
                Button { newCategory = true } label: { categoryCard("新增分類", icon: "plus", color: .secondary) }
                    .buttonStyle(.plain).accessibilityLabel("新增分類")
            }.padding()
        }
    }

    private func categoryCard(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.headline).foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

private enum ContactMode: String, CaseIterable, Identifiable {
    case list = "清單", tags = "標籤", map = "全圖"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .tags: return "tag"
        case .map: return "circle.hexagongrid"
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
            .plannerErrors()
            .navigationTitle("聯絡人").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { Task { if store.saveContact(value) { await store.flush(); if !store.saveFailed { dismiss() } } } }.disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveContact") }
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
