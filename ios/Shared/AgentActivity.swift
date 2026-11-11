import ActivityKit
import AppIntents
import Foundation

/// The Live Activity / Dynamic Island of a run or a demonstration recording: while the agent works the app
/// is in the background, so this is the only thing the user sees.
struct AgentActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case running, help, countdown, recording, paused
        case resuming  // a stopped run goes on: the user switches back to its app before `since`

        /// A timer counting down to `since`.
        var countsDown: Bool { self == .countdown || self == .resuming }
    }

    struct ContentState: Codable, Hashable {
        var mood: Mood
        var step: Int       // actions done
        var limit: Int      // the step limit of a run
        var line: String    // what it does now, one line
        var finished = false
        var asksVerdict = false  // finished and done: ✓ Correct / ✗ Wrong for a while (RunVerdictIntent)
        var phase = Phase.running
        var since = Date()  // recording start, for the timer; the countdown's end before that
        var label = ""      // what the character says, compact island ("Thinking…", "Tapping Clock")
        var labelFull = ""  // the same, longer, for the expanded island and the Lock Screen
        var minimalLabel: String?  // explicit phase, not inferred from the face
        var waitingSince: Date?  // system-rendered elapsed timer, even between app updates
        var lookX = 0.0     // where the eyes look, -1...1 (darting while it waits, toward the pointer's target)
        var lookY = 0.0

        var look: CGPoint { CGPoint(x: lookX, y: lookY) }

        /// The shared-island bubble must show a phase, including states restored from older builds.
        var minimalStatusText: String {
            for text in [minimalLabel, label] {
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if finished {
                switch mood {
                case .success: return String(localized: "Done")
                case .failure: return String(localized: "Error")
                default: return String(localized: "Stop")
                }
            }
            return phase == .help ? String(localized: "Help") : String(localized: "Wait")
        }

        var statusAccessibilityText: String {
            let full = labelFull.trimmingCharacters(in: .whitespacesAndNewlines)
            return full.isEmpty ? minimalStatusText : full
        }

        /// Only a running run can go stale. Help, Pause, the countdowns and recordings wait for the user, not the
        /// app, and a finished one has nothing left to update.
        var canGoStale: Bool { phase == .running && !finished }

        /// What the widget shows: the stuck face and line only when the system marked a running run stale.
        func stuck(_ isStale: Bool) -> Bool { isStale && canGoStale }
    }

    var task: String
    var runID: String
    var name: String?  // the agent's name, as the user calls it

    static func url(run: String) -> URL { URL(string: "iphoneagent://run/\(run)")! }
}

/// What the Live Activity says once iOS has suspended the app mid-run: its updates stopped, the stale date
/// passed and the system set `isStale`. Tapping it opens the app, which wakes the run.
enum StuckText {
    static var short: String { String(localized: "Paused by iOS") }
    static var full: String { String(localized: "Paused by iOS — tap to continue") }
    static var minimal: String { String(localized: "Stuck") }
}

/// What the Live Activity buttons and notification actions ask the app to do.
enum AgentCommand: String {
    case stop, resume, skip, takeOver, stopRecording, pause, unpause
}

/// Set by the app; nil inside the widget extension (the intents run in the app's process).
@MainActor enum AgentControl {
    static var handle: ((AgentCommand) async -> Void)?
    /// The user's word on a finished run from its Live Activity: (run id, correct).
    static var verdict: ((String, Bool) async -> Void)?
}

/// ✓ / ✗ on a run that says it is done (Henry 2026-11-12). Wrong undoes what an intent learned from it.
struct RunVerdictIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Was the run right?"
    static let isDiscoverable = false
    @Parameter(title: "Run") var run: String
    @Parameter(title: "Correct") var correct: Bool

    init() {}
    init(run: String, correct: Bool) {
        self.run = run
        self.correct = correct
    }

    func perform() async throws -> some IntentResult {
        await AgentControl.verdict?(run, correct)
        return .result()
    }
}

/// Stop button: releases everything and stops the agent.
struct StopAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the agent"
    static let description = IntentDescription("Stops the running task and lets go of the screen.")
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.stop)
        return .result()
    }
}

/// Pause button: the run holds before its next look, keeping everything it has done so far.
struct PauseAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause the agent"
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.pause)
        return .result()
    }
}

/// Continue after Pause: the run goes on from the screen that is in front now.
struct UnpauseAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume the agent"
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.unpause)
        return .result()
    }
}

/// "Needs your help": the user did it by hand, the agent goes on from the current screen.
struct ContinueAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Continue"
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.resume)
        return .result()
    }
}

/// "Needs your help": skip the step the agent is stuck on.
struct SkipStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip step"
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.skip)
        return .result()
    }
}

/// Ends a demonstration recording.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"
    func perform() async throws -> some IntentResult {
        await AgentControl.handle?(.stopRecording)
        return .result()
    }
}
