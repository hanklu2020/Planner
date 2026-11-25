import SwiftUI

struct PlannerSearch {
    var text = ""
    var isVisible = false
    var requestsFocus = false

    var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func reveal(focus: Bool) {
        isVisible = true
        if focus { requestsFocus = true }
    }
}

struct PlannerSearchBar: View {
    @Binding var search: PlannerSearch
    let title: String
    let identifier: String
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(title, text: $search.text)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { focused = false }
                    .accessibilityIdentifier(identifier)
                    .onAppear(perform: focusIfRequested)
                    .onChange(of: search.requestsFocus) { _, _ in focusIfRequested() }
            }
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            Button("取消", action: cancel)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
    }

    private func focusIfRequested() {
        guard search.requestsFocus else { return }
        focused = true
        search.requestsFocus = false
    }
}

struct PlannerSearchPull: ViewModifier {
    let enabled: Bool
    let reveal: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content
                .scrollBounceBehavior(.always, axes: .vertical)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top <= -64
                } action: { _, isPulled in
                    if enabled && isPulled { reveal() }
                }
        } else {
            content
        }
    }
}
