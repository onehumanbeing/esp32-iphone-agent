import SwiftUI
import UIKit

/// Settings: Model, Board, Calibration, Language, Diagnostics, About. Logs and raw metrics live one level down.
struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings
    @ObservedObject var board: BoardLink
    @AppStorage(MockMode.key) private var demoData = false
    @AppStorage(AskMode.key) private var askMode = AskMode.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ModelSettingsView(app: app, settings: settings) } label: {
                        row("Model", "brain", .pink, value: app.modelReady ? (MockMode.on ? "Demo" : settings.currentModel ?? String(localized: "Auto")) : nil)
                    }
                    NavigationLink { BoardSettingsView(app: app, board: board) } label: {
                        row("Board", "cable.connector", .blue,
                            value: board.connected ? "\(board.name) · \(Firmware.version(of: board.status))" : String(localized: "Not connected"))
                    }
                    CalibrationRow(app: app, calibrator: app.calibrator, pointer: app.pointer)
                    Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                        HStack {
                            SettingsLabel(title: "Language", symbol: "globe", color: .indigo)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } footer: {
                    Text("ESP32 Agent follows your iPhone's language. To change it just for this app, open Settings › ESP32 Agent › Language.")
                }
                if #available(iOS 27.0, *) {
                    Section {
                        Picker(selection: Binding(get: { app.captureBackend }, set: { app.setCaptureBackend($0) })) {
                            Text("AirPlay").tag(CaptureBackend.airPlay)
                            Text("On-device capture").tag(CaptureBackend.onDevice)
                        } label: {
                            SettingsLabel(title: "Screen capture", symbol: "rectangle.inset.filled", color: .blue)
                        }
                        .accessibilityIdentifier("capture-backend")
                        .disabled(app.agent.running || app.startingAgent || app.recorder.busy || app.calibrator.busy)
                    } footer: {
                        Text(app.onDeviceCapture
                             ? "Screen sharing is requested when a task or recording starts, or when calibration needs it. The board still controls the phone through USB."
                             : "Use Screen Mirroring to send the screen to the board over Wi-Fi.")
                    }
                }
                Section {
                    Button { UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!) } label: {
                        HStack {
                            SettingsLabel(title: "Notifications", symbol: "bell.badge.fill", color: .red)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                    NavigationLink { MemoryView(store: MemoryStore.shared) } label: {
                        row("Memory", "brain.head.profile", .teal, value: "\(MemoryStore.shared.entries.count)")
                    }
                    Picker(selection: $askMode) {
                        ForEach(AskMode.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingsLabel(title: "Ask me first", symbol: "checkmark.shield.fill", color: .orange)
                    }
                } header: {
                    Text("Runs")
                } footer: {
                    Text("Ask me first: the agent stops and asks you in a notification before paying (Payments only), or also before sending a message, deleting or changing account settings. Every run keeps a low-frame-rate video of the mirrored screen for the review.")
                }
                Section {
                    NavigationLink { DiagnosticsView(app: app, metrics: app.metrics, board: board, feed: app.feed) } label: {
                        SettingsLabel(title: "Diagnostics", symbol: "waveform.path.ecg", color: .green)
                    }
                    Toggle(isOn: $demoData) { SettingsLabel(title: "Demo data", symbol: "theatermasks", color: .purple) }
                    Button { settings.onboarded = false; app.setupPage = .welcome } label: {
                        SettingsLabel(title: "Run setup again", symbol: "arrow.counterclockwise", color: .gray)
                    }
                    .tint(.primary)
                } footer: {
                    Text("Demo data fakes a board, a finished run and the whole setup, to try the app without hardware. Takes effect after you quit and reopen the app.")
                }
                Section {
                    NavigationLink { PrivacySettingsView(app: app, runs: app.runs) } label: {
                        SettingsLabel(title: "Privacy", symbol: "hand.raised.fill", color: .blue)
                    }
                    NavigationLink { AboutView(app: app) } label: {
                        SettingsLabel(title: "About", symbol: "info", color: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func row(_ title: LocalizedStringKey, _ symbol: String, _ color: Color, value: String?) -> some View {
        HStack {
            SettingsLabel(title: title, symbol: symbol, color: color)
            Spacer()
            Text(verbatim: value ?? String(localized: "Not set up")).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Settings › Model: base URL and key (placeholders only), Test Connection, and an Advanced disclosure with
/// the model override (empty = first model from GET {base}/models), per-role models and request tweaks.
struct BoardSettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink

    var body: some View {
        List {
            Section {
                HStack(spacing: Space.l) {
                    AgentFace(mood: board.connected ? .idle : .sleeping).frame(width: 52, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: board.name.isEmpty ? "ESP32 Agent" : board.name).font(.headline)
                        Text(board.connected ? "Connected" : board.pairedID != nil ? "Connecting…" : "Not paired")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Space.xs)
                if board.connected, let s = board.status {
                    ValueRow(title: "Mouse", value: s.usb ?? "–")
                    ValueRow(title: "Mirroring", value: s.ap ?? "–")
                }
            }
            if board.pairedID == nil || !board.connected {
                Section {
                    ForEach(board.found.filter { $0.id != board.pairedID }) { f in
                        Button { Haptics.tick(); board.pair(f.id) } label: {
                            LabeledContent { Text(verbatim: "\(f.rssi) dBm") } label: { Text(verbatim: f.name) }
                        }
                        .tint(.primary)
                    }
                    Button { board.scan() } label: {
                        HStack {
                            Text(board.scanning ? "Scanning…" : "Scan for Boards")
                            if board.scanning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(board.scanning)
                } header: {
                    Text("Nearby")
                }
            }
            Section {
                Button { app.startJoin() } label: {
                    HStack {
                        Text("Join the Board's Wi-Fi")
                        Spacer()
                        if app.join.busy { ProgressView() }
                    }
                }
                .disabled(app.join.busy)
                if let ssid = app.hotspotSSID { ValueRow(title: "Network", value: ssid) }
                if let net = app.manualHotspot, let pass = net.pass {
                    if let ssid = net.ssid { ValueRow(title: "Network", value: ssid) }
                    ValueRow(title: "Password", value: pass)
                    Button { UIPasteboard.general.string = pass; Haptics.success() } label: { Text("Copy Wi-Fi Password") }
                    Button { UIPasteboard.general.string = pass; Hotspot.openWiFiSettings() } label: { Text("Open Settings") }
                }
            } header: {
                Text("Wi-Fi")
            } footer: {
                Text("Turn off Personal Hotspot before joining. While joined, the internet goes over cellular data. Switch back in Settings › Wi-Fi when you are done.")
            }
            FirmwareSection(app: app, updater: app.firmware, board: board)
            if board.pairedID != nil {
                Section {
                    Button("Unpair Board", role: .destructive) { Task { await board.unpair() } }
                    Button("Forget in This App", role: .destructive) { board.forget() }
                } footer: {
                    Text("Unpair erases the bonds on the board. iOS keeps its own: also tap (i) next to \"ESP32 Agent\" in Settings › Bluetooth and choose Forget This Device.")
                }
            }
        }
        .navigationTitle("Board")
        .navigationBarTitleDisplayMode(.inline)
        .task { await app.refreshHotspot() }
    }
}

/// Settings › Calibration: one tap calibrates on the grid board; accuracy and span in a small second line.
struct CalibrationRow: View {
    @ObservedObject var app: AppModel
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var pointer: Pointer

    private var ready: Bool { MockMode.on || calibrator.boardReady }

    var body: some View {
        Button { calibrator.calibrate() } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Calibration")
                        if let span = pointer.span {
                            Text(verbatim: "\(pointer.quality.map(CalibrationText.percent) ?? "–") · \(span.w) × \(span.h)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } icon: { SettingsIcon(symbol: "scope", color: .orange) }
                Spacer()
                if ready {
                    Text("Calibrate").foregroundStyle(Color.accentColor)
                } else {
                    Text("Connect the board").foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .disabled(!ready || calibrator.busy)
    }
}
