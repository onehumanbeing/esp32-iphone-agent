import SwiftUI

/// The character takes off before a run: "See you later!" and it shrinks up toward the island while the
/// board sends the app home at once (a fade under Reduce Motion). Only a problem (board slow, swipe up yourself)
/// brings back words and Cancel; the overlay stays until the app is really in the background.
struct DepartureOverlay: View {
    let problem: String?
    let cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gone = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()  // plain, no blur: the app is flicked away at once
            VStack(spacing: Space.l) {
                AgentFace(mood: .acting)
                    .frame(width: 140, height: 157)
                    .scaleEffect(gone && !reduceMotion ? 0.15 : 1, anchor: .top)
                    .offset(y: gone && !reduceMotion ? -360 : 0)
                    .opacity(gone ? 0 : 1)
                    .accessibilityHidden(true)
                Text("See you later!").font(.title2.bold()).opacity(gone ? 0 : 1)
                if let problem {
                    VStack(spacing: Space.m) {
                        Text(verbatim: problem)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Button("Cancel", role: .cancel, action: cancel)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(minHeight: 44)
                    }
                    .padding(Space.l)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: problem)
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3).delay(0.1)) { gone = true }  // with the board's flick
        }
        .accessibilityLabel(Text("Starting"))
    }
}

/// "Needs your help": why, and Take over / Continue / Skip / Stop (the same as the Live Activity).
struct HelpPanel: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            Label { Text(verbatim: app.help ?? "") } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning)
            }
            .font(.body.weight(.semibold))
            if app.takingOver {
                Text("Do the step yourself, then tap Continue.").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.s) {
                if app.takingOver {
                    Button { app.answerHelp(.resume) } label: { Label("Continue", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Palette.ok)
                } else {
                    Button { app.takeOver() } label: { Label("Take Over", systemImage: "hand.point.up.left.fill") }
                        .buttonStyle(.borderedProminent)
                }
                Button { app.answerHelp(.skip) } label: { Text("Skip Step") }.buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) { Task { await app.stopAgent() } } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered).accessibilityLabel(Text("Stop"))
            }
            .controlSize(.regular)
        } header: {
            Text("Needs your help")
        }
    }
}

/// The run is paused for a lost link: what is missing, how long, and what (if anything) the user should do.
struct RecoveryPanel: View {
    @ObservedObject var app: AppModel
    let stage: Recovery.Stage

    var body: some View {
        Section {
            HStack(spacing: Space.m) {
                if stage.ask {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning)
                } else {
                    ProgressView()
                }
                Text(verbatim: app.recoveryStatus(stage).full).font(.body.weight(.semibold))
                Spacer()
                Text(timerInterval: app.recoverySince...Date.distantFuture, countsDown: false)
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if app.recoveryLine(stage) != app.recoveryStatus(stage).full {
                Text(verbatim: app.recoveryLine(stage)).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await app.stopAgent() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            }
        } header: {
            if stage.part == .frames {
                Text("Waiting for a screen image")
            } else {
                Text("Connection lost, run paused")
            }
        }
    }
}
