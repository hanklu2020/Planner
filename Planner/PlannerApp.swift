import SwiftUI

@main
struct PlannerApp: App {
    @StateObject private var store = PlannerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "zh_Hant_TW"))
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: PlannerStore

    var body: some View {
        TabView {
            PlanView()
                .tabItem { Label("計畫", systemImage: "calendar") }
            JournalView()
                .tabItem { Label("日記", systemImage: "book") }
            ContactsView()
                .tabItem { Label("人脈", systemImage: "person.2") }
        }
        .alert("無法儲存", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}
