import SwiftUI
import UIKit

/// 0 · Welcome: the character wakes up and says hello. The risks were accepted on the first-launch sheet
/// (Agree and Continue); after Not Now there, the button here is the acceptance (Accept and Get Started).
struct WelcomePage: View {
    var accepted: Bool
    let wireless: Bool
    var boardQuestion: BoardQuestionPanel?  // first launch only
    @State private var awake = false

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: awake ? .idle : .sleeping, title: "Hi, I'm \(AppName.current)",
                       message: wireless
                           ? "Tell me a task and I'll do it on this iPhone: I see the screen through Screen Mirroring and control the pointer."
                           : "Tell me a task and I'll do it on this iPhone: I see the screen through Screen Mirroring and tap with a USB mouse.")
            if let boardQuestion { boardQuestion }
            Panel {
                if accepted {
                    DisclosureGroup {
                        Text(Disclaimer.text).font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                    } label: {
                        Label("Understand the risks", systemImage: "exclamationmark.shield").font(.body.weight(.semibold))
                    }
                } else {
                    Label("Understand the risks", systemImage: "exclamationmark.shield").font(.body.weight(.semibold))
                    Text(Disclaimer.text).font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                }
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            awake = true
        }
    }
}

enum Disclaimer {
    static var text: LocalizedStringKey {
        "\(AppName.current) is experimental software that controls this iPhone on its own. It can tap the wrong thing, send messages, change settings, buy things or delete data. Watch it while it runs and stop it if anything looks wrong. Screenshots of your screen are sent to the model endpoint you choose. You use it at your own risk; the authors accept no liability for any loss or damage."
    }
}

/// 1 · Connect the board: Bluetooth permission, scan, pair (automatically when only one board is found).
struct ConnectPage: View {
    @ObservedObject var board: BoardLink
    @Binding var toBluetooth: Bool  // switched to Bluetooth on this page: BluetoothSteps instead of the offer
    @State private var stuck = false

    private var wireless: Bool { board.status?.isWirelessHID == true || DeviceCaps.hasLightning }

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: board.connected ? .success : board.scanning ? .listening : .sleeping,
                       title: wireless ? "Connect the board" : "Plug Me In",
                       message: board.status?.isWirelessHID == true
                           ? "Keep the Bluetooth board powered on and near this iPhone."
                           : wireless
                           ? "Power the board from any USB charger and keep it near this iPhone. I'll find it over Bluetooth; tap Pair when iOS asks."
                           : "Connect the board to the USB-C port. I'll find it over Bluetooth; tap Pair when iOS asks.")
            if !board.connected && !wireless { MiniPhoneDemo(kind: .plugIn) }
            Panel {
                switch board.state {
                case .unauthorized:
                    Label("Bluetooth is not allowed for \(AppName.current).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .padding(.top, Space.s)
                case .poweredOff:
                    Label("Turn on Bluetooth in Control Center.", systemImage: "antenna.radiowaves.left.and.right.slash")
                default:
                    boards
                }
            }
            if toBluetooth {
                Panel { BluetoothSteps(board: board) }
            } else if board.connected {
                LightningAdvice(board: board, toBluetooth: $toBluetooth)
            }
            if !board.connected { FirmwareLinks() }
            if !board.connected && !MockMode.on { DemoOffer() }
        }
        .onAppear { board.scan(); autoPair() }
        .onValueChange(of: board.state) { _, s in if s == .poweredOn { board.scan() } }
        .onValueChange(of: board.found) { autoPair() }
        .task(id: board.connected) { stuck = false; stuck = await BoardRepairHint.wait(connected: board.connected) }
    }

    /// Only one board nearby: pair it without asking.
    private func autoPair() {
        if board.found.count == 1, board.pairedID == nil, let f = board.found.first { board.pair(f.id) }
    }

    /// Not connected → Found → Pairing → Connected. A paired board reconnects by itself when it is plugged in.
    @ViewBuilder private var boards: some View {
        if board.connected {
            CheckRow(title: "Connected to \(board.name.isEmpty ? "the board" : board.name)", done: true)
        } else if board.connecting {
            CheckRow(title: "Connecting to the board…", done: false, active: true, waiting: true)
        } else if board.linking {
            CheckRow(title: "Pairing… tap Pair when iOS asks", done: false, active: true, waiting: true)
        } else if board.pairedID == nil, board.found.count == 1, let f = board.found.first {
            CheckRow(title: "Found \(f.name)", done: false, active: true, waiting: true)
        } else if !board.found.isEmpty {
            ForEach(board.found) { f in
                Button { board.pair(f.id) } label: {
                    HStack {
                        Text("Pair \(f.name)").lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, Space.s)
                }
            }
        } else {
            CheckRow(title: "Searching for the board over Bluetooth…", done: false, active: true, waiting: board.scanning)
        }
        if board.pairingLost {
            // Short: a long warning pushed the button off small screens.
            Text("Pairing failed. Replug the board, then forget \(BoardName.current) in Settings › Bluetooth.")
                .font(.footnote).foregroundStyle(Palette.warning).lineLimit(2).minimumScaleFactor(0.85)
                .padding(.top, Space.s)
        } else if !board.connected || (board.signalStrength ?? 0) < -80 {
            Text((board.signalStrength ?? 0) < -80
                 ? "Weak signal? Try placing the board right against the side of your phone, or attach its antenna."
                 : "No antenna? Try placing the board right against the side of your phone.")
                .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
        }
        if !board.connected && !board.pairingLost {
            if !board.lastError.isEmpty {
                Text(verbatim: board.lastError).font(.footnote).foregroundStyle(Palette.warning).lineLimit(2)
            }
        }
        BoardRepairHint(board: board, stuck: stuck).padding(.top, Space.s)
    }
}

