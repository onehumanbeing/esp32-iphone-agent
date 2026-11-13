import Foundation

/// Pause from the Dynamic Island, at the gesture gate: a gesture chosen before the pause is not sent after it.
extension AgentLoop {
    /// The gate in front of a gesture already chosen. True = the person paused there, so do not send it.
    func pausedBeforeGesture() async throws -> Bool {
        droppingChosenGesture = true
        defer {
            droppingChosenGesture = false
            chosenGestureDropped = false
        }
        try await gate?()
        return chosenGestureDropped
    }

    /// The pause hold waited. Counts only in front of a chosen gesture, not during a look.
    func notePauseInterrupted() {
        if droppingChosenGesture { chosenGestureDropped = true }
    }
}
