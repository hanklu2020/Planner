import Foundation

enum Domain: String, Codable, CaseIterable, Identifiable {
    case spiritual, social, physical, intellectual, family, work
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spiritual: return "靈性"
        case .social: return "社交"
        case .physical: return "體能"
        case .intellectual: return "智能"
        case .family: return "家庭"
        case .work: return "工作"
        }
    }
    var symbol: String {
        switch self {
        case .spiritual: return "sparkles"
        case .social: return "person.2"
        case .physical: return "figure.walk"
        case .intellectual: return "book.closed"
        case .family: return "house"
        case .work: return "briefcase"
        }
    }
}

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, achieved, ended
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: return "進行中"
        case .paused: return "已暫停"
        case .achieved: return "已達成"
        case .ended: return "已結束"
        }
    }
}

enum TimeScale: String, Codable, CaseIterable, Identifiable, Hashable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "週"
        case .month: return "月"
        case .year: return "年"
        }
    }
    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

enum PlannerDates {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_TW")
        c.timeZone = .current
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }
    static func start(_ date: Date, _ scale: TimeScale, calendar: Calendar = calendar) -> Date {
        calendar.dateInterval(of: scale.component, for: date)!.start
    }
    static func shifted(_ date: Date, _ scale: TimeScale, by value: Int, calendar: Calendar = calendar) -> Date {
        calendar.date(byAdding: scale.component, value: value, to: date)!
    }
    static func text(_ date: Date, _ format: String = "M/d", calendar: Calendar = calendar) -> String {
        // Keep formatters local to each thread: fast reuse without cross-thread mutation.
        let key = "Planner.format.\(calendar.identifier).\(calendar.timeZone.identifier).\(calendar.firstWeekday).\(calendar.minimumDaysInFirstWeek).\(format)"
        let formatter: DateFormatter
        if let cached = Thread.current.threadDictionary[key] as? DateFormatter { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_TW")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            Thread.current.threadDictionary[key] = formatter
        }
        return formatter.string(from: date)
    }
    static func heading(_ date: Date, scale: TimeScale) -> String {
        switch scale {
        case .day: return text(date, "M月d日 EEEE")
        case .week:
            let first = start(date, .week)
            return "\(text(first))–\(text(shifted(first, .day, by: 6)))"
        case .month: return text(date, "yyyy年 M月")
        case .year: return text(date, "yyyy年")
        }
    }
}

struct Schedule: Codable, Hashable {
    var date: Date
    var scale: TimeScale
    init(_ date: Date, scale: TimeScale = .day, calendar: Calendar = PlannerDates.calendar) {
        self.date = PlannerDates.start(date, scale, calendar: calendar)
        self.scale = scale
    }
    var label: String {
        switch scale {
        case .day: return PlannerDates.text(date)
        case .week: return "\(PlannerDates.text(date)) 當週"
        case .month: return PlannerDates.text(date, "yyyy/M")
        case .year: return PlannerDates.text(date, "yyyy年")
        }
    }
    func appears(in date: Date, scale viewScale: TimeScale, calendar: Calendar = PlannerDates.calendar) -> Bool {
        guard scale.rank <= viewScale.rank,
              let own = calendar.dateInterval(of: scale.component, for: self.date),
              let view = calendar.dateInterval(of: viewScale.component, for: date) else { return false }
        return own.start < view.end && view.start < own.end
    }
    func needsAttention(on today: Date = Date(), calendar: Calendar = PlannerDates.calendar) -> Bool {
        guard let interval = calendar.dateInterval(of: scale.component, for: date) else { return false }
        return interval.end <= calendar.startOfDay(for: today)
    }
}

struct Goal: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var domain: Domain = .intellectual
    var extraDomains: [Domain]?
    var domainOrder: [String: Int]?
    var domains: [Domain] { [domain] + (extraDomains ?? []).filter { $0 != domain } }
    var domainTitle: String { domains.map(\.title).joined(separator: "、") }
    var criteria = ""
    var targetDate: Date?
    var status: GoalStatus = .active
    var createdAt = Date()
    var achievedAt: Date?
}

struct Step: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
}

struct PlanningChange: Codable, Equatable {
    var at = Date()
    var previous: Schedule?
    var next: Schedule?
}

