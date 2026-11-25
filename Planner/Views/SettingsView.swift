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
    @State private var folderAction: FolderAction?
    @State private var browser = false
    @State private var clearPlans = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("版本", value: "2.1.0")
                    LabeledContent("目標", value: "\(store.data.goals.count)")
                    LabeledContent("任務", value: "\(store.data.tasks.count)")
                    LabeledContent("聯絡人", value: "\(store.data.contacts.count)")
                    if store.isSaving { Label("正在儲存…", systemImage: "arrow.triangle.2.circlepath").font(.caption) }
                    if store.saveFailed { Button("重試儲存") { Task { await store.flush() } } }
                }
                Section {
                    Text(location).font(.subheadline).textSelection(.enabled)
                    Button("查看資料檔", systemImage: "doc.text") { browser = true }.disabled(store.recoveryRequired)
                    Button("開啟現有資料夾", systemImage: "folder") { folderAction = .open }
                    Button("變更儲存位置", systemImage: "folder.badge.plus") { folderAction = .move }.disabled(store.recoveryRequired)
                    Button("重新載入檔案", systemImage: "arrow.clockwise") { Task { await store.reloadFolder() } }.disabled(store.recoveryRequired)
                    Menu("建立全新資料") {
                        Button("使用預設位置") { Task { await store.startNew() } }
                        Button("選擇其他位置") { folderAction = .create }
                    }
                } header: { Text("資料位置") } footer: {
                    Text("日記按月份、人脈按人物保存為 Markdown。切換或建立新資料會保留原位置的檔案。重新載入時，無法儲存的修改會另存復原副本。")
                }
                Section {
                    Button("另存資料夾備份", systemImage: "folder.badge.plus") { folderAction = .backup }.disabled(store.recoveryRequired)
                    Button("匯出完整備份", systemImage: "square.and.arrow.up") {
                        do { backup = PlannerBackup(bytes: try store.exportData()); export = true }
                        catch { store.error = error.localizedDescription }
                    }.disabled(store.recoveryRequired)
                    Button("匯入 JSON 備份", systemImage: "square.and.arrow.down") { importing = true }
                } header: { Text("備份與還原") } footer: {
                    Text("備份請選另一個位置。刪除 App 可能一併移除「我的 iPhone／Planner」中的檔案；重要內容請另外保存。匯入備份會建立新的工作資料夾，原資料與原備份保留。")
                }
                Section {
                    Button("清空目標與計畫", role: .destructive) { clearPlans = true }.disabled(store.recoveryRequired)
                } footer: { Text("只清除目標、任務與回顧安排。日記、聯絡人、已留下的完成與往來紀錄會保留。") }
                Section("使用方式") {
                    Text("資料可讀取時直接開啟；找不到資料時，可選資料夾或重新開始。")
                    Text("點日期快選、多選批次安排；待安排清單可連續安排。縮放或點日期標題切換日／週／月／年。")
                    Text("完成任務會留下獨立歷史。重新開啟或刪除任務，不會抹去既有日記與往來。")
                    Text("Markdown 文字可用一般工具閱讀。保留文件內的識別標記；外部改動後，先重新載入再編輯。")
                }.font(.subheadline)
            }
            .disabled(store.loading)
            .overlay { if store.loading { ProgressView("正在處理資料…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .plannerErrors()
            .navigationTitle("設定與備份").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $folderAction) { mode in
                FolderPicker(directory: store.directory, selected: { url in
                    folderAction = nil
                    Task {
                        switch mode {
                        case .open: await store.openFolder(url)
                        case .create: await store.startNew(in: url)
                        case .move: await store.moveFolder(to: url)
                        case .backup: await store.backupFolder(to: url)
                        }
                    }
                }, cancelled: { folderAction = nil })
            }
            .sheet(isPresented: $browser) { VaultBrowserView() }
            .fileExporter(isPresented: $export, document: backup, contentType: .json, defaultFilename: "Planner-\(PlannerDates.text(Date(), "yyyy-MM-dd-HHmm"))") { result in
                if case .failure(let error) = result { store.error = "無法匯出：\(error.localizedDescription)" }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = store.importData(try Data(contentsOf: url))
                } catch { store.error = "無法讀取備份：\(error.localizedDescription)" }
            }
            .confirmationDialog("清空目標與計畫？日記與人脈歷史會保留。", isPresented: $clearPlans, titleVisibility: .visible) {
                Button("清空目標與計畫", role: .destructive) {
                    _ = store.commit { $0.goals = []; $0.tasks = []; $0.reviews = [] }
                }
            }
        }
    }
    private var location: String {
        guard let url = store.directory else { return "尚未選擇位置" }
        let root = MarkdownVault.defaultDirectory.path
        if url.path == root { return "我的 iPhone／Planner" }
        if url.path.hasPrefix(root + "/") { return "我的 iPhone／Planner／" + String(url.path.dropFirst(root.count + 1)) }
        return url.lastPathComponent
    }
}
