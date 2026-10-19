import SwiftUI

/// A searchable selection sheet shared by setup and all model overrides.
struct ModelPicker: View {
    @ObservedObject var settings: Settings
    let title: LocalizedStringKey
    @Binding var selection: String
    let automatic: String
    var allowsDefault = true
    /// Instead of writing `selection` (the shared model also takes a tested model's parameters).
    var onChoose: ((String) -> Void)? = nil
    @State private var showingModels = false

    var body: some View {
        Button { showingModels = true } label: {
            LabeledContent(title) {
                HStack {
                    Text(selection.isEmpty ? automatic : ModelSelectionView.displayName(selection))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Image(systemName: "chevron.right").font(.footnote)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingModels) {
            ModelSelectionView(settings: settings, selection: $selection, allowsDefault: allowsDefault, onChoose: onChoose)
        }
    }
}
