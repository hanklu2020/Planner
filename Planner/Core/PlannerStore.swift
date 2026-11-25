import SwiftUI
import UIKit

@MainActor
final class PlannerStore: ObservableObject {
    @Published private(set) var data = PlannerDocument() {
        didSet {
            contactIndex.update(from: oldValue, to: data)
            journalIndex.update(from: oldValue, to: data)
        }
    }
    private(set) var contactIndex = ContactTagIndex()
    private(set) var journalIndex = JournalSearchIndex()
    var tags: ContactTagCatalog { data.tagCatalog ?? ContactTagCatalog() }
    @Published private(set) var recentTags: [UUID] = []
    @Published private(set) var canUndoChange = false
    private var changeUndo: (() -> Void)?
    private var undoToken = UUID()

    @Published var error: String?
    @Published private(set) var recoveryRequired = false
    @Published var pendingGoalID: UUID?
    @Published var notice: String?
    @Published private(set) var canUndoSchedule = false
    @Published private(set) var loading = false
    @Published private(set) var isSaving = false
    @Published private(set) var directory: URL?
    @Published var startupReason = ""
    @Published private(set) var saveFailed = false
    private let disk: PlannerDisk
    private let defaults: UserDefaults
    private let folderStorage: Bool
    private let files: FolderSession
    private var saveRevision = 0
    private var backgroundID: UIBackgroundTaskIdentifier = .invalid
    private var scheduleUndo: [(id: UUID, schedule: Schedule?, order: Int?)] = []

