import SwiftUI

enum ContactMode: String, CaseIterable, Identifiable {
    case list = "清單", tags = "標籤", map = "全圖", birthday = "生日"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .tags: return "tag"
        case .map: return "circle.hexagongrid"
        case .birthday: return "birthday.cake"
        }
    }
}

enum ContactScope: Hashable {
    case active, untagged, noBirthday, archived
}

struct ContactCriteria: Hashable {
    var scope: ContactScope = .active
    var query = ""
    var tagID: UUID?

    func tags(in catalog: ContactTagCatalog) -> [ContactTag] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? [] : catalog.tags.filter { catalog.name(for: $0).localizedCaseInsensitiveContains(term) }
    }
}

enum ContactMapScope: Hashable {
    case filtered(ContactCriteria, category: String?)
    case person(UUID)

    var circles: ContactMapCircles {
        switch self {
        case .filtered(_, let category): return .category(category)
        case .person(let id): return .person(id)
        }
    }

    func criteria(in contacts: [UUID: Contact]) -> ContactCriteria {
        switch self {
        case .filtered(let criteria, _): return criteria
        case .person(let id): return ContactCriteria(scope: contacts[id]?.archived == true ? .archived : .active)
        }
    }
}

enum ContactRoute: Hashable {
    case person(UUID), category(String), members(UUID, ContactCriteria)
    case circleBirthdays(UUID, ContactCriteria), focusMap(UUID), focusBirthday(UUID)
    case mapResult(ContactMapSelection, ContactMapScope)
}

@MainActor
enum ContactDirectory {
    nonisolated static func nameOrder(_ first: Contact, _ second: Contact) -> Bool {
        let result = first.name.localizedStandardCompare(second.name)
        return result == .orderedSame ? first.id.uuidString < second.id.uuidString : result == .orderedAscending
    }

    static func people(_ store: PlannerStore, in criteria: ContactCriteria, circle: UUID? = nil) -> [Contact] {
        let index = store.contactIndex
        let catalog = store.tags
        let registered = Set(catalog.tags.map(\.id))
        let matchingTags = Set(criteria.tags(in: catalog).map(\.id))
        let term = criteria.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let people = circle.map { (index.members[$0] ?? []).compactMap { index.byID[$0] } } ?? Array(index.byID.values)
        return people.filter { person in
            guard person.archived == (criteria.scope == .archived) else { return false }
            let tags = person.tagIDs ?? []
            if let tag = criteria.tagID, !tags.contains(tag) { return false }
            switch criteria.scope {
            case .untagged: if tags.contains(where: registered.contains) { return false }
            case .noBirthday: if person.birthday != nil { return false }
            case .active, .archived: break
            }
            return term.isEmpty || tags.contains(where: matchingTags.contains)
                || (person.name + " " + person.details).localizedCaseInsensitiveContains(term)
        }.sorted(by: nameOrder)
    }
}

struct ContactsView: View {
    @EnvironmentObject private var store: PlannerStore
    @FocusState private var searchFocused: Bool
    @State private var criteria = ContactCriteria()
    @State private var searching = false
    @State private var editing: Contact?
    @State private var mode: ContactMode = .list
    @State private var visited: Set<ContactMode> = [.list]
    @State private var selection = ContactSelection()
    @State private var newCategory = false
    @State private var mapCategory: String?
    @State private var path: [ContactRoute] = []

