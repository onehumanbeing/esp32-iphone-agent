import SwiftUI

struct ModelSelectionView: View {
    @ObservedObject var settings: Settings
    @Binding var selection: String
    let allowsDefault: Bool
    var onChoose: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var customID = ""

    static let routers: Set<String> = ["openrouter/free", "openrouter/auto"]

    static func displayName(_ id: String) -> String {
        switch id {
        case "openrouter/free": String(localized: "Automatic · Free models")
        case "openrouter/auto": String(localized: "Automatic · OpenRouter")
        default: id
        }
    }

    private var tested: [TestedModel] { TestedModels.list(for: settings.provider).filter { matchesSearch($0.id) } }

    /// The endpoint's list, without the tested models shown above it.
    private var matches: [String] {
        let testedIDs = Set(TestedModels.list(for: settings.provider).map(\.id))
        let ids = Set(settings.models + (selection.isEmpty ? [] : [selection])).subtracting(testedIDs)
        return ids.filter(matchesSearch).sorted()
    }

    private func matchesSearch(_ id: String) -> Bool {
        search.isEmpty || id.localizedStandardContains(search) || Self.displayName(id).localizedStandardContains(search)
    }

    var body: some View {
        let visible = matches, tested = tested
        NavigationStack {
            List {
                if allowsDefault && search.isEmpty {
                    Button("Use Default") { choose("") }
                }
                DisclosureGroup("Custom model") {
                    TextField("Model ID", text: $customID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Use Model ID") { choose(customID.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(customID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !tested.isEmpty {
                    Section("Tested") {
                        ForEach(tested, id: \.id) { row($0.id, recommended: $0.recommended) }
                    }
                }
                if settings.provider == .openRouter {
                    openRouterSections(visible)
                } else if !visible.isEmpty {
                    Section("Models") {
                        ForEach(visible, id: \.self) { id in row(id) }
                    }
                }
                if settings.loadingModels {
                    ProgressView("Loading models…")
                } else if visible.isEmpty && tested.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No models loaded", systemImage: "list.bullet",
                                               description: Text("Refresh the list or enter a model ID below."))
                    } else { ContentUnavailableView.search(text: search) }
                }
                if let error = settings.modelsError {
                    Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
                }

            }
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh Models", systemImage: "arrow.clockwise") {
                        Task { await settings.loadModels() }
                    }
                    .disabled(settings.loadingModels || !settings.isConfigured)
                }
            }
            .task {
                if settings.models.isEmpty && !settings.loadingModels { await settings.loadModels() }
            }
        }
    }

    /// Free (the free router first) and paid (the auto router first); the list holds vision models only.
    @ViewBuilder private func openRouterSections(_ visible: [String]) -> some View {
        let free = visible.filter { settings.freeModels.contains($0) || $0 == "openrouter/free" }
            .sorted { ($0 == "openrouter/free" ? 0 : 1, $0) < ($1 == "openrouter/free" ? 0 : 1, $1) }
        let paid = visible.filter { !free.contains($0) }
            .sorted { ($0 == "openrouter/auto" ? 0 : 1, $0) < ($1 == "openrouter/auto" ? 0 : 1, $1) }
        if !free.isEmpty {
            Section {
                ForEach(free, id: \.self) { id in row(id) }
            } header: { Text("Free") } footer: {
                Text("Free models are rate-limited (about 20 requests a minute, 50 a day) and often busy; a run takes 20–40 requests, so runs can be slow or stop partway. Automatic picks a free vision model for each request.")
            }
        }
        if !paid.isEmpty {
            Section {
                ForEach(paid, id: \.self) { id in row(id) }
            } header: { Text(verbatim: "OpenRouter") } footer: {
                Text("Billed to your OpenRouter credits. Vision models only.")
            }
        }
    }

    private func row(_ id: String, recommended: Bool = false) -> some View {
        Button { choose(id) } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(Self.displayName(id)).foregroundStyle(.primary)
                    if Self.routers.contains(id) {
                        Text(verbatim: id).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if recommended { RecommendedBadge() }
                if selection == id {
                    Image(systemName: "checkmark").accessibilityLabel("Selected")
                }
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }

    private func choose(_ id: String) {
        if let onChoose, !id.isEmpty { onChoose(id) } else { selection = id }
        dismiss()
    }
}