struct PlannerTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var notes = ""
    var domain: Domain?
    var goalID: UUID?
    var schedule: Schedule?
    var deadline: Date?
    var steps: [Step] = []
    var contactIDs: [UUID] = []
    var createdAt = Date()
    var completedAt: Date?
    var cancelled = false
    var focusDate: Date?
    var planningHistory: [PlanningChange] = []
    var planOrder: Int?
    var isDone: Bool { completedAt != nil }
    var isOpen: Bool { !isDone && !cancelled }
    var stepProgress: String { "\(steps.filter(\.done).count)/\(steps.count)" }
    func isOverdue(on date: Date = Date(), calendar: Calendar = PlannerDates.calendar) -> Bool {
        guard isOpen, let deadline else { return false }
        return calendar.startOfDay(for: deadline) < calendar.startOfDay(for: date)
    }
    func needsAttention(on date: Date = Date()) -> Bool {
        isOpen && (isOverdue(on: date) || schedule?.needsAttention(on: date) == true)
    }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text = ""
    var language = "zh"
}

struct Contact: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var details = ""
    var keepHistory = false
    var archived = false
    var tagIDs: [UUID]?
    var birthday: ContactBirthday?
}

struct Interaction: Codable, Identifiable, Equatable {
    var id = UUID()
    var contactID: UUID
    var date = Date()
    var text = ""
}

struct GoalReview: Codable, Identifiable, Equatable {
    var id = UUID()
    var goalID: UUID
    var date = Date()
    var note = ""
    var decision = ""
}

