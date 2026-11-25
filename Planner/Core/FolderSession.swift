import Foundation

struct OpenedFolder {
    let document: PlannerDocument
    let directory: URL
    let notice: String?
}

// All filesystem work and the coalesced writer share one serial queue.
final class FolderSession {
    private let queue = DispatchQueue(label: "Planner.files", qos: .userInitiated)
    private var vault: MarkdownVault?
    private var pending: PlannerDocument?
    private var work: DispatchWorkItem?
    private let legacy: PlannerDisk
    private let defaults: UserDefaults
    init(legacy: PlannerDisk, defaults: UserDefaults) { self.legacy = legacy; self.defaults = defaults }
    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    private func flushNow() throws {
        work?.cancel(); work = nil
        if let pending {
            guard let vault else { throw PlannerError.invalidBackup("尚未選擇資料位置。") }
            try vault.save(pending); self.pending = nil
        }
    }
    func flush() async throws { try await perform { try self.flushNow() } }
    func enqueue(_ document: PlannerDocument, urgent: Bool = false, completion: @escaping @MainActor (String?) -> Void) {
        queue.async {
            self.work?.cancel(); self.pending = document
            let item = DispatchWorkItem {
                let failure: String?
                do { try self.flushNow(); failure = nil } catch { failure = error.localizedDescription }
                Task { @MainActor in completion(failure) }
            }
            self.work = item
            self.queue.asyncAfter(deadline: .now() + (urgent ? 0 : 0.18), execute: item)
        }
    }
    func open(_ directory: URL, migrateLegacy: Bool = false) async throws -> OpenedFolder {
        try await perform {
            try self.flushNow()
            let candidate = MarkdownVault(directory: directory)
            if let document = try candidate.load() {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".planner/backup.marker").path) {
                    return try self.install(document, in: MarkdownVault.defaultDirectory, notice: "已還原備份，原備份保留。")
                }
                self.vault = candidate
                return OpenedFolder(document: document, directory: directory, notice: candidate.warnings.isEmpty ? nil : "已載入可用內容；部分檔案無法讀取，原檔保留。")
            }
            if let backup = try candidate.findBackup() {
                return try self.install(backup, in: MarkdownVault.defaultDirectory, notice: "已從備份還原，原備份保留。")
            }
            if migrateLegacy {
                if FileManager.default.fileExists(atPath: self.legacy.file.path) {
                    let document = try self.legacy.load(defaults: self.defaults)
                    return try self.install(document, in: directory, notice: "已轉換舊版資料，原檔保留。")
                }
                if ["tasks", "journal", "contacts"].contains(where: { LegacyStorage.bytes($0, defaults: self.defaults)?.isEmpty == false }) {
                    let migration = self.recoverLegacy()
                    guard migration.recovered else { throw PlannerError.invalidBackup("舊資料格式無法辨識。請選擇資料夾或重新開始；原資料保留。") }
                    let opened = try self.install(migration.document, in: directory, notice: migration.issues.isEmpty ? "已匯入舊版資料。" : "已載入可用資料；無法辨識的內容保留於原始資料副本。")
                    for key in ["tasks", "journal", "contacts"] {
                        if let raw = LegacyStorage.bytes(key, defaults: self.defaults) {
                            let destination = opened.directory.appendingPathComponent(".planner/原始資料/\(key).json")
                            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try raw.write(to: destination, options: .atomic)
                        }
                    }
                    return opened
                }
            }
            throw PlannerError.invalidBackup("找不到可用的 Planner 資料。請選擇存有資料的資料夾，或重新開始。")
        }
    }
    private func recoverLegacy() -> (document: PlannerDocument, recovered: Bool, issues: [String]) {
        var result = PlannerDocument(), issues: [String] = [], found = false
        for key in ["tasks", "journal", "contacts"] {
            guard let bytes = LegacyStorage.bytes(key, defaults: defaults), !bytes.isEmpty else { continue }
            do {
                guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [Any] else { throw PlannerError.invalidBackup(key) }
                if rows.isEmpty { found = true }
                for row in rows {
                    do {
                        let record = try JSONDecoder().decode(LegacyRecord.self, from: JSONSerialization.data(withJSONObject: row))
                        found = true
                        switch key {
                        case "tasks": result.tasks.append(PlannerTask(id: record.id, title: record.text, notes: record.done ? "舊版匯入，原完成日期未記錄。" : "", completedAt: record.done ? Date() : nil))
                        case "journal": result.journal.append(JournalEntry(id: record.id, text: record.text + "\n\n〔舊版匯入，原日期未記錄〕"))
                        default: result.contacts.append(Contact(id: record.id, name: record.text))
                        }
                    } catch { issues.append(key) }
                }
            } catch { issues.append(key) }
        }
        return (result, found, issues)
    }
    private func install(_ value: PlannerDocument, in folder: URL, notice: String?) throws -> OpenedFolder {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let directory = try MarkdownVault.freshLocation(in: folder)
        let next = MarkdownVault(directory: directory)
        var document = value; document.captureCompletions()
        try next.save(document)
        self.vault = next
        return OpenedFolder(document: document, directory: directory, notice: notice)
    }
    func create(in directory: URL, document: PlannerDocument = PlannerDocument()) async throws -> OpenedFolder {
        try await perform {
            try self.flushNow()
            return try self.install(document, in: directory, notice: "已建立資料，原有檔案保留。")
        }
    }
    func reload() async throws -> OpenedFolder {
        try await perform {
            guard let vault = self.vault else { throw PlannerError.invalidBackup("尚未選擇資料夾。") }
            // Keep unsaved edits available for export instead of silently discarding them.
            do { try self.flushNow() }
            catch {
                guard let pending = self.pending else { throw error }
                let scope = vault.directory.startAccessingSecurityScopedResource()
                defer { if scope { vault.directory.stopAccessingSecurityScopedResource() } }
                let file = vault.directory.appendingPathComponent("未儲存修改-\(UUID().uuidString).json")
                try JSONEncoder().encode(pending).write(to: file, options: .atomic)
                self.pending = nil
            }
            guard let value = try vault.load() else { throw PlannerError.invalidBackup("找不到原資料，請重新選擇資料夾。") }
            return OpenedFolder(document: value, directory: vault.directory, notice: "已重新載入。")
        }
    }
    func copy(_ document: PlannerDocument, to parent: URL) async throws -> URL {
        try await perform {
            try self.flushNow()
            let scoped = parent.startAccessingSecurityScopedResource()
            defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
            let folder = parent.appendingPathComponent("Planner備份-\(PlannerDates.text(Date(), "yyyyMMdd-HHmmss"))-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try MarkdownVault(directory: folder).save(document)
            try Data("Planner backup".utf8).write(to: folder.appendingPathComponent(".planner/backup.marker"), options: .atomic)
            return folder
        }
    }
}
