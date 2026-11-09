import SwiftUI

/// The model row's fold: provider, key and model, the same fields as before.
struct ModelFieldsSheet: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { ProviderFields(settings: settings) }
                if let url = settings.provider.keyURL {
                    Section { KeyLinkRow(title: "Get an API key", url: url) }
                }
            }
            .navigationTitle("Large Language Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The Jev row's fold: Handsy's server (default), or TypeSafe on your own key.
struct JevFieldsSheet: View {
    @AppStorage(JevConfig.ownKey) private var ownKey = false
    @AppStorage(JevConfig.modelKey) private var model = TypeSafeJev.defaultModel
    @AppStorage(JevConfig.thresholdKey) private var threshold = JevConfig.defaultThreshold
    @State private var apiKey = JevConfig.apiKey
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Runs on", selection: $ownKey) {
                        Text(verbatim: "Handsy").tag(false)
                        Text("TypeSafe, your key").tag(true)
                    }
                    if ownKey {
                        FieldRow(title: "API key") {
                            SecureField("API key", text: $apiKey, prompt: Text("Required"))
                        }
                        FieldRow(title: "Model") {
                            TextField("Model", text: $model, prompt: Text(verbatim: TypeSafeJev.defaultModel))
                        }
                    }
                } footer: {
                    Text(ownKey ? "Steps go straight from this iPhone to TypeSafe on your key; Handsy gets nothing. The key stays in this iPhone's Keychain."
                         : "Steps go to Jev on Handsy's server, free of charge.")
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        LabeledContent("Confidence needed", value: threshold.formatted(.percent.precision(.fractionLength(0))))
                        Slider(value: $threshold, in: JevConfig.thresholdRange, step: 0.05)
                            .accessibilityLabel(Text("Confidence needed"))
                    }
                    if threshold != JevConfig.defaultThreshold {
                        Button("Reset to Default") { threshold = JevConfig.defaultThreshold }
                    }
                } footer: {
                    Text("Jev takes a step only when it is at least this sure; otherwise the Large Language Model decides. Lower is faster, higher is more careful. Handsy's server may ask for more on some kinds of steps.")
                }
                if ownKey, let url = URL(string: "https://typesafe.ai") {
                    Section { KeyLinkRow(title: "Get a TypeSafe key", url: url) }
                }
            }
            .navigationTitle("Jev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: apiKey) { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: JevConfig.keychainAccount)
                DebugLog.redact([apiKey]) }
        }
    }
}

/// A label on the left, the field right-aligned on the same line.
struct FieldRow<Field: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: Space.m) {
            Text(title)
            field.multilineTextAlignment(.trailing).labelsHidden().frame(maxWidth: .infinity)
        }
        .frame(minHeight: 44)
    }
}

/// Where to get a key: a whole row that opens the provider's page.
struct KeyLinkRow: View {
    let title: LocalizedStringKey
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: Space.m) {
                Image(systemName: "key").frame(width: 24).foregroundStyle(.secondary)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Settings › Privacy: Jev's consent for own-model runs, and withdraw (which turns Jev off).
struct JevConsentSection: View {
    @State private var granted = JevConsent.granted

    var body: some View {
        if Trial.available, granted || JevConsent.granted {
            Section {
                LabeledContent("Jev", value: String(localized: "Allowed"))
                Button("Withdraw", role: .destructive) {
                    JevConsent.revoke()
                    Analytics.capture("jev_consent", ["granted": false])
                    granted = false
                }
            } footer: {
                Text("With your own model, each step's screenshot, task, plan and recent actions go to Jev while it is on.")
            }
        }
    }
}
