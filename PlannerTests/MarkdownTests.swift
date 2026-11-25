import XCTest
@testable import Planner

final class MarkdownTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture() -> PlannerDocument {
        var value = PlannerDocument()
        let contact = Contact(name: "#家人/朋友", details: "電話：123\n\n喜歡閱讀 & 運動")
        let goal = Goal(title: "家庭聚餐", domain: .family)
        value.contacts = [contact]; value.goals = [goal]
        value.journal = [JournalEntry(date: Date(timeIntervalSince1970: 1795550400), text: "第一段。\n\n## 自己的標題\n- 一個項目\n中文與日本語、絵文字🌱")]
        value.interactions = [Interaction(contactID: contact.id, date: Date(timeIntervalSince1970: 1795550400), text: "通話內容\n下一次再見面。")]
        value.tasks = [PlannerTask(title: "訂餐廳", notes: "保留完成當下的說明", goalID: goal.id, contactIDs: [contact.id], completedAt: Date(timeIntervalSince1970: 1795550400))]
        value.captureCompletions(); return value
    }
    func testMarkdownReadableRoundTripAndNoDuplicateBodiesInCore() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = fixture(), vault = MarkdownVault(directory: root)
        try vault.save(doc)
        let restored = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertEqual(restored.journal, doc.journal)
        XCTAssertEqual(restored.contacts, doc.contacts)
        XCTAssertEqual(restored.interactions, doc.interactions)
        XCTAssertEqual(restored.completions, doc.completions)
        XCTAssertEqual(restored.tasks, doc.tasks)
        let state = try String(contentsOf: root.appendingPathComponent(".planner/state.json"), encoding: .utf8)
        XCTAssertFalse(state.contains("第一段")); XCTAssertFalse(state.contains("電話"))
        let file = root.appendingPathComponent("Journal/2026-11.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("第一段")); XCTAssertTrue(text.contains("訂餐廳"))
    }
    func testMarkdownSurvivesDeletingPlansAndRenamingTask() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = fixture(); let original = doc.completions
        let vault = MarkdownVault(directory: root); try vault.save(doc)
        doc.tasks[0].title = "改名"; doc.tasks[0].completedAt = nil; doc.captureCompletions()
        XCTAssertEqual(doc.completions, original)
        doc.goals = []; doc.tasks = []; doc.reviews = []
        try vault.save(doc)
        let loaded = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertEqual(loaded.completions, original); XCTAssertEqual(loaded.journal, doc.journal)
        XCTAssertTrue(loaded.tasks.isEmpty); XCTAssertEqual(loaded.contacts.count, 1)
    }
    func testMissingAndCorruptCoreRebuildFromMarkdown() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = fixture(); try MarkdownVault(directory: root).save(doc)
        let file = root.appendingPathComponent(".planner/state.json")
        try FileManager.default.removeItem(at: file)
        var recovered = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertEqual(recovered.journal, doc.journal); XCTAssertEqual(recovered.contacts, doc.contacts)
        XCTAssertTrue(recovered.tasks.isEmpty)
        try Data("broken".utf8).write(to: file)
        let vault = MarkdownVault(directory: root)
        recovered = try XCTUnwrap(vault.load()); try vault.save(recovered)
        XCTAssertEqual(recovered.completions, doc.completions)
    }
    func testExternalChangesAreNotOverwritten() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = fixture(); let vault = MarkdownVault(directory: root); try vault.save(doc)
        let file = root.appendingPathComponent("Journal/2026-11.md")
        let external = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "第一段", with: "外部修改")
        try Data(external.utf8).write(to: file)
        doc.journal[0].text = "App 修改"
        XCTAssertThrowsError(try vault.save(doc))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)
        let reread = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertTrue(reread.journal[0].text.contains("外部修改"))
    }
    func testPartlyDamagedMarkdownPreservesGoodFilesAndArchivesBadBytes() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = fixture(); try MarkdownVault(directory: root).save(doc)
        let bad = root.appendingPathComponent("Journal/2026-10.md"), raw = Data("<!-- Planner Markdown 1 -->\n# 壞掉\n\n<!-- planner:invalid -->\n".utf8)
        try raw.write(to: bad)
        let vault = MarkdownVault(directory: root)
        doc = try XCTUnwrap(vault.load())
        XCTAssertEqual(doc.journal.count, 1); XCTAssertFalse(vault.warnings.isEmpty)
        doc.journal.append(JournalEntry(date: Date(timeIntervalSince1970: 1790870400), text: "新內容"))
        try vault.save(doc)
        let archive = root.appendingPathComponent(".planner/無法讀取")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil).contains { try Data(contentsOf: $0) == raw })
    }
    func testPlanningOnlySaveDoesNotRewriteMarkdown() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = fixture(); let vault = MarkdownVault(directory: root); try vault.save(doc)
        let file = root.appendingPathComponent("Journal/2026-11.md")
        let old = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        // URL resource values can retain a cached timestamp after setAttributes.
        func modified() throws -> Date? { try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date }
        XCTAssertEqual(try modified(), old)
        doc.tasks[0].schedule = Schedule(Date()); try vault.save(doc)
        XCTAssertEqual(try modified(), old)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testPendingWriteRecoveryAndEmptyFolderDetection() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try MarkdownVault(directory: root).load())
        var first = fixture(); let vault = MarkdownVault(directory: root); try vault.save(first)
        first.journal[0].text = "中斷前最新內容"
        try JSONEncoder().encode(first).write(to: root.appendingPathComponent(".planner/pending.json"))
        let next = MarkdownVault(directory: root), recovered = try XCTUnwrap(next.load())
        XCTAssertEqual(recovered.journal[0].text, "中斷前最新內容")
        try next.save(recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".planner/pending.json").path))
        XCTAssertEqual(try MarkdownVault(directory: root).load()?.journal[0].text, "中斷前最新內容")
    }
    func testBirthdayMetadataKeepsTagsAndLegacyMarkdownReadable() throws {
        let tag = UUID(), person = Contact(name: "Amy", details: "備註", tagIDs: [tag], birthday: ContactBirthday(month: 2, day: 29))
        let bytes = try PlannerMarkdown.person(person, interactions: [], completions: [])
        let path = "Contacts/Amy.md"
        func read(_ bytes: Data) throws -> Contact? {
            try PlannerMarkdown.read(bytes, fallbackName: "Amy", fallbackDate: Date(), relativePath: path, contactFile: true).contacts.first
        }
        XCTAssertEqual(try read(bytes), person)
        let old = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "**生日**：02-29\n\n", with: "")
        XCTAssertEqual(try read(Data(old.utf8))?.tagIDs, [tag])
        XCTAssertNil(try read(Data(old.utf8))?.birthday)
        let calendar = PlannerDates.calendar
        let newYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        let date = try XCTUnwrap(person.birthday?.next(on: newYear, calendar: calendar))
        XCTAssertEqual(PlannerDates.text(date, "yyyy-MM-dd", calendar: calendar), "2025-02-28")
    }

    func testDeletingContactRemovesItsMarkdownAndKeepsOtherPerson() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MarkdownVault(directory: root)
        var document = PlannerDocument()
        let kept = Contact(name: "Keep"), removed = Contact(name: "Remove")
        document.contacts = [kept, removed]
        try vault.save(document)
        let people = root.appendingPathComponent("Contacts")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: people, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("Remove--") })
        document.contacts = [kept]
        try vault.save(document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try MarkdownVault(directory: root).load()?.contacts, [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".planner/封存").path))
    }

    func testLegacyMissingFieldsAndStringStorage() throws {
        let suite = "MarkdownTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("[{\"title\":\"舊任務\"}]", forKey: "tasks")
        defaults.set("[{\"name\":\"舊聯絡人\"}]", forKey: "contacts")
        let value = try PlannerMigration.migrate(defaults: defaults)
        XCTAssertEqual(value.tasks.first?.title, "舊任務"); XCTAssertFalse(value.tasks[0].isDone)
        XCTAssertEqual(value.contacts.first?.name, "舊聯絡人")
    }
    func testVersionTwoMissingOptionalCollectionsStillLoads() throws {
        let data = Data("{\"version\":2,\"tasks\":[],\"journal\":[]}".utf8)
        let document = try PlannerDisk.decode(data)
        XCTAssertEqual(document.version, PlannerDocument.currentVersion); XCTAssertTrue(document.contacts.isEmpty)
    }
    func testLargeJournalAndDuplicateNamesRemainSeparate() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = PlannerDocument()
        doc.contacts = [Contact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "同名"), Contact(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "同名")]
        doc.journal = (0..<2000).map { JournalEntry(date: Date(timeIntervalSince1970: 1795550400 + Double($0)), text: "第\($0)筆日記，保留中文內容。") }
        try MarkdownVault(directory: root).save(doc)
        let loaded = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertEqual(loaded.journal.count, 2000); XCTAssertEqual(loaded.contacts.count, 2)
    }
    @MainActor
    func testStartupCreateRememberReloadAndHistoryIndependence() async throws {
        let root = try temporary(), suite = "MarkdownTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        // An explicit existing folder is the normal startup path after selection.
        let value = fixture(); try MarkdownVault(directory: root).save(value)
        let store = PlannerStore(defaults: defaults)
        for _ in 0..<2000 { if !store.loading { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(store.loading)
        await store.openFolder(root)
        XCTAssertFalse(store.recoveryRequired)
        XCTAssertEqual(store.data.journal, value.journal)
        XCTAssertTrue(store.commit { $0.tasks = []; $0.goals = []; $0.reviews = [] })
        await store.flush()
        let loaded = try XCTUnwrap(MarkdownVault(directory: root).load())
        XCTAssertEqual(loaded.completions, value.completions)
        let reopened = PlannerStore(defaults: defaults)
        for _ in 0..<2000 { if !reopened.loading { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(reopened.loading)
        XCTAssertFalse(reopened.recoveryRequired)
        XCTAssertEqual(reopened.data.journal, value.journal)
        await store.startNew(in: root)
        XCTAssertFalse(store.recoveryRequired); XCTAssertTrue(store.data.journal.isEmpty)
        XCTAssertNotEqual(store.directory, root)
        XCTAssertEqual(try MarkdownVault(directory: root).load()?.journal, value.journal)
    }
}
