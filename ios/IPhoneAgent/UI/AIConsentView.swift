import SwiftUI

/// What goes to the model provider, before the first request to it. Agree only after reading to the end.
struct AIConsentSheet: View {
    let baseURL: String
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var host: String { AIConsent.host(baseURL) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("To work, ESP32 Agent sends data to the AI service you chose. Nothing is sent until you agree.")
                }
                Section("Sent to") {
                    Label { Text(verbatim: host).font(.body.monospaced()) } icon: { Image(systemName: "server.rack") }
                }
                Section("What is sent") {
                    Label("A screenshot of your mirrored screen at every step of a run, so the AI can see it", systemImage: "photo")
                    Label("The task you type and the steps so far", systemImage: "text.bubble")
                    if !Trial.isTrial(baseURL) { Label("Your API key, to sign in to that service", systemImage: "key") }
                }
                Section("When") {
                    Label("Only when you start a run, test the connection, check the calibration or save an intent", systemImage: "hand.tap")
                }
                if Trial.isTrial(baseURL) {  // free line
                    TrialConsentSections()
                } else {
                    Section {
                        Text("Screenshots may show anything on your screen. \(host) handles them under its own privacy policy and terms; the ESP32 Agent developer never receives them. You can withdraw this anytime in Settings › Privacy.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Send to AI Service?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    AIConsent.grant(baseURL)
                    Analytics.capture("ai_consent", ["granted": true])
                    onAgree()
                    dismiss()
                } label: {
                    Text("I Agree to Send This Data").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal).padding(.vertical, Space.s)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// In the model form: the state of the agreement for the current host, and the button that asks for it.
struct AIConsentRow: View {
    @ObservedObject var settings: Settings
    @State private var asking = false

    var body: some View {
        if AIConsent.store && settings.isConfigured {
            let host = AIConsent.host(settings.baseURL)
            Group {
                if AIConsent.granted(settings.baseURL) {
                    Label { Text("Allowed to send to \(host)") } icon: {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(Palette.ok)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                } else {
                    // Nothing works until this is allowed: an unmistakable blocker with a solid button.
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label { Text("Not allowed to send to \(host) yet") } icon: {
                            Image(systemName: "exclamationmark.shield.fill")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        Button { asking = true } label: {
                            Text("Review and Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, Space.s)
                }
            }
            .sheet(isPresented: $asking) {
                AIConsentSheet(baseURL: settings.baseURL) { settings.consentChanged() }
            }
        }
    }
}

/// Settings › Privacy: the agreed host, and withdraw.
struct AIConsentSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        if AIConsent.store {
            Section {
                if let host = AIConsent.grantedHost {
                    LabeledContent("Allowed", value: host)
                    Button("Withdraw", role: .destructive) {
                        AIConsent.revoke()
                        Analytics.capture("ai_consent", ["granted": false])
                        settings.consentChanged()
                    }
                } else {
                    Text("No AI service allowed. Runs ask first.").foregroundStyle(.secondary)
                }
            } header: {
                Text("AI service")
            } footer: {
                Text("Screenshots and your task go only to the AI service you allowed, and only during runs, tests and intent saving.")
            }
        }
    }
}