/// The board isn't found, or the remembered one won't connect: how to pair it again from the start. The board takes a
/// new phone only in the 3 minutes after power-on (ble_link.cpp PAIR_WINDOW_MS). Shown once it has been stuck a while.
/// A Lightning iPhone can't take the board's USB mouse: switch a --dual-hid board to Bluetooth, or point an
/// older USB-only board at the Bluetooth firmware.
struct LightningAdvice: View {
    @ObservedObject var board: BoardLink
    @Binding var toBluetooth: Bool
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        switch DeviceCaps.bluetoothAdvice(lightning: DeviceCaps.hasLightning, status: board.status) {
        case .none: EmptyView()
        case .switchInput:
            Panel {
                Label("This iPhone has no USB-C port, so the board has to be its Bluetooth mouse.", systemImage: "cable.connector.slash")
                    .font(.subheadline)
                Button { switchToBluetooth() } label: {
                    HStack { Text("Switch the Board to Bluetooth"); if busy { Spacer(); ProgressView() } }
                }
                .font(.body.weight(.semibold)).disabled(busy).padding(.top, Space.m)
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.top, Space.s) }
            }
        case .needsFirmware:
            Panel {
                Label("This iPhone has no USB-C port, so the board has to be its Bluetooth mouse, and its firmware is USB only.",
                      systemImage: "cable.connector.slash")
                    .font(.subheadline)
                Text("On a computer, open \(FirmwareLinks.install.absoluteString), plug the board into it and install the Bluetooth firmware. Then come back here.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, Space.s)
                Link(destination: FirmwareLinks.install) { Text(verbatim: "manina.ai/install") }
                    .font(.footnote.weight(.semibold)).padding(.top, Space.s)
            }
        }
    }

    private func switchToBluetooth() {
        busy = true
        error = nil
        Task {
            do {
                try await BluetoothSteps.switchInput(to: "ble", on: board)
                toBluetooth = true
            } catch {
                self.error = String(localized: "The board did not switch: \(error.localizedDescription)")
            }
            busy = false
        }
    }
}

struct BoardRepairHint: View {
    @ObservedObject var board: BoardLink
    let stuck: Bool

    static func shows(stuck: Bool, connected: Bool, linking: Bool, paired: Bool, found: Bool) -> Bool {
        stuck && !connected && !linking && (paired || !found)
    }

