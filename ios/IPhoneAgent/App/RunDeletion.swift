import Foundation

extension AppModel {
    func canDeleteRun(_ run: Run) -> Bool {
        !startingAgent && !(agent.running && run.id == runID)
    }

    /// Remove the recording first; a disk failure must leave its visible state intact.
    func deleteRun(_ run: Run) throws {
        guard canDeleteRun(run) else {
            throw DeviceError(message: String(localized: "Stop the run before deleting it."))
        }
        try runs.delete(run)
        intents.forget(run: run.id)
        if review?.runID == run.id { review = nil }
        live.dismiss(runID: run.id)
        if run.id == runID {
            try agent.clear()
            lastTask = ""
            currentIntent = nil
            if !recorder.recording && !recorder.inferring {
                moodReset?.cancel()
                runMood = nil
            }
        }
        publishWidget()
    }
}

extension AppModel {
    /// The runs "Delete All Runs" / "Delete Failed Runs" remove: each one a swipe could delete, so never the run in
    /// progress. Imported runs have no outcome of their own, so "failed" leaves them.
    static func bulkDeletable(_ runs: [Run], failedOnly: Bool, canDelete: (Run) -> Bool) -> [Run] {
        runs.filter { canDelete($0) && (!failedOnly || (!$0.imported && $0.outcome == .failed)) }
    }

    /// Deletes them through `deleteRun`, every run on disk (the list shows only the newest 30), then reloads the list.
    func deleteRuns(failedOnly: Bool) throws {
        defer { runs.reload() }
        runs.reload(limit: .max)
        for run in Self.bulkDeletable(runs.runs, failedOnly: failedOnly, canDelete: canDeleteRun) { try deleteRun(run) }
    }
}
