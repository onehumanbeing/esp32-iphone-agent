import SwiftUI

/// One yes for everything a run still needs: the Large Language Model's host and/or Jev. Nothing goes to either
/// until the user agrees here; each part is withdrawn on its own in Settings › Privacy.
struct SendConsentSheet: View {
    @ObservedObject var settings: Settings
    var model: Bool
    var jev: Bool
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                SendConsentHero()
                SendConsentParts(settings: settings, model: model, jev: jev)
                SendConsentFooter(policy: jev && JevConsent.target == JevConsent.handsy ? Trial.privacyURL : nil)
            }
            .listSectionSpacing(Space.l)
            .navigationTitle(model && jev ? "Allow Sending to Both?" : "Allow Sending?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button(action: agree) {
                    Text(model && jev ? "Allow Both" : "Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal).padding(.vertical, Space.s)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }

    private func agree() {
        settings.grantConsent(model: model, jev: jev)
        onAgree()
        dismiss()
    }
}

/// The top of a consent sheet: nothing is sent before the yes.
struct SendConsentHero: View {
    var body: some View {
        Section {
            VStack(spacing: Space.s) {
                Image(systemName: "hand.raised").font(.system(size: 36, weight: .light)).foregroundStyle(Palette.ink)
                Text("Nothing leaves this iPhone until you agree.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }
}

/// What a run sends and to whom: the model's host and/or Jev, for the current configuration.
struct SendConsentParts: View {
    @ObservedObject var settings: Settings
    var model: Bool
    var jev: Bool

    private var host: String { AIConsent.host(settings.baseURL) }
    private var freeLine: Bool { Trial.isTrial(settings.baseURL) }
    private var jevOwnKey: Bool { JevConsent.target != JevConsent.handsy }

    var body: some View {
        if model { modelPart }
        if jev { jevPart }
    }

    @ViewBuilder private var modelPart: some View {
        Section {
            // The free line names who runs it, not just its address.
            if freeLine { recipient("brain", "Large Language Model", String(localized: "Handsy Free, operated by Holomix, Inc. (\(host))")) }
            else { recipient("brain", "Large Language Model", host, mono: true) }
            item("photo", "A screenshot of your mirrored screen at every step of a run, so the AI can see it")
            item("text.bubble", "The task you type and the steps so far")
            if !freeLine { item("key", "Your API key, to sign in to that service") }
            if freeLine { item("iphone", "Your iPhone's model (e.g. iPhone18,2), to adapt to its screen") }
            item("hand.tap", "Only when you start a run, test the connection, check the calibration or save an intent")
            if !freeLine { item("building.columns", "Handled under \(host)'s own privacy policy and terms") }
        }
        if freeLine { TrialConsentSections() }
    }

    private var jevPart: some View {
        Section {
            recipient("bolt", "Jev (decision model)",
                      jevOwnKey ? String(localized: "TypeSafe, on your own key")
                                : String(localized: "Holomix, Inc. (Handsy) and its provider TypeSafe"))
            item("photo", "A screenshot of your mirrored screen at every step")
            item("text.bubble", "Your task, the plan and the recent actions")
            if !jevOwnKey { item("lock", "Kept privately to run and improve Jev") }
        }
    }

    private func recipient(_ symbol: String, _ title: LocalizedStringKey, _ to: String, mono: Bool = false) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(verbatim: to).font(mono ? .footnote.monospaced() : .footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func item(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
        .listRowSeparator(.hidden)
    }
}

/// The bottom of a consent sheet: a warning about screenshots, withdraw, and a privacy policy.
struct SendConsentFooter: View {
    var policy: URL?

    var body: some View {
        Section {
            Text("Screenshots may show anything on your screen, so avoid private tasks. Withdraw anytime in Settings › Privacy.")
                .font(.footnote).foregroundStyle(.secondary)
            if let policy { Link("Privacy policy", destination: policy).font(.footnote) }
        }
    }
}

/// On the model page: what a run still needs a yes for, in one card with one button.
struct SendConsentCard: View {
    @ObservedObject var settings: Settings
    var model: Bool
    var jev: Bool
    var onAgree: () -> Void = {}
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label { Text(prompt) } icon: { Image(systemName: "hand.raised") }
                .font(.subheadline.weight(.semibold))
            Button { asking = true } label: {
                Text("Review and Allow").font(.headline).frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, Space.s)
        .sheet(isPresented: $asking) { SendConsentSheet(settings: settings, model: model, jev: jev, onAgree: onAgree) }
    }

    private var prompt: LocalizedStringKey {
        model && jev ? "Allow sending to the Large Language Model and Jev first"
            : jev ? "Allow sending to Jev first" : "Allow sending to \(AIConsent.host(settings.baseURL)) first"
    }
}
