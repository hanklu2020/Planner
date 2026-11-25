import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var query = ""
    @State private var editing: PlannerContact?

    private var filtered: [PlannerContact] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.contacts.filter {
            search.isEmpty || $0.text.localizedStandardContains(search) || $0.details.localizedStandardContains(search)
        }.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { contact in
                NavigationLink(value: contact.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contact.text)
                        if !contact.details.isEmpty {
                            Text(contact.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.contacts.isEmpty && query.isEmpty {
                    ContentUnavailableView(
                        "還沒有聯絡人",
                        systemImage: "person.2",
                        description: Text("點右上角 ＋ 新增。")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜尋人脈")
            .navigationTitle("人脈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = PlannerContact() } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("新增聯絡人")
                }
            }
            .navigationDestination(for: UUID.self) { ContactDetailView(contactID: $0) }
            .sheet(item: $editing) { ContactEditor(draft: $0) }
        }
    }
}

private struct ContactDetailView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let contactID: UUID
    @State private var editingContact: PlannerContact?
    @State private var editingTask: PlanTask?
    @State private var editingInteraction: Interaction?

    private var contact: PlannerContact? { store.contacts.first { $0.id == contactID } }
    private var relatedTasks: [PlanTask] {
        store.tasks.filter { $0.contactIDs.contains(contactID) }
    }

    var body: some View {
        Group {
            if let contact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !contact.details.isEmpty {
                            DisclosureGroup("聯絡方式與備註") {
                                Text(contact.details)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .font(.subheadline)
                        }
                        TaskGroup(
                            title: "相關待辦",
                            rows: relatedTasks.filter { !$0.done }.sorted { $0.date < $1.date },
                            empty: "沒有相關待辦",
                            edit: { editingTask = $0 }
                        )
                        history(contact)
                    }
                    .padding(16)
                }
                .navigationTitle(contact.text)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("新增相關任務", systemImage: "plus") {
                                var task = PlanTask()
                                task.contactIDs = [contactID]
                                editingTask = task
                            }
                            Button("新增互動紀錄", systemImage: "square.and.pencil") {
                                editingInteraction = Interaction()
                            }
                            Button("編輯聯絡人", systemImage: "person.crop.circle") {
                                editingContact = contact
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("聯絡人操作")
                    }
                }
            } else {
                ContentUnavailableView("聯絡人已刪除", systemImage: "person.crop.circle.badge.xmark")
                    .onAppear { dismiss() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(item: $editingContact) { ContactEditor(draft: $0) }
        .sheet(item: $editingTask) { TaskEditor(draft: $0) }
        .sheet(item: $editingInteraction) { InteractionEditor(contactID: contactID, draft: $0) }
        .onChange(of: contact == nil) { _, missing in
            if missing { dismiss() }
        }
    }

    private func history(_ contact: PlannerContact) -> some View {
        let completed = relatedTasks.filter(\.done)
            .sorted { ($0.completedAt ?? $0.date) > ($1.completedAt ?? $1.date) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("互動紀錄").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if completed.isEmpty && contact.interactions.isEmpty {
                Text("尚無紀錄").font(.subheadline).foregroundStyle(.secondary)
            }
            // Completed tasks remain live references, avoiding duplicate stored history.
            ForEach(completed) { task in
                VStack(alignment: .leading, spacing: 0) {
                    Text(PlannerDates.text(task.completedAt ?? task.date, "yyyy/M/d") + " · 已完成任務")
                        .font(.caption).foregroundStyle(.secondary)
                    TaskRow(task: task, edit: { editingTask = task })
                    Divider()
                }
            }
            ForEach(contact.interactions.sorted { $0.date > $1.date }) { interaction in
                Button { editingInteraction = interaction } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PlannerDates.text(interaction.date, "yyyy/M/d"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(interaction.text)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }
}
