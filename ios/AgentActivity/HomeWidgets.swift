import AppIntents
import SwiftUI
import WidgetKit

struct AgentEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentSnapshot?  // nil: the app hasn't written one yet
}

struct AgentProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentEntry { AgentEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (AgentEntry) -> Void) {
        completion(AgentEntry(date: .now, snapshot: context.isPreview ? SharedState.load() ?? .preview : SharedState.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentEntry>) -> Void) {
        // The app reloads the timelines when its state changes.
        completion(Timeline(entries: [AgentEntry(date: .now, snapshot: SharedState.load())], policy: .never))
    }
}

/// Home Screen (small: the character and its status; medium: plus up to four saved intents as buttons)
/// and Lock Screen (circular: the character; rectangular: the last run).
struct AgentStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedState.kind, provider: AgentProvider()) { entry in
            AgentWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(AppName.current)
        .description("See whether the agent is ready and run your saved intents.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct AgentWidgetView: View {
    let entry: AgentEntry
    @Environment(\.widgetFamily) private var family

    private var snap: AgentSnapshot { entry.snapshot ?? AgentSnapshot(status: .needsSetup) }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemMedium: medium
        default: small
        }
    }

    private var statusText: Text {
        if entry.snapshot == nil { return Text("Open the app") }
        switch snap.status {
        case .ready: return Text("Ready")
        case .running: return Text("Running · step \(snap.step)")
        case .offline: return Text("Board offline")
        case .needsSetup: return Text("Needs setup")
        }
    }

    private var face: some View {
        AgentFace(mood: snap.mood, animated: false, reacts: false)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            face.frame(width: 52, height: 58)
            Spacer(minLength: 0)
            Text(verbatim: AppName.current).font(.caption).foregroundStyle(.secondary)
            statusText.font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            if snap.status == .running {
                Text(verbatim: snap.task).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                face.frame(width: 52, height: 58)
                Spacer(minLength: 0)
                statusText.font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.8)
            }
            .frame(width: 96, alignment: .leading)
            if snap.intents.isEmpty {
                Text("Save an intent in the app to run it from here.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    ForEach(snap.intents.prefix(4)) { item in
                        Button(intent: RunSavedIntentIntent(intent: SavedIntentEntity(item))) {
                            Label { Text(verbatim: item.name).lineLimit(1) } icon: { Image(systemName: item.symbol) }
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .disabled(snap.status == .running)
                    }
                }
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            face.padding(8)
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if snap.status == .running {
                Label { Text("Step \(snap.step)") } icon: { Image(systemName: "play.fill") }.font(.headline)
                Text(verbatim: snap.task).font(.caption).lineLimit(2)
            } else if let run = snap.lastRun {
                Label { Text(run.ok ? "Done" : "Not finished") } icon: {
                    Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                }
                .font(.headline)
                Text(verbatim: run.task).font(.caption).lineLimit(1)
                Text(run.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(verbatim: AppName.current).font(.headline)
                statusText.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Control Center: run the last intent; stop the agent.
struct RunLastIntentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RunLastIntent") {
            ControlWidgetButton(action: RunLastIntentIntent()) {
                Label("Run Last Intent", systemImage: "bolt.fill")
            }
        }
        .displayName("Run Last Intent")
        .description("Runs the saved intent you ran last.")
    }
}

struct StopAgentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StopAgent") {
            ControlWidgetButton(action: StopAgentIntent()) {
                Label("Stop \(AppName.current)", systemImage: "stop.fill")
            }
        }
        .displayName("Stop \(AppName.current)")
        .description("Stops the running task and lets go of the screen.")
    }
}

#Preview("Small", as: .systemSmall) {
    AgentStatusWidget()
} timeline: {
    AgentEntry(date: .now, snapshot: .preview)
}

#Preview("Medium", as: .systemMedium) {
    AgentStatusWidget()
} timeline: {
    AgentEntry(date: .now, snapshot: .preview)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    AgentStatusWidget()
} timeline: {
    AgentEntry(date: .now, snapshot: .preview)
}
