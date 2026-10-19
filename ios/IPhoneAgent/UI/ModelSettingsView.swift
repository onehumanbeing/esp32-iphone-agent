import SwiftUI

/// Settings › Model: endpoint, key and the model picked from the endpoint's list; overrides under Advanced.
struct ModelSettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings
    @State private var testing = false
    @State private var advanced = false
    @AppStorage(ModelImage.key) private var shrinkImage = true
    @AppStorage(AppModel.prewarmKey) private var prewarm = true

    var body: some View {
        Form {
            Section {
                ProviderFields(settings: settings)
            } header: {
                Text("Model Provider")
            } footer: {
                if let url = settings.provider.keyURL { Link("Get an API key", destination: url) }
            }
            Section {
                Button {
                    testing = true
                    Task { await app.pingLLM(); testing = false }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if testing { ProgressView() } else if let ok = app.modelOK {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? Palette.ok : Palette.stop)
                        }
                    }
                }
                .disabled(testing || !app.modelReady)
                ModelTestTimingView(app: app)
                if let error = app.modelError {
                    Text(verbatim: error).font(.footnote).foregroundStyle(Palette.stop)
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    let same = String(localized: "Same as Model")
                    ModelPicker(settings: settings, title: "Planner model", selection: $settings.plannerModel, automatic: same)
                    ModelPicker(settings: settings, title: "Actor model", selection: $settings.actorModel, automatic: same)
                    Picker("Token parameter", selection: $settings.tokenParam) {
                        ForEach(["auto"] + LLMClient.tokenParams, id: \.self) { Text(verbatim: $0) }
                    }
                    TextField("Extra body JSON", text: $settings.extraBody, prompt: Text(verbatim: "{}"))
                        .font(.body.monospaced())
                    Toggle("Smaller screenshots", isOn: $shrinkImage)
                    Toggle("Pre-warm screen stream", isOn: $prewarm)
                }
            } footer: {
                if advanced {
                    Text("Smaller screenshots send the model a 540-pixel-wide copy of the screen, which uploads faster. Pre-warm streams the screen while this app is open, so a run sees the screen sooner.")
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)

    }
}