    init(folderStorage: Bool = true, disk: PlannerDisk = .standard, defaults: UserDefaults = .standard) {
        self.disk = disk; self.defaults = defaults; self.folderStorage = folderStorage
        self.files = FolderSession(legacy: disk, defaults: defaults)
        if folderStorage {
            loading = true
            Task { await openLastFolder() }
        } else {
            do { let loaded = try disk.load(defaults: defaults); try disk.save(loaded); data = loaded }
            catch { recoveryRequired = true; self.error = "無法讀取原資料：\(error.localizedDescription)" }
        }
    }
    private func rememberedDirectory() throws -> URL {
        if let relative = defaults.string(forKey: "Planner.folder.relative") {
            return relative.isEmpty ? MarkdownVault.defaultDirectory : MarkdownVault.defaultDirectory.appendingPathComponent(relative, isDirectory: true)
        }
        if let bytes = defaults.data(forKey: "Planner.folder.bookmark") {
            var stale = false
            let url = try URL(resolvingBookmarkData: bytes, options: .withoutUI, bookmarkDataIsStale: &stale)
            return url
        }
        return MarkdownVault.defaultDirectory
    }
    private func adopt(_ opened: OpenedFolder) throws {
        var bookmarkWarning: String?
        let root = MarkdownVault.defaultDirectory.standardizedFileURL.path
        let path = opened.directory.standardizedFileURL.path
        if path == root || path.hasPrefix(root + "/") {
            defaults.set(path == root ? "" : String(path.dropFirst(root.count + 1)), forKey: "Planner.folder.relative")
            defaults.removeObject(forKey: "Planner.folder.bookmark")
        } else {
            let scoped = opened.directory.startAccessingSecurityScopedResource()
            defer { if scoped { opened.directory.stopAccessingSecurityScopedResource() } }
            do {
                let bookmark = try opened.directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(bookmark, forKey: "Planner.folder.bookmark")
            } catch {
                defaults.set(Data(), forKey: "Planner.folder.bookmark")
                bookmarkWarning = "目前資料夾可用，但無法記住位置；下次開啟時請重新選擇。"
            }
            defaults.removeObject(forKey: "Planner.folder.relative")
        }
        data = opened.document; directory = opened.directory
        recoveryRequired = false; startupReason = ""; error = bookmarkWarning; saveFailed = false
        notice = opened.notice; clearUndo(); clearChangeUndo(); recentTags = []; pendingGoalID = nil
    }
    func openLastFolder() async {
        guard !isSaving else { return }
        loading = true
        defer { loading = false }
        do {
            let remembered = defaults.object(forKey: "Planner.folder.relative") != nil || defaults.data(forKey: "Planner.folder.bookmark") != nil
            try adopt(await files.open(rememberedDirectory(), migrateLegacy: !remembered))
        } catch { recoveryRequired = true; startupReason = error.localizedDescription }
    }
    func openFolder(_ url: URL) async {
        loading = true; defer { loading = false }
        do { try adopt(await files.open(url)) }
        catch { self.error = error.localizedDescription }
    }
    func startNew(in folder: URL? = nil) async {
        loading = true; defer { loading = false }
        do { try adopt(await files.create(in: folder ?? MarkdownVault.defaultDirectory)) }
        catch { self.error = error.localizedDescription }
    }
    func moveFolder(to folder: URL) async {
        guard !recoveryRequired else { return }
        loading = true; defer { loading = false }
        do { try adopt(await files.create(in: folder, document: data)); notice = "已切換儲存位置，原資料保留。" }
        catch { self.error = error.localizedDescription }
    }
    func backupFolder(to folder: URL) async {
        loading = true; defer { loading = false }
        do { _ = try await files.copy(data, to: folder); notice = "已另存完整備份。" }
        catch { self.error = error.localizedDescription }
    }
    func reloadFolder() async {
        loading = true; defer { loading = false }
        do { try adopt(await files.reload()) }
        catch { self.error = error.localizedDescription }
    }
    func flush() async {
        guard folderStorage else { return }
        do { try await files.flush(); isSaving = false; saveFailed = false }
        catch { self.error = "資料尚未儲存，請重試或先匯出備份：\(error.localizedDescription)"; saveFailed = true; isSaving = false }
    }
    func flushForBackground() {
        guard folderStorage, !recoveryRequired, backgroundID == .invalid else { return }
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Save Planner") { [weak self] in
            Task { @MainActor in self?.endBackgroundSave() }
        }
        Task { await flush(); endBackgroundSave() }
    }
    private func endBackgroundSave() {
        if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
    }
    @discardableResult
    func commit(_ change: (inout PlannerDocument) -> Void) -> Bool {
        guard !recoveryRequired, !loading else { error = "請先選擇資料夾或重新開始。"; return false }
        var next = data; change(&next)
        next.captureCompletions()
        do {
            _ = try next.validated()
            if folderStorage {
                let urgent = data.journal != next.journal || data.contacts != next.contacts || data.interactions != next.interactions || data.completions != next.completions
                data = next; isSaving = true; saveRevision += 1
                let revision = saveRevision
                files.enqueue(next, urgent: urgent) { [weak self] failure in
                    guard let self, self.saveRevision == revision else { return }
                    self.isSaving = false; self.saveFailed = failure != nil
                    if let failure { self.error = "資料尚未儲存，內容仍保留在畫面中。\n\(failure)" }
                }
            } else { try disk.save(next); data = next }
            return true
        } catch { self.error = "未能儲存：\(error.localizedDescription)"; return false }
    }
    func task(_ id: UUID) -> PlannerTask? { data.tasks.first { $0.id == id } }
    func goal(_ id: UUID?) -> Goal? { data.goals.first { $0.id == id } }
    func contact(_ id: UUID) -> Contact? { contactIndex.byID[id] }
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
        let distinct = Domain.allCases.filter { value.domains.contains($0) && $0 != value.domain }
        value.extraDomains = distinct.isEmpty ? nil : distinct
        var order: [String: Int] = [:]
        for domain in value.domains {
            if let rank = value.domainOrder?[domain.rawValue] { order[domain.rawValue] = rank }
            else if !data.goals.contains(where: { $0.id == value.id && $0.domains.contains(domain) }) {
                let peers = data.goals.enumerated().filter { $0.element.domains.contains(domain) }
                order[domain.rawValue] = (peers.map { $0.element.domainOrder?[domain.rawValue] ?? $0.offset }.max() ?? -1) + 1
            }
        }
        value.domainOrder = order.isEmpty ? nil : order
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
        let old = task(value.id)
        if let old {
            value.planOrder = old.planOrder
            value.planningHistory = old.planningHistory
            if old.schedule != value.schedule {
                value.planningHistory.append(PlanningChange(previous: old.schedule, next: value.schedule))
            }
        }
        let success = commit { document in
            if old == nil || old?.schedule != value.schedule {
                value.planOrder = Self.appendOrder(in: document, schedule: value.schedule)
            }
            if let date = old?.completedAt, value.completedAt == nil {
                for i in document.completions.indices where document.completions[i].taskID == value.id
                    && abs(document.completions[i].date.timeIntervalSince(date)) < 1 {
                    document.completions[i].withdrawn = true
                }
            }
            if let index = document.tasks.firstIndex(where: { $0.id == value.id }) { document.tasks[index] = value }
            else { document.tasks.append(value) }
        }
        if success && !value.isDone && pendingGoalID == value.goalID { pendingGoalID = nil }
        if success && value.isDone { checkGoal(value.goalID) }
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
        let requested = Set(ids)
        let targets = data.tasks.filter { requested.contains($0.id) && $0.isOpen }
        let changed = targets.filter { $0.schedule != value }
        guard !changed.isEmpty else { return true }
        let previous = changed.map { (id: $0.id, schedule: $0.schedule, order: $0.planOrder) }
        let changedIDs = Set(changed.map(\.id))
        let success = commit { document in
            for i in document.tasks.indices where changedIDs.contains(document.tasks[i].id) {
                document.tasks[i].planningHistory.append(PlanningChange(previous: document.tasks[i].schedule, next: value))
                document.tasks[i].planOrder = Self.appendOrder(in: document, schedule: value)
                document.tasks[i].schedule = value
            }
        }
        if success {
            clearChangeUndo()
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
                document.tasks[i].planOrder = saved.order
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
    func goals(in domain: Domain, active: Bool) -> [Goal] {
        data.goals.enumerated().filter { $0.element.domains.contains(domain) && ($0.element.status == .active) == active }
            .sorted { a, b in
                let x = a.element.domainOrder?[domain.rawValue] ?? a.offset
                let y = b.element.domainOrder?[domain.rawValue] ?? b.offset
                return x == y ? a.offset < b.offset : x < y
            }.map(\.element)
    }

    func moveGoals(_ rows: [Goal], in domain: Domain, from offsets: IndexSet, to destination: Int) {
        guard let first = rows.first else { return }
        var ids = rows.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        let active = first.status == .active
        let others = goals(in: domain, active: !active).map(\.id)
        let ordered = active ? ids + others : others + ids
        let positions = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
        commit { document in
            for i in document.goals.indices {
                if let order = positions[document.goals[i].id] {
                    var map = document.goals[i].domainOrder ?? [:]
                    map[domain.rawValue] = order
                    document.goals[i].domainOrder = map
                }
            }
        }
    }

    func deleteGoal(_ id: UUID) {
        if commit({ document in
            document.goals.removeAll { $0.id == id }
            document.reviews.removeAll { $0.goalID == id }
            for i in document.tasks.indices where document.tasks[i].goalID == id { document.tasks[i].goalID = nil }
        }), pendingGoalID == id { pendingGoalID = nil }
    }

    func deleteTask(_ id: UUID) {
        let goalID = task(id)?.goalID
        if commit({ $0.tasks.removeAll { $0.id == id } }), pendingGoalID == goalID { pendingGoalID = nil }
    }

    private static func appendOrder(in document: PlannerDocument, schedule: Schedule?) -> Int {
        (document.tasks.lazy.filter { $0.schedule == schedule }.compactMap(\.planOrder).max() ?? 0) + 1
    }

    func movePlanTasks(_ rows: [PlannerTask], from offsets: IndexSet, to destination: Int) {
        guard let first = rows.first else { return }
        let visible = Set(rows.map(\.id))
        var moved = rows
        moved.move(fromOffsets: offsets, toOffset: destination)
        let siblings = data.tasks.filter { $0.isOpen && $0.schedule == first.schedule }.sorted(by: Self.planBefore)
        var replacements = moved.makeIterator()
        let ids = siblings.map { visible.contains($0.id) ? (replacements.next()?.id ?? $0.id) : $0.id }
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset - ids.count) })
        commit { document in
            for i in document.tasks.indices {
                if let order = positions[document.tasks[i].id] { document.tasks[i].planOrder = order }
            }
        }
    }

    static func planBefore(_ a: PlannerTask, _ b: PlannerTask) -> Bool {
        let x = a.planOrder ?? 0, y = b.planOrder ?? 0
        if x != y { return x < y }
        if (a.focusDate != nil) != (b.focusDate != nil) { return a.focusDate != nil }
        if a.isOverdue() != b.isOverdue() { return a.isOverdue() }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    func journalEntry(on date: Date, adding record: CompletionRecord? = nil) -> JournalEntry {
        var entry = data.journal.filter { PlannerDates.calendar.isDate($0.date, inSameDayAs: date) }
            .max { $0.date < $1.date } ?? JournalEntry(date: date)
        if let record {
            entry.text = [entry.text, record.title, record.journalText]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        }
        return entry
    }

    func finishJournalAddition(_ id: UUID) {
        commit { document in
            if let index = document.completions.firstIndex(where: { $0.id == id }) {
                document.completions[index].addedToJournal = true
            }
        }
    }

    func canReopen(_ record: CompletionRecord) -> Bool {
        guard record.isVisible, let date = task(record.taskID)?.completedAt else { return false }
        return abs(date.timeIntervalSince(record.date)) < 1
    }

    func withdrawCompletion(_ record: CompletionRecord) {
        guard canReopen(record), let original = task(record.taskID) else { return }
        var reopened = original
        reopened.completedAt = nil
        guard saveTask(reopened) else { return }
        offerUndo("已取消完成") { [weak self] in
            guard let self, var current = self.task(original.id), current.isOpen else { return }
            current.completedAt = original.completedAt
            self.commit { document in
                if let i = document.tasks.firstIndex(where: { $0.id == original.id }) { document.tasks[i] = current }
                if let i = document.completions.firstIndex(where: { $0.id == record.id }) { document.completions[i].withdrawn = nil }
            }
        }
    }

    private func offerUndo(_ message: String, action: @escaping () -> Void) {
        clearUndo()
        notice = message
        changeUndo = action
        canUndoChange = true
        let token = UUID()
        undoToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            if let self, self.undoToken == token { self.clearChangeUndo() }
        }
    }

    func undoChange() {
        let action = changeUndo
        clearChangeUndo()
        notice = nil
        action?()
    }

    func clearChangeUndo() {
        changeUndo = nil; canUndoChange = false; undoToken = UUID()
    }

    func saveCategory(name: String, color: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var catalog = tags
        guard !name.isEmpty, !catalog.categories.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else { return false }
        catalog.categories.append(ContactTagCategory(id: UUID().uuidString, name: name, color: color))
        return commit { $0.tagCatalog = catalog }
    }

    func saveTag(name: String, category: String, existing: UUID? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var catalog = tags
        guard !name.isEmpty, !catalog.tags.contains(where: {
            $0.categoryID == category && $0.id != existing && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return false }
        if let i = catalog.tags.firstIndex(where: { $0.id == existing }) { catalog.tags[i].name = name }
        else { catalog.tags.append(ContactTag(categoryID: category, name: name)) }
        return commit { $0.tagCatalog = catalog }
    }

    func setCategoryColor(_ color: String, category: String) {
        var catalog = tags
        guard let i = catalog.categories.firstIndex(where: { $0.id == category }) else { return }
        catalog.categories[i].color = color
        commit { $0.tagCatalog = catalog }
    }

    func changeTags(_ tags: Set<UUID>, for people: Set<UUID>, adding: Bool) {
        var changed: [UUID: Set<UUID>] = [:]
        for id in people {
            guard let contact = contact(id) else { continue }
            let current = Set(contact.tagIDs ?? [])
            let delta = adding ? tags.subtracting(current) : tags.intersection(current)
            if !delta.isEmpty { changed[id] = delta }
        }
        guard !changed.isEmpty, applyTags(changed, adding: adding) else { return }
        if adding {
            recentTags = Array((tags.sorted { $0.uuidString < $1.uuidString } + recentTags.filter { !tags.contains($0) }).prefix(5))
        }
        offerUndo("已更新 \(changed.count) 位聯絡人的標籤") { [weak self] in
            _ = self?.applyTags(changed, adding: !adding)
        }
    }

    private func applyTags(_ changed: [UUID: Set<UUID>], adding: Bool) -> Bool {
        commit { document in
            for i in document.contacts.indices {
                guard let delta = changed[document.contacts[i].id] else { continue }
                let current = Set(document.contacts[i].tagIDs ?? [])
                let next = adding ? current.union(delta) : current.subtracting(delta)
                document.contacts[i].tagIDs = next.isEmpty ? nil : next.sorted { $0.uuidString < $1.uuidString }
            }
        }
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
            if let i = document.contacts.firstIndex(where: { $0.id == contact.id }) {
                contact.tagIDs = document.contacts[i].tagIDs
                document.contacts[i] = contact
            }
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
    func exportArchive() async throws -> Data {
        guard !recoveryRequired, !loading else { throw PlannerError.invalidBackup("請先開啟 Planner 資料。") }
        let snapshot = data
        return try await Task.detached(priority: .userInitiated) { try BackupArchive.make(snapshot) }.value
    }

    func restoreArchive(_ backup: PreparedBackup) async -> Bool {
        guard !loading else { return false }
        loading = true
        defer { loading = false }
        do {
            let current = recoveryRequired ? nil : data
            try adopt(await files.restore(backup.document, preserving: current))
            return true
        } catch {
            self.error = "無法還原：\(error.localizedDescription)"
            return false
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
            if folderStorage {
                Task {
                    loading = true; defer { loading = false }
                    do { try adopt(await files.create(in: directory ?? MarkdownVault.defaultDirectory, document: imported)); notice = "已還原備份，原資料保留。" }
                    catch { self.error = error.localizedDescription }
                }
            } else {
                try disk.save(imported); data = imported; recoveryRequired = false; clearUndo(); pendingGoalID = nil
            }
            return true
        } catch { self.error = "無法還原：\(error.localizedDescription)"; return false }
    }
    func restorePrevious() {
        do { _ = importData(try Data(contentsOf: disk.backup)) }
        catch { self.error = "找不到上一份資料。可選擇資料夾，或重新開始。" }
    }
}
