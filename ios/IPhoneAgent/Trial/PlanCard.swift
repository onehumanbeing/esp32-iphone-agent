import SwiftUI

/// The model page's first card (onboarding's "Give Me a Brain" and Settings › Model), Henry 2026-11-12: how to
/// pay for runs, in plain sight. A Handsy key in use shows as such (change or remove it); else the choices: get a
/// plan (the App Store build only: HandsyStoreEntry, kept outside this repository), paste a Handsy key, or use
/// one's own API key. Builds without the free line have no plans and show nothing.
struct PlanCard: View {
    var inForm = false
    var ownModel: () -> Void
    @ObservedObject private var trial = Trial.shared
    @State private var editingKey = false

    var body: some View {
        if Trial.available {
            Group {
                if inForm {
                    Section { rows } header: { Text("Handsy Plan") } footer: { Text(footer) }
                } else {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Handsy Plan").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                        Panel { VStack(alignment: .leading, spacing: Space.m) { rows }.padding(.vertical, Space.m) }
                        Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                    }
                }
            }
            .sheet(isPresented: $editingKey) { HandsyKeySheet() }
        }
    }

    @ViewBuilder private var rows: some View {
        if trial.keyed {
            HStack(spacing: Space.m) {
                Image(systemName: "key.fill").foregroundStyle(Palette.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Handsy key")
                    Text(verbatim: "••••" + trial.key.suffix(4)).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change") { editingKey = true }.buttonStyle(.bordered)
            }
            Button(role: .destructive) { trial.setKey("") } label: { Label("Remove Key", systemImage: "xmark.circle") }
        } else {
            #if HANDSY_STORE
            HandsyStoreEntry()
            #endif
            Button { editingKey = true } label: { Label("I Have a Handsy Key", systemImage: "key") }
            Button { ownModel() } label: { Label("Use My Own API Key", systemImage: "server.rack") }
        }
    }

    private var footer: LocalizedStringKey {
        trial.keyed ? "Runs and recordings use your plan, not the free runs."
            : "Handsy Free gives a few runs per phone. A Handsy plan runs without waiting and reads recordings; your own API key works too."
    }
}

/// Paste a Handsy key (hsk_live_…). Saved in the Keychain; runs use it from the next one.
struct HandsyKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = Trial.shared.key

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Handsy key", text: $key, prompt: Text(verbatim: "hsk_live_…"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { key = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? key } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("The key stays in this iPhone's Keychain. With it, runs use your plan instead of the free runs.")
                }
            }
            .navigationTitle("Handsy Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Trial.shared.setKey(key); dismiss() }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
