import SwiftUI
import UIKit

enum TagPalette {
    static func color(_ hex: String) -> Color {
        let rgb = UInt32(hex, radix: 16) ?? 0x5270A0
        return Color(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &alpha) else { return "5270A0" }
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

struct TagBatch: Identifiable {
    let id = UUID()
    let people: Set<UUID>
    let adding: Bool
}

struct TagBatchPicker: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let batch: TagBatch
    @State private var selection: Set<UUID> = []
    @State private var search = ""

    var body: some View {
        let affected = store.tags.tags.reduce(into: [UUID: Set<UUID>]()) { result, tag in
            let existing = store.contactIndex.members[tag.id] ?? []
            result[tag.id] = batch.adding ? batch.people.subtracting(existing) : batch.people.intersection(existing)
        }
        let count = selection.reduce(into: Set<UUID>()) { $0.formUnion(affected[$1] ?? []) }.count
        let matching = store.tags.tags.filter { tag in
            affected[tag.id]?.isEmpty == false && (search.isEmpty ||
                ([store.tags.category(for: tag)?.name ?? "", tag.name].joined(separator: " ")).localizedCaseInsensitiveContains(search))
        }
        return NavigationStack {
            List {
                if batch.adding && search.isEmpty {
                    let recent = store.recentTags.compactMap { id in matching.first { $0.id == id } }
                    if !recent.isEmpty { Section("最近使用") { ForEach(recent) { tagRow($0, count: affected[$0.id]?.count ?? 0, qualified: true) } } }
                }
                ForEach(store.tags.categories) { category in
                    let tags = matching.filter { $0.categoryID == category.id }
                    if !tags.isEmpty { Section(category.name) { ForEach(tags) { tagRow($0, count: affected[$0.id]?.count ?? 0) } } }
                }
                if matching.isEmpty {
                    Text(batch.adding ? "沒有可加入的標籤。可在標籤頁新增。" : "沒有可移除的標籤。").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(batch.adding ? "加入標籤" : "移除標籤").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜尋分類或標籤")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("套用 · \(count) 人") { store.changeTags(selection, for: batch.people, adding: batch.adding); dismiss() }.disabled(count == 0)
                }
            }
        }
    }

    private func tagRow(_ tag: ContactTag, count: Int, qualified: Bool = false) -> some View {
        Button {
            if selection.contains(tag.id) { selection.remove(tag.id) } else { selection.insert(tag.id) }
        } label: {
            HStack {
                Image(systemName: selection.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                Text(qualified ? "\(store.tags.category(for: tag)?.name ?? "")／\(tag.name)" : tag.name)
                Spacer()
                Text("\(count)／\(batch.people.count) 人").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TagCategoryEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = Color.blue
    @State private var duplicate = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("分類名稱", text: $name)
                ColorPicker("大圈顏色", selection: $color, supportsOpacity: false)
                if duplicate { Text("這個分類名稱已存在。").foregroundStyle(.red) }
            }
            .navigationTitle("新增分類").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("新增") {
                        if store.saveCategory(name: name, color: TagPalette.hex(color)) { dismiss() }
                        else { duplicate = true }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct TagCategoryView: View {
    @EnvironmentObject private var store: PlannerStore
    let categoryID: String
    var criteria = ContactCriteria()
    @State private var editing: ContactTag?
    @State private var name = ""
    @State private var naming = false

    var body: some View {
        if let category = store.tags.categories.first(where: { $0.id == categoryID }) {
            let visible = Set(ContactDirectory.people(store, in: criteria).map(\.id))
            List {
                ColorPicker("大圈顏色", selection: Binding(get: {
                    TagPalette.color(category.color)
                }, set: { store.setCategoryColor(TagPalette.hex($0), category: categoryID) }), supportsOpacity: false)
                ForEach(store.tags.tags(in: categoryID)) { tag in
                    NavigationLink(value: ContactRoute.members(tag.id, criteria)) {
                        HStack {
                            Text(tag.name)
                            Spacer()
                            Text("\((store.contactIndex.members[tag.id] ?? []).intersection(visible).count) 人").foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("改名") { edit(tag) }.tint(.plannerAccent) }
                }
                Button("新增標籤", systemImage: "plus") { edit(nil) }
            }
            .navigationTitle(category.name).navigationBarTitleDisplayMode(.inline)
            .alert(editing == nil ? "新增標籤" : "標籤改名", isPresented: $naming) {
                TextField("標籤名稱", text: $name)
                Button("儲存") {
                    if !store.saveTag(name: name, category: categoryID, existing: editing?.id) { store.error = "請輸入未使用的標籤名稱。" }
                }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private func edit(_ tag: ContactTag?) {
        editing = tag; name = tag?.name ?? ""; naming = true
    }
}

struct ContactTagLabel: View {
    @EnvironmentObject private var store: PlannerStore
    let tag: ContactTag

    var body: some View {
        Label(store.tags.name(for: tag), systemImage: "tag")
            .foregroundStyle(TagPalette.color(store.tags.category(for: tag)?.color ?? ""))
    }
}

struct TagMembers: View {
    @EnvironmentObject private var store: PlannerStore
    let tagID: UUID
    var criteria = ContactCriteria()
    @State private var selection = ContactSelection()
    @State private var adding = false

    var body: some View {
        let tag = store.tags.tags.first { $0.id == tagID }
        let people = ContactDirectory.people(store, in: criteria, circle: tagID)
        ContactPeopleList(people: people, circle: tagID, selection: $selection)
            .safeAreaInset(edge: .top, spacing: 0) {
                NavigationLink(value: ContactRoute.circleBirthdays(tagID, criteria)) {
                    Label("看這個圈的生日", systemImage: "birthday.cake").font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 9)
                }
            }
            .navigationTitle(tag?.name ?? "成員").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(selection.active ? "取消選取" : "選取") { selection = ContactSelection(active: !selection.active) }
                        .disabled(people.isEmpty && !selection.active)
                    Button { adding = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("加入成員")
                }
            }
            .sheet(isPresented: $adding) { AddTagMembers(tagID: tagID, name: tag?.name ?? "") }
    }
}

private struct AddTagMembers: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let tagID: UUID
    let name: String
    @State private var search = ""
    @State private var selection = ContactSelection(active: true)
    @State private var draft: Contact?

    var body: some View {
        let existing = store.contactIndex.members[tagID] ?? []
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = store.contactIndex.byID.values.filter {
            term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.details.localizedCaseInsensitiveContains(term)
        }.sorted(by: ContactDirectory.nameOrder)
        let available = matches.filter { !$0.archived && !existing.contains($0.id) }
        let others = term.isEmpty ? [] : matches.filter { existing.contains($0.id) || $0.archived }
        return NavigationStack {
            List {
                if !available.isEmpty {
                    Button("全選這 \(available.count) 筆結果") { selection.ids = Set(available.map(\.id)) }
                    ForEach(available) { person in
                        Button { selection.toggle(person.id) } label: {
                            Label { candidate(person) } icon: {
                                Image(systemName: selection.ids.contains(person.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    Section("其他同名或符合的聯絡人") { ForEach(others) { candidate($0) } }
                }
                if available.isEmpty && term.isEmpty {
                    Text("目前沒有可加入的聯絡人。").foregroundStyle(.secondary)
                }
                Button(term.isEmpty ? "新增聯絡人" : "新增「\(term)」", systemImage: "person.badge.plus") {
                    draft = Contact(name: term, tagIDs: [tagID])
                }
            }
            .searchable(text: $search, prompt: "搜尋或輸入新姓名")
            .navigationTitle("加入 \(name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 \(selection.ids.count) 人") {
                        store.changeTags([tagID], for: selection.ids, adding: true)
                        dismiss()
                    }.disabled(selection.ids.isEmpty)
                }
            }
            .onChange(of: Set(available.map(\.id))) { _, ids in selection.ids.formIntersection(ids) }
            .sheet(item: $draft) { ContactEditor(initial: $0, isNew: true) }
        }
    }

    private func candidate(_ person: Contact) -> some View {
        let tags = store.tags.tags.filter { person.tagIDs?.contains($0.id) == true }.prefix(2).map { store.tags.name(for: $0) }
        let status = person.archived ? "已封存" : person.tagIDs?.contains(tagID) == true ? "已加入" : nil
        let note = ([status].compactMap { $0 } + tags + [person.details]).filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            Text(person.name).foregroundStyle(.primary)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

struct CirclePreview: View {
    @EnvironmentObject private var store: PlannerStore
    let tag: ContactTag
    let criteria: ContactCriteria
    let open: (ContactRoute) -> Void

    var body: some View {
        let people = ContactDirectory.people(store, in: criteria, circle: tag.id)
        let birthdays = BirthdayOccurrence.upcoming(for: people)
        List {
            Section("\(people.count) 位聯絡人") {
                ForEach(people.prefix(3)) { person in
                    Button(person.name) { open(.person(person.id)) }
                }
                Button("查看成員", systemImage: "person.2") { open(.members(tag.id, criteria)) }
            }
            Section("近期生日") {
                ForEach(birthdays.prefix(2)) { event in
                    Button { open(.person(event.id)) } label: {
                        LabeledContent(event.person.name, value: PlannerDates.text(event.date, "M/d"))
                    }
                }
                Button("看這個圈的生日", systemImage: "birthday.cake") { open(.circleBirthdays(tag.id, criteria)) }
            }
        }.safeAreaInset(edge: .top) {
            ContactTagLabel(tag: tag).font(.headline).padding(.top, 24).padding(.bottom, 5)
        }
    }
}

struct ContactCircleMap<EmptyActions: View>: View {
    @EnvironmentObject private var store: PlannerStore
    let counts: [UUID: Int]
    let open: (ContactTag) -> Void
    @ViewBuilder var emptyActions: () -> EmptyActions

    var body: some View {
        let tags = store.tags.tags.filter { counts[$0.id] != nil }
        if tags.isEmpty {
            ContentUnavailableView {
                Label("這個範圍沒有可顯示的圈子", systemImage: "circle.hexagongrid")
            } description: {
                Text("全圖顯示目前範圍內有成員的標籤。")
            } actions: { emptyActions() }
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(tags) { tag in
                        let color = TagPalette.color(store.tags.category(for: tag)?.color ?? "")
                        Button { open(tag) } label: {
                            VStack(spacing: 5) {
                                Text(tag.name).font(.headline).lineLimit(2)
                                Text("\(counts[tag.id] ?? 0) 人").font(.caption).monospacedDigit()
                            }.multilineTextAlignment(.center)
                                .padding(12).frame(maxWidth: .infinity, minHeight: 104)
                                .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
                                .overlay { Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1) }
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }
        }
    }
}
