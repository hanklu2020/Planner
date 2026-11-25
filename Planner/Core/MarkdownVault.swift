import Foundation
import CryptoKit

// Compact metadata keeps identity and dates; all actual content remains ordinary Markdown.
private struct MarkdownMeta: Codable {
    var kind: String
    var id: UUID
    var date: Date?
    var language: String?
    var keepHistory: Bool?
    var archived: Bool?
    var taskID: UUID?
    var domain: Domain?
    var goalTitle: String?
    var contactIDs: [UUID]?
    var withdrawn: Bool?
    var addedToJournal: Bool?
    var hiddenFromJournal: Bool?
    var journalExcerpt: String?
}

struct MarkdownContent {
    var journal: [JournalEntry] = []
    var contacts: [Contact] = []
    var interactions: [Interaction] = []
    var completions: [CompletionRecord] = []
    var hasBirthdayField = false
}

enum PlannerMarkdown {
    private static let birthdayPrefix = "**生日**："
    private static let tagPrefix = "<!-- Planner tags: "
    static let signature = "<!-- Planner Markdown 1 -->"
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        return encoder
    }
    private static func block(_ meta: MarkdownMeta, heading: String, text: String) throws -> String {
        let end = "<!-- /planner:\(meta.id.uuidString) -->"
        guard !text.contains(end) else { throw PlannerError.invalidBackup("內容包含保留標記，請移除該行後重試。") }
        let json = String(decoding: try encoder().encode(meta), as: UTF8.self)
        return "<!-- planner:\(json) -->\n\(heading)\n\n\(text)\n\(end)\n\n"
    }
    static func journal(_ month: String, entries: [JournalEntry], completions: [CompletionRecord]) throws -> Data {
        var blocks: [(Date, String, String)] = []
        for entry in entries {
            blocks.append((entry.date, entry.id.uuidString, try block(MarkdownMeta(kind: "journal", id: entry.id, date: entry.date, language: entry.language),
                heading: "## \(PlannerDates.text(entry.date, "yyyy-MM-dd HH:mm"))", text: entry.text)))
        }
        for record in completions { blocks.append((record.date, record.id.uuidString, try completionBlock(record))) }
        let text = signature + "\n# \(month) 日記\n\n" + blocks.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }.joined()
        return Data(text.utf8)
    }
    static func person(_ contact: Contact, interactions: [Interaction], completions: [CompletionRecord]) throws -> Data {
        var text = signature + "\n# 聯絡人\n\n"
        text += try block(MarkdownMeta(kind: "contact", id: contact.id, keepHistory: contact.keepHistory, archived: contact.archived), heading: "## \(contact.name.replacingOccurrences(of: "\n", with: " "))", text: contact.details)
        text += birthdayPrefix + (contact.birthday?.text ?? "") + "\n\n"
        var records: [(Date, String, String)] = []
        for entry in interactions {
            records.append((entry.date, entry.id.uuidString, try block(MarkdownMeta(kind: "interaction", id: entry.id, date: entry.date, contactIDs: [contact.id]), heading: "### \(PlannerDates.text(entry.date, "yyyy-MM-dd HH:mm")) 往來", text: entry.text)))
        }
        for record in completions { records.append((record.date, record.id.uuidString, try completionBlock(record, summary: true))) }
        text += records.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }.joined()
        if let tags = contact.tagIDs, !tags.isEmpty {
            text += tagPrefix + tags.map(\.uuidString).sorted().joined(separator: " ") + " -->\n"
        }
        return Data(text.utf8)
    }
    private static func completionBlock(_ record: CompletionRecord, summary: Bool = false) throws -> String {
        let meta = MarkdownMeta(kind: "completion", id: record.id, date: record.date, taskID: record.taskID, domain: record.domain, goalTitle: record.goalTitle, contactIDs: record.contactIDs, withdrawn: record.withdrawn, addedToJournal: record.addedToJournal, hiddenFromJournal: record.hiddenFromJournal,
            journalExcerpt: summary ? nil : record.journalExcerpt)
        // Contact files retain a short standalone record; the monthly journal has the full text.
        return try block(meta, heading: "### \(record.title.replacingOccurrences(of: "\n", with: " "))", text: "完成日期：\(PlannerDates.text(record.date, "yyyy-MM-dd HH:mm"))\n" + (summary ? "" : record.text))
    }
    private static func cursorAfterRecord(_ index: String.Index, in text: String) -> String.Index {
        text[index...].firstIndex { !$0.isWhitespace } ?? text.endIndex
    }

    static func read(_ data: Data, fallbackName: String, fallbackDate: Date, relativePath: String, contactFile: Bool) throws -> MarkdownContent {
        guard var text = String(data: data, encoding: .utf8) else { throw PlannerError.invalidBackup("\(relativePath) 不是 UTF-8 文字。") }
        var tags: [UUID]?
        if contactFile, let footer = text.range(of: "\n" + tagPrefix, options: .backwards),
           !text[footer.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") {
            let line = text[footer.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            tags = line.split(whereSeparator: \.isWhitespace).compactMap { UUID(uuidString: String($0)) }
            text.removeSubrange(footer.lowerBound..<text.endIndex)
        }
        var result = MarkdownContent()
        if !text.hasPrefix(signature) {
            guard !text.contains("<!-- planner:") else { throw PlannerError.invalidBackup("\(relativePath) 的文件標記不完整，原檔已保留。") }
            let bytes = Array(SHA256.hash(data: Data(relativePath.utf8)).prefix(16))
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let id = UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))")!
            if contactFile { result.contacts = [Contact(id: id, name: fallbackName, details: text, tagIDs: tags)] }
            else { result.journal = [JournalEntry(id: id, date: fallbackDate, text: text + "\n\n〔匯入文件，日期依檔案修改時間〕")] }
            return result
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var cursor = text.startIndex
        // Only the signature and generated document heading may precede the first record.
        let preambleEnd = text.range(of: "\n\n")?.upperBound ?? text.endIndex
        cursor = preambleEnd
        while cursor < text.endIndex {
            while cursor < text.endIndex && text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            if cursor == text.endIndex { break }
            guard text[cursor...].hasPrefix("<!-- planner:"), let lineEnd = text[cursor...].firstIndex(of: "\n") else {
                throw PlannerError.invalidBackup("\(relativePath) 的紀錄格式無法辨識，原檔未被改寫。")
            }
            let line = String(text[cursor..<lineEnd])
            guard line.hasSuffix(" -->") else { throw PlannerError.invalidBackup("文件標記損壞：\(relativePath)") }
            let meta = try decoder.decode(MarkdownMeta.self, from: Data(line.dropFirst("<!-- planner:".count).dropLast(4).utf8))
            let start = text.index(after: lineEnd), endMarker = "\n<!-- /planner:\(meta.id.uuidString) -->"
            guard let end = text.range(of: endMarker, range: start..<text.endIndex), let split = text.range(of: "\n\n", range: start..<end.lowerBound) else {
                throw PlannerError.invalidBackup("紀錄不完整：\(relativePath)")
            }
            let headingLine = String(text[start..<split.lowerBound])
            let heading = headingLine.hasPrefix("### ") ? String(headingLine.dropFirst(4)) : String(headingLine.dropFirst(3))
            let body = String(text[split.upperBound..<end.lowerBound])
            var nextRecord = end.upperBound
            switch meta.kind {
            case "journal":
                guard let date = meta.date else { throw PlannerError.invalidBackup("日記缺少日期。") }
                result.journal.append(JournalEntry(id: meta.id, date: date, text: body, language: meta.language ?? "zh"))
            case "contact":
                let remainder = text[cursorAfterRecord(end.upperBound, in: text)...]
                var birthday: ContactBirthday?
                if remainder.hasPrefix(birthdayPrefix) {
                    let lineEnd = remainder.firstIndex(of: "\n") ?? text.endIndex
                    birthday = ContactBirthday(text: String(remainder[..<lineEnd].dropFirst(birthdayPrefix.count)))
                    result.hasBirthdayField = true
                    nextRecord = lineEnd
                }
                result.contacts.append(Contact(id: meta.id, name: heading, details: body, keepHistory: meta.keepHistory ?? false,
                                               archived: meta.archived ?? false, tagIDs: tags, birthday: birthday))
            case "interaction":
                guard let date = meta.date, let person = meta.contactIDs?.first else { throw PlannerError.invalidBackup("往來缺少日期或聯絡人。") }
                result.interactions.append(Interaction(id: meta.id, contactID: person, date: date, text: body))
            case "completion":
                guard let date = meta.date, let taskID = meta.taskID else { throw PlannerError.invalidBackup("完成紀錄不完整。") }
                let detail = body.firstIndex(of: "\n").map { String(body[body.index(after: $0)...]) } ?? ""
                result.completions.append(CompletionRecord(id: meta.id, taskID: taskID, date: date, title: String(heading), text: detail, domain: meta.domain, goalTitle: meta.goalTitle, contactIDs: meta.contactIDs ?? [], withdrawn: meta.withdrawn, addedToJournal: meta.addedToJournal, hiddenFromJournal: meta.hiddenFromJournal, journalExcerpt: meta.journalExcerpt))
            default: throw PlannerError.invalidBackup("文件包含較新版本的紀錄，請先更新 Planner。")
            }
            cursor = nextRecord
        }
        return result
    }
}

