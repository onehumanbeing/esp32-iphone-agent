import Foundation

/// Henry 2026-11-13: long tasks. A task over many items may take up to `longLimit` rounds instead of `maxSteps`;
/// every `saveEvery` moves the run writes what it collected (notebook, plan) into its trace as a `checkpoint` row,
/// so a run resumed from Runs (after the app was closed, or the board was lost) goes on with them instead of an
/// empty notebook.
extension AgentLoop {
    static let longLimit = 1000
    static let saveEvery = 10
    static let checkpointAction = "checkpoint"

    /// The round limit of this run.
    var stepLimit: Int { inventory.needed ? max(maxSteps, Self.longLimit) : maxSteps }

    /// The limit for a task before its run starts (the Live Activity's counter).
    func stepLimit(for task: String) -> Int {
        Inventory(task: task, until: replay.until != nil).needed ? max(maxSteps, Self.longLimit) : maxSteps
    }

    /// A checkpoint row once every `saveEvery` moves, when the notebook has something.
    func saveCheckpoint() {
        let moves = steps.filter { !StepText.notMoves.contains($0["action"]?.str ?? "") }.count
        guard moves > 0, moves % Self.saveEvery == 0, !notebook.isEmpty,
              steps.last?["action"]?.str != Self.checkpointAction,
              let data = try? JSONEncoder().encode(notebook) else { return }
        record(nil, ["action": .str(Self.checkpointAction), "notebook": .str(String(decoding: data, as: UTF8.self)),
                     "moves": .int(moves)])
    }

    /// The notebook of the last checkpoint in `steps` (or an empty one), with the notes made after it: a checkpoint
    /// comes every 10 moves, so a run resumed after a reinstall lost the notes since the last one (2026-11-18).
    static func savedNotebook(_ steps: [JObject]) -> Notebook {
        let at = steps.lastIndex(where: { $0["action"]?.str == checkpointAction })
        var book = at.flatMap { steps[$0]["notebook"]?.str }
            .flatMap { try? JSONDecoder().decode(Notebook.self, from: Data($0.utf8)) } ?? Notebook()
        for s in steps[(at.map { $0 + 1 } ?? 0)...] {
            // notes, and the record reader's lines (2026-11-18: they lived only in "record" rows, lost on Continue)
            let texts = (s["action"]?.str == "note" ? [s["text"]?.str ?? ""] : [])
                + (s["recorded"]?.arr ?? []).compactMap(\.str)
            for text in texts where !text.isEmpty && !book.noted(text) { book.note(text) }
        }
        return book
    }
}
