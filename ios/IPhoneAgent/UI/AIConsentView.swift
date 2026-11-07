import SwiftUI

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
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(Palette.muted)
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
                SendConsentSheet(settings: settings, model: true, jev: false)
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
                Text("Screenshots and your task go only to the AI service you allowed (and to Jev, if you turn it on), and only during runs, tests and intent saving.")
            }
        }
    }
}