    /// Waits ~10 s while the board stays disconnected (run it as `.task(id: board.connected)`).
    static func wait(connected: Bool) async -> Bool {
        guard !connected, (try? await Task.sleep(for: .seconds(10))) != nil else { return false }
        return true
    }

    var body: some View {
        if Self.shows(stuck: stuck, connected: board.connected, linking: board.linking,
                      paired: board.pairedID != nil, found: !board.found.isEmpty) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Board not showing up?").font(.subheadline.weight(.semibold))
                let first = board.pairedID != nil ? 1 : 0
                if first == 1 {
                    Button(action: board.retryDiscovery) { step(1, "Forget this board in the app") }
                        .buttonStyle(.borderless)  // in a List row: only the button, not the whole row
                }
                step(first + 1, "In Settings › Bluetooth, forget \(BoardName.current) if it is listed.")
                step(first + 2, "Unplug the board and plug it back in.")
                step(first + 3, "Pair within 3 minutes: after power-on the board accepts a new phone for 3 minutes only.")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: "\(n).circle") }
    }
}

/// A board fresh from the shop has no firmware and never shows up: point to the browser installer and the source.
/// No board at hand: turn on Demo data from the first setup page (the same switch as Settings › Developer).
/// It is read once at launch (MockMode), so the app says to reopen it.
struct DemoOffer: View {
    @AppStorage(MockMode.key) private var demoData = false
    @State private var told = false

    var body: some View {
        Button("No board yet? Try the demo") { demoData = true; told = true }
            .font(.footnote.weight(.semibold))
            .alert("Demo Data Is On", isPresented: $told) {
                Button("OK") {}
            } message: {
                Text("Quit \(AppName.current) and open it again to try the whole app without a board. Nothing is sent anywhere in the demo. Turn it off in Settings › Developer.")
            }
    }
}

struct FirmwareLinks: View {
    static let install = URL(string: "https://manina.ai/install")!

    /// One line, so both links stay above the bottom button on every iPhone.
    var body: some View {
        HStack(spacing: Space.m) {
            Text("New board?").foregroundStyle(.secondary)
            Link(destination: Self.install) { Label { Text(verbatim: "manina.ai/install") } icon: { Image(systemName: "desktopcomputer") } }
            Link(destination: AboutView.repo) {
                Label { Text(verbatim: "GitHub") } icon: {
                    Image("GitHubMark").renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14)
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .labelStyle(TightLabel())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .tint(.primary)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) { configuration.icon; configuration.title }
    }
}

/// 2 · Let it see the screen: join the board's Wi-Fi (one tap, the system asks), or point the board at the
/// home Wi-Fi (LAN mode), then Screen Mirroring. The page's one action is the bottom button (OnboardingView);
/// manual join shows only if one-tap fails. Devices without cellular get LAN mode only.
struct SeePage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    @Binding var onWiFi: Bool
    @Binding var lanChoice: Bool
    @Binding var lanSSID: String
    @Binding var lanPass: String
    @Binding var lanRemember: Bool
    @State private var copied = false
    @State private var sharing = Hotspot.sharing  // this iPhone is a Personal Hotspot right now
    @Environment(\.scenePhase) private var scenePhase

