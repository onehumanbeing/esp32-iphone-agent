import SwiftUI

/// What run data holds, for the consent sheet and Settings › Privacy. The saved runs are never uploaded; what a
/// run sends to the model and to Jev is covered by their own consent (SendConsentSheet).
struct PrivacyLists: View {
    var body: some View {
        Section {
            entry("Kept on this iPhone", Self.kept)
            entry("Never collected", Self.never)
        } header: {
            Text("Your data")
        } footer: {
            Text("The run history on this iPhone is never uploaded. What a run sends while it works goes only to the AI service you allow (and to Jev, when it is on); Handsy Free keeps its own record of each run. An export is redacted: secrets and IP addresses removed, typed text hidden, the top of every screenshot blacked out.")
        }
    }

    private func entry(_ title: LocalizedStringKey, _ items: [String.LocalizationValue]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(verbatim: ListFormatter.localizedString(byJoining: items.map { String(localized: $0) }))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static let kept: [String.LocalizationValue] = ["Per-step screenshots", "Actions", "Model replies", "Timings",
                                                   "Board metrics", "Device model and iOS version"]
    static let never: [String.LocalizationValue] = ["Wi-Fi password", "API key", "Base URL", "Contacts"]
}

/// The usage-stats switch, off by default; only in builds that can send stats (see Analytics).
struct UsageStatsSection: View {
    @AppStorage(Analytics.consentKey) private var on = false

    var body: some View {
        if Analytics.available {
            Section {
                Toggle("Share anonymous usage stats", isOn: $on)
                    .onChange(of: on) { _, value in Analytics.consentChanged(value) }
            } footer: {
                Text("Helps improve setup and runs: which setup steps finish, run results, step counts and timings, the model provider, model speed and token counts, app and iOS version, and crash reports. Never your tasks, screenshots, model replies, keys or addresses.")
            }
        }
    }
}

/// First launch, before setup: one sheet for what a run sends and to whom (the model and Jev as set up now),
/// what is kept here, and the two switches (both off). Agree and Continue records the same yes as
/// SendConsentSheet; Not Now records none, so the first run asks again. See FirstConsent.
struct ConsentSheet: View {
    @ObservedObject var settings: Settings
    @AppStorage(RunShare.keepKey) private var keep = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let parts = FirstConsent.parts(settings)
        NavigationStack {
            List {
                SendConsentHero()
                SendConsentParts(settings: settings, model: parts.model, jev: parts.jev)
                if !parts.model && !parts.jev {
                    Section { Text("Once a model is set up, you'll be asked before a run sends anything to it.").font(.subheadline) }
                }
                PrivacyLists()
                Section {
                    Toggle("Keep run data for sharing", isOn: $keep)
                } footer: {
                    Text("Lets you export redacted runs from Settings › Privacy to share with the community. You can change this anytime.")
                }
                UsageStatsSection()
                SendConsentFooter(policy: AboutView.privacyPolicy)
            }
            .listSectionSpacing(Space.l)
            .navigationTitle("Your Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { FirstConsent.notNow(); dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { FirstConsent.agree(settings); dismiss() } label: {
                    Text("Agree and Continue").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
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

/// Settings › Privacy: the same lists, the switch, and Export run data.
struct PrivacySettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @AppStorage(RunShare.keepKey) private var keep = false
    @State private var picked = Set<String>()
    @State private var package: RunShare.Package?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            AIConsentSection(settings: app.settings)
            JevConsentSection()
            PrivacyLists()
            Section { Toggle("Keep run data for sharing", isOn: $keep) }
            if keep { export }
            UsageStatsSection()
            Section { LinkRow(title: "Privacy policy", symbol: "hand.raised.fill", color: .indigo, url: AboutView.privacyPolicy) }
        }
        .navigationTitle("Privacy")
        .onAppear { runs.reload() }
        .onChange(of: picked) { package = nil }
    }

    @ViewBuilder private var export: some View {
        Section {
            ForEach(runs.runs.filter { !$0.imported }) { run in
                Button { toggle(run.id) } label: {
                    HStack {
                        Image(systemName: picked.contains(run.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked.contains(run.id) ? Color.accentColor : .secondary)
                        Text(verbatim: run.task.isEmpty ? run.id : run.task).lineLimit(1)
                        Spacer()
                        Text(run.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text("Export run data")
        }
        Section {
            if let package {
                Text("\(package.runs) runs, \(ByteCountFormatter.string(fromByteCount: Int64(package.bytes), countStyle: .file)), redacted")
                ShareLink(item: package.url) { Label("Share", systemImage: "square.and.arrow.up") }
            } else {
                Button { prepare() } label: {
                    HStack {
                        Label("Prepare Export", systemImage: "doc.zipper")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(picked.isEmpty || working)
            }
            if let error { Text(verbatim: error).foregroundStyle(Palette.stop).font(.footnote) }
        } footer: {
            Text("A .zip with steps, metrics, screenshots, video frames and debug.log, redacted before it is written.")
        }
    }

    private func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func prepare() {
        working = true
        error = nil
        let folders = runs.runs.filter { picked.contains($0.id) }.map(\.folder)
        let redactor = app.shareRedactor
        Task.detached {
            let result = Result { try RunShare.export(folders, redactor: redactor, debugLog: DebugLog.url) }
            await MainActor.run {
                working = false
                switch result {
                case .success(let p): package = p
                case .failure(let e): error = e.localizedDescription
                }
            }
        }
    }
}
