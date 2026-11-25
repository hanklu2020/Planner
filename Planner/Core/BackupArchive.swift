import Foundation
import ZIPFoundation

struct PreparedBackup: Identifiable {
    let id = UUID()
    let createdAt: Date
    let document: PlannerDocument
}

enum BackupArchive {
    private struct Manifest: Codable {
        var formatVersion = 1
        let createdAt: Date
        let appVersion: String
        let files: [String]
    }

    private static let manifestPath = "manifest.json"
    private static let documentPath = "Planner.json"
    static let maximumBytes = 128 * 1024 * 1024

    static func make(_ document: PlannerDocument, date: Date = Date()) throws -> Data {
        _ = try document.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var entries = try MarkdownVault.snapshotFiles(document).filter { $0.key.hasSuffix(".md") }
        entries[documentPath] = try encoder.encode(document)
        entries[manifestPath] = try encoder.encode(Manifest(createdAt: date,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            files: entries.keys.sorted()))
        guard entries.values.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw PlannerError.invalidBackup("備份超過大小上限。") }

        let zip = try Archive(accessMode: .create)
        for (path, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate) { offset, size in
                let start = Int(offset)
                return bytes.subdata(in: start..<min(start + size, bytes.count))
            }
        }
        guard let bytes = zip.data else { throw PlannerError.invalidBackup("未能建立備份。") }
        return bytes
    }

    static func read(_ url: URL) throws -> PreparedBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard (info.fileSize ?? 0) <= maximumBytes else { throw PlannerError.invalidBackup("備份超過大小上限。") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw PlannerError.invalidBackup("備份超過大小上限。") }
        if url.pathExtension.lowercased() == "json" {
            return PreparedBackup(createdAt: info.contentModificationDate ?? Date(), document: try PlannerDisk.decode(bytes))
        }

        let zip = try Archive(data: bytes, accessMode: .read)
        var extracted: [String: Data] = [:]
        var expandedBytes = 0
        for entry in zip {
            let path = entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let isMarkdown = parts.count == 2 && ["Journal", "Contacts"].contains(String(parts[0]))
                && parts[1].hasSuffix(".md") && !parts[1].contains("\\")
            guard entry.type == .file, path == manifestPath || path == documentPath || isMarkdown,
                  extracted[path] == nil, entry.uncompressedSize <= UInt64(maximumBytes - expandedBytes) else {
                throw PlannerError.invalidBackup("備份包含重複、不支援或超過大小上限的項目。")
            }
            var content = Data()
            let checksum = try zip.extract(entry) { chunk in
                guard chunk.count <= maximumBytes - expandedBytes else { throw PlannerError.invalidBackup("備份超過大小上限。") }
                expandedBytes += chunk.count
                content.append(chunk)
            }
            guard checksum == entry.checksum, content.count == Int(entry.uncompressedSize) else {
                throw PlannerError.invalidBackup("備份檔案已損毀。")
            }
            extracted[path] = content
        }
        guard let manifestBytes = extracted.removeValue(forKey: manifestPath), let core = extracted[documentPath] else {
            throw PlannerError.invalidBackup("備份缺少必要檔案。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
        guard manifest.formatVersion == 1, manifest.files.sorted() == extracted.keys.sorted() else {
            throw PlannerError.invalidBackup("備份格式較新或檔案不完整。")
        }
        let document = try PlannerDisk.decode(core)
        return PreparedBackup(createdAt: manifest.createdAt, document: document)
    }
}
