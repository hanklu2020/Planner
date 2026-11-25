import Foundation

enum PlanScale: Int, Codable, CaseIterable, Identifiable {
    case day, week, month, year

    var id: Int { rawValue }
    var title: String { ["日", "週", "月", "年"][rawValue] }
    var noun: String { self == .day ? "任務" : "目標" }
    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    // One completed pinch changes at most one level; small movements do nothing.
    func zoomed(by magnification: Double) -> PlanScale {
        guard magnification.isFinite, magnification > 0 else { return self }
        if magnification < 0.78 { return PlanScale(rawValue: min(rawValue + 1, 3)) ?? self }
        if magnification > 1.28 { return PlanScale(rawValue: max(rawValue - 1, 0)) ?? self }
        return self
    }
}

enum PlannerDates {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hant_TW")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func start(of scale: PlanScale, at date: Date) -> Date {
        calendar.dateInterval(of: scale.component, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func contains(_ date: Date, in scale: PlanScale, at anchor: Date) -> Bool {
        guard let interval = calendar.dateInterval(of: scale.component, for: anchor) else { return false }
        return date >= interval.start && date < interval.end
    }

    static func adding(_ value: Int, _ component: Calendar.Component, to date: Date) -> Date {
        calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    static func days(of scale: PlanScale, at date: Date) -> [Date] {
        let first = start(of: scale, at: date)
        let count = scale == .week ? 7 : (calendar.range(of: .day, in: .month, for: first)?.count ?? 0)
        return (0..<count).map { adding($0, .day, to: first) }
    }

    static func monthCells(at date: Date) -> [Date?] {
        let first = start(of: .month, at: date)
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array<Date?>(repeating: nil, count: offset) + days(of: .month, at: date).map(Optional.some)
    }

    static func text(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func title(for scale: PlanScale, at date: Date) -> String {
        switch scale {
        case .day: return text(date, "M/d（EEE）")
        case .week:
            let first = start(of: .week, at: date)
            let last = adding(6, .day, to: first)
            let format = calendar.component(.year, from: first) == calendar.component(.year, from: last)
                ? "M/d" : "yyyy/M/d"
            return "\(text(first, format))–\(text(last, format))"
        case .month: return text(date, "yyyy 年 M 月")
        case .year: return text(date, "yyyy 年")
        }
    }
}

struct PlanTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var done = false
    var date = Date()
    var scale = PlanScale.day
    var isPriority = false
    var notes = ""
    var contactIDs: [UUID] = []
    var completedAt: Date?

    init(date: Date = Date(), scale: PlanScale = .day) {
        self.date = date
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey {
        case id, text, done, date, scale, isPriority, notes, contactIDs, completedAt
    }

    // Original MVP records have only id/text/done. Missing fields get defaults;
    // malformed existing fields still produce an error rather than losing data.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        scale = try c.decodeIfPresent(PlanScale.self, forKey: .scale) ?? .day
        isPriority = try c.decodeIfPresent(Bool.self, forKey: .isPriority) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        contactIDs = try c.decodeIfPresent([UUID].self, forKey: .contactIDs) ?? []
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        if done && completedAt == nil { completedAt = date }
    }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var date = Date()

    init(date: Date = Date()) { self.date = date }

    enum CodingKeys: String, CodingKey { case id, text, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
    }
}

struct Interaction: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text = ""
}

struct PlannerContact: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var details = ""
    var interactions: [Interaction] = []

    init() {}

    enum CodingKeys: String, CodingKey { case id, text, details, interactions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        interactions = try c.decodeIfPresent([Interaction].self, forKey: .interactions) ?? []
    }
}

enum TaskRules {
    static func priorityCount(in tasks: [PlanTask], for draft: PlanTask) -> Int {
        tasks.filter {
            $0.id != draft.id && $0.scale == .day && $0.isPriority && !$0.done &&
            PlannerDates.calendar.isDate($0.date, inSameDayAs: draft.date)
        }.count
    }

    static func normalized(_ task: PlanTask, previous: PlanTask?, now: Date) -> PlanTask {
        var result = task
        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.scale != .day { result.isPriority = false }
        result.contactIDs = Array(Set(result.contactIDs)).sorted { $0.uuidString < $1.uuidString }
        result.completedAt = result.done ? (previous?.completedAt ?? now) : nil
        return result
    }
}
