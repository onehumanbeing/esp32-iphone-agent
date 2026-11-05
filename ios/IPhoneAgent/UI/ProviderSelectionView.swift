import SwiftUI

/// The Provider row of the model form: the current provider's logo and name; tapping opens the list.
struct ProviderPicker: View {
    @ObservedObject var settings: Settings
    @State private var showing = false

    private var name: String {
        guard settings.provider == .others else { return settings.provider.title }
        return settings.customEndpoints.first { $0.id == settings.activeCustomID }?.title ?? String(localized: "Custom Endpoint")
    }

    var body: some View {
        Button { showing = true } label: {
            LabeledContent("Provider") {
                HStack(spacing: Space.s) {
                    ProviderLogoView(provider: settings.provider, size: 22)
                    Text(verbatim: name).lineLimit(1).truncationMode(.middle)
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

/// All providers with their logos (recommended first), then the saved custom endpoints.
/// A filter narrows the list to what's already set up.
struct ProviderSelectionView: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var configuredOnly = false

    private var presets: [ModelProvider] {
        let all = ModelProvider.allCases.filter { $0 != .others && $0 != .handsyTrial }  // free line: own section
        let ordered = all.filter(\.recommended) + all.filter { !$0.recommended }
        return configuredOnly ? ordered.filter(settings.isConfigured) : ordered
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
                if !presets.isEmpty {
                    Section("Providers") { ForEach(presets, content: presetRow) }
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
                        recommended: provider.recommended, configured: settings.isConfigured(provider), selected: selected)
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
                        recommended: false, configured: true, selected: selected)
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

/// One provider in the list: logo, name and address, status badges at the top right.
private struct ProviderRow: View {
    let logo: ModelProvider
    let title: String
    let subtitle: String
    let recommended: Bool
    let configured: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            ProviderLogoView(provider: logo, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(verbatim: title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: Space.s)
                    if selected { StatusBadge(text: "In Use", color: .blue, symbol: "checkmark.circle.fill") }
                    else if configured { StatusBadge(text: "Configured", color: .green, symbol: "checkmark") }
                    if recommended { RecommendedBadge() }
                }
                Text(verbatim: subtitle)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

/// A provider's mark in its brand color on a tinted rounded square.
struct ProviderLogoView: View {
    let provider: ModelProvider
    let size: CGFloat

    private var color: Color {
        let c = provider.brandColor
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.opacity(0.15))
            .frame(width: size, height: size)
            .overlay { mark.foregroundStyle(color) }
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

/// Small tinted capsule for list status ("Recommended", "Configured").
struct StatusBadge: View {
    let text: LocalizedStringKey
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// "Recommended" badge, shared by the provider and model lists.
struct RecommendedBadge: View {
    var body: some View { StatusBadge(text: "Recommended", color: .orange, symbol: "star.fill") }
}
