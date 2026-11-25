import Foundation

struct ContactTagCategory: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var color: String
}

struct ContactTag: Codable, Identifiable, Equatable {
    var id = UUID()
    var categoryID: String
    var name: String
}

struct ContactTagCatalog: Codable, Equatable {
    var categories: [ContactTagCategory] = [
        .init(id: "family", name: "家庭", color: "C07896"),
        .init(id: "church", name: "教會", color: "8072BE"),
        .init(id: "work", name: "工作", color: "467EAF"),
        .init(id: "country", name: "國家", color: "528B72"),
        .init(id: "wealth", name: "高資產", color: "B88445")
    ]
    var tags: [ContactTag] = []

    var isValid: Bool {
        let keys = Set(categories.map(\.id))
        return keys.count == categories.count && Set(tags.map(\.id)).count == tags.count
            && tags.allSatisfy { keys.contains($0.categoryID) }
    }

    func tags(in category: String) -> [ContactTag] { tags.filter { $0.categoryID == category } }
    func category(for tag: ContactTag) -> ContactTagCategory? { categories.first { $0.id == tag.categoryID } }
    func name(for tag: ContactTag) -> String { [category(for: tag)?.name, tag.name].compactMap { $0 }.joined(separator: "／") }
}

struct ContactTagIndex {
    private(set) var members: [UUID: Set<UUID>] = [:]
    private(set) var byID: [UUID: Contact] = [:]
    private(set) var latest: [UUID: String] = [:]

    mutating func update(from old: PlannerDocument?, to next: PlannerDocument) {
        if old?.contacts != next.contacts {
            let nextByID = Dictionary(uniqueKeysWithValues: next.contacts.map { ($0.id, $0) })
            for (id, oldContact) in byID where nextByID[id] != oldContact {
                for tag in oldContact.tagIDs ?? [] { members[tag]?.remove(id) }
            }
            for (id, newContact) in nextByID where byID[id] != newContact {
                for tag in newContact.tagIDs ?? [] { members[tag, default: []].insert(id) }
            }
            byID = nextByID
        }
        if old?.completions != next.completions || old?.interactions != next.interactions {
            var events: [UUID: (Date, String)] = [:]
            func add(_ id: UUID, _ date: Date, _ text: String) {
                if events[id].map({ $0.0 >= date }) != true { events[id] = (date, text) }
            }
            for entry in next.interactions { add(entry.contactID, entry.date, entry.text) }
            for entry in next.completions where entry.isVisible {
                for id in entry.contactIDs { add(id, entry.date, entry.title) }
            }
            latest = events.mapValues { $0.1 }
        }
    }
}

struct JournalSearchIndex {
    private(set) var entries: [UUID: (JournalEntry, String)] = [:]
    private(set) var completions: [UUID: (CompletionRecord, String)] = [:]

    mutating func update(from old: PlannerDocument?, to next: PlannerDocument) {
        if old?.journal != next.journal {
            let valid = Set(next.journal.map(\.id))
            entries = entries.filter { valid.contains($0.key) }
            for entry in next.journal where entries[entry.id]?.0 != entry {
                entries[entry.id] = (entry, Self.normalized(entry.text))
            }
        }
        if old?.completions != next.completions {
            let visible = next.completions.filter(\.appearsInJournal)
            let valid = Set(visible.map(\.id))
            completions = completions.filter { valid.contains($0.key) }
            for entry in visible where completions[entry.id]?.0 != entry {
                completions[entry.id] = (entry, Self.normalized(entry.title + "\n" + entry.text))
            }
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

struct ContactBirthday: Codable, Equatable {
    let month: Int
    let day: Int
    let year: Int?

    init?(month: Int, day: Int, year: Int? = nil) {
        guard (1...12).contains(month), year.map({ (1...9999).contains($0) }) ?? true else { return nil }
        guard (1...Self.days(in: month, year: year)).contains(day) else { return nil }
        self.month = month; self.day = day; self.year = year
    }

    init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let month = Int(parts[parts.count - 2]), let day = Int(parts[parts.count - 1]) else { return nil }
        let year = parts.count == 3 ? Int(parts[0]) : nil
        guard parts.count != 3 || year != nil else { return nil }
        self.init(month: month, day: day, year: year)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let month = try values.decode(Int.self, forKey: .month)
        let day = try values.decode(Int.self, forKey: .day)
        let year = try values.decodeIfPresent(Int.self, forKey: .year)
        guard let valid = Self(month: month, day: day, year: year) else {
            throw DecodingError.dataCorruptedError(forKey: .day, in: values, debugDescription: "Invalid birthday")
        }
        self = valid
    }

    private enum CodingKeys: String, CodingKey { case month, day, year }

    static func days(in month: Int, year: Int? = nil) -> Int {
        guard (1...12).contains(month) else { return 31 }
        let lengths = [31, isLeap(year ?? 2000) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return lengths[month - 1]
    }

    var text: String {
        let monthDay = String(format: "%02d-%02d", month, day)
        return year.map { String(format: "%04d-", $0) + monthDay } ?? monthDay
    }

    var title: String { year.map { "\($0) 年 \(month) 月 \(day) 日" } ?? "\(month) 月 \(day) 日" }

    func next(on date: Date, calendar: Calendar = PlannerDates.calendar) -> Date? {
        guard let birthday = Self(month: month, day: day, year: year) else { return nil }
        let today = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: today)
        func occurrence(_ year: Int) -> Date? {
            let day = birthday.month == 2 && birthday.day == 29 && !Self.isLeap(year) ? 28 : birthday.day
            return calendar.date(from: DateComponents(year: year, month: birthday.month, day: day))
        }
        guard let thisYear = occurrence(year) else { return nil }
        return thisYear >= today ? thisYear : occurrence(year + 1)
    }

    private static func isLeap(_ year: Int) -> Bool { year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400)) }
}

struct BirthdayOccurrence: Identifiable {
    let person: Contact
    let date: Date
    var id: UUID { person.id }

    static func upcoming(for contacts: [Contact], on date: Date = Date(), calendar: Calendar = PlannerDates.calendar) -> [Self] {
        contacts.compactMap { person -> Self? in
            guard let birthday = person.birthday, let next = birthday.next(on: date, calendar: calendar) else { return nil }
            return Self(person: person, date: next)
        }.sorted { left, right in
            if left.date != right.date { return left.date < right.date }
            let order = left.person.name.localizedStandardCompare(right.person.name)
            return order == .orderedSame ? left.id.uuidString < right.id.uuidString : order == .orderedAscending
        }
    }
}
