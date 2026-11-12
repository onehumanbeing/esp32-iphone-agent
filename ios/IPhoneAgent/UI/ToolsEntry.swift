import SwiftUI

/// "Tools [Beta] · 2 on": the row to the Tools page in Settings › Model, and on onboarding's "Give Me a Brain".
struct ToolsRowLabel: View {
    @ObservedObject private var store = ToolStore.shared
    @ObservedObject private var trial = Trial.shared

    var body: some View {
        LabeledContent {
            Text("\(store.active.count) on")
        } label: {
            Label {
                HStack(spacing: Space.s) {
                    Text("Tools")
                    BetaBadge()
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
        }
    }
}

/// Onboarding's "Give Me a Brain": the Tools row as a card that opens the Tools page in a sheet.
struct ToolsEntry: View {
    @State private var open = false

    var body: some View {
        Button(action: show) {
            HStack {
                ToolsRowLabel()
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            NavigationStack {
                ToolsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) }
                    }
            }
        }
    }

    private func show() { open = true }
    private func close() { open = false }
}
