import SwiftUI
import UniformTypeIdentifiers

enum FolderAction: String, Identifiable {
    case open, create, move, backup
    var id: String { rawValue }
}

struct FolderPicker: UIViewControllerRepresentable {
    var directory: URL?
    var selected: (URL) -> Void
    var cancelled: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected, cancelled: cancelled) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.directoryURL = directory
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL) -> Void
        let cancelled: () -> Void
        init(selected: @escaping (URL) -> Void, cancelled: @escaping () -> Void) { self.selected = selected; self.cancelled = cancelled }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { selected(url) } else { cancelled() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelled() }
    }
}

struct StartupView: View {
    @EnvironmentObject private var store: PlannerStore
    @State private var action: FolderAction?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "folder.badge.questionmark").font(.system(size: 42)).foregroundStyle(Color.plannerAccent)
                Text("從資料繼續，\n或重新開始。").font(.title.bold())
                Text(store.startupReason).font(.subheadline).foregroundStyle(.secondary)
                Button { action = .open } label: { Label("選擇資料夾", systemImage: "folder").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).accessibilityIdentifier("chooseDataFolder")
                Menu {
                    Button("使用預設位置") { Task { await store.startNew() } }.accessibilityIdentifier("startNewDefault")
                    Button("選擇其他位置") { action = .create }
                } label: { Label("重新開始", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.bordered).accessibilityIdentifier("startNewMenu")
                Text("預設位置：我的 iPhone／Planner\n原有資料會保留；建立新資料不需要備份。").font(.caption).foregroundStyle(.secondary)
                Button("重試讀取") { Task { await store.openLastFolder() } }.font(.subheadline)
                Spacer(minLength: 0)
            }.padding(24).padding(.top, 24)
                .navigationTitle("Planner").navigationBarTitleDisplayMode(.inline)
                .disabled(store.loading)
                .overlay { if store.loading { ProgressView("正在處理資料…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
                .sheet(item: $action) { mode in
                    FolderPicker(directory: store.directory, selected: { url in
                        action = nil
                        Task { if mode == .open { await store.openFolder(url) } else { await store.startNew(in: url) } }
                    }, cancelled: { action = nil })
                }
        }
    }
}

struct CompletionRow: View {
    let record: CompletionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(record.title, systemImage: "checkmark.circle.fill").foregroundStyle(Color.plannerAccent)
            if let goal = record.goalTitle { Text(goal).font(.caption).foregroundStyle(.secondary) }
            if !record.text.isEmpty { Text(record.text).font(.subheadline).foregroundStyle(.secondary) }
            Text(PlannerDates.text(record.date, "yyyy/M/d HH:mm")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct VaultBrowserView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.red) }
                if files.isEmpty && failure == nil { Text("寫下日記或新增聯絡人後，Markdown 檔案就會出現在這裡。").foregroundStyle(.secondary) }
                ForEach(files, id: \.self) { file in
                    NavigationLink { MarkdownPreview(file: file, root: store.directory!) } label: {
                        Label(file.lastPathComponent, systemImage: "doc.text")
                    }
                }
            }.navigationTitle("資料檔案").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task {
                    await store.flush()
                    guard let root = store.directory else { return }
                    do {
                        files = try await Task.detached(priority: .userInitiated) {
                            let scope = root.startAccessingSecurityScopedResource()
                            defer { if scope { root.stopAccessingSecurityScopedResource() } }
                            return try ["日記", "人脈"].flatMap { folder -> [URL] in
                                let url = root.appendingPathComponent(folder)
                                guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
                            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                        }.value
                    } catch { failure = error.localizedDescription }
                }
        }
    }
}

private struct MarkdownPreview: View {
    let file: URL
    let root: URL
    @State private var content = ""
    var body: some View {
        ScrollView { Text(content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(18) }
            .navigationTitle(file.lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .task {
                do {
                    let root = root, file = file
                    content = try await Task.detached(priority: .userInitiated) {
                        let scope = root.startAccessingSecurityScopedResource()
                        defer { if scope { root.stopAccessingSecurityScopedResource() } }
                        let raw = try String(contentsOf: file, encoding: .utf8)
                        return raw.components(separatedBy: "\n").filter { !$0.hasPrefix("<!-- Planner") && !$0.hasPrefix("<!-- planner:") && !$0.hasPrefix("<!-- /planner:") }.joined(separator: "\n")
                    }.value
                } catch { content = "無法讀取：\(error.localizedDescription)" }
            }
    }
}
