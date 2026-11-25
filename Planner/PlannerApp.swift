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
        Group {
            if store.loading && store.directory == nil {
                ProgressView("正在讀取資料…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.recoveryRequired {
                StartupView()
            } else {
                TabView(selection: $tab) {
                    GoalsView().tabItem { Label("目標", systemImage: "scope") }.tag(0)
                    PlanView().tabItem { Label("計畫", systemImage: "calendar") }.tag(1)
                    JournalView().tabItem { Label("日記", systemImage: "book.closed") }.tag(2)
                    ContactsView().tabItem { Label("人脈", systemImage: "person.2") }.tag(3)
                }.disabled(store.loading)
            }
        }
        .overlay(alignment: .bottom) {
            if tab != 3 || store.recoveryRequired { PlannerNotice().padding(.bottom, 58) }
        }
        .plannerErrors()
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onChange(of: scenePhase) { _, value in
            // Refresh relative dates and overdue indicators after midnight / foregrounding.
            if value == .active { store.objectWillChange.send() }
            else { store.flushForBackground() }
        }
    }
}

struct PlannerNotice: View {
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        if let notice = store.notice {
            HStack {
                Text(notice).font(.caption)
                Spacer(minLength: 8)
                if store.canUndoChange { Button("復原") { store.undoChange() }.font(.caption.bold()) }
                else if store.canUndoSchedule { Button("復原") { store.undoSchedule() }.font(.caption.bold()) }
                Button { store.notice = nil; store.clearChangeUndo() } label: {
                    Image(systemName: "xmark").font(.caption)
                }.accessibilityLabel("關閉提示")
            }
            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
        }
    }
}
