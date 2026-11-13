import SwiftUI

/// The free line at the top of Choose Provider, with its live free / busy badge.
struct TrialSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var trial = Trial.shared
    let dismiss: DismissAction

    var body: some View {
        Section {
            Button {
                settings.selectedProvider = .handsyTrial
                dismiss()
            } label: {
                ProviderRow(logo: .handsyTrial, title: ModelProvider.handsyTrial.title,
                            subtitle: String(localized: "Private model, no API key. Limited capacity."),
                            selected: settings.provider == .handsyTrial, wraps: true) {
                    TrialBadge(status: trial.status)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Free")
        }
        .task { _ = await trial.refresh() }
    }
}

/// In Model settings, in place of the key and model fields.
struct TrialPanel: View {
    @ObservedObject private var trial = Trial.shared
    @State private var key = Trial.shared.key

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(verbatim: "Handsy").font(.headline)
                Spacer()
                if trial.keyed { StatusBadge(text: "Key", symbol: "key.fill", emphasized: true) } else { TrialBadge(status: trial.status) }
                Button { Task { _ = await trial.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Check again")
            }
            Text("Free to try with limited capacity: up to 3 minutes per run, a few runs per phone. When it's busy, try again in a minute or add your own model.")
                .font(.footnote).foregroundStyle(.secondary)
            SecureField("Handsy key", text: $key, prompt: Text("Handsy key (optional)"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: key) { _, new in trial.setKey(new) }
            Text("With a Handsy key, runs use your plan instead of the free runs.")
                .font(.footnote).foregroundStyle(.secondary)
            #if HANDSY_STORE
            HandsyStoreEntry()
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.s)
        .task { _ = await trial.refresh() }
    }
}

struct TrialBadge: View {
    let status: Trial.Status

    var body: some View {
        switch status {
        case .free: StatusBadge(text: "Free", symbol: "circle.fill", emphasized: true)
        case .waiting: StatusBadge(text: "Queue", symbol: "hourglass")
        case .busy: StatusBadge(text: "Busy", symbol: "hourglass")
        case .usedUp: StatusBadge(text: "Used Up")
        case .unavailable: StatusBadge(text: "Unavailable")
        case .unknown: ProgressView().controlSize(.mini)
        }
    }
}

/// What the AI consent sheet adds for the free line: runs are recorded, and where they are processed.
struct TrialConsentSections: View {
    var body: some View {
        Section("Recorded") {
            Label("Each run on Handsy Free (task, screenshots, replies, timing) is saved privately to fix problems and improve Handsy", systemImage: "externaldrive")
            Label("Processed and kept on infrastructure operated by or on behalf of Holomix, Inc.", systemImage: "globe.asia.australia")
            Label("To decide simple steps faster, a step's screenshot, your task and the plan may go to TypeSafe, a service provider", systemImage: "bolt")
        }
        Section {
            Text("Screenshots may show anything on your screen and are not blurred, so avoid private tasks on Handsy Free. To have records deleted, write to support@handsy.tech. You can withdraw this anytime in Settings › Privacy.")
                .font(.footnote).foregroundStyle(.secondary)
            if let url = Trial.privacyURL { Link("Handsy Free privacy notice", destination: url).font(.footnote) }
        }
    }
}

/// Settings › Privacy: the installation ID Handsy Free keeps records under, and the mail that asks to delete them.
struct TrialRecordsSection: View {
    var body: some View {
        if Trial.available {
            let id = Trial.shared.installationID
            Section {
                LabeledContent("Installation ID") {
                    Text(verbatim: id).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let url = Self.mail(id) { Link("Ask to Delete My Records", destination: url) }
            } header: {
                Text("Handsy Free records")
            } footer: {
                Text("Handsy Free keeps its record of each run under this ID. The mail asks us to delete them; nothing else is attached.")
            }
        }
    }

    static func mail(_ id: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = "support@handsy.tech"
        parts.queryItems = [URLQueryItem(name: "subject", value: "Delete my Handsy Free records"),
                            URLQueryItem(name: "body", value: "Please delete the Handsy Free records of installation \(id).")]
        return parts.url
    }
}
