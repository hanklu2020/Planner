import SwiftUI

struct BirthdayDraft {
    var enabled: Bool
    var month: Int
    var day: Int
    var year: String

    init(_ birthday: ContactBirthday?) {
        enabled = birthday != nil
        month = birthday?.month ?? 1
        day = birthday?.day ?? 1
        year = birthday?.year.map { String($0) } ?? ""
    }

    var value: ContactBirthday? {
        guard enabled else { return nil }
        let number = Int(year)
        guard year.isEmpty || number.map({ $0 <= PlannerDates.calendar.component(.year, from: Date()) }) == true else { return nil }
        return ContactBirthday(month: month, day: day, year: number)
    }

    var isValid: Bool { !enabled || value != nil }
}

struct BirthdayFields: View {
    @Binding var draft: BirthdayDraft

    var body: some View {
        Toggle("生日", isOn: $draft.enabled)
        if draft.enabled {
            HStack {
                Picker("月", selection: $draft.month) {
                    ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) }
                }
                Picker("日", selection: $draft.day) {
                    ForEach(1...ContactBirthday.days(in: draft.month), id: \.self) { Text("\($0) 日").tag($0) }
                }
            }.pickerStyle(.menu)
            .onChange(of: draft.month) { _, month in draft.day = min(draft.day, ContactBirthday.days(in: month)) }
            TextField("出生年（選填）", text: $draft.year).keyboardType(.numberPad)
            if !draft.isValid { Text("請輸入有效的生日。").font(.caption).foregroundStyle(.red) }
        }
    }
}

struct ContactEditor: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var value: Contact
    @State private var birthday: BirthdayDraft
    @State private var more = false
    @State private var saving = false
    @State private var confirmingDuplicate = false
    let isNew: Bool
    var openExisting: ((UUID) -> Void)?

    init(initial: Contact, isNew: Bool = false, openExisting: ((UUID) -> Void)? = nil) {
        _value = State(initialValue: initial)
        _birthday = State(initialValue: BirthdayDraft(initial.birthday))
        self.isNew = isNew
        self.openExisting = openExisting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名", text: $value.name).focused($nameFocused)
                        .submitLabel(.done).onSubmit(submit).accessibilityIdentifier("contactName")
                    if isNew { DisclosureGroup("更多資料", isExpanded: $more) { fields } }
                    else { fields }
                }
                if !isNew || more {
                    Section {
                        Toggle("保留長期紀錄", isOn: $value.keepHistory)
                        Toggle("封存聯絡人", isOn: $value.archived)
                    }
                }
            }
            .plannerErrors()
            .navigationTitle(isNew ? "新增聯絡人" : "編輯聯絡人").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存", action: submit).disabled(cleanName.isEmpty || !birthday.isValid || saving)
                        .accessibilityIdentifier("saveContact")
                }
            }
            .task { if isNew && value.name.isEmpty { nameFocused = true } }
            .confirmationDialog("已有同名聯絡人", isPresented: $confirmingDuplicate, titleVisibility: .visible) {
                if openExisting != nil {
                    ForEach(duplicates.prefix(3)) { person in
                        Button("查看 \(describe(person))") {
                            dismiss()
                            openExisting?(person.id)
                        }
                    }
                }
                Button("仍要新增") { save() }
                Button("取消", role: .cancel) { }
            } message: { Text(duplicates.prefix(3).map(describe).joined(separator: "\n")) }
            .interactiveDismissDisabled(saving)
        }
    }

    private var fields: some View {
        Group {
            TextField("聯絡方式或備註（選填）", text: $value.details, axis: .vertical).lineLimit(2...5)
            BirthdayFields(draft: $birthday)
        }
    }

    private var cleanName: String { value.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var duplicates: [Contact] {
        store.contactIndex.byID.values.filter { $0.id != value.id && $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }
            .sorted(by: ContactDirectory.nameOrder)
    }

    private func describe(_ person: Contact) -> String {
        let tags = store.tags.tags.filter { person.tagIDs?.contains($0.id) == true }.prefix(2).map { store.tags.name(for: $0) }
        let detail = tags.isEmpty ? person.details : tags.joined(separator: "、")
        return detail.isEmpty ? person.name : "\(person.name) · \(detail.prefix(70))"
    }

    private func submit() {
        guard !cleanName.isEmpty, birthday.isValid, !saving else { return }
        if isNew && !duplicates.isEmpty { confirmingDuplicate = true }
        else { save() }
    }

    private func save() {
        saving = true
        value.birthday = birthday.value
        Task {
            defer { saving = false }
            if store.saveContact(value) {
                await store.flush()
                if !store.saveFailed { dismiss() }
            }
        }
    }
}

struct BirthdayQueue: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let ids: [UUID]
    @State private var position = 0
    @State private var saving = false

    var body: some View {
        NavigationStack {
            if let id = ids.indices.contains(position) ? ids[position] : nil, let contact = store.contact(id) {
                BirthdayForm(contact: contact, next: position + 1 < ids.count, saving: $saving,
                             submit: { save($0, id: id, advance: $1) }, close: { dismiss() })
                    .id(id)
            } else {
                ContentUnavailableView("沒有待編輯的聯絡人", systemImage: "birthday.cake")
                    .toolbar { Button("完成") { dismiss() } }
            }
        }.interactiveDismissDisabled(saving)
    }

    private func save(_ birthday: ContactBirthday?, id: UUID, advance: Bool) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            guard store.setBirthday(birthday, for: id) else { return }
            await store.flush()
            guard !store.saveFailed else { return }
            if advance { position += 1 }
            else { dismiss() }
        }
    }
}

private struct BirthdayForm: View {
    let contact: Contact
    let next: Bool
    @Binding var saving: Bool
    let submit: (ContactBirthday?, Bool) -> Void
    let close: () -> Void
    @State private var draft: BirthdayDraft

    init(contact: Contact, next: Bool, saving: Binding<Bool>, submit: @escaping (ContactBirthday?, Bool) -> Void, close: @escaping () -> Void) {
        self.contact = contact; self.next = next; _saving = saving; self.submit = submit; self.close = close
        var draft = BirthdayDraft(contact.birthday)
        draft.enabled = true
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Form {
            BirthdayFields(draft: $draft)
            if next { Button("儲存並編輯下一位") { submit(draft.value, true) }.disabled(saving || draft.value == nil) }
        }
        .plannerErrors()
        .navigationTitle(contact.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: close).disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") { submit(draft.value, false) }.disabled(saving || !draft.isValid)
            }
        }
    }
}
