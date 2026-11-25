import SwiftUI

struct ContactSelection {
    var active = false
    var ids: Set<UUID> = []

    mutating func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }
}

struct ContactPeopleList: View {
    @EnvironmentObject private var store: PlannerStore
    let people: [Contact]
    var birthdays = false
    var circle: UUID?
    var offersBirthdayFill = false
    @Binding var selection: ContactSelection
    @State private var batch: TagBatch?
    @State private var birthdayQueue: BirthdayTargets?
    @State private var confirm: ContactBatchAction?

    var body: some View {
        let today = PlannerDates.calendar.startOfDay(for: Date())
        let upcoming = birthdays ? BirthdayOccurrence.upcoming(for: people, on: today) : []
        let visible = birthdays ? upcoming.map(\.person) : people
        List {
            if offersBirthdayFill && !people.isEmpty && !selection.active {
                birthdayFillButton(people.map(\.id))
            }
            if birthdays { birthdayRows(upcoming, today: today) }
            else if people.isEmpty {
                EmptyMessage(title: circle == nil ? "沒有符合的聯絡人" : "沒有符合的成員",
                             symbol: "person.2", detail: circle == nil ? "可以調整篩選或新增聯絡人。" : "可以從右上角加入成員。")
            } else {
                ForEach(people) { row($0) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selection.active { selectionBar(visible: visible) }
        }
        .sheet(item: $batch, onDismiss: { selection.ids.removeAll() }) { TagBatchPicker(batch: $0) }
        .sheet(item: $birthdayQueue) { BirthdayQueue(ids: $0.ids) }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { action in
            Button(action.title, role: action.isDestructive ? .destructive : nil) { apply(action) }
            Button("取消", role: .cancel) { }
        }
        .onChange(of: Set(visible.map(\.id))) { _, ids in selection.ids.formIntersection(ids) }
    }

    @ViewBuilder private func birthdayRows(_ upcoming: [BirthdayOccurrence], today: Date) -> some View {
        if upcoming.isEmpty {
            let missing = people.filter { $0.birthday == nil }.map(\.id)
            if missing.isEmpty {
                EmptyMessage(title: "沒有符合的生日", symbol: "birthday.cake", detail: "可以調整目前的搜尋或篩選。")
            } else {
                Section {
                    birthdayFillButton(missing)
                } header: { Text("這份名單還沒有生日") }
            }
        } else {
            let calendar = PlannerDates.calendar
            let grouped = Dictionary(grouping: upcoming.filter { $0.date != today }, by: { PlannerDates.start($0.date, .month, calendar: calendar) })
            let todayRows = upcoming.filter { $0.date == today }
            if !todayRows.isEmpty {
                Section("今天生日") { ForEach(todayRows) { row($0.person, date: $0.date) } }
            }
            ForEach(grouped.keys.sorted(), id: \.self) { month in
                Section(PlannerDates.text(month, "yyyy 年 M 月")) {
                    ForEach(grouped[month] ?? []) { row($0.person, date: $0.date) }
                }
            }
        }
    }

    private func birthdayFillButton(_ ids: [UUID]) -> some View {
        Button("填寫生日 · \(ids.count) 人", systemImage: "birthday.cake") {
            birthdayQueue = BirthdayTargets(ids: ids)
        }
    }

    @ViewBuilder private func row(_ person: Contact, date: Date? = nil) -> some View {
        if selection.active {
            Button { selection.toggle(person.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection.ids.contains(person.id) ? "checkmark.circle.fill" : "circle")
                    personLabel(person, date: date)
                }
            }.accessibilityAddTraits(selection.ids.contains(person.id) ? .isSelected : [])
        } else {
            NavigationLink(value: ContactRoute.person(person.id)) { personLabel(person, date: date) }
                .swipeActions(allowsFullSwipe: false) {
                    if let circle {
                        Button("移出", role: .destructive) { store.changeTags([circle], for: [person.id], adding: false) }
                    }
                }
        }
    }

    private func personLabel(_ person: Contact, date: Date?) -> some View {
        HStack(spacing: 14) {
            if let date {
                Text(PlannerDates.text(date, "M/d")).monospacedDigit().font(.subheadline)
                    .foregroundStyle(Color.plannerAccent).frame(minWidth: 36, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).foregroundStyle(.primary)
                if date == nil {
                    let summary = store.contactIndex.latest[person.id] ?? person.details
                    if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }

    private func selectionBar(visible: [Contact]) -> some View {
        HStack {
            Menu("已選 \(selection.ids.count) 人") {
                Button("全選目前 \(visible.count) 人") { selection.ids = Set(visible.map(\.id)) }
                    .disabled(visible.isEmpty)
                Button("清除選取") { selection.ids.removeAll() }.disabled(selection.ids.isEmpty)
            }
            Spacer()
            if let circle {
                Button("移出 \(selection.ids.count) 人", role: .destructive) { confirm = .leave(circle) }
                    .disabled(selection.ids.isEmpty)
            } else {
                Button("加標籤") { batch = TagBatch(people: selection.ids, adding: true) }.disabled(selection.ids.isEmpty)
            }
            Menu("更多") {
                if circle != nil { Button("加標籤") { batch = TagBatch(people: selection.ids, adding: true) } }
                Button("移除指定標籤") { batch = TagBatch(people: selection.ids, adding: false) }
                ForEach(ContactBatchAction.options) { action in
                    Button(action.title, role: action.isDestructive ? .destructive : nil) { confirm = action }
                        .disabled(affected(action).isEmpty)
                }
            }.disabled(selection.ids.isEmpty)
        }.font(.subheadline).padding(13).background(.regularMaterial)
    }

    private var confirmationTitle: String {
        guard let confirm else { return "" }
        return "\(confirm.title) · \(affected(confirm).count) 人？"
    }

    private func affected(_ action: ContactBatchAction) -> Set<UUID> {
        switch action {
        case .clear: return Set(selection.ids.filter { store.contact($0)?.tagIDs?.isEmpty == false })
        case .leave(let id): return selection.ids.intersection(store.contactIndex.members[id] ?? [])
        case .history(let status): return store.contactsChanging(\.keepHistory, to: status, among: selection.ids)
        case .archive(let status): return store.contactsChanging(\.archived, to: status, among: selection.ids)
        }
    }

    private func apply(_ action: ContactBatchAction) {
        let ids = affected(action)
        switch action {
        case .clear: store.clearTags(for: ids)
        case .leave(let tag): store.changeTags([tag], for: ids, adding: false)
        case .history(let status): store.setContacts(\.keepHistory, to: status, among: ids)
        case .archive(let status): store.setContacts(\.archived, to: status, among: ids)
        }
        selection.ids.removeAll()
    }
}

private struct BirthdayTargets: Identifiable {
    let id = UUID()
    let ids: [UUID]
}

private enum ContactBatchAction: Identifiable {
    case clear, history(Bool), archive(Bool), leave(UUID)

    static let options: [Self] = [.clear, .history(true), .history(false), .archive(true), .archive(false)]

    var id: String { title }
    var isDestructive: Bool {
        switch self { case .clear, .leave: return true; default: return false }
    }
    var title: String {
        switch self {
        case .clear: return "清除全部標籤"
        case .history(let value): return value ? "保留長期紀錄" : "取消保留長期紀錄"
        case .archive(let value): return value ? "封存聯絡人" : "取消封存"
        case .leave: return "移出成員"
        }
    }
}
