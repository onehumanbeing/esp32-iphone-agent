import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgentActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
        AgentStatusWidget()
        RunLastIntentControl()
        StopAgentControl()
    }
}

/// The Live Activity and Dynamic Island: running (eyes, "3/12", current step, Stop), needs help
/// (Continue / Skip / Stop), the 3-2-1 before a recording, and recording a demonstration (red dot, timer, Stop).
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AgentActivityAttributes.url(run: context.attributes.runID))
        } dynamicIsland: { context in
            let s = context.state, stuck = s.stuck(context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Eyes(state: s, stuck: stuck).padding(4).frame(width: 44, height: 44).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counter(state: s).font(.headline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: context.attributes.task).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Says(state: s, full: true, stuck: stuck).font(.subheadline.weight(.semibold))
                        if let since = s.waitingSince, !s.finished {
                            Text(since, style: .timer).monospacedDigit().font(.footnote)
                                .timerAccessibility("Waiting time")
                        }
                        if s.line != s.labelFull && (s.phase != .running || s.finished) {
                            Text(verbatim: s.line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if s.phase == .running {
                            ProgressView(value: Double(min(s.step, s.limit)), total: Double(max(s.limit, 1))).tint(.white)
                        }
                        if !s.finished { Buttons(state: s) }
                    }
                }
            } compactLeading: {
                if s.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else if s.phase == .countdown {
                    Image(systemName: "record.circle").foregroundStyle(.white)
                } else {
                    Eyes(state: s, stuck: stuck).padding(3).frame(width: 24, height: 24)
                }
            } compactTrailing: {
                if (s.phase == .recording || s.phase.countsDown) && !s.finished {
                    Counter(state: s).font(.caption).frame(maxWidth: 44)
                } else {
                    Says(state: s, full: false, stuck: stuck).font(.caption.bold()).frame(width: 92, alignment: .trailing)
                }
            } minimal: {
                if s.phase == .recording {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                } else if s.phase.countsDown && !s.finished {
                    Counter(state: s).font(.caption2)
                } else {
                    // Screen Mirroring shares the island during a run and leaves only this bubble: the face.
                    AgentMinimalStatus(state: s, stuck: stuck)
                }
            }
            .widgetURL(AgentActivityAttributes.url(run: context.attributes.runID))
            .keylineTint(s.phase == .help ? .orange : s.phase == .recording ? .red : .white)
        }
    }
}

/// "3/12" while running, 3-2-1 before a recording, the elapsed time while recording.
private struct Counter: View {
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        if state.phase.countsDown && !state.finished {
            // The system counts down on its own; the app switches to recording when it ends.
            Text(timerInterval: state.since.addingTimeInterval(-10)...state.since, countsDown: true)
                .monospacedDigit().foregroundStyle(.white).multilineTextAlignment(.trailing)
                .timerAccessibility("Countdown")
        } else if state.phase == .recording && !state.finished {
            Text(state.since, style: .timer)
                .monospacedDigit().foregroundStyle(.red).multilineTextAlignment(.trailing)
                .timerAccessibility("Recording time")
        } else {
            Text(verbatim: "\(state.step)/\(state.limit)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// A fixed label instead of the live timer text. Archiving the Live Activity encodes a timer's accessibility
    /// text, and SwiftUI aborts there (NSRangeException in ResolvableTextSegmentAttribute, TestFlight 1.0.1 (9)).
    func timerAccessibility(_ label: LocalizedStringKey) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(Text(label))
    }
}

private struct Buttons: View {
    let state: AgentActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .help:
                Button(intent: ContinueAgentIntent()) { Label("Continue", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .tint(.green)
                Button(intent: SkipStepIntent()) { Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity) }
                    .tint(.gray)
                Button(intent: StopAgentIntent()) { Image(systemName: "stop.fill") }.tint(.red)
            case .countdown, .recording:
                Button(intent: StopRecordingIntent()) {
                    Label("Stop Recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            case .running:
                Button(intent: PauseAgentIntent()) { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    .tint(.gray)
                Button(intent: StopAgentIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .tint(.red)
            case .resuming:
                Button(intent: StopAgentIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .tint(.red)
            case .paused:
                Button(intent: UnpauseAgentIntent()) { Label("Continue", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .tint(.green)
                Button(intent: StopAgentIntent()) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .tint(.red)
            }
        }
        .buttonStyle(.borderedProminent)
    }
}

/// The character's face without the USB tab. Widgets do not animate on their own, but between updates a
/// new `look` springs toward the gesture's target and a new mood morphs the expression. Stuck: "×" eyes.
private struct Eyes: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: AgentActivityAttributes.ContentState
    var stuck = false
    var body: some View {
        AgentFace(mood: state.mood, look: state.look, lookRange: 2.4, animated: false, showsTab: false, crossed: stuck)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state)
    }
}

/// What the character says ("Thinking…", "Tapping Clock", "Done!"), colored by how things stand.
/// Stuck (iOS suspended the app): "Paused by iOS — tap to continue" instead.
private struct Says: View {
    let state: AgentActivityAttributes.ContentState
    let full: Bool
    var stuck = false
    var body: some View {
        let text = stuck ? (full ? StuckText.full : StuckText.short) : full ? state.labelFull : state.label
        Text(verbatim: text.isEmpty ? state.line : text)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: state)  // the same beat as the face
    }

    private var color: Color {
        if state.phase == .help { return .orange }
        if state.finished { return state.mood == .success ? .green : state.mood == .failure ? .orange : .secondary }
        return .white
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        let s = context.state, stuck = s.stuck(context.isStale)
        HStack(alignment: .top, spacing: 14) {
            if (s.phase == .recording || s.phase == .countdown) && !s.finished {
                Image(systemName: s.phase == .recording ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 40)).foregroundStyle(s.phase == .recording ? .red : .white).frame(width: 52)
            } else {
                Eyes(state: s, stuck: stuck).frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let name = context.attributes.name {
                    Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack {
                    Text(verbatim: context.attributes.task).font(.headline).lineLimit(1)
                    Spacer()
                    Counter(state: s).font(.subheadline)
                }
                if !s.finished && (stuck || !s.labelFull.isEmpty) {
                    Says(state: s, full: true, stuck: stuck).font(.subheadline.weight(.semibold))
                }
                if s.phase != .running || s.finished {
                    Text(verbatim: s.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if s.finished {
                    Label(s.mood == .success ? "Done · tap to review" : "Ended · tap to review",
                          systemImage: s.mood == .success ? "checkmark.circle.fill" : "play.circle")
                        .font(.footnote.weight(.semibold))
                } else {
                    if s.phase == .running {
                        ProgressView(value: Double(min(s.step, s.limit)), total: Double(max(s.limit, 1))).tint(.white)
                    }
                    Buttons(state: s).controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}
