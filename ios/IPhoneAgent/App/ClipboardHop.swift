import UIKit

/// The agent's `write`: iOS ignores clipboard writes from a background app (Pointer.type), so the agent opens this
/// app through Spotlight, `holdWhileInFront` writes the text while the app is in front and sends it home again,
/// and the actor then pastes with cmd+v in the target app. A keyboard paste needs no "Allow Paste" prompt.
extension AppModel {
    func putOnClipboard(_ text: String) async throws -> Bool {
        pendingClipboard = text
        clipboardWritten = false
        defer { pendingClipboard = nil }
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "ESP32 Agent"
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
