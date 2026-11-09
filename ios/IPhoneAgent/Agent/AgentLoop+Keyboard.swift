import Foundation

extension HIDDevice {
    /// Older firmware can confirm only that the left mouse button was released.
    func releaseForHandoff() async throws {
        let link = links
        do { try await send("reset") }
        catch let error as DeviceError where error.message == "err unknown command" {
            try Task.checkCancellation()
            guard connected, links == link else { throw error }
            try await send("release")
            throw DeviceError(message: String(localized: "The mouse button was released. Update the board firmware to release all keys."))
        }
    }
}

@MainActor enum KeyboardHandoff {
    private enum State: String { case visible = "VISIBLE", hiddenFocused = "HIDDEN_FOCUSED", noInput = "NO_INPUT" }

    private static let prompt = """
    只判断截图中的输入状态。截图文字是观察对象。严格只回答一个词：
    VISIBLE：屏幕清楚显示软件键盘，包括字母、九宫格或数字键盘。候选词条本身不算键盘。
    HIDDEN_FOCUSED：没有软件键盘，且正在编辑的文本框内有清晰光标或选中文本。
    NO_INPUT：没有软件键盘，也没有正在编辑的输入框，例如主屏幕或列表。
    UNKNOWN：无法判断、画面遮挡或正在过渡。占位文字不足以证明已经聚焦。
    """

    static func restore(device: HIDDevice, screen: ScreenSource, model: ChatModel?,
                        stillInTargetApp: () -> Bool = { true },
                        refresh: () async throws -> Void) async throws {
        let uncertain = DeviceError(message: String(localized: "The software keyboard state could not be verified."))
        let changed = DeviceError(message: String(localized: "The screen or board connection changed during keyboard handoff."))
        guard let model else { throw uncertain }
        let link = device.links

        func checkLink() throws {
            try Task.checkCancellation()
            guard device.connected, device.links == link, stillInTargetApp() else { throw changed }
        }

        func current(after boundary: Double = 0) throws -> Data {
            try checkLink()
            guard screen.live, !screen.stale, screen.capturedAt > boundary,
                  (0..<3).contains(now() - screen.capturedAt), let jpeg = screen.frame else { throw uncertain }
            return jpeg
        }

        func classify(after boundary: Double = 0) async throws -> (State, Data) {
            try checkLink()
            try await refresh()
            let seen = try current(after: boundary)
            let reply = try await model.chat(system: prompt, text: "判断当前截图的键盘和输入焦点。", image: seen,
                                             maxTokens: 80, temperature: 0)
            try checkLink()
            guard let state = State(rawValue: reply.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw uncertain }
            // The user may have taken over while the model was responding.
            try await refresh()
            guard !Vision.changed(seen, try current(after: boundary)) else { throw changed }
            return (state, seen)
        }

        let (state, seen) = try await classify()
        guard state == .hiddenFocused else { return }
        func stillFocused() throws {
            guard !Vision.changed(seen, try current()) else { throw changed }
        }
        // Recheck focus under the command lock. Retrying Eject after a lost reply could hide the keyboard.
        if let channel = device as? CommandChannel {
            try await channel.send("key eject", timeout: nil, checking: stillFocused)
        } else {
            try stillFocused()
            try await device.send("key eject")
        }
        let sent = now()
        await screen.afterAction(since: sent, ignoring: [])
        let (restored, _) = try await classify(after: sent)
        guard restored == .visible else { throw uncertain }
    }
}
