import SwiftUI
#if HANDSY_STORE
import StoreKit
#endif

/// The model page's plan banner (onboarding's "Give Me a Brain" and Settings › Model), Henry 2026-11-12: how runs
/// are paid for, in plain sight but small, above the deciders. App Store build: a black banner to the plans (its
/// link and storefront rule live in HandsyStoreEntry, outside this repository) and "Already have a key?" under it.
/// TestFlight and this repository's builds: that line only. With a key: the banner says the plan is active and
/// opens the key sheet. One's own API key is set up in the Large Language Model row below, not here.
/// Builds without the free line show nothing.
struct PlanCard: View {
    var inForm = false
    @ObservedObject private var trial = Trial.shared
    @State private var editingKey = false
    @State private var plansShown = false

    var body: some View {
        if Trial.available {
            Group {
                if inForm {
                    Section { content }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } else {
                    content
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
        VStack(alignment: .leading, spacing: Space.s) {
            if trial.keyed {
                Button { editingKey = true } label: {
                    PlanBanner(symbol: "checkmark.seal.fill", title: "Handsy Plan · Active",
                               detail: Text("Key ending in \(String(trial.key.suffix(4)))"))
                }
                .buttonStyle(.plain)
            } else {
                #if HANDSY_STORE
                if plansShown {
                    Link(destination: HandsyStoreEntry.plans) {
                        PlanBanner(symbol: "sparkles", title: "Get a Handsy Plan",
                                   detail: Text("No waiting, and it reads your recordings"))
                    }
                    .buttonStyle(.plain)
                }
                #endif
                Button { editingKey = true } label: {
                    Text("Already have a Handsy key?").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.l)
            }
        }
    }
}

/// A short black banner with a soft sheen: the plan, in the app's black-and-white look in light and dark.
private struct PlanBanner: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: Text

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).symbolRenderingMode(.hierarchical)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                detail.font(.footnote).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            Image(systemName: "arrow.right").font(.footnote.weight(.bold)).opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Space.l)
        .frame(height: 64)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
        }
        .contentShape(.rect)
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
