import AppIntents
import Foundation
import GameController
import UIKit

/// LiveActivityIntent keeps execution in the running agent process without bringing its UI over the editor.
struct GetLocalInputIntent: LiveActivityIntent {
    static let openAppWhenRun = false
    static let title: LocalizedStringResource = "Get Pending Local Input"
    static let description = IntentDescription("Returns the active local input packet to Handsy Local Copy. Contains no text outside that one pending request.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        DebugLog.write("local copy: shortcut requested packet")
        do {
            let packet = try AppModel.shared.localCopy.claim(at: now())
            DebugLog.write("local copy: packet delivered to shortcut")
            return .result(value: packet)
        } catch {
            DebugLog.write("local copy: packet request rejected: \(error.localizedDescription)")
            throw error
        }
    }
}

struct CompleteLocalInputIntent: LiveActivityIntent {
    static let openAppWhenRun = false
    static let title: LocalizedStringResource = "Confirm Local Input Copy"
    static let description = IntentDescription("Confirms the request ID and the exact text read back by the local copy shortcut.")
    @Parameter(title: "Request ID") var requestID: String
    @Parameter(title: "Copied Text") var copiedText: String

    @MainActor func perform() async throws -> some IntentResult {
        do {
            try AppModel.shared.localCopy.acknowledge(id: requestID, text: copiedText, at: now())
            DebugLog.write("local copy: exact copied text acknowledged")
        } catch {
            DebugLog.write("local copy: copy confirmation rejected: \(error.localizedDescription)")
            throw error
        }
        return .result()
    }
}

enum LocalCopyTrigger { case configured, openShortcut }

extension AppModel {
    var localInputIssue: String? {
        // isAssistiveTouchRunning reported false on the test phone while the floating control was visible.
        // Keep that value in diagnostics, but gate host readiness on actual phone input accessories instead.
        LocalCopyPreflight.issue(boardConnected: board.connected, usb: board.status?.usb,
                                 keyboard: GCKeyboard.coalesced != nil, mouse: !GCMouse.mice().isEmpty,
                                 button: LocalCopyConfig.useButton)
    }

    var localInputStatus: String {
        "USB \(board.status?.usb ?? "unknown"), phone keyboard \(GCKeyboard.coalesced != nil), phone mouse \(!GCMouse.mice().isEmpty), AssistiveTouch \(UIAccessibility.isAssistiveTouchRunning)"
    }

    /// One type operation: trigger the configured local shortcut, wait for its real completion, recheck the
    /// original editor, and paste once. Never reopen an app or ask the model to reconstruct the insertion point.
    func typeWithLocalShortcut(_ text: String) async throws -> (field: String, value: String) {
        guard LocalCopyConfig.verified else {
            return ("typed", "nothing typed: finish Settings > Unicode Input: import Handsy Local Copy, bind its trigger and pass Test Copy. Do not retry input until setup is complete.")
        }
        guard appIsBackgrounded, feed.live, !feed.stale, let before = feed.frame else {
            return ("typed", "nothing typed: the destination editor must be visible with a current screen")
        }
        let links = pointer.device.links
        try await runLocalCopy(text)
        let deadline = now() + 4
        var unchanged = false
        while now() < deadline {
            try Task.checkCancellation()
            guard board.connected, pointer.device.links == links, appIsBackgrounded else { break }
            let since = now()
            guard let after = await feed.fresh(since: since, timeout: 0.8), !feed.stale else { continue }
            if await Vision.off({ Vision.similar(before, after) }) { unchanged = true; break }
        }
        guard unchanged, localInputIssue == nil else {
            return ("typed", "nothing pasted: shortcut copied the text, but the original editor did not return unchanged. Inspect the screen and focus before new input; no automatic paste was sent.")
        }
        try Task.checkCancellation()
        agent.markLocalPasteAttempt()  // record before the board reply, including a lost ACK or restart
        try await pointer.key("cmd+v")
        return ("pasted", "local shortcut acknowledged this exact full text; one paste sent in the unchanged editor. Inspect the result and any iOS paste permission request; do not repeat paste or split this text into separate lines.")
    }

    func runLocalCopy(_ text: String, trigger: LocalCopyTrigger = .configured) async throws {
        if trigger == .configured {
            // Read status without sending any HID command. "USB ok" alone can mean connected to a Mac.
            try await board.refreshStatus()
            DebugLog.write("local copy: preflight \(localInputStatus)")
            if let issue = localInputIssue { throw DeviceError(message: issue) }
        } else {
            guard !agent.running, !appIsBackgrounded else {
                throw DeviceError(message: "Open Unicode Input settings before testing the shortcut directly.")
            }
        }
        // First-time Shortcuts permission prompts need time for the user. Runtime input keeps the 20 s lease.
        let timeout = trigger == .openShortcut ? 60.0 : LocalCopySession.timeout
        let id = try localCopy.begin(text, at: now(), timeout: timeout, requiresBoard: trigger == .configured)
        defer { localCopy.cancel(id) }
        var background = UIBackgroundTaskIdentifier.invalid
        if trigger == .openShortcut {
            background = UIApplication.shared.beginBackgroundTask(withName: "Verify Local Copy") { [weak self] in
                Task { @MainActor in self?.localCopy.cancel(id) }
            }
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        DebugLog.write("local copy: began \(trigger == .openShortcut ? "direct shortcut test" : "configured trigger")")
        let links = pointer.device.links
        if trigger == .openShortcut {
            var url = URLComponents()
            url.scheme = "shortcuts"; url.host = "run-shortcut"
            url.queryItems = [URLQueryItem(name: "name", value: LocalCopyConfig.name)]
            guard let target = url.url, await UIApplication.shared.open(target) else {
                throw DeviceError(message: "Could not open Shortcuts. Import Handsy Local Copy on this iPhone first.")
            }
        } else if LocalCopyConfig.useButton {
            let p = LocalCopyConfig.point
            DebugLog.write(String(format: "local copy: long press at %.1f%%, %.1f%%", p.x * 100, p.y * 100))
            try await pointer.point(p.x, p.y, aim: true)
            try await pointer.device.send("press")
            do { try await Task.sleep(for: .milliseconds(900)) }
            catch { _ = try? await pointer.device.send("release"); throw error }
            try await pointer.device.send("release")
        } else { try await pointer.key(LocalCopyConfig.combo) }
        while let pending = localCopy.pending, pending.packet.id == id, now() < pending.expires {
            try Task.checkCancellation()
            if trigger == .configured {
                guard board.connected, pointer.device.links == links, localInputIssue == nil else {
                    throw DeviceError(message: "The phone's input connection changed during local copy; nothing pasted.")
                }
            }
            if localCopy.completed(id, at: now()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let message = localCopy.timeoutMessage
        DebugLog.write("local copy: \(message)")
        throw DeviceError(message: message)
    }
}
