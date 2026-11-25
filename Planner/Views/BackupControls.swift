import SwiftUI
import UniformTypeIdentifiers

private struct PlannerZIPDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PlannerError.invalidBackup("無法開啟備份。") }
        bytes = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct BackupControls: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var output: PlannerZIPDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var working = false
    @State private var pending: PreparedBackup?

    var body: some View {
        Group {
            if !store.recoveryRequired {
                Button("匯出完整備份", systemImage: "square.and.arrow.up") {
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            let bytes = try await store.exportArchive()
                            output = PlannerZIPDocument(bytes: bytes)
                            exporting = true
                        } catch { store.error = error.localizedDescription }
                    }
                }
            }
            Button("還原備份", systemImage: "square.and.arrow.down") { importing = true }
            if working { ProgressView("正在處理備份…") }
        }
        .disabled(working || store.loading)
        .fileExporter(isPresented: $exporting, document: output, contentType: .zip,
                      defaultFilename: "Planner-\(PlannerDates.text(Date(), "yyyy-MM-dd-HHmmss"))-\(UUID().uuidString.prefix(6))") { result in
            if case .failure(let error) = result { store.error = "無法匯出：\(error.localizedDescription)" }
            output = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .json]) { result in
            working = true
            Task {
                defer { working = false }
                do {
                    let url = try result.get()
                    pending = try await Task.detached(priority: .userInitiated) { try BackupArchive.read(url) }.value
                } catch { store.error = "無法讀取備份：\(error.localizedDescription)" }
            }
        }
        .sheet(item: $pending) { RestorePreview(backup: $0) }
    }
}

private struct RestorePreview: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    let backup: PreparedBackup

    var body: some View {
        NavigationStack {
            Form {
                let date = PlannerDates.text(backup.createdAt, "yyyy/MM/dd HH:mm")
                Section {
                    LabeledContent("備份時間", value: date)
                    LabeledContent("目標", value: "\(backup.document.goals.count)")
                    LabeledContent("任務", value: "\(backup.document.tasks.count)")
                    LabeledContent("日記", value: "\(backup.document.journal.count)")
                    LabeledContent("聯絡人", value: "\(backup.document.contacts.count)")
                } footer: {
                    Text("目前畫面將換成 \(date) 的資料。若目前有資料，會先將還原前的 ZIP 存到「Planner Backups」。")
                }
            }
            .plannerErrors()
            .disabled(store.loading)
            .interactiveDismissDisabled(store.loading)
            .navigationTitle("預覽備份").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.loading) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("確認還原", role: .destructive) {
                        Task { if await store.restoreArchive(backup) { dismiss() } }
                    }.disabled(store.loading)
                }
            }
        }
    }
}
