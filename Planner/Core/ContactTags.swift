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
