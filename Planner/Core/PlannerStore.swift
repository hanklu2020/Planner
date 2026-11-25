import SwiftUI

@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var data = PlannerDocument()
    @Published var error: String?
    @Published private(set) var recoveryRequired = false
    @Published var pendingGoalID: UUID?
    @Published var notice: String?
    @Published private(set) var canUndoSchedule = false
    private let disk: PlannerDisk
    private var scheduleUndo: [(id: UUID, schedule: Schedule?)] = []

    init(disk: PlannerDisk = .standard, defaults: UserDefaults = .standard) {
        self.disk = disk
        do {
            let loaded = try disk.load(defaults: defaults)
            try disk.save(loaded)
            data = loaded
        } catch {
            recoveryRequired = true
            self.error = "無法讀取原資料，已停止寫入以保留檔案。\n\(error.localizedDescription)"
        }
    }

    @discardableResult
    func commit(_ change: (inout PlannerDocument) -> Void) -> Bool {
        guard !recoveryRequired else { error = "請先從設定還原資料，再進行編輯。"; return false }
        var next = data
        change(&next)
        do { try disk.save(next); data = next; return true }
        catch { self.error = "未能儲存這次變更：\(error.localizedDescription)"; return false }
    }
    func task(_ id: UUID) -> PlannerTask? { data.tasks.first { $0.id == id } }
    func goal(_ id: UUID?) -> Goal? { data.goals.first { $0.id == id } }
    func contact(_ id: UUID) -> Contact? { data.contacts.first { $0.id == id } }
    func tasks(for goalID: UUID) -> [PlannerTask] { data.tasks.filter { $0.goalID == goalID && !$0.cancelled } }
    func progress(for goalID: UUID) -> String {
        let rows = tasks(for: goalID)
        return "任務完成 \(rows.filter(\.isDone).count)/\(rows.count)"
    }
    func nextTask(for goalID: UUID) -> PlannerTask? {
        tasks(for: goalID).filter(\.isOpen).sorted {
            ($0.schedule?.date ?? .distantFuture) < ($1.schedule?.date ?? .distantFuture)
        }.first
    }

    @discardableResult
    func saveGoal(_ value: Goal) -> Bool {
        var value = value
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { return false }
        if value.status == .achieved { value.achievedAt = value.achievedAt ?? Date() }
        else { value.achievedAt = nil }
        let success = commit { document in
            if let index = document.goals.firstIndex(where: { $0.id == value.id }) { document.goals[index] = value }
            else { document.goals.append(value) }
            for i in document.tasks.indices where document.tasks[i].goalID == value.id { document.tasks[i].domain = value.domain }
        }
        if success && value.status != .active && pendingGoalID == value.id { pendingGoalID = nil }
        return success
    }
    @discardableResult
    func saveTask(_ value: PlannerTask) -> Bool {
        var value = value
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { return false }
        value.steps.removeAll { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if value.cancelled { value.completedAt = nil; value.focusDate = nil }
        if let goal = goal(value.goalID) { value.domain = goal.domain }
        if let old = task(value.id) {
            value.planningHistory = old.planningHistory
            if old.schedule != value.schedule {
                value.planningHistory.append(PlanningChange(previous: old.schedule, next: value.schedule))
            }
        }
        let success = commit { document in
            if let index = document.tasks.firstIndex(where: { $0.id == value.id }) { document.tasks[index] = value }
            else { document.tasks.append(value) }
        }
        if success && !value.isDone && pendingGoalID == value.goalID { pendingGoalID = nil }
        return success
    }
    func moveTasks(for goalID: UUID, from offsets: IndexSet, to destination: Int) {
        _ = commit { document in
            let indices = document.tasks.indices.filter { document.tasks[$0].goalID == goalID && document.tasks[$0].isOpen }
            var tasks = indices.map { document.tasks[$0] }
            tasks.move(fromOffsets: offsets, toOffset: destination)
            for (index, task) in zip(indices, tasks) { document.tasks[index] = task }
        }
    }
    func toggleDone(_ id: UUID) {
        guard var value = task(id), !value.cancelled else { return }
        value.completedAt = value.isDone ? nil : Date()
        if value.isDone { for i in value.steps.indices { value.steps[i].done = true } }
        if saveTask(value), value.isDone { checkGoal(value.goalID) }
    }
    func toggleStep(_ taskID: UUID, stepID: UUID) {
        guard var value = task(taskID), let index = value.steps.firstIndex(where: { $0.id == stepID }), !value.cancelled else { return }
        value.steps[index].done.toggle()
        value.completedAt = value.steps.allSatisfy(\.done) ? (value.completedAt ?? Date()) : nil
        if saveTask(value), value.isDone { checkGoal(value.goalID) }
    }
    private func checkGoal(_ id: UUID?) {
        guard let id, let goal = goal(id), goal.status == .active else { return }
        let values = tasks(for: id)
        if !values.isEmpty && values.allSatisfy(\.isDone) { pendingGoalID = id }
    }
    @discardableResult
    func schedule(_ ids: [UUID], to value: Schedule?) -> Bool {
        let targets = data.tasks.filter { ids.contains($0.id) && $0.isOpen }
        let changed = targets.filter { $0.schedule != value }
        guard !changed.isEmpty else { return true }
        let previous = changed.map { (id: $0.id, schedule: $0.schedule) }
        let changedIDs = Set(changed.map(\.id))
        let success = commit { document in
            for i in document.tasks.indices where changedIDs.contains(document.tasks[i].id) {
                document.tasks[i].planningHistory.append(PlanningChange(previous: document.tasks[i].schedule, next: value))
                document.tasks[i].schedule = value
            }
        }
        if success {
            scheduleUndo = previous; canUndoSchedule = true
            notice = value.map { "已安排 \(changed.count) 項至 \($0.label)" } ?? "已將 \(changed.count) 項放回待安排"
        }
        return success
    }
    func undoSchedule() {
        guard canUndoSchedule else { return }
        let success = commit { document in
            for saved in scheduleUndo {
                guard let i = document.tasks.firstIndex(where: { $0.id == saved.id }) else { continue }
                document.tasks[i].planningHistory.append(PlanningChange(previous: document.tasks[i].schedule, next: saved.schedule))
                document.tasks[i].schedule = saved.schedule
            }
        }
        if success { clearUndo(); notice = "已復原日期安排" }
    }
    func clearUndo() { scheduleUndo = []; canUndoSchedule = false }
    func toggleFocus(_ id: UUID, on date: Date) {
        guard var task = task(id), task.isOpen, task.schedule?.scale == .day else { return }
        let calendar = PlannerDates.calendar
        if let current = task.focusDate, calendar.isDate(current, inSameDayAs: date) { task.focusDate = nil }
        else {
            let count = data.tasks.filter { $0.isOpen && $0.schedule?.appears(in: date, scale: .day) == true && $0.focusDate.map { calendar.isDate($0, inSameDayAs: date) } == true }.count
            guard count < 3 else { error = "這一天已選了三件重點，請先取消其中一件。"; return }
            task.focusDate = calendar.startOfDay(for: date)
        }
        _ = saveTask(task)
    }
    @discardableResult
    func saveJournal(_ entry: JournalEntry) -> Bool {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return commit { document in
            if let i = document.journal.firstIndex(where: { $0.id == entry.id }) { document.journal[i] = entry }
            else { document.journal.append(entry) }
        }
    }
    @discardableResult
    func saveContact(_ contact: Contact) -> Bool {
        var contact = contact; contact.name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.name.isEmpty else { return false }
        return commit { document in
            if let i = document.contacts.firstIndex(where: { $0.id == contact.id }) { document.contacts[i] = contact }
            else { document.contacts.append(contact) }
        }
    }
    @discardableResult
    func saveInteraction(_ entry: Interaction) -> Bool {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return commit { document in
            if let i = document.interactions.firstIndex(where: { $0.id == entry.id }) { document.interactions[i] = entry }
            else { document.interactions.append(entry) }
        }
    }
    @discardableResult
    func review(_ goalID: UUID, decision: String, note: String, status: GoalStatus? = nil) -> Bool {
        commit { document in
            document.reviews.append(GoalReview(goalID: goalID, note: note, decision: decision))
            if let status, let i = document.goals.firstIndex(where: { $0.id == goalID }) {
                document.goals[i].status = status
                document.goals[i].achievedAt = status == .achieved ? Date() : nil
            }
        }
    }
    func exportData() throws -> Data {
        guard !recoveryRequired else { throw PlannerError.invalidBackup("請先還原資料，避免匯出空白內容。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }
    @discardableResult
    func importData(_ bytes: Data) -> Bool {
        do {
            let imported = try PlannerDisk.decode(bytes)
            try disk.save(imported)
            data = imported; recoveryRequired = false; clearUndo(); pendingGoalID = nil
            notice = "資料已還原"; return true
        } catch { self.error = "無法還原：\(error.localizedDescription)"; return false }
    }
    func restorePrevious() {
        do { _ = importData(try Data(contentsOf: disk.backup)) }
        catch { self.error = "無法讀取上一份資料：\(error.localizedDescription)" }
    }
}
