import SwiftUI

/// One compact configuration form shared by onboarding and Settings.
struct ProviderFields: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            ProviderPicker(settings: settings)
            Divider()
            if settings.provider == .others {
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $settings.baseURL, prompt: Text(verbatim: "https://…/v1"))
                        .keyboardType(.URL).multilineTextAlignment(.trailing).labelsHidden()
                }
                .frame(minHeight: 44).padding(.vertical, Space.xs)
                Divider()
            }
            if settings.provider == .handsyTrial {  // free line: no key, one fixed model
                TrialPanel()
            } else {
                LabeledContent("API key") {
                    SecureField("API key", text: $settings.apiKey,
                                prompt: Text(settings.provider == .others ? "Optional" : "Required"))
                        .multilineTextAlignment(.trailing).labelsHidden()
                }
                .frame(minHeight: 44).padding(.vertical, Space.xs)
                Divider()
                ModelPicker(settings: settings, title: "Model", selection: $settings.model,
                            automatic: String(localized: "Choose a model"), allowsDefault: false,
                            onChoose: settings.chooseModel)
                    .frame(minHeight: 44).padding(.vertical, Space.xs)
            }
            if AIConsent.store && settings.isConfigured {
                Divider()
                AIConsentRow(settings: settings)
            }
            if settings.provider == .openRouter && (settings.model == "openrouter/free" || settings.model.hasSuffix(":free")) {
                Text("Free models are rate-limited (about 20 requests a minute, 50 a day) and often busy. A run takes 20–40 requests, so runs can be slow or stop partway. A paid model works better.")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, Space.s)
            }
            if let error = settings.modelsError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .task(id: settings.baseURL + "\n" + settings.apiKey) {
            guard settings.provider != .others, !settings.apiKey.isEmpty,
                  (try? await Task.sleep(for: .milliseconds(700))) != nil else { return }
            await settings.loadModels()
        }
    }
}
