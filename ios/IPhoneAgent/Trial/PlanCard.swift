import SwiftUI
#if HANDSY_STORE
import StoreKit
#endif

/// The model page's first card (onboarding's "Give Me a Brain" and Settings › Model), Henry 2026-11-12: how runs
/// are paid for, in plain sight. Without a key: the plans button (App Store build only; its link and storefront
/// rule live in HandsyStoreEntry, outside this repository), then a Handsy key and one's own API key, as rows like
/// the deciders below. With a key: the plan in use (change or remove it in the key sheet).
/// Builds without the free line have no plans and show nothing.
struct PlanCard: View {
    var inForm = false
    var ownModel: () -> Void
    @ObservedObject private var trial = Trial.shared
    @State private var editingKey = false
    #if HANDSY_STORE
    @State private var plansShown = false
    #endif

    private static let rowHeight: CGFloat = 64

    var body: some View {
        if Trial.available {
            Group {
                if inForm {
                    Section { content } header: { Text("Handsy Plan") } footer: { Text(footer) }
                } else {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Handsy Plan").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                        Panel { content }
                        Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Space.l)
                    }
                }
            }
            .sheet(isPresented: $editingKey) { HandsyKeySheet() }
            #if HANDSY_STORE
            .task {
                plansShown = HandsyStoreEntry.linkAllowed(await Storefront.current?.countryCode)
                for await storefront in Storefront.updates { plansShown = HandsyStoreEntry.linkAllowed(storefront.countryCode) }
            }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        if trial.keyed {
            row("key.fill", "Handsy Plan", Text("Key ending in \(String(trial.key.suffix(4)))"), badge: true) { editingKey = true }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                #if HANDSY_STORE
                if plansShown {
                    Link(destination: HandsyStoreEntry.plans) {
                        Label("Get a Handsy Plan", systemImage: "sparkles")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .padding(.bottom, Space.s)
                }
                #endif
                row("key", "Handsy Key", Text("Paste the key from your plan")) { editingKey = true }
                Divider().padding(.leading, 44)
                row("server.rack", "Your Own API Key", Text("Any OpenAI-compatible vision model")) { ownModel() }
            }
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, _ detail: Text, badge: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: symbol).font(.body).foregroundStyle(Palette.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    detail.font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if badge { StatusBadge(text: "Active", symbol: "checkmark", emphasized: true) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: Self.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var footer: LocalizedStringKey {
        trial.keyed ? "Runs and recordings use your plan, not the free runs."
            : "Handsy Free gives a few runs per phone. A plan runs without waiting and reads your recordings."
    }
}

/// Paste, change or remove a Handsy key (hsk_live_…). Saved in the Keychain; runs use it from the next one.
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
                if Trial.shared.keyed {
                    Section {
                        Button(role: .destructive) { Trial.shared.setKey(""); dismiss() } label: { Text("Remove Key") }
                    }
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
