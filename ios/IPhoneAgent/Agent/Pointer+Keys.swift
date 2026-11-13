import CoreGraphics
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
        guard let screen, screen.live, var frame = screen.frame else { return .none }
        var layout = await KeyboardLayout.read(frame)
        // the keyboard often isn't in the frame yet right after a key opened the field (Spotlight's cmd+space):
        // 2026-11-11 two "Google Maps" went into pinyin unseen before the third try saw it. Look once more.
        if layout == .none {
            await screen.settled(quiet: 0.2, least: 0.3, most: 1.0)
            if let later = screen.frame { frame = later; layout = await KeyboardLayout.read(frame) }
        }
        // ctrl+space cycles every keyboard the phone has (English, 拼音, emoji …). Each press is followed until the
        // screen shows a different keyboard; one that shows no change ends it. iddzz 2026-11-12: the second read
        // came before the switch showed, a second press went on past 拼音 to emoji, and "智能椅" never went in.
        for _ in 0..<3 {
            if layout == .none || (layout == .pinyin) == pinyin { return layout }
            log("type: the keyboard is \(layout == .pinyin ? "pinyin" : "English"); switching")
            let before = layout
            try await toggleKeyboard()
            layout = await changedLayout(from: before)
            if layout == before {
                log("type: the keyboard still reads \(before == .pinyin ? "pinyin" : "English") after ctrl+space; not pressing again")
                return .none
            }
            if layout == .none {  // emoji or another keyboard with no 123 key: one more press goes on round
                log("type: ctrl+space showed another keyboard (emoji?); switching on")
                try await toggleKeyboard()
                layout = await changedLayout(from: .none)
            }
        }
        return layout == .none || (layout == .pinyin) == pinyin ? layout : .none
    }

    /// The keyboard read until it differs from `before`, for up to 2.5 s (the switch animates).
    private func changedLayout(from before: KeyboardLayout) async -> KeyboardLayout {
        guard let screen else { return .none }
        let until = Date().addingTimeInterval(2.5)
        var layout = before
        repeat {
            if let frame = screen.frame { layout = await KeyboardLayout.read(frame) }
            if layout != before { return layout }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < until
        return layout
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
        // An absolute mouse (#99): iOS ignored AC Home there, and an animated screen (Weather) looked like it worked.
        if absolute { return try await homeSwipe() }
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
        let changed = await Vision.off { Vision.changed(before, after) }
        // A small change can be the app moving by itself (an animated sheet) while the key did nothing: the step's
        // verdict, which ignores what moves by itself, then reads "did NOT change" and no flick went out. The same
        // app's words still on screen, and not the Home Screen (its Search pill), say the key missed.
        let stayed = !again && changed ? await Self.keyMissed(before, after) : false
        guard Self.needsFlick(changed: changed, again: again, stayed: stayed) else { return }
        log(again ? "home: the Home key again changed little; flicking up from the home bar"
                  : stayed ? "home: the Home key left the app's words on screen; flicking up from the home bar"
                  : "home: the Home key left the screen unchanged; flicking up from the home bar")
        try await homeSwipe()
        // 2026-11-13: in Messages the flick scrolled the list instead (the press landed on the app, not the home
        // bar). Still the same app's words on screen: once more at full speed, and the outcome goes in the log.
        await screen.settled(quiet: 0.2, least: 0.3, most: 1.0)
        guard await Self.sameApp(before, screen.frame) else { return log("home: the flick left the app") }
        log("home: the flick left the app's words on screen (scrolled it?); once more at full speed")
        try await homeSwipe(full: true)
        await screen.settled(quiet: 0.2, least: 0.3, most: 1.0)
        log(await Self.sameApp(before, screen.frame) ? "home: still in the app after two flicks" : "home: the second flick left the app")
    }

    /// The Home Screen's Search button (the low "Search" / "搜索" label), tapped precisely; false = not on screen.
    func tapSearchButton() async throws -> Bool {
        guard let screen, screen.live, let jpeg = screen.frame, let image = Vision.image(jpeg) else { return false }
        guard let box = SearchPill.label(await UITreeOCR.lines(image), size: CGSize(width: image.width, height: image.height)) else {
            log("open: cmd+space brought nothing up and no Search button is on screen")
            return false
        }
        log("open: cmd+space brought nothing up; tapping the Search button")
        try await tap(Double(box.midX), Double(box.midY), aim: true)
        return true
    }

    /// After the Home key: flick up from the home bar? Not after a big change (handled before). `changed`: the
    /// screen changed at all; `again`: the previous step was Home too; `stayed`: the change was small and the
    /// app's words are still there, not on the Home Screen (`keyMissed`).
    nonisolated static func needsFlick(changed: Bool, again: Bool, stayed: Bool) -> Bool {
        again || !changed || stayed
    }

    /// The Home key left the app in front: most of its words are still there, and `before` was not the Home Screen
    /// (where the key changes nothing and a flick could open the App Switcher).
    static func keyMissed(_ before: Data?, _ after: Data?) async -> Bool {
        guard let before, let image = Vision.image(before) else { return false }
        let lines = await UITreeOCR.lines(image)
        guard SearchPill.label(lines, size: CGSize(width: image.width, height: image.height)) == nil else { return false }
        return await sameApp(before, after)
    }

    /// Most of the text on `before` is still on `after`: the same app (scrolled, perhaps), not the Home Screen.
    static func sameApp(_ before: Data?, _ after: Data?) async -> Bool {
        func words(_ jpeg: Data?) async -> Set<String> {
            guard let jpeg, let image = Vision.image(jpeg) else { return [] }
            return Set(await UITreeOCR.lines(image).map(\.text).filter { $0.count >= 4 })
        }
        let a = await words(before), b = await words(after)
        guard a.count >= 3 else { return false }
        return Double(a.intersection(b).count) / Double(a.count) >= 0.4
    }
}

/// The Home Screen's Search pill, found by its label ("Search" / "搜索") low on the screen.
enum SearchPill {
    /// The label's box in screen fractions; nil = no pill on these OCR lines of a frame of `size` pixels.
    static func label(_ lines: [(text: String, box: [Int])], size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let hit = lines.first { line in
            let text = line.text.trimmingCharacters(in: CharacterSet(charactersIn: "Q. ")).lowercased()
            return (text == "search" || text == "搜索") && Double(line.box[1]) / size.height > 0.6
        }
        guard let b = hit?.box else { return nil }
        let w = Double(size.width), h = Double(size.height)
        return CGRect(x: Double(b[0]) / w, y: Double(b[1]) / h, width: Double(b[2] - b[0]) / w, height: Double(b[3] - b[1]) / h)
    }

    /// `p` (screen fractions) is on the pill: its label, widened by the pill's icon and padding.
    static func covers(_ label: CGRect, _ p: CGPoint) -> Bool {
        label.insetBy(dx: -0.08, dy: -0.02).contains(p)
    }

    /// A tap at `p` hit the pill on `jpeg`.
    @MainActor static func tapped(_ jpeg: Data?, at p: CGPoint) async -> Bool {
        guard let jpeg, let image = Vision.image(jpeg) else { return false }
        let size = CGSize(width: image.width, height: image.height)
        return label(await UITreeOCR.lines(image), size: size).map { covers($0, p) } ?? false
    }
}
