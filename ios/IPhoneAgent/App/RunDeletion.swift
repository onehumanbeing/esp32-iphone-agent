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
