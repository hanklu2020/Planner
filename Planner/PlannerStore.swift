import SwiftUI

@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var tasks: [PlanTask] = []
    @Published private(set) var journal: [JournalEntry] = []
    @Published private(set) var contacts: [PlannerContact] = []
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private var unreadableKeys: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tasks = load("tasks")
        journal = load("journal")
        contacts = load("contacts")
    }

    private func load<T: Decodable>(_ key: String) -> [T] {
        guard let data = defaults.data(forKey: key), !data.isEmpty else { return [] }
        do { return try JSONDecoder().decode([T].self, from: data) }
        catch {
            unreadableKeys.insert(key)
            errorMessage = "部分原有資料無法讀取，已保留原始內容並停止寫入該類資料。請勿刪除 App。"
            return []
        }
    }

    private func write<T: Encodable>(_ rows: [T], key: String) -> Bool {
        guard !unreadableKeys.contains(key) else {
            errorMessage = "這類資料讀取失敗，為保留原始內容，暫時無法修改。"
            return false
        }
        do {
            defaults.set(try JSONEncoder().encode(rows), forKey: key)
            return true
        } catch {
            errorMessage = "資料無法儲存，請保留目前畫面並稍後再試。"
            return false
        }
    }

    @discardableResult
    func save(_ task: PlanTask) -> Bool {
        let value = TaskRules.normalized(task, previous: tasks.first { $0.id == task.id }, now: Date())
        guard !value.text.isEmpty else { return false }
        guard !value.isPriority || value.done || TaskRules.priorityCount(in: tasks, for: value) < 3 else {
            errorMessage = "同一天最多設定三件未完成的今日重點。"
            return false
        }
        let rows = replacing(value, in: tasks)
        guard write(rows, key: "tasks") else { return false }
        tasks = rows
        return true
    }

    func toggle(_ task: PlanTask) {
        var value = task
        value.done.toggle()
        save(value)
    }

    @discardableResult
    func save(_ entry: JournalEntry) -> Bool {
        var value = entry
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.text.isEmpty else { return false }
        let rows = replacing(value, in: journal)
        guard write(rows, key: "journal") else { return false }
        journal = rows
        return true
    }

    @discardableResult
    func save(_ contact: PlannerContact) -> Bool {
        var value = contact
        value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.text.isEmpty else { return false }
        let rows = replacing(value, in: contacts)
        guard write(rows, key: "contacts") else { return false }
        contacts = rows
        return true
    }

    @discardableResult
    func deleteTask(_ id: UUID) -> Bool {
        let rows = tasks.filter { $0.id != id }
        guard write(rows, key: "tasks") else { return false }
        tasks = rows
        return true
    }

    @discardableResult
    func deleteEntry(_ id: UUID) -> Bool {
        let rows = journal.filter { $0.id != id }
        guard write(rows, key: "journal") else { return false }
        journal = rows
        return true
    }

    @discardableResult
    func deleteContact(_ id: UUID) -> Bool {
        let rows = contacts.filter { $0.id != id }
        guard write(rows, key: "contacts") else { return false }
        contacts = rows
        // Task text stays intact. References to missing contacts are hidden in the UI.
        return true
    }

    private func replacing<T: Identifiable>(_ value: T, in rows: [T]) -> [T] {
        if let index = rows.firstIndex(where: { $0.id == value.id }) {
            var result = rows
            result[index] = value
            return result
        }
        return rows + [value]
    }

    func tasks(in scale: PlanScale, at date: Date) -> [PlanTask] {
        tasks.filter { $0.scale == scale && PlannerDates.contains($0.date, in: scale, at: date) }
            .sorted {
                if $0.done != $1.done { return !$0.done }
                if $0.isPriority != $1.isPriority { return $0.isPriority }
                return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
            }
    }

    func contactNames(for task: PlanTask) -> String {
        contacts.filter { task.contactIDs.contains($0.id) }.map(\.text).joined(separator: "、")
    }
}
