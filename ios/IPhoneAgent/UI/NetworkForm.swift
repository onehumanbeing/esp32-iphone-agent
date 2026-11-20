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
            if pass.isEmpty && !ssid.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("A network without a password: anyone nearby can join it. The board lets only this device mirror to it and encrypts the screen it sends here, but its own hotspot is safer.",
                      systemImage: "lock.open")
            }
            if app.lanJoin == .joined { MirroringRestartHint(app: app) }
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
        // the phone's network, or (a home network iOS won't name, the phone on the board's hotspot) the last one used
        let hotspot = app.board.net?.mode == "ap" ? app.board.net?.ssid : app.hotspotSSID
        if ssid.isEmpty, let suggested = LanMemory.suggestion(current: await Hotspot.currentSSID(), boardHotspot: hotspot,
                                                              last: LanMemory.lastSSID) { ssid = suggested }
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
                    if app.lanJoin == .joined && app.board.status?.ap != "streaming" { MirroringSteps(app: app) }
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

/// After the board moved to another network: iOS keeps no mirroring session across it (the old one may still show as
/// on in Control Center, frozen), so Screen Mirroring has to be started again. Shown until it streams.
struct MirroringRestartHint: View {
    @ObservedObject var app: AppModel

    var body: some View {
        if app.networkSwitched && app.board.status?.ap != "streaming" {
            Label("The board is on another network now: start Screen Mirroring again. In Control Center tap Screen Mirroring, tap Stop Mirroring if it still shows \(BoardName.current), then pick \(BoardName.current).",
                  systemImage: "rectangle.on.rectangle")
                .font(.footnote)
                .foregroundStyle(Palette.warning)
        }
    }
}


/// The board is on the network, mirroring not yet: where to tap, the Control Center picture, and the wait. Shared by
/// setup's See page (hotspot and Home Wi-Fi) and Settings' Home Wi-Fi sheet, so every path shows the same steps.
struct MirroringSteps: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: Space.xl) {
            Text("Now swipe down from the top-right corner and tap **Screen Mirroring → \(BoardName.current)**.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            MirroringRestartHint(app: app)
            MiniPhoneDemo(kind: .controlCenter)
            VStack(spacing: Space.s) {
                HStack(spacing: Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Screen Mirroring…")
                }
                Label("Keep the screen unlocked: locking stops mirroring.", systemImage: "lock.open")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}