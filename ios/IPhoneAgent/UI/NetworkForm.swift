import SwiftUI

/// The LAN-mode form: which home Wi-Fi the board should join. Shared by onboarding's See page and
/// Settings › Board. The name field stays editable (the board is 2.4 GHz-only, so a phone on a split
/// 5 GHz network means typing the 2.4 GHz name); the password is remembered per SSID in the Keychain.
struct LanForm: View {
    @ObservedObject var app: AppModel
    @Binding var ssid: String
    @Binding var pass: String
    @Binding var remember: Bool

    private var failure: String? { if case .failed(let why) = app.lanJoin { return why } else { return nil } }

    var body: some View {
        Panel {
            LabeledContent {
                TextField("Wi-Fi name", text: $ssid)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: { Text("Network") }
            Divider().padding(.vertical, Space.s)
            LabeledContent {
                SecureField("Password (empty if none)", text: $pass)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } label: { Text("Password") }
            Divider().padding(.vertical, Space.s)
            Toggle("Remember this network's password", isOn: $remember)
        }
        .disabled(app.lanJoin.busy)
        VStack(alignment: .leading, spacing: Space.s) {
            Label("The board only supports 2.4 GHz Wi-Fi. If the router's 2.4 GHz and 5 GHz bands share one name, that name works. If they differ, enter the 2.4 GHz one — this device can stay on 5 GHz.",
                  systemImage: "antenna.radiowaves.left.and.right")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            }
            if DeviceCaps.hasCellular {
                Label("Trouble finding the board later? The router may isolate devices from each other or block mDNS (common on office and hotel networks). The board's own hotspot always works.",
                      systemImage: "info.circle")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .task { await prefill() }
        .onChange(of: ssid) { _, name in
            if let saved = WiFiPasswords.get(name), !saved.isEmpty { pass = saved; remember = true }
        }
    }

    /// Follow the phone's current network; its password is filled if it was remembered before.
    private func prefill() async {
        if ssid.isEmpty, let current = await Hotspot.currentSSID() { ssid = current }
        if pass.isEmpty, let saved = WiFiPasswords.get(ssid) { pass = saved }
    }
}

/// Settings › Board › Wi-Fi: the LAN form as a sheet, with the Connect button and a way back to the hotspot.
struct LanSheet: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var pass = ""
    @State private var remember = true

    private var buttonTitle: LocalizedStringKey {
        app.lanJoin == .joined ? "Connected" : app.lanJoin.buttonTitle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.xl) {
                    LanForm(app: app, ssid: $ssid, pass: $pass, remember: $remember)
                    Button { app.startLanJoin(ssid: ssid, pass: pass, remember: remember) } label: {
                        HStack(spacing: Space.s) {
                            if app.lanJoin.busy { ProgressView().tint(.white) }
                            Text(buttonTitle)
                        }
                    }
                    .buttonStyle(BigButton())
                    .disabled(app.lanJoin.busy || ssid.trimmingCharacters(in: .whitespaces).isEmpty || app.lanJoin == .joined)
                    .padding(.horizontal, Space.l)
                }
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.l)
            }
            .background(Palette.grouped.ignoresSafeArea())
            .onAppear { app.resetLanJoin() }
            .navigationTitle("Home Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The Connect button's label for the LAN flow, in onboarding and Settings.
extension LanJoinState {
    var buttonTitle: LocalizedStringKey {
        switch self {
        case .applying: return "Sending to the Board…"
        case .boardConnecting: return "The Board Is Joining the Wi-Fi…"
        case .checkingPhone: return "Checking This Device…"
        case .failed: return "Try Again"
        default: return "Connect the Board to This Wi-Fi"
        }
    }
}
