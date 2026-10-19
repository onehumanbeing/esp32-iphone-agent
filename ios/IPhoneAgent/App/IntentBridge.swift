import AppIntents
import Foundation
import WidgetKit

/// Siri, Shortcuts, widgets and controls → the app; and the app's state → the widgets (App Group snapshot).
extension AppModel {
    func handle(_ request: AgentRequest) async -> String {
        DebugLog.write("intent: \(request)")
        switch request {
        case .runTask(let task):
            return await runFromIntent(task, intent: nil)
        case .runSaved(let id):
            let saved = id.flatMap { intents.item($0) } ?? intents.item(widgetSnapshot?.lastIntent) ?? intents.items.first
            guard let saved else { return String(localized: "There are no saved intents yet.") }
            return await runFromIntent(saved.prompt, intent: saved)
        case .status:
            return statusLines.joined(separator: "\n")
        case .calibrate:
            guard MockMode.on || board.connected else { return String(localized: "The board isn't connected.") }
            calibrator.calibrate()
            return String(localized: "Calibrating the pointer…")
        }
    }

    /// Checks what a run needs before starting it from outside the app (no screen to fix things on).
    private func runFromIntent(_ task: String, intent: SavedTask?) async -> String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return String(localized: "The task is empty.") }
        if agent.running { return String(localized: "Already running: \(agent.task)") }
        if !MockMode.on {
            guard settings.isConfigured else { return String(localized: "Set up the model in Settings first.") }
            guard pointer.calibrated else { return String(localized: "Calibrate the pointer in ESP32 Agent first.") }
            guard await waitReady(mirroring: true, timeout: 20) else {
                return String(localized: "The board or Screen Mirroring isn't ready. Connect the board and start Screen Mirroring.")
            }
        }
        await run(task, intent: intent)
        publishWidget()
        if agent.running { return String(localized: "Started: \(task)") }
        return String(localized: "Could not start: \(log.last?.text ?? "")")
    }

    /// Board, mirroring, calibration, model and run, for Siri and the status snippet.
    var statusLines: [String] {
        let s = board.status
        var lines: [String] = []
        if MockMode.on { lines.append(String(localized: "Demo data is on.")) }
        lines.append(board.connected ? String(localized: "Board connected") : String(localized: "Board not connected"))
        lines.append(feed.live || s?.ap == "streaming" ? String(localized: "Screen Mirroring on")
                     : String(localized: "Screen Mirroring off"))
        if pointer.calibrated {
            lines.append(pointer.quality.map { String(localized: "Calibrated, \(CalibrationText.percent($0))") }
                         ?? String(localized: "Calibrated"))
        } else {
            lines.append(String(localized: "Not calibrated"))
        }
        lines.append(settings.isConfigured || MockMode.on
                     ? String(localized: "Model: \(MockMode.on ? "Demo" : settings.currentModel ?? String(localized: "Automatic"))")
                     : String(localized: "Model not set up"))
        lines.append(agent.running ? String(localized: "Running step \(moveCount): \(agent.task)") : String(localized: "Not running"))
        return lines
    }

    var widgetSnapshot: AgentSnapshot? { SharedState.load() }

    /// Writes the snapshot when it changed and reloads the widgets: at once for a new state, at most every
    /// 30 s for a step count alone (background reloads are budgeted).
    func publishWidget() {
        var snap = AgentSnapshot(status: .ready)
        if agent.running {
            snap.status = .running
        } else if !modelReady || !(MockMode.on || pointer.calibrated) || (!MockMode.on && board.pairedID == nil) {
            snap.status = .needsSetup
        } else if !MockMode.on && !board.connected {
            snap.status = .offline
        }
        snap.step = agent.running ? moveCount : 0
        snap.task = agent.running ? agent.task : ""
        snap.intents = intents.items.map { .init(id: $0.id, name: $0.name, prompt: $0.prompt, symbol: $0.symbol) }
        let old = widgetSnapshot
        snap.lastIntent = currentIntent?.id ?? old?.lastIntent
        if let last = runs.runs.first(where: {
            !$0.id.hasPrefix("rec-") && !$0.steps.isEmpty && outcome(for: $0) != .running
        }),
           let step = last.steps.last {
            snap.lastRun = .init(task: last.task, ok: last.outcome == .done,
                                 line: step.action["answer"]?.str ?? step.action["reason"]?.str ?? "", date: last.date)
        }
        snap.demo = MockMode.on
        guard snap != old else { return }
        var quiet = old ?? snap
        quiet.step = snap.step
        let stepOnly = old != nil && quiet == snap
        if stepOnly && now() - lastWidgetReload < 30 { return }
        SharedState.save(snap)
        lastWidgetReload = now()
        WidgetCenter.shared.reloadAllTimelines()
        if old?.intents != snap.intents { AgentShortcuts.updateAppShortcutParameters() }
    }
}
