import Foundation

/// Pause / Continue from the Dynamic Island. The run finishes the gesture in flight, then holds at the next gate
/// until Continue. A gesture already chosen is not sent after that; the next look decides. Stop still works.
/// Nothing it collected is lost.
extension AppModel {
    func pause() {
        guard agent.running, help == nil, !paused else { return }
        paused = true
        DebugLog.write("run: paused from the Live Activity")
        live.update(mood: .listening, step: moveCount, line: String(localized: "Paused. Tap Continue and I'll go on from here."),
                    phase: .paused, status: .paused)
    }

    func unpause() {
        guard paused else { return }
        paused = false
        DebugLog.write("run: continued from the Live Activity")
        live.update(mood: .thinking, step: moveCount, line: String(localized: "Going on from here…"), phase: .running,
                    status: .looking)
    }

    /// The gate's second half: wait while paused, then let the screen settle (the user may have moved on by hand).
    func holdWhilePaused() async throws {
        guard paused, agent.running else { return }
        live.show(.paused, mood: .listening)
        let since = now()
        while paused {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        agent.notePauseInterrupted()  // only a chosen gesture is dropped; a look after Continue still acts
        _ = await feed.fresh(since: since, timeout: 3)
        await feed.settled()
    }
}
