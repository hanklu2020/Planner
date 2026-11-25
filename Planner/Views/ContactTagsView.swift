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
    @State private var editing: ContactTag?
    @State private var name = ""
    @State private var naming = false

    var body: some View {
        if let category = store.tags.categories.first(where: { $0.id == categoryID }) {
            List {
                ColorPicker("大圈顏色", selection: Binding(get: {
                    TagPalette.color(category.color)
                }, set: { store.setCategoryColor(TagPalette.hex($0), category: categoryID) }), supportsOpacity: false)
                ForEach(store.tags.tags(in: categoryID)) { tag in
                    NavigationLink { TagMembers(tagID: tag.id) } label: {
                        HStack {
                            Text(tag.name)
                            Spacer()
                            Text("\(store.contactIndex.members[tag.id]?.count ?? 0) 人").foregroundStyle(.secondary)
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

struct TagMembers: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let tagID: UUID
    var modal = false
    @State private var selecting = false
    @State private var adding = false
    @State private var selected: Set<UUID> = []
    @State private var removing = false

    var body: some View {
        let tag = store.tags.tags.first { $0.id == tagID }
        let ids = store.contactIndex.members[tagID] ?? []
        let rows = ids.compactMap { store.contact($0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        List {
            if rows.isEmpty { Text("這個圈子還沒有成員。").foregroundStyle(.secondary) }
            ForEach(rows) { person in
                if selecting {
                    Button {
                        if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                    } label: { Label(person.name, systemImage: selected.contains(person.id) ? "checkmark.circle.fill" : "circle") }
                } else {
                    NavigationLink(person.name) { ContactDetailView(contactID: person.id) }
                }
            }
        }
        .navigationTitle(tag?.name ?? "成員").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if modal { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(selecting ? "取消選取" : "選取") { selecting.toggle(); selected = [] }.disabled(rows.isEmpty && !selecting)
                Button { adding = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("加入成員")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button("全選 \(rows.count) 人") { selected = ids }
                    Spacer()
                    Button("移出 \(selected.count) 人", role: .destructive) { removing = true }.disabled(selected.isEmpty)
                }.padding(13).background(.regularMaterial)
            }
        }
        .confirmationDialog("移出 \(selected.count) 人？", isPresented: $removing, titleVisibility: .visible) {
            Button("移出成員", role: .destructive) {
                store.changeTags([tagID], for: selected, adding: false); selecting = false; selected = []
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
    @State private var selected: Set<UUID> = []

    var body: some View {
        let existing = store.contactIndex.members[tagID] ?? []
        let contacts = store.contactIndex.byID.values.filter {
            !$0.archived && !existing.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NavigationStack {
            List {
                if !contacts.isEmpty { Button("全選這 \(contacts.count) 筆結果") { selected.formUnion(contacts.map(\.id)) } }
                ForEach(contacts) { person in
                    Button {
                        if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
                    } label: { Label(person.name, systemImage: selected.contains(person.id) ? "checkmark.circle.fill" : "circle") }
                }
            }
            .searchable(text: $search, prompt: "搜尋聯絡人")
            .navigationTitle("加入 \(name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入 \(selected.count) 人") { store.changeTags([tagID], for: selected, adding: true); dismiss() }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct ContactCircleMap: View {
    @EnvironmentObject private var store: PlannerStore
    let categories: [ContactTagCategory]
    let tags: [ContactTag]
    var select: (ContactTag) -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        let zoom = clamped(scale * magnification)
        let columns = 2
        let cell: CGFloat = 150
        let gap: CGFloat = 14
        let width = (cell + gap) * CGFloat(columns) - gap
        let height = (cell + gap) * CGFloat((tags.count + columns - 1) / columns) - gap
        return Group {
            if tags.isEmpty {
                ContentUnavailableView("還沒有圈子", systemImage: "circle.hexagongrid", description: Text("前往標籤頁建立大圈。"))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: columns), spacing: gap) {
                        ForEach(tags) { tag in
                            let category = categories.first { $0.id == tag.categoryID }
                            let color = TagPalette.color(category?.color ?? "")
                            let count = store.contactIndex.members[tag.id]?.count ?? 0
                            Button { select(tag) } label: {
                                VStack(spacing: 6) {
                                    Text(tag.name).font(.headline).lineLimit(2)
                                    Text("\(count) 人").font(.caption).monospacedDigit()
                                }.multilineTextAlignment(.center)
                                    .padding(14).frame(width: cell, height: cell)
                                    .foregroundStyle(color)
                                    .background(color.opacity(0.12), in: Circle())
                                    .overlay { Circle().strokeBorder(color.opacity(0.5), lineWidth: 1) }
                            }.buttonStyle(.plain)
                        }
                    }
                    .frame(width: width, height: height, alignment: .top)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: width * zoom, height: height * zoom, alignment: .topLeading)
                    .padding(16)
                }
                .simultaneousGesture(MagnificationGesture().updating($magnification) { value, state, _ in
                    state = value
                }.onEnded { scale = clamped(scale * $0) })
            }
        }
    }

    private func clamped(_ value: CGFloat) -> CGFloat { min(2.5, max(0.6, value)) }
}
