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

/// "Needs your help": why, in words, and two actions, the likely one filled (HIG: one prominent action). Stop is the
/// run bar's below. The run's own limits read as sentences, not reasons ("step limit reached", 2026-11-06).
struct HelpPanel: View {
    @ObservedObject var app: AppModel

    private var reason: String { app.help ?? "" }
    private var limit: Bool { reason == AgentLoop.stepLimitReason }
    private var stalled: Bool { reason.hasPrefix(AgentLoop.stallReason) }
    private var touchless: Bool { reason == TouchCheck.reason }
    private var repeating: Bool { reason == NoProgress.reason }  // a stall too (its prefix): the same buttons
    /// Model rounds failed in a row: "3 errors in a row" said nothing to users (2026-11-20); the agent words it.
    private var erring: Bool { reason.hasSuffix(AgentLoop.errorsReason) }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.m) {
                Label { title } icon: { Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning) }
                    .font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if erring, let words = app.agent.helpMessage {  // already in the user's language
                    Text(verbatim: words).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s) {
                    if app.takingOver {
                        Button { app.answerHelp(.resume) } label: { Label("Continue", systemImage: "play.fill") }
                            .buttonStyle(BigButton())
                        Button("Skip Step") { app.answerHelp(.skip) }.buttonStyle(BigButton.tinted)
                    } else if limit || touchless || erring {
                        Button { app.answerHelp(.resume) } label: {
                            Label(erring ? LocalizedStringKey("Continue") : "Keep Going", systemImage: "play.fill")
                        }
                        .buttonStyle(BigButton())
                        Button("Take Over") { app.takeOver() }.buttonStyle(BigButton.tinted)
                    } else {
                        Button { app.takeOver() } label: { Label("Take Over", systemImage: "hand.point.up.left.fill") }
                            .buttonStyle(BigButton())
                        Button(stalled ? "Keep Going" : "Skip Step") { app.answerHelp(stalled ? .resume : .skip) }
                            .buttonStyle(BigButton.tinted)
                    }
                }
            }
            .padding(.vertical, Space.xs)
        } header: {
            Text("Needs your help")
        }
    }

    private var title: Text {
        if limit { return Text("That's \(app.agent.stepLimit) steps") }
        if repeating { return Text("I keep repeating the same step") }
        if stalled { return Text("The screen hasn't changed in a while") }
        if touchless { return Text("My taps aren't reaching the iPhone") }
        if erring { return Text("The AI service isn't answering") }
        return Text(verbatim: reason)
    }

    private var detail: LocalizedStringKey? {
        if app.takingOver { return "Do the step yourself, then tap Continue." }
        if touchless { return "\(TouchCheck.advice) Then tap Keep Going." }
        if repeating { return "\(NoProgress.advice) Then tap Keep Going." }
        if limit { return "A safety limit. If the run is still getting somewhere, keep going." }
        if stalled { return "My taps may be missing. Do this step yourself, or let me try again." }
        return nil
    }
}

/// The run is paused for a lost link: what is missing, how long, and what (if anything) the user should do.
struct RecoveryPanel: View {
    @ObservedObject var app: AppModel
    let stage: Recovery.Stage

    var body: some View {
        Section {
            // Henry 2026-11-18: a blue icon on a red Stop beside a three-line bold title looked off; the big Stop
            // at the bottom already stops the run, so the card only says what is missing and for how long.
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                if stage.ask {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning)
                } else {
                    ProgressView()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: stage.status.full).font(.body)
                    if stage.line != stage.status.full {
                        Text(verbatim: stage.line).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(timerInterval: app.recoverySince...Date.distantFuture, countsDown: false)
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
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

/// Above the face on Home in Bluetooth mode after a long mirroring session or frozen video (MirrorHint): a tip,
/// not a warning; × hides it until mirroring restarts, "Don't show again" for good.
struct MirrorHintBanner: View {
    @ObservedObject var app: AppModel
    let busy: Bool  // a run starting or going: the tip waits

    var body: some View {
        if app.mirrorHintShown && !busy {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label("Bluetooth mode: if runs get stuck after a long session, stop and restart Screen Mirroring.",
                          systemImage: "rectangle.on.rectangle")
                    Button("Don't Show Again") { app.dismissMirrorHint(forever: true) }
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { app.dismissMirrorHint(forever: false) } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Close"))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.accent)
            .buttonStyle(.plain)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, Space.l)
            .transition(.opacity.combined(with: .scale))
        }
    }
}
