import SwiftUI

/// On Home: checks for firmware when the board connects, opens the update sheet by itself when this app needs a
/// newer board, and shows the sheet when the banner is tapped.
struct FirmwareGate: ViewModifier {
    @ObservedObject var app: AppModel
    @ObservedObject var updater: FirmwareUpdater
    @ObservedObject var board: BoardLink

    func body(content: Content) -> some View {
        content
            .task(id: updater.usesUSBRelease) { if updater.usesUSBRelease { await updater.boardConnected() } }
            .sheet(isPresented: $updater.presented) { FirmwareSheet(app: app, updater: updater, board: board) }
    }
}

/// Above the face on Home: "Update firmware 2 → 3", with × to put it off until the next release.
struct FirmwareBanner: View {
    @ObservedObject var updater: FirmwareUpdater

    var body: some View {
        if updater.showsBanner, let release = updater.release {
            HStack(spacing: Space.s) {
                Button { updater.presented = true } label: {
                    Label("Update firmware \(updater.current.description) → \(release.ver.description)", systemImage: "arrow.down.circle")
                        .font(.footnote.weight(.medium))
                }
                Button { withAnimation { updater.dismissBanner() } } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Not Now")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Color(.secondarySystemFill), in: Capsule())
            .transition(.opacity.combined(with: .scale))
        }
    }
}

/// Settings › Board › Firmware: the board's version and the way into the same sheet.
struct FirmwareSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var updater: FirmwareUpdater
    @ObservedObject var board: BoardLink
    @State private var showing = false

    var body: some View {
        Section {
            ValueRow(title: "Version", value: board.connected ? updater.current.description : "–")
            if updater.available, let release = updater.release {
                Button { showing = true } label: { Label("Update to \(release.ver.description)", systemImage: "arrow.down.circle") }
            } else if updater.checking {
                HStack { Text("Checking for Updates…").foregroundStyle(.secondary); Spacer(); ProgressView() }
            } else if board.status?.isWirelessHID != true {
                Button("Check for Updates") { Task { await updater.check() } }.disabled(!updater.usesUSBRelease)
            }
        } header: {
            Text("Firmware")
        } footer: {
            if board.status?.board == "note4" {
                Text("Use firmware made for Note 4. Back up the board and follow its USB installation guide.")
            } else if board.connected && !updater.usesUSBRelease {
                Text("Use firmware for your board model. Back up the board and follow its installation guide.")
            } else if let error = updater.checkError {
                Text(verbatim: error)
            } else if updater.release != nil && !updater.available && board.connected {
                Text("The board is up to date.")
            }
        }
        .sheet(isPresented: $showing) { FirmwareSheet(app: app, updater: updater, board: board) }
    }
}

