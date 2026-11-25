import XCTest
@testable import Planner

final class PlannerTests: XCTestCase {
    private var calendar: Calendar {
        var value = PlannerDates.calendar
        value.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testLooseWeekDoesNotBecomeADay() {
        let week = Schedule(date(2026, 11, 25), scale: .week, calendar: calendar)
        XCTAssertFalse(week.appears(in: date(2026, 11, 25), scale: .day, calendar: calendar))
        XCTAssertTrue(week.appears(in: date(2026, 11, 23), scale: .week, calendar: calendar))
        XCTAssertFalse(week.appears(in: date(2026, 11, 30), scale: .week, calendar: calendar))
    }
    func testMonthAndYearRemainLoose() {
        let month = Schedule(date(2026, 11, 25), scale: .month, calendar: calendar)
        XCTAssertFalse(month.appears(in: date(2026, 11, 25), scale: .week, calendar: calendar))
        XCTAssertTrue(month.appears(in: date(2026, 11, 2), scale: .month, calendar: calendar))
        let year = Schedule(date(2026, 11, 25), scale: .year, calendar: calendar)
        XCTAssertFalse(year.appears(in: date(2026, 11, 25), scale: .month, calendar: calendar))
        XCTAssertTrue(year.appears(in: date(2026, 1, 1), scale: .year, calendar: calendar))
    }
    func testCrossYearWeekAndLeapDay() {
        let week = Schedule(date(2026, 12, 31), scale: .week, calendar: calendar)
        XCTAssertTrue(week.appears(in: date(2027, 1, 1), scale: .week, calendar: calendar))
        let leap = Schedule(date(2028, 2, 29), calendar: calendar)
        XCTAssertTrue(leap.appears(in: date(2028, 2, 1), scale: .month, calendar: calendar))
        XCTAssertFalse(leap.appears(in: date(2028, 3, 1), scale: .month, calendar: calendar))
    }
    func testPastPlanAndDeadlineAreDistinct() {
        let today = date(2026, 11, 25)
        var task = PlannerTask(schedule: Schedule(date(2026, 11, 24), calendar: calendar), deadline: date(2026, 11, 27))
        XCTAssertTrue(task.schedule!.needsAttention(on: today, calendar: calendar))
        XCTAssertFalse(task.isOverdue(on: today, calendar: calendar))
        task.deadline = date(2026, 11, 25)
        XCTAssertFalse(task.isOverdue(on: today, calendar: calendar))
        XCTAssertTrue(task.isOverdue(on: date(2026, 11, 26), calendar: calendar))
    }
    func testDaylightSavingUsesCalendarDays() {
        var la = calendar; la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sunday = Schedule(date(2026, 3, 8, calendar: la), calendar: la)
        XCTAssertFalse(sunday.needsAttention(on: date(2026, 3, 8, 23, calendar: la), calendar: la))
        XCTAssertTrue(sunday.needsAttention(on: date(2026, 3, 9, 0, calendar: la), calendar: la))
        XCTAssertTrue(sunday.appears(in: date(2026, 3, 8, calendar: la), scale: .day, calendar: la))
    }
    func testLegacyMigrationPreservesIDsAndOriginalKeys() throws {
        let suite = "PlannerTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), now = date(2026, 11, 25)
        defaults.set(try JSONEncoder().encode([LegacyRecord(id: id, text: "原任務", done: true)]), forKey: "tasks")
        defaults.set(try JSONEncoder().encode([LegacyRecord(id: UUID(), text: "原日記", done: false)]), forKey: "journal")
        defaults.set(try JSONEncoder().encode([LegacyRecord(id: UUID(), text: "家人", done: false)]), forKey: "contacts")
        let result = try PlannerMigration.migrate(defaults: defaults, now: now)
        XCTAssertEqual(result.tasks.first?.id, id)
        XCTAssertEqual(result.tasks.first?.title, "原任務")
        XCTAssertTrue(result.tasks.first!.isDone)
        XCTAssertTrue(result.tasks.first!.notes.contains("原完成日期未記錄"))
        XCTAssertNil(result.tasks.first?.schedule)
        XCTAssertTrue(result.journal[0].text.contains("原日記"))
        XCTAssertEqual(result.contacts[0].name, "家人")
        XCTAssertNotNil(defaults.data(forKey: "tasks"))
    }
    func testCorruptLegacyDataDoesNotSilentlyDisappear() {
        let suite = "PlannerTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("corrupt".utf8), forKey: "journal")
        XCTAssertThrowsError(try PlannerMigration.migrate(defaults: defaults))
    }
    func testBackupRejectsFutureVersionDuplicateAndDanglingLinks() throws {
        var document = PlannerDocument()
        document.version = 999
        XCTAssertThrowsError(try document.validated())
        document = PlannerDocument()
        let task = PlannerTask(title: "任務")
        document.tasks = [task, task]
        XCTAssertThrowsError(try document.validated())
        document.tasks = [PlannerTask(goalID: UUID())]
        XCTAssertThrowsError(try document.validated())
        document.tasks = [PlannerTask(contactIDs: [UUID()])]
        XCTAssertThrowsError(try document.validated())
    }
    func testDiskRoundTripAndPreviousSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PlannerDisk(directory: directory)
        var first = PlannerDocument(); first.tasks = [PlannerTask(title: "第一份")]
        try disk.save(first)
        var second = first; second.tasks[0].title = "第二份"; try disk.save(second)
        XCTAssertEqual(try disk.load(), second)
        XCTAssertEqual(try PlannerDisk.decode(Data(contentsOf: disk.backup)), first)
        try Data("broken".utf8).write(to: disk.file)
        XCTAssertThrowsError(try disk.load())
        XCTAssertEqual(try PlannerDisk.decode(Data(contentsOf: disk.backup)), first)
    }

