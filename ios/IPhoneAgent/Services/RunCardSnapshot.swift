import Foundation

/// Home uses live progress during a run and one stored run for every part of the last-run card.
struct RunCardSnapshot {
    let task: String
    let lastStep: JObject?
    let moveCount: Int
    let frame: Data?
    let cover: URL?
    let storedRun: Run?

    static func select(running: Bool, liveTask: String, liveSteps: [JObject], liveFrame: Data?,
                       storedRun: Run?) -> Self? {
        if running {
            return Self(task: liveTask, lastStep: liveSteps.last,
                        moveCount: liveSteps.filter { !StepText.notMoves.contains($0["action"]?.str ?? "") }.count,
                        frame: liveFrame, cover: nil, storedRun: nil)
        }
        guard let storedRun else { return nil }
        return Self(task: storedRun.task, lastStep: storedRun.steps.last?.action, moveCount: storedRun.moves.count,
                    frame: nil, cover: storedRun.cover, storedRun: storedRun)
    }
}