/// The update, start to end: what changes, join the board's Wi-Fi, Update, then progress until the board is
/// back. While it runs (or when this app needs it) the sheet can't be swiped away; the screen stays on.
struct FirmwareSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var updater: FirmwareUpdater
    @ObservedObject var board: BoardLink
    @Environment(\.dismiss) private var dismiss

    private var onBoardWiFi: Bool { app.onBoardHotspot(manual: false) }

    var body: some View {
        Group {
            if updater.phase == .idle { intro } else { FirmwareProgress(updater: updater, close: close) }
        }
        .padding(Space.xl)
        .interactiveDismissDisabled(updater.busy || updater.mustUpdate)
        .task {
            while !Task.isCancelled {
                await app.refreshHotspot()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func close() {
        updater.dismiss()
        if !updater.mustUpdate { dismiss() }
    }

    private var intro: some View {
        VStack(spacing: Space.l) {
            Spacer()
            FirmwareArt(phase: .idle)
            Text(updater.required ? "Board Update Required" : "Update the Board").font(.title2.bold())
            Group {
                if updater.required {
                    Text("This version of ESP32 Agent needs board firmware \(Firmware.required.description) or later.")
                } else {
                    Text("Takes about a minute. Your intents and settings stay as they are.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let release = updater.release {
                Text(verbatim: "\(updater.current) → \(release.ver)").font(.title3.monospacedDigit().weight(.semibold))
                if let notes = release.notes, !notes.isEmpty {
                    Text(verbatim: notes).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Spacer()
            steps
        }
    }

    @ViewBuilder private var steps: some View {
        VStack(spacing: Space.s) {
            if updater.release == nil {
                if updater.checking {
                    ProgressView("Checking for Updates…")
                } else {
                    if let error = updater.checkError { Text(verbatim: error).font(.footnote).foregroundStyle(.secondary) }
                    Button("Check Again") { Task { await updater.check() } }
                        .buttonStyle(BigButton(tint: .primary, ink: Color(.systemBackground)))
                }
            } else if let blocker = updater.blocker {
                Text(verbatim: blocker).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !onBoardWiFi {
                Text(joinText).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { app.startJoin() } label: {
                    HStack { Text("Join the Board's Wi-Fi"); if app.join.busy { ProgressView().tint(Color(.systemBackground)) } }
                }
                .buttonStyle(BigButton(tint: .primary, ink: Color(.systemBackground)))
                .disabled(app.join.busy)
            } else {
                Label("On the board's Wi-Fi", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                Button("Update Now") { updater.install() }
                    .buttonStyle(BigButton(tint: .primary, ink: Color(.systemBackground)))
            }
            if !updater.mustUpdate {
                Button("Later") { dismiss() }.buttonStyle(BigButton(tint: Color(.secondarySystemFill), ink: .primary))
            }
        }
    }

    private var joinText: String {
        if case .failed(let reason) = app.join { return reason }
        return String(localized: "The update goes over the board's Wi-Fi. Join it first; the internet keeps working over cellular.")
    }
}

/// Progress, then the result. Try Again keeps the sheet; Done closes it.
struct FirmwareProgress: View {
    @ObservedObject var updater: FirmwareUpdater
    let close: () -> Void

    var body: some View {
        VStack(spacing: Space.l) {
            Spacer()
            FirmwareArt(phase: updater.phase, progress: updater.progress)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if updater.phase == .sending {  // the ring around the face shows it too
                Text(verbatim: updater.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            Spacer()
            if updater.busy {
                Label("Keep this app open and the board plugged in.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(spacing: Space.s) {
                    if case .failed = updater.phase {
                        Button("Try Again") { updater.install() }
                            .buttonStyle(BigButton(tint: .primary, ink: Color(.systemBackground)))
                            .disabled(updater.blocker != nil)
                    }
                    Button(updater.phase == .done ? "Done" : "Close", action: close)
                        .buttonStyle(updater.phase == .done ? BigButton(tint: .primary, ink: Color(.systemBackground))
                                                             : BigButton(tint: Color(.secondarySystemFill), ink: .primary))
                }
            }
        }
        .animation(.default, value: updater.phase)
    }

    private var title: LocalizedStringKey {
        switch updater.phase {
        case .idle, .downloading: "Downloading Update…"
        case .sending: "Sending to the Board…"
        case .restarting: "Board Restarting…"
        case .done: "Board Updated"
        case .failed: "Update Didn't Finish"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .sending where updater.attempt > 1:
            String(localized: "Connection dropped. Trying again (\(updater.attempt) of \(FirmwareUpdater.attempts)).")
        case .sending: String(localized: "Over the board's Wi-Fi.")
        case .restarting: String(localized: "The board checks the new firmware and reconnects.")
        case .done: String(localized: "Firmware \(updater.current.description).")
        case .failed(let message): message
        default: String(localized: "Checking the signature.")
        }
    }
}

/// The character taking the update: chevrons stream down into it while it downloads and receives, a ring around
/// the board fills with the send progress, and the face follows along (thinking while it restarts, then
/// happy or sad).
struct FirmwareArt: View {
    let phase: FirmwareUpdater.Phase
    var progress = 0.0
    private let size: CGFloat = 112

    private var mood: Mood {
        switch phase {
        case .idle: .idle
        case .downloading, .sending: .listening
        case .restarting: .thinking
        case .done: .success
        case .failed: .failure
        }
    }
    private var streaming: Bool { phase == .downloading || phase == .sending }

    var body: some View {
        VStack(spacing: Space.s) {
            Chevrons(moving: streaming).frame(width: 28, height: 30).opacity(phase == .done ? 0 : 1)
            ZStack(alignment: .top) {
                let ring = RoundedRectangle(cornerRadius: (size + 16) * 0.24, style: .continuous)
                ring.stroke(Color(.quaternaryLabel), lineWidth: 3)
                    .frame(width: size + 16, height: size + 16)
                    .offset(y: -8)
                ring.trim(from: 0, to: phase == .sending ? progress : phase == .restarting || phase == .done ? 1 : 0)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 16, height: size + 16)
                    .offset(y: -8)
                    .animation(.easeOut(duration: 0.3), value: progress)
                AgentFace(mood: mood).frame(width: size, height: size * 1.12)
            }
            .frame(height: size * 1.12)
        }
        .accessibilityHidden(true)
    }
}

/// Three down chevrons lighting up in turn, top to bottom: data on its way in.
private struct Chevrons: View {
    let moving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !moving)) { t in
            let step = Int(t.date.timeIntervalSinceReferenceDate * 4) % 3
            VStack(spacing: -4) {
                ForEach(0..<3, id: \.self) { i in
                    Chevron()
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 18, height: 8)
                        .opacity(moving ? (i == step ? 1 : 0.25) : 0.25 + Double(i) * 0.3)
                }
            }
        }
    }
}

private struct Chevron: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        }
    }
}
