import Foundation

/// A link that looks up but no longer works: the board stops answering, or mirroring stops sending frames while
/// the app still shows the last one. Every action then "changes nothing" and the model keeps acting on a picture
/// that no longer moves. After `rounds` rounds in a row that left the screen practically unchanged (the step's
/// `changed`, any action), the loop checks the link before asking the model again: the board answers a ping and a
/// frame captured from now on arrives. A failed check ends the run with what to check; a passing one changes
/// nothing (the stall limit, the touch check and the model's own loop handling go on as before).
enum LinkCheck {
    /// Unchanged rounds in a row before each check.
    static let rounds = 3

    /// Due after this many unchanged rounds in a row (every `rounds`, so a streak is checked again as it grows).
    static func due(_ unchanged: Int) -> Bool { unchanged > 0 && unchanged % rounds == 0 }

    enum Failure: Equatable { case board, frames }

    /// nil = the link works (or the fakes can't tell). Only for a screen that still counts as live: a known loss
    /// (no board, no mirroring) is the recovery's (AgentLoop.waitForScreen), which waits and asks the user.
    @MainActor static func check(_ device: HIDDevice?, _ screen: ScreenSource?) async -> Failure? {
        guard let device, let screen, screen.live else { return nil }
        do { try await device.send("ping") } catch { return Task.isCancelled ? nil : .board }
        guard await screen.freshFrame() != false || Task.isCancelled else { return .frames }
        return nil
    }

    /// The fail step's reason, shown to the user (and the run's end).
    static var reason: String {
        String(localized: "The iPhone screen or the board stopped responding. Check that the board has power and Screen Mirroring is on, then start again.")
    }
}

extension AgentLoop {
    /// LinkCheck after a round; throws (ending the run) when the board or the mirrored screen stopped responding.
    func checkLink(unchanged: Int) async throws {
        guard LinkCheck.due(unchanged) else { return }
        try await gate?()
        let failure = await LinkCheck.check(phone?.device, screen)
        try Task.checkCancellation()
        DebugLog.write("link check: \(unchanged) rounds changed nothing; "
                       + (failure.map { $0 == .board ? "the board did not answer" : "no fresh frame arrived" } ?? "board and frames fine"))
        if failure != nil { throw BlindError(reason: LinkCheck.reason) }
    }
}