struct CompletionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var taskID: UUID
    var date: Date
    var title: String
    var text: String
    var domain: Domain?
    var goalTitle: String?
    var contactIDs: [UUID]
    var withdrawn: Bool?
    var addedToJournal: Bool?
    var hiddenFromJournal: Bool?
    var journalExcerpt: String?

    var isVisible: Bool { withdrawn != true }
    var appearsInJournal: Bool { isVisible && addedToJournal != true && hiddenFromJournal != true }
    var journalText: String {
        journalExcerpt ?? text.components(separatedBy: "\n").compactMap { line in
            if line.hasPrefix("- [ ] ") { return nil }
            if line.hasPrefix("- [x] ") { return "- " + line.dropFirst(6) }
            return line
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PlannerDocument: Codable, Equatable {
    static let currentVersion = 5
    var version = currentVersion
    var goals: [Goal] = []
    var tasks: [PlannerTask] = []
    var journal: [JournalEntry] = []
    var contacts: [Contact] = []
    var interactions: [Interaction] = []
    var reviews: [GoalReview] = []
    var completions: [CompletionRecord] = []
    var tagCatalog: ContactTagCatalog?

    init() {}
    enum CodingKeys: String, CodingKey { case version, goals, tasks, journal, contacts, interactions, reviews, completions, tagCatalog }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        guard (2...Self.currentVersion).contains(version) else { throw PlannerError.invalidBackup("不支援此備份版本。") }
        guard !c.allKeys.isEmpty else { throw PlannerError.invalidBackup("沒有可辨識的 Planner 資料。") }
        self.version = Self.currentVersion
        goals = try c.decodeIfPresent([Goal].self, forKey: .goals) ?? []
        tasks = try c.decodeIfPresent([PlannerTask].self, forKey: .tasks) ?? []
        journal = try c.decodeIfPresent([JournalEntry].self, forKey: .journal) ?? []
        contacts = try c.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        interactions = try c.decodeIfPresent([Interaction].self, forKey: .interactions) ?? []
        reviews = try c.decodeIfPresent([GoalReview].self, forKey: .reviews) ?? []
        completions = try c.decodeIfPresent([CompletionRecord].self, forKey: .completions) ?? []
        tagCatalog = try c.decodeIfPresent(ContactTagCatalog.self, forKey: .tagCatalog)
    }

    mutating func captureCompletions() {
        let recorded = Dictionary(grouping: completions.filter(\.isVisible), by: \.taskID)
        let titles = Dictionary(goals.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for task in tasks where !task.cancelled {
            guard let date = task.completedAt,
                  recorded[task.id]?.contains(where: { abs($0.date.timeIntervalSince(date)) < 1 }) != true else { continue }
            let steps = task.steps.map { "- [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
            let done = task.steps.filter(\.done).map { "- \($0.title)" }.joined(separator: "\n")
            completions.append(CompletionRecord(taskID: task.id, date: date, title: task.title,
                text: [task.notes, steps].filter { !$0.isEmpty }.joined(separator: "\n\n"), domain: task.domain,
                goalTitle: task.goalID.flatMap { titles[$0] }, contactIDs: task.contactIDs,
                journalExcerpt: [task.notes, done].filter { !$0.isEmpty }.joined(separator: "\n\n")))
        }
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion else { throw PlannerError.invalidBackup("不支援此備份版本，請使用相容版本的 Planner。") }
        func unique<T: Identifiable>(_ values: [T]) -> Bool where T.ID == UUID {
            Set(values.map(\.id)).count == values.count
        }
        guard unique(goals), unique(tasks), unique(journal), unique(contacts), unique(interactions), unique(reviews), unique(completions),
              tasks.allSatisfy({ unique($0.steps) }), tagCatalog?.isValid != false else { throw PlannerError.invalidBackup("備份含有重複項目。") }
        let goalIDs = Set(goals.map(\.id)), contactIDs = Set(contacts.map(\.id))
        guard tasks.allSatisfy({ task in
            (task.goalID == nil || goalIDs.contains(task.goalID!)) && Set(task.contactIDs).isSubset(of: contactIDs)
        }), interactions.allSatisfy({ contactIDs.contains($0.contactID) }),
              reviews.allSatisfy({ goalIDs.contains($0.goalID) }) else {
            throw PlannerError.invalidBackup("備份的目標或聯絡人關聯不完整。")
        }
        return self
    }
}

enum PlannerError: LocalizedError {
    case invalidBackup(String)
    var errorDescription: String? {
        switch self { case .invalidBackup(let message): return message }
    }
}

struct LegacyRecord: Codable {
    var id: UUID
    var text: String
    var done: Bool
    init(id: UUID, text: String, done: Bool) { self.id = id; self.text = text; self.done = done }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text)
            ?? c.decodeIfPresent(String.self, forKey: .title)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decode(String.self, forKey: .content)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? c.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
    }
    private enum Keys: String, CodingKey { case id, text, title, name, content, done, isCompleted }
}

enum LegacyStorage {
    static func bytes(_ key: String, defaults: UserDefaults) -> Data? {
        if let data = defaults.data(forKey: key) { return data }
        if let text = defaults.string(forKey: key) { return Data(text.utf8) }
        if let value = defaults.object(forKey: key), JSONSerialization.isValidJSONObject(value) {
            return try? JSONSerialization.data(withJSONObject: value)
        }
        return nil
    }
}

enum PlannerMigration {
    static func migrate(defaults: UserDefaults, now: Date = Date()) throws -> PlannerDocument {
        var result = PlannerDocument()
        func rows(_ key: String) throws -> [LegacyRecord] {
            guard let data = LegacyStorage.bytes(key, defaults: defaults), !data.isEmpty else { return [] }
            return try JSONDecoder().decode([LegacyRecord].self, from: data)
        }
        result.tasks = try rows("tasks").map {
            var task = PlannerTask()
            task.id = $0.id; task.title = $0.text; task.createdAt = now
            // The MVP did not record dates. Do not invent a completion date.
            if $0.done { task.completedAt = now; task.notes = "舊版匯入：原完成日期未記錄，顯示日期為匯入日。" }
            return task
        }
        result.journal = try rows("journal").map {
            var entry = JournalEntry()
            entry.id = $0.id; entry.date = now
            entry.text = $0.text + "\n\n〔舊版匯入，原日期未記錄〕"
            return entry
        }
        result.contacts = try rows("contacts").map {
            var contact = Contact(); contact.id = $0.id; contact.name = $0.text; return contact
        }
        return try result.validated()
    }
}

struct PlannerDisk {
    let directory: URL
    var file: URL { directory.appendingPathComponent("planner-v2.json") }
    var backup: URL { directory.appendingPathComponent("planner-v2.previous.json") }
    static var standard: Self {
        Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Planner", isDirectory: true))
    }
    func load(defaults: UserDefaults = .standard) throws -> PlannerDocument {
        guard FileManager.default.fileExists(atPath: file.path) else {
            // A missing primary file with a backup is a recovery case, not a new install.
            if FileManager.default.fileExists(atPath: backup.path) {
                throw PlannerError.invalidBackup("主資料檔遺失。請先還原上一份資料或匯入備份。")
            }
            return try PlannerMigration.migrate(defaults: defaults)
        }
        return try Self.decode(Data(contentsOf: file))
    }
    static func decode(_ data: Data) throws -> PlannerDocument {
        try JSONDecoder().decode(PlannerDocument.self, from: data).validated()
    }
    func save(_ document: PlannerDocument) throws {
        _ = try document.validated()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(document)
        if manager.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            // Never replace a good backup with an unreadable primary file.
            if (try? Self.decode(previous)) != nil { try previous.write(to: backup, options: .atomic) }
        }
        try encoded.write(to: file, options: .atomic)
    }
}
