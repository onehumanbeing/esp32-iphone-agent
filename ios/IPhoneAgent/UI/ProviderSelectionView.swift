import SwiftUI

/// The Provider row of the model form: the current provider's logo and name; tapping opens the list.
struct ProviderPicker: View {
    @ObservedObject var settings: Settings
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            LabeledContent("Provider") {
                HStack(spacing: Space.s) {
                    ProviderLogoView(provider: settings.provider, size: 22)
                    Text(verbatim: settings.providerName).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) { ProviderSelectionView(settings: settings) }
    }
}

extension Settings {
    /// The provider's name, or the custom endpoint's.
    var providerName: String {
        guard provider == .others else { return provider.title }
        return customEndpoints.first { $0.id == activeCustomID }?.title ?? String(localized: "Custom Endpoint")
    }
}

/// All providers with their logos (recommended ones in their own section), then the saved custom endpoints.
/// A filter narrows the list to what's already set up.
struct ProviderSelectionView: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var configuredOnly = false

    private var presets: [ModelProvider] {
        let all = ModelProvider.allCases.filter { $0 != .others && $0 != .handsyTrial }  // free line: own section
        return configuredOnly ? all.filter(settings.isConfigured) : all
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $configuredOnly) {
                    Text("All").tag(false)
                    Text("Configured").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if Trial.available && !configuredOnly { TrialSection(settings: settings, dismiss: dismiss) }  // free line
                let recommended = presets.filter(\.recommended), more = presets.filter { !$0.recommended }
                if !recommended.isEmpty {
                    Section("Recommended") { ForEach(recommended, content: presetRow) }
                }
                if !more.isEmpty {
                    Section("More Providers") { ForEach(more, content: presetRow) }
                }
                if !configuredOnly || !settings.customEndpoints.isEmpty {
                    Section("Custom Endpoints") {
                        ForEach(settings.customEndpoints, content: customRow)
                        if !configuredOnly { addRow }
                    }
                }
            }
            .overlay {
                if configuredOnly, presets.isEmpty, settings.customEndpoints.isEmpty {
                    ContentUnavailableView("No Configured Providers", systemImage: "key",
                                           description: Text("Add an API key to a provider to see it here."))
                }
            }
            .navigationTitle("Choose Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { settings.saveCurrent() }  // the endpoint in use shows up in the list
        }
    }

    private func presetRow(_ provider: ModelProvider) -> some View {
        let selected = settings.provider == provider
        return Button {
            settings.selectedProvider = provider
            dismiss()
        } label: {
            ProviderRow(logo: provider, title: provider.title, subtitle: provider.host,
                        configured: settings.isConfigured(provider), selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customRow(_ endpoint: CustomEndpoint) -> some View {
        let selected = settings.provider == .others && settings.activeCustomID == endpoint.id
        return Button {
            settings.selectCustom(endpoint.id)
            dismiss()
        } label: {
            ProviderRow(logo: .others, title: endpoint.title,
                        subtitle: endpoint.model.isEmpty ? endpoint.baseURL : endpoint.model,
                        configured: true, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .swipeActions {
            if !selected {
                Button("Delete", systemImage: "trash", role: .destructive) { settings.deleteCustom(endpoint.id) }
            }
        }
    }

    private var addRow: some View {
        Button {
            settings.selectCustom(nil)
            dismiss()
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Custom Endpoint").foregroundStyle(.primary)
                    Text("Any OpenAI-compatible endpoint").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One provider in the list: logo, name and address; at the trailing edge "Configured" or, for the one in
/// use, the selection checkmark (like Settings.app).
struct ProviderRow<Status: View>: View {
    let logo: ModelProvider
    let title: String
    let subtitle: String
    var configured = false
    let selected: Bool
    var wraps = false  // a sentence, not an address: wrap instead of cutting the middle out
    @ViewBuilder var status: Status

    var body: some View {
        HStack(spacing: Space.m) {
            ProviderLogoView(provider: logo, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).foregroundStyle(.primary).lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(wraps ? 2 : 1).truncationMode(wraps ? .tail : .middle)
            }
            Spacer(minLength: Space.s)
            status
            if configured && !selected { StatusBadge(text: "Configured") }
            if selected {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

extension ProviderRow where Status == EmptyView {
    init(logo: ModelProvider, title: String, subtitle: String, configured: Bool, selected: Bool) {
        self.init(logo: logo, title: title, subtitle: subtitle, configured: configured, selected: selected) { EmptyView() }
    }
}

/// A provider's mark, one color on a quiet rounded square: the list stays calm, the names do the work.
struct ProviderLogoView: View {
    let provider: ModelProvider
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: size, height: size)
            .overlay { mark.foregroundStyle(Palette.ink) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch provider.logo {
        case .asset(let name):
            Image(name).resizable().scaledToFit().padding(size * 0.22)
        case .letter(let letter):
            Text(verbatim: letter).font(.system(size: size * 0.5, weight: .bold, design: .rounded))
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.45, weight: .medium))
        }
    }
}

/// Quiet status text at the end of a list row ("Configured", "Busy"). `emphasized` takes the accent, for the
/// one state worth noticing (the free line is free); everything else stays secondary.
struct StatusBadge: View {
    let text: LocalizedStringKey
    var symbol: String?
    var emphasized = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(emphasized ? Palette.accent : Palette.muted)
        .fixedSize()
    }
}

/// "Recommended" in the model list.
struct RecommendedBadge: View {
    var body: some View { StatusBadge(text: "Recommended") }
}