    var body: some View {
        let people = ContactDirectory.people(store, in: criteria)
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if searching || !criteria.query.isEmpty { searchBar }
                if criteria.scope != .active || criteria.tagID != nil { filterBar }
                if !criteria.query.isEmpty { matchedTags }
                ZStack {
                    ForEach(ContactMode.allCases.filter(visited.contains)) { panel in
                        content(for: panel, people: people)
                            .opacity(panel == mode ? 1 : 0)
                            .allowsHitTesting(panel == mode)
                            .accessibilityHidden(panel != mode)
                            .zIndex(panel == mode ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { controls }
            .navigationDestination(for: ContactRoute.self, destination: destination)
            .sheet(item: $editing) { ContactEditor(initial: $0, isNew: true) { push(.person($0)) } }
            .sheet(isPresented: $newCategory) { TagCategoryEditor() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { PlannerNotice() }
        .onChange(of: criteria) { _, _ in selection.ids.removeAll() }
        .onChange(of: path) { _, _ in selection = ContactSelection() }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Menu {
                ForEach(ContactMode.allCases) { choice in
                    Button { show(choice) } label: { Label(choice.rawValue, systemImage: choice == mode ? "checkmark" : choice.symbol) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(mode.rawValue).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }.accessibilityLabel("人脈檢視，\(mode.rawValue)")
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("搜尋人或標籤", systemImage: "magnifyingglass") {
                    searching = true
                    Task { @MainActor in searchFocused = true }
                }
                Section("篩選") {
                    filter("全部聯絡人", .active)
                    filter("未加標籤", .untagged)
                    filter("未填生日", .noBirthday)
                    filter("已封存", .archived)
                }
                if mode == .list || mode == .birthday {
                    Button(selection.active ? "取消選取" : "選取", systemImage: "checkmark.circle") {
                        selection = ContactSelection(active: !selection.active)
                    }
                }
                if mode == .map {
                    Picker("全圖分類", selection: $mapCategory) {
                        Text("所有分類").tag(nil as String?)
                        ForEach(store.tags.categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityLabel("搜尋、篩選與選取")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { editing = Contact() } label: { Image(systemName: "plus") }.accessibilityLabel("新增聯絡人")
        }
    }

    private func filter(_ title: String, _ scope: ContactScope) -> some View {
        Button { criteria.scope = scope; criteria.tagID = nil } label: {
            if criteria.scope == scope { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋聯絡人或標籤", text: $criteria.query).focused($searchFocused)
                .submitLabel(.search).onSubmit { searchFocused = false }
            Button("取消") { criteria.query = ""; searching = false; searchFocused = false }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack {
            if criteria.scope != .active {
                filterChip(filterTitle, color: .plannerAccent) { criteria.scope = .active }
            }
            if let id = criteria.tagID, let tag = store.tags.tags.first(where: { $0.id == id }) {
                filterChip(store.tags.name(for: tag), color: TagPalette.color(store.tags.category(for: tag)?.color ?? "")) {
                    criteria.tagID = nil
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func filterChip(_ title: String, color: Color, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            Label(title, systemImage: "xmark.circle.fill").font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(color.opacity(0.12), in: Capsule()).foregroundStyle(color)
        }.accessibilityLabel("清除篩選，\(title)")
    }

    private var filterTitle: String {
        switch criteria.scope {
        case .active: return "全部聯絡人"
        case .untagged: return "未加標籤"
        case .noBirthday: return "未填生日"
        case .archived: return "已封存"
        }
    }

    private var matchedTags: some View {
        let tags = criteria.tags(in: store.tags)
        return Group {
            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(tags) { tag in
                            Button {
                                searchFocused = false
                                criteria = ContactCriteria(scope: criteria.scope == .archived ? .archived : .active, tagID: tag.id)
                                searching = false
                                push(.members(tag.id, criteria))
                            } label: { ContactTagLabel(tag: tag) }.buttonStyle(.bordered)
                        }
                    }.padding(.horizontal, 16)
                }.scrollIndicators(.hidden).padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder private func content(for panel: ContactMode, people: [Contact]) -> some View {
        switch panel {
        case .list:
            ContactPeopleList(people: people, offersBirthdayFill: criteria.scope == .noBirthday, selection: $selection)
        case .birthday:
            ContactPeopleList(people: people, birthdays: true, selection: $selection)
        case .tags:
            categories
        case .map:
            setMap(people: people, scope: .filtered(criteria, category: mapCategory))
        }
    }

    private var categories: some View {
        let untagged = ContactDirectory.people(store, in: ContactCriteria(scope: .untagged))
        return ScrollView {
            VStack(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(store.tags.categories) { category in
                        NavigationLink(value: ContactRoute.category(category.id)) {
                            card(category.name, icon: "tag", color: TagPalette.color(category.color))
                        }.buttonStyle(.plain)
                    }
                    Button { newCategory = true } label: { card("新增分類", icon: "plus", color: .secondary) }.buttonStyle(.plain)
                }
                Button {
                    criteria = ContactCriteria(scope: .untagged)
                    show(.list)
                } label: {
                    HStack {
                        Label("未加標籤", systemImage: "tag")
                        Spacer()
                        Text("\(untagged.count) 人").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(14).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }.padding(16)
        }
    }

    private func card(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon).font(.headline).foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func setMap(people: [Contact], scope: ContactMapScope) -> some View {
        let index = store.contactIndex
        let tags = scope.circles.tagIDs(in: store.tags, contacts: index.byID)
        let map = ContactSetMap(universe: Set(people.map(\.id)), tags: tags, memberships: index.members)
        let tagScope = ContactCriteria(scope: scope.criteria(in: index.byID).scope == .archived ? .archived : .active)
        return ContactSetMapView(map: map, catalog: store.tags, openTag: {
            push(.members($0, tagScope))
        }, openResult: {
            push(.mapResult($0, scope))
        })
    }

    private func push(_ route: ContactRoute) { path.append(route) }

    private func show(_ choice: ContactMode) {
        guard choice != mode else { return }
        selection = ContactSelection()
        mode = choice
        visited.insert(choice)
        searchFocused = false
    }

    @ViewBuilder private func destination(_ route: ContactRoute) -> some View {
        switch route {
        case .person(let id):
            ContactDetailView(contactID: id)
        case .category(let id):
            TagCategoryView(categoryID: id, criteria: criteria)
        case .members(let id, let scope):
            TagMembers(tagID: id, criteria: scope)
        case .circleBirthdays(let id, let scope):
            ScopedBirthdays(title: "\(store.tags.tags.first { $0.id == id }?.name ?? "這個圈")的生日",
                            people: ContactDirectory.people(store, in: scope, circle: id))
        case .focusBirthday(let id):
            ScopedBirthdays(title: store.contact(id)?.name ?? "生日", people: [store.contact(id)].compactMap { $0 })
        case .focusMap(let id):
            if let person = store.contact(id) {
                let scope = ContactMapScope.person(id)
                let criteria = scope.criteria(in: store.contactIndex.byID)
                setMap(people: ContactDirectory.people(store, in: criteria), scope: scope)
                    .navigationTitle("\(person.name)的圈子").navigationBarTitleDisplayMode(.inline)
            }
        case .mapResult(let filter, let scope):
            let index = store.contactIndex
            let universe = ContactDirectory.people(store, in: scope.criteria(in: index.byID))
            let tags = scope.circles.tagIDs(in: store.tags, contacts: index.byID)
            let ids = ContactSetMap.people(for: filter, in: Set(universe.map(\.id)), tags: tags, memberships: index.members)
            ContactSetResults(title: resultTitle(filter), excludesOtherCircles: isExact(filter),
                              people: universe.filter { ids.contains($0.id) })
        }
    }
    private func resultTitle(_ selection: ContactMapSelection) -> String {
        switch selection {
        case .union: return "圈內聯集"
        case .outside: return "不在圖中任何圈"
        case .exact(let tags):
            let catalog = store.tags
            let names = Dictionary(uniqueKeysWithValues: catalog.tags.map { ($0.id, catalog.name(for: $0)) })
            return "只在 " + tags.compactMap { names[$0] }.joined(separator: " ＋ ")
        }
    }

    private func isExact(_ selection: ContactMapSelection) -> Bool {
        if case .exact = selection { return true }
        return false
    }
}

private struct ScopedBirthdays: View {
    let title: String
    let people: [Contact]
    @State private var selection = ContactSelection()

    var body: some View {
        ContactPeopleList(people: people, birthdays: true, selection: $selection)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(selection.active ? "取消選取" : "選取") { selection = ContactSelection(active: !selection.active) } }
    }
}
