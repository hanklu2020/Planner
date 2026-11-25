import Foundation

@main
struct ModelChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            PlannerDates.calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour
            ))!
        }

        check(PlanScale.day.zoomed(by: 0.1) == .week, "A pinch changes only one level")
        check(PlanScale.week.zoomed(by: 0.77) == .month, "Pinch out to month")
        check(PlanScale.month.zoomed(by: 1.29) == .week, "Pinch in to week")
        check(PlanScale.year.zoomed(by: 10) == .month, "Zoom in changes only one level")
        check(PlanScale.day.zoomed(by: 2) == .day, "Clamp at day")
        check(PlanScale.year.zoomed(by: 0.2) == .year, "Clamp at year")
        check(PlanScale.month.zoomed(by: 1.1) == .month, "Ignore small movement")
        check(PlanScale.month.zoomed(by: .nan) == .month, "Ignore invalid scale")
        check(PlanScale.month.zoomed(by: 0) == .month, "Ignore zero scale")

        let feb = date(2024, 2, 15)
        check(PlannerDates.days(of: .month, at: feb).count == 29, "Leap February")
        check(PlannerDates.days(of: .month, at: date(2026, 2, 1)).count == 28, "Normal February")
        let cells = PlannerDates.monthCells(at: date(2026, 11, 1))
        check(cells.prefix(6).allSatisfy { $0 == nil }, "Monday-first calendar with Sunday month start")
        check(cells.compactMap { $0 }.count == 30, "No missing month dates")
        let crossYear = PlannerDates.days(of: .week, at: date(2027, 1, 1))
        check(crossYear.count == 7, "Seven days")
        check(PlannerDates.calendar.component(.weekday, from: crossYear[0]) == 2, "Starts Monday")
        check(PlannerDates.contains(date(2026, 12, 28), in: .week, at: date(2027, 1, 1)), "Cross-year week")
        check(!PlannerDates.contains(date(2027, 1, 4), in: .week, at: date(2027, 1, 1)), "Exclusive week end")
        check(!PlannerDates.contains(date(2027, 1, 1, 0), in: .year, at: date(2026, 11, 25)), "Exclusive year end")
        check(PlannerDates.contains(date(2026, 11, 30, 23), in: .month, at: date(2026, 11, 1)), "Include final evening")

        let id = UUID()
        let oldData = Data("[{\"id\":\"\(id.uuidString)\",\"text\":\"保留原資料\",\"done\":true}]".utf8)
        let task = try JSONDecoder().decode([PlanTask].self, from: oldData)[0]
        check(task.id == id && task.text == "保留原資料" && task.done, "Legacy task identity and fields")
        check(task.scale == .day && task.contactIDs.isEmpty && task.completedAt != nil, "Legacy defaults")
        let entry = try JSONDecoder().decode([JournalEntry].self, from: oldData)[0]
        check(entry.id == id && entry.text == "保留原資料", "Legacy journal")
        let contact = try JSONDecoder().decode([PlannerContact].self, from: oldData)[0]
        check(contact.id == id && contact.text == "保留原資料" && contact.interactions.isEmpty, "Legacy contact")
        let roundTrip = try JSONDecoder().decode(PlanTask.self, from: JSONEncoder().encode(task))
        check(roundTrip == task, "Extended task round-trip")

        var pending = PlanTask(date: date(2026, 11, 25))
        pending.text = "  task \n"
        pending.isPriority = true
        let contactID = UUID()
        pending.contactIDs = [contactID, contactID]
        var finished = pending
        finished.done = true
        let now = date(2026, 11, 26)
        let normalized = TaskRules.normalized(finished, previous: pending, now: now)
        check(normalized.completedAt == now, "Actual completion date")
        check(normalized.text == "task" && normalized.contactIDs == [contactID], "Trim and deduplicate")
        let edited = TaskRules.normalized(normalized, previous: normalized, now: date(2026, 12, 1))
        check(edited.completedAt == now, "Editing preserves completion date")
        var reopened = normalized
        reopened.done = false
        check(TaskRules.normalized(reopened, previous: normalized, now: now).completedAt == nil, "Reopening clears completion")
        var goal = pending
        goal.scale = .year
        check(!TaskRules.normalized(goal, previous: nil, now: now).isPriority, "Only daily tasks can be Top 3")

        var otherDay = pending
        otherDay.id = UUID()
        otherDay.date = date(2026, 11, 26)
        var another = pending
        another.id = UUID()
        check(TaskRules.priorityCount(in: [pending, another, otherDay], for: pending) == 1, "Priority count excludes self and other dates")
        check(TaskRules.priorityCount(in: [normalized], for: another) == 0, "Completed tasks do not occupy priority slots")
        print("Passed \(checks) model checks.")
    }
}
