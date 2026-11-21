import UIKit
import UniformTypeIdentifiers

/// The agent's `write` (and a Japanese/Korean `type`, AgentLoop.pasteInstead; a Chinese one uses ClipboardCarry):
/// iOS ignores clipboard writes from a background app (Pointer.type), so the agent opens this
/// app through Spotlight, `holdWhileInFront` writes the text while the app is in front and sends it home again,
/// and the actor then pastes with cmd+v in the target app. A keyboard paste needs no "Allow Paste" prompt.
extension AppModel {
    func putOnClipboard(_ text: String) async throws -> Bool {
        pendingClipboard = text
        clipboardWritten = false
        defer { pendingClipboard = nil }
        let name = AppName.current
        try await pointer.goHome()
        try await Task.sleep(for: .milliseconds(800))
        try await pointer.swipe(0.5, 0.35, 0.5, 0.6, hold: false)  // Spotlight from the middle of the Home Screen
        try await Task.sleep(for: .milliseconds(900))
        try await pointer.type(name)
        try await Task.sleep(for: .milliseconds(900))
        resumeAsked = now()  // the agent opens the app itself: the gate sends it away again at once
        try await pointer.key("enter")
        let deadline = now() + 6
        while appIsBackgrounded && now() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        guard !appIsBackgrounded else {
            DebugLog.write("clipboard: Spotlight did not open the app")
            return false
        }
        resumeAsked = now()
        try await holdWhileInFront()
        return clipboardWritten
    }
}

extension AppModel {
    /// At a run's start, while this app is still in front: the Chinese text the run will likely type goes on the
    /// clipboard once (ClipboardCarry.pick), for the paste when pinyin stops part way. Nothing to carry: the
    /// clipboard is left as it is.
    /// Synchronous, from what is in hand (recorded steps, the cached plan, the prompt): never waits for the planner.
    func carryClipboard(_ task: String, inFront: Bool) {
        let t0 = now()
        agent.carried = nil
        let typed = agent.replay.steps.compactMap { $0.action["action"]?.str == "type" ? $0.action["text"]?.str : nil }
        guard inFront, !appIsBackgrounded,
              let pick = ClipboardCarry.pick(task: task, plan: agent.cachedPlan, typed: typed) else {
            DebugLog.write("clipboard: nothing to carry")
            return
        }
        let expires = Self.writeLocalClipboard(pick.text)
        agent.carried = ClipboardCarry(text: pick.text, changeCount: UIPasteboard.general.changeCount, source: pick.source,
                                       expires: expires)
        DebugLog.write(String(format: "clipboard: carried %d chars from %@ at start in %.0f ms", pick.text.count, pick.source, (now() - t0) * 1000))
    }

    /// The agent's clipboard writes stay on this iPhone and expire (ClipboardCarry.lifetime): Universal Clipboard
    /// sent the carried text to the user's Mac, which played its paste sound (Henry 2026-11-20).
    @discardableResult
    static func writeLocalClipboard(_ text: String) -> Date {
        let expires = Date().addingTimeInterval(ClipboardCarry.lifetime)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: expires])
        return expires
    }
}