    private var streaming: Bool { board.connected && board.status?.ap == "streaming" }
    /// On the network of the chosen mode: a board still in the other mode doesn't count (it switches first).
    private var joined: Bool { lanChoice == app.lanMode && app.onBoardHotspot(manual: onWiFi) }
    private var failure: String? {
        if case .failed(let why) = lanChoice ? app.lanJoin : .idle { return why }
        if !lanChoice, case .failed(let why) = app.join { return why }
        return nil
    }

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: streaming ? .success : (app.join.busy || app.lanJoin.busy || joined) ? .listening : failure != nil ? .failure : .idle,
                       title: "Let Me See the Screen",
                       message: lanChoice
                           ? "Screen Mirroring goes to the board over your Wi-Fi network."
                           : "Screen Mirroring goes to the board over its own Wi-Fi.")
            if DeviceCaps.hasCellular {
                Picker("Network", selection: $lanChoice) {
                    Text("Board's Hotspot").tag(false)
                    Text("Home Wi-Fi").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Label("This device has no cellular data, so the board shares your Wi-Fi instead of opening its own hotspot.",
                      systemImage: "wifi")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if lanChoice { lan } else { hotspot }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: joined)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.join)
        .task {  // join once by itself, then keep checking every 2 s while on this step
            if !joined, !lanChoice { app.startJoin(auto: true) }
            while !Task.isCancelled && !streaming {
                await app.refreshHotspot()
                sharing = Hotspot.sharing
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onValueChange(of: scenePhase) { _, phase in
            if phase == .active { sharing = Hotspot.sharing; Task { await app.refreshHotspot() } }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: app.manualHotspot?.ssid)
    }

    /// LAN mode: the board joins the home Wi-Fi; the phone stays on whatever network it has. Once the board is on it,
    /// the form folds away like the hotspot path's hints, so the mirroring picture is on screen, not below the fold.
    private var lan: some View {
        VStack(spacing: Space.xl) {
            if !joined { LanForm(app: app, ssid: $lanSSID, pass: $lanPass, remember: $lanRemember) }
            Panel {
                CheckRow(title: "Board on your Wi-Fi", done: joined, active: !joined,
                         waiting: app.lanJoin.busy && !joined,
                         detail: app.lanJoin.busy ? "This takes up to a minute — the board restarts its Wi-Fi." : nil)
                Divider().padding(.vertical, Space.s)
                CheckRow(title: "Start Screen Mirroring", done: streaming, active: joined && !streaming)
            }
            if joined && !streaming { MirroringSteps(app: app) }
        }
    }

    /// Hotspot mode: the phone joins the board's own Wi-Fi; the internet keeps working over cellular.
    private var hotspot: some View {
        VStack(spacing: Space.xl) {
            Panel {
                CheckRow(title: "Join the board's Wi-Fi", done: joined, active: !joined, waiting: app.join.busy && !joined,
                         detail: joined ? nil : app.join == .verifying ? "Checking the connection…"
                            : app.join.busy ? "Joining usually takes up to 10 seconds — hang tight." : failure.map { LocalizedStringKey($0) })
                Divider().padding(.vertical, Space.s)
                CheckRow(title: "Start Screen Mirroring", done: streaming, active: joined && !streaming)
            }
            if !joined {
                if let net = app.manualHotspot, let ssid = net.ssid, failure != nil { manual(ssid: ssid, pass: net.pass) }
                if sharing && !app.phoneHostsBoard {  // seen, not guessed: say it plainly, above the general hints
                    Label("This iPhone's Personal Hotspot is on. Turn it off in Settings › Personal Hotspot, then join the board's Wi-Fi.",
                          systemImage: "personalhotspot")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    Label("Turn off Personal Hotspot first: while it shares this iPhone's internet, the iPhone can't join the board's Wi-Fi.",
                          systemImage: "personalhotspot")
                    Label("Internet uses cellular data while on the board's Wi-Fi.", systemImage: "antenna.radiowaves.left.and.right")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Button("I'm already on the board's Wi-Fi") { onWiFi = true }.font(.footnote)
            } else if !streaming {
                MirroringSteps(app: app)
            }
        }
    }

    /// One-tap join failed: the network and its password, to join in Settings › Wi-Fi.
    private func manual(ssid: String, pass: String?) -> some View {
        Panel {
            LabeledContent("Network") { Text(verbatim: ssid).font(.body.monospaced()).textSelection(.enabled) }
            if let pass {
                Divider().padding(.vertical, Space.s)
                LabeledContent("Password") {
                    HStack(spacing: Space.s) {
                        Text(verbatim: pass).font(.body.monospaced().weight(.semibold)).textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = pass
                            copied = true
                            Haptics.success()
                        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                            .accessibilityLabel(Text(copied ? "Copied" : "Copy"))
                    }
                }
                Divider().padding(.vertical, Space.s)
                Button {
                    UIPasteboard.general.string = pass; copied = true
                    Hotspot.openWiFiSettings()
                } label: { Label("Copy Password & Open Settings", systemImage: "gear") }
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

/// 3 · Let it act: numbered AssistiveTouch steps (with a demo), then calibration on the grid board (bottom button).
/// The page moves on by itself once the pointer is calibrated; until then it says what it waits for, and after
/// 20 s on the same thing, the likely cause and its fix.
struct ActPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var pointer: Pointer
    @State private var assistiveTouch = UIAccessibility.isAssistiveTouchRunning
    @State private var stuck = false
    @Environment(\.scenePhase) private var scenePhase

    private var wireless: Bool { board.status?.isWirelessHID == true || DeviceCaps.hasLightning }  // as ConnectPage: a Lightning iPhone is Bluetooth only
    private var mouse: Bool { MockMode.on || board.status?.inputReady == true }
    private var mirroring: Bool { MockMode.on || app.onDeviceCapture || board.status?.ap == "streaming" }
    private var touchOn: Bool { MockMode.on || assistiveTouch }
    private var calibrated: Bool { calibrator.hasValidCalibration }  // iPad: in this orientation
    private var deviceName: String { board.name.isEmpty ? String(localized: "the board connected in this app") : board.name }

    /// The first thing still missing: what the page waits for.
    enum Wait { case assistiveTouch, mouse, mirroring, calibrate, none }

    static func wait(assistiveTouch: Bool, mouse: Bool, mirroring: Bool, calibrated: Bool, busy: Bool) -> Wait {
        if calibrated || busy { return .none }
        if !assistiveTouch { return .assistiveTouch }
        if !mouse { return .mouse }
        if !mirroring { return .mirroring }
        return .calibrate
    }

    private var wait: Wait {
        Self.wait(assistiveTouch: touchOn, mouse: mouse, mirroring: mirroring, calibrated: calibrated, busy: calibrator.busy)
    }

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: calibrated ? .success : calibrator.busy ? .acting : .idle,
                       title: "Let Me Use the Pointer",
                       message: wireless
                           ? "The board works as a Bluetooth mouse. iOS shows its pointer only when AssistiveTouch is on."
                           : "The board works as a USB mouse. iOS shows its pointer only when AssistiveTouch is on.")
            if !calibrated { steps }
            if !calibrated && !touchOn { MiniPhoneDemo(kind: .assistiveTouch) }
            Panel {
                CheckRow(title: "AssistiveTouch on", done: touchOn, active: wait == .assistiveTouch,
                         waiting: wait == .assistiveTouch, detail: wait == .assistiveTouch ? "Waiting for you to turn it on in Settings…" : nil)
                Divider().padding(.vertical, Space.s)
                CheckRow(title: "Mouse connected", done: mouse, active: wait == .mouse, waiting: wait == .mouse,
                         detail: wait == .mouse ? "Waiting for the board's mouse…" : nil)
                Divider().padding(.vertical, Space.s)
                if !app.onDeviceCapture {
                    CheckRow(title: "Screen Mirroring on", done: mirroring, active: wait == .mirroring, waiting: wait == .mirroring,
                             detail: wait == .mirroring ? "Waiting for mirroring…" : nil)
                    Divider().padding(.vertical, Space.s)
                }
                CheckRow(title: "Pointer calibrated", done: calibrated, active: wait == .calibrate, waiting: calibrator.busy,
                         detail: wait == .calibrate ? "Ready. Tap Calibrate below."
                             : pointer.quality.map { q -> LocalizedStringKey in "Accuracy \(CalibrationText.percent(q))" })
            }
            if stuck, let hint { Label(hint, systemImage: "lightbulb").font(.footnote).foregroundStyle(Palette.warning) }
            if !calibrated {
                Text("Tip: in AssistiveTouch › Pointer Devices, set Tracking Speed to the middle and turn Pointer Animations off.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.assistiveTouchStatusDidChangeNotification)) { _ in
            assistiveTouch = UIAccessibility.isAssistiveTouchRunning
        }
        .onValueChange(of: scenePhase) { _, phase in  // back from Settings: read it again
            if phase == .active { assistiveTouch = UIAccessibility.isAssistiveTouchRunning }
        }
        .task(id: wait) {
            stuck = false
            guard wait != .none, wait != .calibrate, (try? await Task.sleep(for: .seconds(20))) != nil else { return }
            stuck = true
        }
    }

    /// What to do, in order; a step shows a check once the app sees it done.
    private var steps: some View {
        Panel {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Do this once:").font(.subheadline.weight(.semibold))
                step(1, "Open Settings › Accessibility › Touch › AssistiveTouch.", done: touchOn)
                step(2, "Turn AssistiveTouch on.", done: touchOn)
                if wireless {
                    step(3, "Under Devices › Bluetooth Devices, pair \(deviceName).", done: mouse)
                }
                step(wireless ? 4 : 3, "Come back to this app and tap Calibrate below. I move the pointer over a grid to learn where it lands; it takes a few seconds.", done: calibrated)
            }
            .font(.footnote)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey, done: Bool) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle").foregroundStyle(done ? Palette.ok : Color.accentColor)
        }
    }

    /// After 20 s on the same step: the likely cause and its fix.
    private var hint: LocalizedStringKey? {
        switch wait {
        case .assistiveTouch:
            return "AssistiveTouch is still off. In Settings › Accessibility › Touch › AssistiveTouch, turn on the switch at the top, then come back here."
        case .mouse:
            if !board.connected { return "The board isn't connected. Keep it powered on and near this iPhone; it reconnects by itself." }
            if wireless { return "On this iPhone, open Settings › Accessibility › Touch › AssistiveTouch › Devices › Bluetooth Devices and pair \(deviceName)." }
            if board.status?.usb == "asleep" { return "The board's USB is asleep. Unlock this iPhone, then try again." }
            return "The board is plugged in by USB, but this iPhone isn't getting its input. Plug it straight into this iPhone (not a computer, hub or charger), tap Allow if iPhone asks about the accessory, then try again."
        case .mirroring:
            return "Screen Mirroring is off. Swipe down from the top-right corner, tap Screen Mirroring and choose “\(BoardName.current)”."
        case .calibrate, .none:
            return nil
        }
    }
}

/// 4 · Give it a brain: an OpenAI-compatible vision model; Test Connection; a first task to try.
struct BrainPage: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(spacing: Space.xl) {
            PageHeader(mood: app.modelOK == true ? .success : app.modelOK == false ? .failure : .thinking,
                       title: "Give Me a Brain", message: message)
            if MockMode.on {
                Panel {
                    Label("Demo data simulates the model.", systemImage: "theatermasks")
                    // The demo still shows what a real run asks before it sends anything.
                    let pending = settings.pendingConsent
                    if settings.isConfigured, pending.model || pending.jev {
                        SendConsentCard(settings: settings, model: pending.model, jev: pending.jev)
                    }
                }
            } else {
                ModelFieldsPanel(settings: settings)
                ToolsEntry()
            }
            if app.modelTestStarted != nil || app.modelTestSeconds != nil { ModelTestTimingView(app: app) }
        }
    }

    /// The connection result lives in the header (and as a mark on the model row), not in a card of its own.
    private var message: LocalizedStringKey {
        switch app.modelOK {
        case true?: return "Connected. Try this first: \(IntentStore.note.prompt)"
        case false?: return "\(app.modelError ?? String(localized: "Could not reach the model. Check the URL and key."))"
        case nil: return "Any OpenAI-compatible vision model works. The key stays in this iPhone's Keychain."
        }
    }
}

/// The model box of the Brain page: who decides each step (with the model folded into its row) when the build has
/// Jev, else endpoint and key with placeholders only; the model is picked from the endpoint (nothing personal is built in).
struct ModelFieldsPanel: View {
    @ObservedObject var settings: Settings

    var body: some View {
        if Trial.available {
            DecidersPanel(settings: settings)
        } else {
            fields
        }
    }

    private var fields: some View {
        VStack(spacing: Space.xs) {
            Panel { ProviderFields(settings: settings) }
            if let url = settings.provider.keyURL {
                Link("Get an API key", destination: url)
                    .font(.footnote).tint(.secondary).underline()
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .chatGPTSignInHost()
    }
}
