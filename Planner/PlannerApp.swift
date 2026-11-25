import SwiftUI

@main
struct PlannerApp: App {
    @StateObject private var store = PlannerStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).tint(.plannerAccent)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: PlannerStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showingSettings = false
    var body: some View {
        TabView(selection: $tab) {
            GoalsView().tabItem { Label("目標", systemImage: "scope") }.tag(0)
            PlanView().tabItem { Label("計畫", systemImage: "calendar") }.tag(1)
            JournalView().tabItem { Label("日記", systemImage: "book.closed") }.tag(2)
            ContactsView().tabItem { Label("人脈", systemImage: "person.2") }.tag(3)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.recoveryRequired {
                Button("資料需要還原，點此開啟設定", systemImage: "exclamationmark.icloud") { showingSettings = true }
                    .font(.callout).padding(10).frame(maxWidth: .infinity).background(.orange.opacity(0.15))
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer(minLength: 8)
                    if store.canUndoSchedule { Button("復原") { store.undoSchedule() }.font(.caption.bold()) }
                    Button { store.notice = nil } label: { Image(systemName: "xmark").font(.caption) }.accessibilityLabel("關閉提示")
                }
                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16).padding(.bottom, 58)
            }
        }
        .alert("無法完成操作", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: scenePhase) { _, value in
            // Refresh relative dates and overdue indicators after midnight / foregrounding.
            if value == .active { store.objectWillChange.send() }
        }
    }
}
