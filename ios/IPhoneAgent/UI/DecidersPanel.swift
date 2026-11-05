import SwiftUI

/// The heart of the model page (onboarding's "Give Me a Brain" and Settings › Model): who decides each step.
/// Two rows, Jev and the model: hold and drag one to set the order, switch each on or off. The model row folds
/// its provider, key and model into a sheet. On your own model, switching Jev on asks for its consent first.
/// Builds without the free line have no Jev: the caller shows the model fields as they are.
struct DecidersPanel: View {
    @ObservedObject var settings: Settings
    var inForm = false
    @State private var deciders = Deciders.standard(freeLine: false)
    @State private var editingModel = false
    @State private var askingConsent = false
    @AppStorage(Deciders.raceKey) private var race = false

    private var freeLine: Bool { settings.provider == .handsyTrial }

    var body: some View {
        Group {
            if inForm {
                Section { rows } header: { Text("Who decides each step") } footer: { Text(footer) }
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Who decides each step").font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.l)
                    Panel { rows }
                    Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                }
            }
        }
        .onAppear { deciders = .load(freeLine: freeLine) }
        .onChange(of: settings.provider) { deciders = .load(freeLine: freeLine) }
        .onChange(of: deciders) { deciders.save(freeLine: freeLine) }
        .sheet(isPresented: $askingConsent) { JevConsentSheet { deciders.set(.jev, on: true, freeLine: false) } }
        .sheet(isPresented: $editingModel) { ModelFieldsSheet(settings: settings) }
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(deciders.order.enumerated()), id: \.element) { index, decider in
                if index > 0 { Divider() }
                row(decider)
            }
            if deciders.mode == .jevFirst {
                Divider()
                Toggle("Ask Jev and the model together", isOn: $race).tint(Palette.accent).frame(minHeight: 48)
            }
            if AIConsent.store && settings.isConfigured && !AIConsent.granted(settings.baseURL) {
                Divider()
                AIConsentRow(settings: settings)
            }
        }
    }

    private func row(_ decider: Decider) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: "line.3.horizontal").font(.footnote).foregroundStyle(.tertiary)
            Image(systemName: decider == .jev ? "bolt" : "brain").frame(width: 24)
            if decider == .model {
                Button { editingModel = true } label: { label(decider) }.buttonStyle(.plain)
            } else {
                label(decider)
            }
            Toggle(decider == .jev ? "Jev" : "Model", isOn: binding(decider))
                .labelsHidden()
                .tint(Palette.accent)
                .disabled(decider == .model && freeLine)
        }
        .frame(minHeight: 60)
        .contentShape(.rect)
        .draggable(decider.rawValue) { label(decider).padding(Space.m).background(Palette.surface, in: .rect(cornerRadius: 10)) }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let moved = Decider(rawValue: raw), moved != decider,
                  let from = deciders.order.firstIndex(of: moved), let to = deciders.order.firstIndex(of: decider)
            else { return false }
            withAnimation(.snappy) { deciders.order.remove(at: from); deciders.order.insert(moved, at: to) }
            Haptics.tick()
            return true
        }
    }

    private func label(_ decider: Decider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(decider == .jev ? "Jev (decision model)" : "Model").foregroundStyle(.primary)
            if decider == .jev {
                Text("Takes the plain steps in a fraction of a second.").font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: Space.xs) {
                    Text(verbatim: modelName).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var modelName: String {
        if freeLine { return ModelProvider.handsyTrial.title }
        guard settings.isConfigured else { return String(localized: "Not set up") }
        return settings.model.isEmpty ? settings.providerName : settings.model
    }

    private func binding(_ decider: Decider) -> Binding<Bool> {
        Binding {
            deciders.isOn(decider)
        } set: { on in
            if decider == .jev, on, !freeLine, !JevConsent.granted { askingConsent = true; return }
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

/// The model row's fold: provider, key and model, the same fields as before.
struct ModelFieldsSheet: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProviderFields(settings: settings)
                } footer: {
                    if let url = settings.provider.keyURL { Link("Get an API key", destination: url) }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
