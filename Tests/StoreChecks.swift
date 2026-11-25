import SwiftUI

@main
struct StoreChecks {
    @MainActor
    static func main() throws {
        let suite = "PlannerChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyID = UUID()
        let legacy = Data("[{\"id\":\"\(legacyID.uuidString)\",\"text\":\"原任務\",\"done\":false}]".utf8)
        defaults.set(legacy, forKey: "tasks")
        let store = PlannerStore(defaults: defaults)
        precondition(store.tasks.first?.id == legacyID)
        precondition(defaults.data(forKey: "tasks") == legacy, "Loading must not rewrite legacy bytes")

        var task = store.tasks[0]
        task.notes = "新備註"
        precondition(store.save(task))
        let reloaded = PlannerStore(defaults: defaults)
        precondition(reloaded.tasks[0].notes == "新備註" && reloaded.tasks[0].id == legacyID)

        var contact = PlannerContact()
        contact.text = "Hank"
        precondition(store.save(contact))
        task.contactIDs = [contact.id]
        precondition(store.save(task))
        store.toggle(task)
        precondition(store.tasks[0].done && store.tasks[0].completedAt != nil)
        precondition(store.deleteContact(contact.id))
        precondition(store.tasks[0].text == "原任務", "Deleting contact cannot delete tasks")

        for number in 1...3 {
            var priority = PlanTask()
            priority.text = "重點 \(number)"
            priority.isPriority = true
            precondition(store.save(priority))
        }
        var fourth = PlanTask()
        fourth.text = "第四件"
        fourth.isPriority = true
        precondition(!store.save(fourth), "Reject a fourth priority")
        precondition(!store.tasks.contains { $0.id == fourth.id })

        let invalid = Data("invalid JSON".utf8)
        defaults.set(invalid, forKey: "journal")
        let protectedStore = PlannerStore(defaults: defaults)
        precondition(protectedStore.errorMessage != nil)
        var entry = JournalEntry()
        entry.text = "不能覆蓋原始資料"
        precondition(!protectedStore.save(entry))
        precondition(defaults.data(forKey: "journal") == invalid)
        print("Passed store migration, persistence, priority, and corruption checks.")
    }
}
