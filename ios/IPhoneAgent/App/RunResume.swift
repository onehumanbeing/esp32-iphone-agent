import Foundation

/// A stopped run goes on from where it was: same task, plan, steps and notes. The agent can't bring that app
/// back itself (it doesn't know which one, and Home would lose the screen), so the user switches back to it
/// while the Dynamic Island counts down.
extension AppModel {
    static let switchBackSeconds = 5.0
    static let switchBackLimit = 30.0  // nobody switched: Home, as for a new run (the model opens the app again)

    /// The last run stopped before it was done, and its steps are still in memory.
    var canResume: Bool {
        !agent.running && !startingAgent && !agent.task.isEmpty && !agent.steps.isEmpty
            && agent.steps.last?["action"]?.str != "done"
    }

    func resumeRun() async {
        guard canResume else { return }
        DebugLog.write("run: resume \"\(agent.task.prefix(80))\" after \(agent.steps.count) steps")
        await startAgent(agent.task, resume: true)
    }

    /// The countdown, then the app must be in the background. True once it is.
    func waitForSwitchBack() async throws -> Bool {
        let ends = Date().addingTimeInterval(Self.switchBackSeconds), giveUp = now() + Self.switchBackLimit
        let line = String(localized: "Switch back to the app you were in. I'll go on from there.")
        homeHint = line
        live.update(mood: .listening, step: moveCount, line: line, phase: .resuming, status: .switchBack, since: ends)
        defer { homeHint = nil }
        while now() < giveUp {
            try Task.checkCancellation()
            if appIsBackgrounded && Date() >= ends {
                DebugLog.write("run: resume: the user switched back")
                live.update(mood: .thinking, step: moveCount, line: String(localized: "Going on from here…"), phase: .running,
                            status: .looking)
                return true
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        DebugLog.write("run: resume: nobody switched back in \(Int(Self.switchBackLimit)) s; going Home")
        return try await leaveForRun()
    }
}
