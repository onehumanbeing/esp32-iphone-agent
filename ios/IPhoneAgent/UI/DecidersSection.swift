import SwiftUI

/// Settings › Model: who decides each step. Two rows, Jev and the model: drag to set the order, switch each on
/// or off. On your own model, switching Jev on asks for its consent first.
struct DecidersSection: View {
    @ObservedObject var settings: Settings
    @State private var deciders = Deciders.standard(freeLine: false)
    @State private var asking = false
    @AppStorage(Deciders.raceKey) private var race = false

    private var freeLine: Bool { settings.provider == .handsyTrial }

    var body: some View {
        if Trial.available {
            Section {
                ForEach($deciders.order, id: \.self, editActions: .move) { $decider in row(decider) }
                if deciders.mode == .jevFirst { Toggle("Ask Jev and the model together", isOn: $race) }
            } header: {
                Text("Who decides each step")
            } footer: {
                Text(footer)
            }
            .onAppear { deciders = .load(freeLine: freeLine) }
            .onChange(of: settings.provider) { deciders = .load(freeLine: freeLine) }
            .onChange(of: deciders) { deciders.save(freeLine: freeLine) }
            .sheet(isPresented: $asking) { JevConsentSheet { deciders.set(.jev, on: true, freeLine: false) } }
        }
    }

    private func row(_ decider: Decider) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: decider == .jev ? "bolt.fill" : "brain")
                .foregroundStyle(decider == .jev ? Color.orange : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(decider == .jev ? "Jev (decision model)" : "Model")
                Text(decider == .jev ? "Takes the plain steps in a fraction of a second." : "Thinks through each step it gets.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(decider == .jev ? "Jev" : "Model", isOn: binding(decider))
                .labelsHidden()
                .disabled(decider == .model && freeLine)
        }
    }

    private func binding(_ decider: Decider) -> Binding<Bool> {
        Binding {
            deciders.isOn(decider)
        } set: { on in
            if decider == .jev, on, !freeLine, !JevConsent.granted { asking = true; return }
            deciders.set(decider, on: on, freeLine: freeLine)
        }
    }

    private var footer: LocalizedStringKey {
        switch deciders.mode {
        case .jevFirst: return "Jev goes first and leaves the steps it isn't sure about to the model. Drag to change the order."
        case .modelFirst: return "The model decides. Jev steps in only when the model doesn't answer. Drag to change the order."
        case .jevOnly: return "Experimental: only Jev decides. When it isn't sure about a step, the run stops and asks you."
        case .modelOnly: return freeLine ? "Only the model decides. On the free line the model stays on."
            : "Only your model decides. Jev sends each step to Handsy, so it asks before it turns on."
        }
    }
}

/// What goes to Jev from an own-model run, before the first step goes there. Agree only after reading.
struct JevConsentSheet: View {
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Jev is Handsy's decision model. It takes the plain steps of a run quickly, so your model has less to do. Nothing goes to Jev until you agree.")
                }
                Section("Sent to") {
                    Label("Holomix, Inc. (Handsy) and its provider TypeSafe", systemImage: "server.rack")
                }
                Section("What is sent") {
                    Label("A screenshot of your mirrored screen at every step", systemImage: "photo")
                    Label("Your task, the plan and the recent actions", systemImage: "text.bubble")
                }
                Section("What happens to it") {
                    Label("Kept privately to run and improve Jev", systemImage: "lock")
                    Label("Avoid private tasks while Jev is on", systemImage: "eye.slash")
                    Label("Withdraw anytime in Settings › Privacy; Jev then turns off", systemImage: "arrow.uturn.backward")
                }
                if let url = Trial.privacyURL {
                    Section { Link("Privacy policy", destination: url) }
                }
            }
            .navigationTitle("Turn On Jev?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    JevConsent.grant()
                    Analytics.capture("jev_consent", ["granted": true])
                    onAgree()
                    dismiss()
                } label: {
                    Text("I Agree, Turn On Jev").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
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

/// Settings › Privacy: Jev's consent for own-model runs, and withdraw (which turns Jev off).
struct JevConsentSection: View {
    @State private var granted = JevConsent.granted

    var body: some View {
        if Trial.available, granted {
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
