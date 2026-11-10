import Foundation

/// Typing and keys through the board's keyboard: text, key combos and the Home key.
extension Pointer {
    /// The board types printable ASCII (one key per character). Chinese goes in as toneless pinyin through
    /// the pinyin keyboard, word by word, each committed and read back (HanTyper); accented Latin letters
    /// through Option keys (Accents); emoji are dropped. Other scripts (kana, Hangul, Cyrillic …) are not typed at
    /// all: the agent pastes them (Scripts, AgentLoop.pasteInstead). The clipboard is no route from here: iOS
    /// refuses a background app's write (a Mac's Universal Clipboard text got pasted instead, 2026-10-20).
    /// Returns nil when all went in, else a note for the model (what did not, and what is left).
    @discardableResult
    func type(_ text: String) async throws -> String? {
        if Scripts.needsPaste(text) { return "nothing typed: the board cannot type this script; \"\(text)\" is left" }
        let han = HanTyper.isHan(text)
        let typed = han ? Self.typeable(text) : Accents.plan(text).typed
        if typed != text { DebugLog.write("type: \(text.count) chars as \"\(typed)\"") }
        guard !typed.isEmpty else { throw DeviceError(message: "nothing typeable in that text (the board types ASCII and accented Latin letters)") }
        let layout = try await matchKeyboard(pinyin: han)
        let typer = HanTyper(send: { [self] in _ = try await device.send("type \($0)") }, key: { [self] in try await key($0) },
                             toggle: { [self] in try await toggleKeyboard() }, look: { [weak self] in
            guard let screen = self?.screen, screen.live else { return nil }
            await screen.settled(quiet: 0.3, least: 0.5, most: 2.0)
            guard let image = screen.frame.flatMap(Vision.image) else { return nil }
            return HanTyper.Seen(words: await UITreeOCR.lines(image, cells: true), height: image.height)
        })
        // English text only needs the check that its letters did not stay pinyin when the keyboard was not seen
        let note = try await typer.type(text, checkLetters: han || layout == .none)
        if let note { log("type: \(note)") }
        return note
    }

    /// English text on a pinyin keyboard comes out as unconfirmed pinyin, and Chinese on an English one as plain
    /// letters; models rarely notice (2026-11-03 runs). Read the keyboard off the screen and switch (ctrl+space).
    /// The layout it ended on (.none: no keyboard on screen, as with the board as a hardware keyboard: HanTyper
    /// then tells the layouts apart by whether typed letters bring up candidates).
    @discardableResult
    private func matchKeyboard(pinyin: Bool) async throws -> KeyboardLayout {
        guard let screen, screen.live else { return .none }
        var layout = KeyboardLayout.none
        for _ in 0..<2 {
            guard let frame = screen.frame else { return .none }
            layout = await KeyboardLayout.read(frame)
            if layout == .none || (layout == .pinyin) == pinyin { return layout }
            log("type: the keyboard is \(layout == .pinyin ? "pinyin" : "English"); switching")
            try await toggleKeyboard()
        }
        return layout == .none || (layout == .pinyin) == pinyin ? layout : .none
    }

    /// ctrl+space (pinyin <-> English), waited for until the screen shows it.
    private func toggleKeyboard() async throws {
        let sent = now()
        try await key("ctrl+space")
        guard let screen, screen.live else { return }
        _ = await screen.fresh(since: sent, timeout: 1.5)
        await screen.settled(quiet: 0.2, least: 0.4, most: 1.5)
    }

    /// "卫生纸 3卷" → "weishengzhi 3juan": Han characters to joined pinyin, accents folded, the rest dropped.
    /// `trim` false keeps spaces at the ends (a piece of a longer text).
    nonisolated static func typeable(_ text: String, trim: Bool = true) -> String {
        guard !text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else { return text }
        var out = ""
        for ch in text {
            let s = String(ch)
            let isHan = s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
            let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s)
                .applyingTransform(.stripDiacritics, reverse: false) ?? s
            let kept = String(String.UnicodeScalarView(latin.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }))
            if isHan { out += kept.replacingOccurrences(of: " ", with: "") } else { out += kept }
        }
        return trim ? out.trimmingCharacters(in: .whitespaces) : out
    }
    /// Models write "delete" for the Mac's backspace key; the board knows it as "backspace" (2026-11-02 log).
    func key(_ combo: String) async throws {
        let keys = combo.split(separator: "+").map { $0 == "delete" ? "backspace" : String($0) }
        try await device.send("key \(keys.joined(separator: "+"))")
    }
    /// The board's consumer-control Home key ("AC Home"), which iOS treats like a keyboard's home key. Boards
    /// without it (older firmware) answer an error: then Cmd+H and the flick up from the home bar (a flick, not
    /// a rest: resting opens the app switcher). An acknowledged key that left the screen as it was gets the flick
    /// too: a contacts-sharing sheet and Calendar stayed through a dozen "homescreen → ok" (2026-11-03).
    /// Leaving an app is a big change; a small one (a clock ticking, a caret) may be UI noise while the key did not
    /// take effect. `again`: the previous step was Home too and changed little, so flick even after a small change
    /// (only then: on the Home Screen the flick would open the App Switcher).
    ///
    /// The check looks at the first frame captured after the key, then at the screen once it was still for a moment
    /// (2026-11-11: it waited for a 0.3 s still screen after at least 0.6 s, up to 2 s; with an app that kept moving
    /// that was 2.2 s before the flick). Leaving an app shows as a big change in the first frames already.
    func goHome(again: Bool = false) async throws {
        let before = screen?.live == true ? screen?.frame : nil
        let sent = now()
        do {
            try await device.send("homescreen")
        } catch let error as DeviceError where error.message.hasPrefix("err ") {
            // 开发板明确拒绝时可尝试旧固件的快捷键，回执超时则交给上层重新观察。
            try await key("cmd+h")
            try await Task.sleep(nanoseconds: 350_000_000)
            return try await homeSwipe()
        }
        guard let screen, let before else { return }
        if let first = await screen.fresh(since: sent, timeout: 1.0), await Vision.off({ Vision.bigChange(before, first) }) { return }
        await screen.settled(quiet: 0.2, least: 0.3, most: 1.0)
        let after = screen.frame
        if await Vision.off({ Vision.bigChange(before, after) }) { return }
        if !again, await Vision.off({ Vision.changed(before, after) }) { return }
        log(again ? "home: the Home key again changed little; flicking up from the home bar"
                  : "home: the Home key left the screen unchanged; flicking up from the home bar")
        try await homeSwipe()
    }
}