final class MarkdownVault {
    private struct StateVersion: Decodable { let version: Int }
    private struct PendingSave: Codable {
        var document: PlannerDocument
        var deletingContacts: Set<UUID>
    }
    private var pendingContactDeletions: Set<UUID> = []
    private var contactsWithoutBirthdayField: Set<String> = []
    let directory: URL
    private(set) var expected: [String: Data] = [:]
    private var last: PlannerDocument?
    private(set) var repair = false
    private var unreadable: Set<String> = []
    private(set) var warnings: [String] = []
    private let manager = FileManager.default
    static var defaultDirectory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    init(directory: URL) { self.directory = directory }
    private func url(_ path: String) -> URL { directory.appendingPathComponent(path) }
    private func coordinated<T>(writing: Bool, _ work: () throws -> T) throws -> T {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?, error: NSError?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: directory, options: .forMerging, error: &error) { _ in result = Result { try work() } }
        } else {
            coordinator.coordinate(readingItemAt: directory, options: .withoutChanges, error: &error) { _ in result = Result { try work() } }
        }
        if let error { throw error }
        guard let result else { throw PlannerError.invalidBackup("無法存取選定的資料夾。") }
        return try result.get()
    }
    func load() throws -> PlannerDocument? {
        try coordinated(writing: false) {
            expected = [:]; last = nil; repair = false; unreadable = []; warnings = []
            pendingContactDeletions = []; contactsWithoutBirthdayField = []
            var document = PlannerDocument(), found = false, stateBad = false
            let statePath = ".planner/state.json", pendingPath = ".planner/pending.json"
            if manager.fileExists(atPath: url(statePath).path) {
                let bytes = try Data(contentsOf: url(statePath)); expected[statePath] = bytes; found = true
                let decoder = JSONDecoder()
                if let header = try? decoder.decode(StateVersion.self, from: bytes),
                   header.version > PlannerDocument.currentVersion {
                    throw PlannerError.invalidBackup("此資料由較新的 Planner 建立，請先更新 App。")
                }
                do { document = try decoder.decode(PlannerDocument.self, from: bytes) } catch { stateBad = true }
            }
            if manager.fileExists(atPath: url(pendingPath).path) {
                let bytes = try Data(contentsOf: url(pendingPath))
                if let pending = try? JSONDecoder().decode(PendingSave.self, from: bytes) {
                    document = try pending.document.validated()
                    pendingContactDeletions = pending.deletingContacts
                } else {
                    document = try PlannerDisk.decode(bytes)
                }
                for path in try markdownPaths(includeBoth: true) { expected[path] = try Data(contentsOf: url(path)) }
                repair = true
                last = document
                return document
            }
            let paths = try markdownPaths()
            var markdown = MarkdownContent(), failures: [String] = []
            for path in paths {
                let file = url(path), bytes = try Data(contentsOf: file)
                do {
                    let part = try PlannerMarkdown.read(bytes, fallbackName: file.deletingPathExtension().lastPathComponent, fallbackDate: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(), relativePath: path, contactFile: path.hasPrefix("Contacts/") || path.hasPrefix("人脈/") || ["人脈", "Contacts"].contains(directory.lastPathComponent))
                    markdown.journal += part.journal; markdown.contacts += part.contacts; markdown.interactions += part.interactions; markdown.completions += part.completions
                    if !part.contacts.isEmpty, !part.hasBirthdayField,
                       String(decoding: bytes.prefix(64), as: UTF8.self).hasPrefix(PlannerMarkdown.signature) {
                        contactsWithoutBirthdayField.insert(path)
                    }
                    expected[path] = bytes; found = true
                } catch { failures.append(path); expected[path] = bytes; unreadable.insert(path) }
            }
            do {
                if !failures.isEmpty {
                    guard (found && !stateBad) || paths.contains(where: { !failures.contains($0) }) else { throw PlannerError.invalidBackup("資料無法讀取，原檔保留。請選擇資料夾或重新開始。") }
                    warnings = failures
                }
                if !paths.isEmpty {
                    document.journal = try unique(markdown.journal)
                    document.contacts = try unique(markdown.contacts)
                    document.interactions = try unique(markdown.interactions)
                    var records: [UUID: CompletionRecord] = [:]
                    for item in markdown.completions {
                        if let old = records[item.id], old.journalExcerpt != nil || (item.journalExcerpt == nil && old.text.count >= item.text.count) { continue }
                        records[item.id] = item
                    }
                    document.completions = records.values.sorted { $0.date < $1.date }
                }
                if stateBad {
                    guard paths.contains(where: { !failures.contains($0) }) else { throw PlannerError.invalidBackup("資料無法讀取，請選擇資料夾或重新開始。") }
                    repair = true
                }
            }
            if !found { return nil }
            // Rebuild only disposable references; durable Markdown remains independent.
            let goalIDs = Set(document.goals.map(\.id)), contactIDs = Set(document.contacts.map(\.id))
            for i in document.tasks.indices {
                if let id = document.tasks[i].goalID, !goalIDs.contains(id) { document.tasks[i].goalID = nil }
                document.tasks[i].contactIDs.removeAll { !contactIDs.contains($0) }
            }
            document.reviews.removeAll { !goalIDs.contains($0.goalID) }
            document.captureCompletions()
            _ = try document.validated(); last = document
            return document
        }
    }
    private func unique<T: Identifiable>(_ rows: [T]) throws -> [T] where T.ID == UUID {
        guard Set(rows.map(\.id)).count == rows.count else { throw PlannerError.invalidBackup("Markdown 內有重複紀錄，請移除重複副本後重試。") }
        return rows
    }
    private func markdownPaths(includeBoth: Bool = false) throws -> [String] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        var result: [String] = []
        var folders = ["Journal", "Contacts", ""]
        for (english, legacy) in [("Journal", "日記"), ("Contacts", "人脈")] {
            if includeBoth || !manager.fileExists(atPath: url(english).path) { folders.append(legacy) }
        }
        for folder in folders {
            let location = folder.isEmpty ? directory : url(folder)
            guard manager.fileExists(atPath: location.path) else { continue }
            for file in try manager.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) where file.pathExtension.lowercased() == "md" {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                if folder.isEmpty && !["日記", "人脈", "Journal", "Contacts"].contains(directory.lastPathComponent) {
                    let prefix = try Data(contentsOf: file).prefix(64)
                    guard String(decoding: prefix, as: UTF8.self).hasPrefix(PlannerMarkdown.signature) else { continue }
                }
                result.append(folder.isEmpty ? file.lastPathComponent : folder + "/" + file.lastPathComponent)
            }
        }
        return result.sorted()
    }
    private func files(_ document: PlannerDocument) throws -> [String: Data] {
        var result: [String: Data]
        if !repair, contactsWithoutBirthdayField.isEmpty, !expected.keys.contains(where: { $0.hasPrefix("日記/") || $0.hasPrefix("人脈/") }),
           let last, last.journal == document.journal, last.contacts == document.contacts,
           last.interactions == document.interactions, last.completions == document.completions {
            result = expected.filter { $0.key.hasSuffix(".md") }
        } else {
            result = [:]
            let entries = Dictionary(grouping: document.journal) { PlannerDates.text($0.date, "yyyy-MM") }
            let records = Dictionary(grouping: document.completions) { PlannerDates.text($0.date, "yyyy-MM") }
            let oldEntries = Dictionary(grouping: last?.journal ?? []) { PlannerDates.text($0.date, "yyyy-MM") }
            let oldRecords = Dictionary(grouping: last?.completions ?? []) { PlannerDates.text($0.date, "yyyy-MM") }
            for month in Set(entries.keys).union(records.keys) {
                let path = "Journal/\(month).md"
                if let cached = expected[path], !repair, entries[month] == oldEntries[month], records[month] == oldRecords[month] {
                    result[path] = cached
                } else {
                    result[path] = try PlannerMarkdown.journal(month, entries: entries[month] ?? [], completions: records[month] ?? [])
                }
            }
            let interactions = Dictionary(grouping: document.interactions, by: \.contactID)
            var personRecords: [UUID: [CompletionRecord]] = [:]
            for record in document.completions { for id in record.contactIDs { personRecords[id, default: []].append(record) } }
            let oldContacts = Dictionary(uniqueKeysWithValues: (last?.contacts ?? []).map { ($0.id, $0) })
            let oldInteractions = Dictionary(grouping: last?.interactions ?? [], by: \.contactID)
            var oldPersonRecords: [UUID: [CompletionRecord]] = [:]
            for record in last?.completions ?? [] { for id in record.contactIDs { oldPersonRecords[id, default: []].append(record) } }
            for contact in document.contacts {
                var name = contact.name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "_")
                if name.hasPrefix(".") { name = "_" + name }
                if name.isEmpty { name = "未命名" }
                var filename = String(name.prefix(60)) + "--" + String(contact.id.uuidString.prefix(8)) + ".md"
                if result["Contacts/" + filename] != nil { filename = String(name.prefix(60)) + "--" + contact.id.uuidString + ".md" }
                let path = "Contacts/" + filename
                if let cached = expected[path], !repair, !contactsWithoutBirthdayField.contains(path), oldContacts[contact.id] == contact,
                   oldInteractions[contact.id] == interactions[contact.id], oldPersonRecords[contact.id] == personRecords[contact.id] {
                    result[path] = cached
                } else {
                    result[path] = try PlannerMarkdown.person(contact, interactions: interactions[contact.id] ?? [], completions: personRecords[contact.id] ?? [])
                }
            }
        }
        var core = document
        core.journal = []; core.contacts = []; core.interactions = []; core.completions = []
        // JSON contains only disposable planning data; the snapshot below protects in-flight writes.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Core references point into Markdown, so validate only the complete document above.
        result[".planner/state.json"] = try encoder.encode(core)
        return result
    }
    func save(_ document: PlannerDocument) throws {
        _ = try document.validated()
        try coordinated(writing: true) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let desired = try files(document)
            let changed = desired.filter { expected[$0.key] != $0.value }
            let removed = expected.keys.filter { desired[$0] == nil }
            for path in Set(changed.keys).union(removed) {
                let file = url(path)
                if let before = expected[path] {
                    guard manager.fileExists(atPath: file.path), try Data(contentsOf: file) == before else {
                        throw PlannerError.invalidBackup("\(path) 已在外部變更。請先重新載入，避免覆蓋內容。")
                    }
                } else if manager.fileExists(atPath: file.path) {
                    throw PlannerError.invalidBackup("\(path) 已存在，未覆寫。請先重新載入。")
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try manager.createDirectory(at: url(".planner"), withIntermediateDirectories: true)
            for folder in ["Journal", "Contacts"] { try manager.createDirectory(at: url(folder), withIntermediateDirectories: true) }
            let liveContacts = Set(document.contacts.map(\.id))
            let formerlyLive = Set(last?.contacts.map(\.id) ?? [])
            let deletingContacts = pendingContactDeletions.union(formerlyLive).subtracting(liveContacts)
            try encoder.encode(PendingSave(document: document, deletingContacts: deletingContacts))
                .write(to: url(".planner/pending.json"), options: .atomic)
            pendingContactDeletions = deletingContacts
            for path in changed.keys.sorted() {
                let file = url(path)
                if let previous = expected[path] {
                    if unreadable.contains(path) {
                        let kept = url(".planner/無法讀取/\(UUID().uuidString)-\(URL(fileURLWithPath: path).lastPathComponent)")
                        try manager.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try previous.write(to: kept, options: .atomic)
                    }
                    let copy = url(".planner/上一份/" + path)
                    try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try previous.write(to: copy, options: .atomic)
                }
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try desired[path]!.write(to: file, options: .atomic)
                expected[path] = desired[path]
            }
            for path in removed {
                if !deletingContacts.isEmpty, let id = removedContactID(at: path), deletingContacts.contains(id) {
                    try manager.removeItem(at: url(path))
                    expected[path] = nil
                    continue
                }
                let archive = url(".planner/封存/\(UUID().uuidString)-\(URL(fileURLWithPath: path).lastPathComponent)")
                try manager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: url(path), to: archive)
                expected[path] = nil
            }
            try manager.removeItem(at: url(".planner/pending.json"))
            expected = desired; last = document; repair = false
            pendingContactDeletions = []; contactsWithoutBirthdayField = []
            unreadable.subtract(changed.keys); unreadable.subtract(removed); warnings = Array(unreadable).sorted()
        }
    }
    private func removedContactID(at path: String) -> UUID? {
        let personFolders = ["人脈", "Contacts"]
        guard let bytes = expected[path], path.hasSuffix(".md"), !unreadable.contains(path) else { return nil }
        let isContactFile = personFolders.contains { path.hasPrefix($0 + "/") }
            || (!path.contains("/") && (personFolders.contains(directory.lastPathComponent)
                || String(decoding: bytes.prefix(64), as: UTF8.self).hasPrefix(PlannerMarkdown.signature)))
        guard isContactFile else { return nil }
        let file = url(path)
        return (try? PlannerMarkdown.read(bytes, fallbackName: file.deletingPathExtension().lastPathComponent,
                                          fallbackDate: Date(), relativePath: path, contactFile: true))?.contacts.first?.id
    }

    static func snapshotFiles(_ document: PlannerDocument) throws -> [String: Data] {
        try MarkdownVault(directory: defaultDirectory).files(document)
    }

    func findBackup() throws -> PlannerDocument? {
        try coordinated(writing: false) {
            guard manager.fileExists(atPath: directory.path) else { return nil }
            let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) where file.pathExtension.lowercased() == "json" {
                if let value = try? PlannerDisk.decode(Data(contentsOf: file)) { return value }
            }
            return nil
        }
    }
    static func freshLocation(in folder: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path), !(try manager.contentsOfDirectory(atPath: folder.path)).isEmpty {
            let child = folder.appendingPathComponent("新資料-\(PlannerDates.text(Date(), "yyyyMMdd-HHmmss"))-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try manager.createDirectory(at: child, withIntermediateDirectories: true); return child
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
}
