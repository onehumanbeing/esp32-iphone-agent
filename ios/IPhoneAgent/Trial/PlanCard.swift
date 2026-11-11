import SwiftUI
#if HANDSY_STORE
import StoreKit
#endif

/// The model page's plan banner (onboarding's "Give Me a Brain" and Settings › Model), Henry 2026-11-12: how runs
/// are paid for, in plain sight, above the deciders. App Store build: a black banner to the plans (its link and
/// storefront rule live in HandsyStoreEntry, outside this repository). Every build with the free line: a wide
/// "Already have a Handsy key? Set it up now" row. With a key: the banner says the plan is active and opens the
/// key sheet; the App Store build shows the plan, what is left, and opens its plan page instead (both outside
/// this repository, Henry 2026-11-12: not in TestFlight). One's own API key is set up in the Large Language Model
/// row below, not here. Builds without the free line show nothing.
struct PlanCard: View {
    var inForm = false
    @ObservedObject private var trial = Trial.shared
    @State private var editingKey = false
    @State private var managing = false
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
            .sheet(isPresented: $managing) { HandsyStorePlanPage() }
            .task {
                plansShown = HandsyStoreEntry.linkAllowed(await Storefront.current?.countryCode)
                for await storefront in Storefront.updates { plansShown = HandsyStoreEntry.linkAllowed(storefront.countryCode) }
            }
            #endif
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if trial.hasKey {
                #if HANDSY_STORE
                HandsyStorePlanBanner(manage: { managing = true }, enterKey: { editingKey = true })
                #else
                Button { editingKey = true } label: {
                    PlanBanner(title: Text(trial.keyOn ? "Handsy Plan · Active" : "Handsy Plan · Paused"),
                               detail: Text("Key ending in \(String(trial.key.suffix(4)))"))
                }
                .buttonStyle(.plain)
                #endif
            } else {
                #if HANDSY_STORE
                if plansShown {
                    Link(destination: HandsyStoreEntry.plans) {
                        PlanBanner(symbol: "sparkles", title: Text("Get a Handsy Plan"),
                                   detail: Text("No waiting, and it reads your recordings"))
                    }
                    .buttonStyle(.plain)
                }
                #endif
                Button { editingKey = true } label: {
                    PlanBanner(symbol: "key.fill", title: Text("Already have a Handsy key?"),
                               detail: Text("Set it up now: tap here"), dark: false)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A short banner: black with a soft sheen (the plan), or a plain card with a hairline (the key row), in the
/// app's black-and-white look in light and dark. No symbol: the Handsy logo. Also used by the App Store build's
/// plan banner (outside this repository).
struct PlanBanner: View {
    var symbol: String?
    let title: Text
    let detail: Text
    var dark = true

    var body: some View {
        HStack(spacing: Space.m) {
            if let symbol {
                Image(systemName: symbol).font(.title3.weight(.semibold)).symbolRenderingMode(.hierarchical)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(dark ? Color.white.opacity(0.12) : Color.primary.opacity(0.07)))
            } else {
                Image("Logo").resizable().scaledToFit().frame(width: 36, height: 40).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                detail.font(.footnote).opacity(0.7).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            Image(systemName: "arrow.right").font(.footnote.weight(.bold)).opacity(0.7)
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .padding(.horizontal, Space.l)
        .frame(height: 64)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if dark {
                shape.fill(LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(shape.strokeBorder(.white.opacity(0.14)))
            } else {
                shape.fill(Color(.secondarySystemGroupedBackground)).overlay(shape.strokeBorder(.primary.opacity(0.14)))
            }
        }
        .contentShape(.rect)
    }
}

/// Paste or change a Handsy key (hsk_live_…), or say yes to one a link brought (`offered`). Saved in the
/// Keychain; the model switches to Handsy, so the deciders above use the plan from the next run.
struct HandsyKeySheet: View {
    var offered: String?
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @FocusState private var focused: Bool

    private var value: String { (offered ?? key).trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { Trial.looksLikeKey(value) }

    var body: some View {
        VStack(spacing: Space.l) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .accessibilityLabel("Cancel")
            }
            Image(systemName: "key.fill").font(.title.weight(.semibold)).foregroundStyle(Color(.systemBackground))
                .frame(width: 64, height: 64).background(Circle().fill(Color.primary))
            VStack(spacing: Space.s) {
                Text(offered == nil ? "Set Up Your Handsy Key" : "Use This Handsy Key?")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text(offered == nil ? "Paste the key from your Handsy plan. Runs then use your plan: no waiting in line, and recordings are read."
                     : "handsy.tech sent this key to the app. Use it only if you just copied it from your own Handsy plan.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            field
            if !value.isEmpty && !valid {
                Text("A Handsy key starts with hsk_").font(.footnote).foregroundStyle(.red)
            }
            Button { save() } label: {
                Text("Use This Key").font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(Color(.systemBackground))
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary))
            }
            .buttonStyle(.plain)
            .disabled(!valid).opacity(valid ? 1 : 0.35)
            Text("The key stays in this iPhone's Keychain. Tap the plan at the top of Settings › Model to change it.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if offered == nil && Trial.shared.hasKey {
                Button("Remove This Key", role: .destructive) { Trial.shared.setKey(""); dismiss() }.font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl).padding(.top, Space.l)
        .presentationDetents([.large])
        .presentationBackground(Color(.systemBackground))
        .presentationDragIndicator(.visible)
        .onAppear { if offered == nil { focused = true } }
    }

    @ViewBuilder private var field: some View {
        HStack(spacing: Space.s) {
            if let offered {
                Text(verbatim: "hsk_…" + String(offered.suffix(4))).font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SecureField("Handsy key", text: $key, prompt: Text(verbatim: "hsk_live_…"))
                    .font(.body.monospaced()).focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit { if valid { save() } }
                Button {
                    key = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? key
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Space.m).frame(height: 34)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.l).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func save() {
        guard valid else { return }
        Trial.shared.setKey(value)
        let settings = AppModel.shared.settings
        if settings.provider != .handsyTrial { settings.selectProvider(.handsyTrial) }  // the deciders use the plan
        Haptics.tick()
        dismiss()
    }
}

/// iphoneagent://key?k=hsk_live_… (handsy.tech's "Open in Handsy" after a purchase on this iPhone): asks first.
struct HandsyKeyOffer: ViewModifier {
    @ObservedObject private var trial = Trial.shared

    func body(content: Content) -> some View {
        content.sheet(item: $trial.offeredKey) { HandsyKeySheet(offered: $0.key) }
    }

    /// True when `url` was a key link (handled, even when its key is not one).
    @MainActor static func handle(_ url: URL) -> Bool {
        guard url.scheme == "iphoneagent", url.host == "key" else { return false }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "k" }?.value ?? ""
        guard Trial.available, Trial.looksLikeKey(key) else {
            DebugLog.write("key link: ignored (free line \(Trial.available), \(key.count) chars, prefix \(key.prefix(4)))")
            return true
        }
        DebugLog.write("key link: asking about hsk_…\(key.suffix(4))")
        Trial.shared.offeredKey = OfferedKey(key: key)
        return true
    }
}
