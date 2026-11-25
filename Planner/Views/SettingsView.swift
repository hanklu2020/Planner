import SwiftUI
import UniformTypeIdentifiers

struct PlannerBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws { bytes = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}

struct SettingsView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var export = false
    @State private var importing = false
    @State private var backup = PlannerBackup(bytes: Data())
    @State private var pendingImport: Data?
    @State private var confirmImport = false
    @State private var confirmRestore = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("版本", value: "2.0.0")
                    Text("目標有方向，計畫有下一步。").foregroundStyle(.secondary)
                    LabeledContent("目標", value: "\(store.data.goals.count)")
                    LabeledContent("任務", value: "\(store.data.tasks.count)")
                    LabeledContent("聯絡人", value: "\(store.data.contacts.count)")
                }
                Section {
                    Button("匯出完整備份", systemImage: "square.and.arrow.up") {
                        do { backup = PlannerBackup(bytes: try store.exportData()); export = true }
                        catch { store.error = error.localizedDescription }
                    }.disabled(store.recoveryRequired)
                    Button("匯入備份", systemImage: "square.and.arrow.down") { importing = true }
                    Button("還原上一份資料", systemImage: "clock.arrow.circlepath") { confirmRestore = true }
                } header: { Text("備份與還原") } footer: {
                    Text("資料保存在這台 iPhone，離線可用。備份包含日記與聯絡人資料，請存放在自己的安全位置。刪除 App 前請先匯出備份。")
                }
                Section("使用方式") {
                    Text("目標：六個領域，設定成果並加入任務。")
                    Text("計畫：點任務日期快選；多選可批次安排；待安排清單可連續安排。")
                    Text("縮放切換日／週／月／年，也可點日期標題選擇。")
                    Text("完成的任務會出現在日記，並連到相關聯絡人的往來紀錄。今天與昨天標為最近完成，兩天以前列為完成紀錄。")
                    Text("未完成任務會留在待處理，不會自動堆到明天；目標需自行確認達成。")
                }.font(.subheadline)
            }
            .navigationTitle("設定與備份").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $export, document: backup, contentType: .json, defaultFilename: "Planner-\(PlannerDates.text(Date(), "yyyy-MM-dd-HHmm"))") { result in
                if case .failure(let error) = result { store.error = "無法匯出：\(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    _ = try PlannerDisk.decode(bytes)
                    pendingImport = bytes; confirmImport = true
                } catch { store.error = "無法讀取備份：\(error.localizedDescription)" }
            }
            .alert("以備份取代目前資料？", isPresented: $confirmImport) {
                Button("取消", role: .cancel) { pendingImport = nil }
                Button("取代並還原", role: .destructive) { if let bytes = pendingImport { _ = store.importData(bytes) }; pendingImport = nil }
            } message: { Text("目前資料會被備份內容取代。若有新紀錄，請先匯出保存。") }
            .alert("還原上一份資料？", isPresented: $confirmRestore) {
                Button("取消", role: .cancel) { }
                Button("還原", role: .destructive) { store.restorePrevious() }
            } message: { Text("會回到最近一次儲存前的狀態。") }
        }
    }
}