    @MainActor
    func testSharedTasksCompletionReopenAndManualGoalAchievement() throws {
        let (store, directory, defaults, suite) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let goal = Goal(title: "能自我介紹", domain: .intellectual, criteria: "不看稿一分鐘")
        XCTAssertTrue(store.saveGoal(goal))
        let contact = Contact(name: "老師"); XCTAssertTrue(store.saveContact(contact))
        let steps = [Step(title: "寫稿"), Step(title: "練習")]
        let task = PlannerTask(title: "準備內容", goalID: goal.id, steps: steps, contactIDs: [contact.id])
        XCTAssertTrue(store.saveTask(task))
        store.toggleStep(task.id, stepID: steps[0].id)
        XCTAssertFalse(store.task(task.id)!.isDone)
        store.toggleStep(task.id, stepID: steps[1].id)
        XCTAssertTrue(store.task(task.id)!.isDone)
        XCTAssertEqual(store.pendingGoalID, goal.id)
        XCTAssertEqual(store.goal(goal.id)?.status, .active)
        XCTAssertEqual(store.progress(for: goal.id), "任務完成 1/1")
        XCTAssertEqual(store.data.tasks.filter { $0.isDone && $0.contactIDs.contains(contact.id) }.count, 1)
        store.toggleStep(task.id, stepID: steps[0].id)
        XCTAssertNil(store.task(task.id)?.completedAt)
        XCTAssertTrue(store.data.tasks.filter { $0.isDone && $0.contactIDs.contains(contact.id) }.isEmpty)
        XCTAssertEqual(store.data.tasks.count, 1)
    }
    @MainActor
    func testBulkSchedulingUndoPreservesDeadlineCompletionAndOtherEdits() throws {
        let (store, directory, defaults, suite) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let deadline = date(2026, 12, 31)
        let a = PlannerTask(title: "A", deadline: deadline)
        let old = Schedule(date(2026, 11, 26))
        let b = PlannerTask(title: "B", schedule: old)
        let done = PlannerTask(title: "已完成", completedAt: Date())
        _ = store.saveTask(a); _ = store.saveTask(b); _ = store.saveTask(done)
        XCTAssertTrue(store.schedule([a.id, b.id, done.id], to: Schedule(date(2026, 11, 30))))
        var edit = store.task(a.id)!; edit.notes = "安排後新增的說明"; _ = store.saveTask(edit)
        XCTAssertNil(store.task(done.id)?.schedule)
        store.undoSchedule()
        XCTAssertNil(store.task(a.id)?.schedule)
        XCTAssertEqual(store.task(b.id)?.schedule, old)
        XCTAssertEqual(store.task(a.id)?.deadline, deadline)
        XCTAssertEqual(store.task(a.id)?.notes, "安排後新增的說明")
        XCTAssertEqual(store.task(a.id)?.planningHistory.count, 2)
    }
    @MainActor
    func testCorruptFileLocksWritesUntilValidRestore() throws {
        let (store, directory, defaults, suite) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        _ = store.saveTask(PlannerTask(title: "保留"))
        let disk = PlannerDisk(directory: directory), bad = Data("not-json".utf8)
        try bad.write(to: disk.file)
        let recovered = PlannerStore(folderStorage: false, disk: disk, defaults: defaults)
        XCTAssertTrue(recovered.recoveryRequired)
        XCTAssertFalse(recovered.saveTask(PlannerTask(title: "不可覆寫")))
        XCTAssertEqual(try Data(contentsOf: disk.file), bad)
        XCTAssertFalse(recovered.importData(bad))
        XCTAssertTrue(recovered.recoveryRequired)
        XCTAssertTrue(recovered.importData(try store.exportData()))
        XCTAssertFalse(recovered.recoveryRequired)
        XCTAssertEqual(recovered.data.tasks.first?.title, "保留")
    }
    @MainActor
    func testCancelledTasksDoNotInflateGoalProgress() {
        let (store, directory, defaults, suite) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let goal = Goal(title: "目標"); _ = store.saveGoal(goal)
        _ = store.saveTask(PlannerTask(title: "取消", goalID: goal.id, cancelled: true))
        _ = store.saveTask(PlannerTask(title: "有效", goalID: goal.id))
        XCTAssertEqual(store.progress(for: goal.id), "任務完成 0/1")
    }
    @MainActor
    private func makeStore() -> (PlannerStore, URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PlannerTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        return (PlannerStore(folderStorage: false, disk: PlannerDisk(directory: directory), defaults: defaults), directory, defaults, suite)
    }
}
