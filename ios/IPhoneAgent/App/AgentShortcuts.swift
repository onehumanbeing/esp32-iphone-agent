import AppIntents
import SwiftUI

/// "Ask ESP32 Agent to …": runs a typed task. A LiveActivityIntent so it runs in the app process in the
/// background (the run itself happens on the Home Screen) and may start the Live Activity.
struct RunTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Run a Task"
    static let description = IntentDescription("Asks the agent to do a task on this phone, like \"Open Settings and go to Wi-Fi\".")

    @Parameter(title: "Task", requestValueDialog: "What should I do?") var task: String

    static var parameterSummary: some ParameterSummary { Summary("Ask the agent to \(\.$task)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.runTask(task)) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}

/// Calibration catches taps on this app's own screen, so it opens the app.
struct CalibrateIntent: AppIntent {
    static let title: LocalizedStringResource = "Calibrate the Pointer"
    static let description = IntentDescription("Opens the app and calibrates the pointer.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await AgentRequests.handle?(.calibrate) ?? AgentRequests.unavailable
        return .result(dialog: "\(line)")
    }
}

struct GetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Status"
    static let description = IntentDescription("Tells whether the board, Screen Mirroring, calibration and the model are ready.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let line = await AgentRequests.handle?(.status) ?? AgentRequests.unavailable
        let snapshot = SharedState.load()
        return .result(dialog: "\(line)", view: StatusSnippet(mood: snapshot?.mood ?? .sleeping, lines: AppModel.shared.statusLines))
    }
}

struct StatusSnippet: View {
    let mood: Mood
    let lines: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AgentFace(mood: mood, animated: false, reacts: false).frame(width: 44, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text(verbatim: $0).font(.subheadline) }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

struct AgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunSavedIntentIntent(), phrases: [
            "Run \(.applicationName) intent \(\.$intent)",
            "Run \(\.$intent) with \(.applicationName)",
        ], shortTitle: "Run Intent", systemImageName: "bolt.fill")
        AppShortcut(intent: RunTaskIntent(), phrases: [
            "Ask \(.applicationName) to do something",
            "Give \(.applicationName) a task",
        ], shortTitle: "Run a Task", systemImageName: "text.bubble")
        AppShortcut(intent: StopAgentIntent(), phrases: [
            "Stop \(.applicationName)",
        ], shortTitle: "Stop", systemImageName: "stop.fill")
        AppShortcut(intent: GetStatusIntent(), phrases: [
            "\(.applicationName) status",
            "Is \(.applicationName) ready",
        ], shortTitle: "Status", systemImageName: "checkmark.circle")
        AppShortcut(intent: CalibrateIntent(), phrases: [
            "Calibrate \(.applicationName)",
        ], shortTitle: "Calibrate", systemImageName: "scope")
    }
}
