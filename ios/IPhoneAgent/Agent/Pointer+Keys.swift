import CoreGraphics
import Foundation
import UIKit

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
        try await typeStop(text)?.note
    }

    /// `type`, with what is left to paste when the pinyin keyboard could not give a word (HanTyper.Stop.rest).
    func typeStop(_ text: String) async throws -> HanTyper.Stop? {
        if Scripts.needsPaste(text) { return .init(note: "nothing typed: the board cannot type this script; \"\(text)\" is left") }
        let han = HanTyper.isHan(text)
        let typed = han ? Self.typeable(text) : Accents.plan(text).typed
        if typed != text { DebugLog.write("type: \(text.count) chars as \"\(typed)\"") }
        guard !typed.isEmpty else { throw DeviceError(message: "nothing typeable in that text (the board types ASCII and accented Latin letters)") }
        // Chinese: HanTyper tells the keyboard from the field after the first word's space. The on-screen keyboard
        // is hidden with the board as a hardware keyboard: it read "English" every time, and ctrl+space on the
        // pinyin keyboard switched it to English (2026-11-20, 5–6 s lost per type)
        let layout = han ? .none : try await matchKeyboard(pinyin: false)
        let typer = HanTyper(send: { [self] in _ = try await device.send("type \($0)") }, key: { [self] in try await key($0) },
                             toggle: { [self] in try await toggleKeyboard() }, look: { [weak self] in
            guard let screen = self?.screen, screen.live else { return nil }
            await screen.settled(quiet: 0.3, least: 0.5, most: 2.0)
            guard let image = screen.frame.flatMap(Vision.image) else { return nil }
            return HanTyper.Seen(words: await UITreeOCR.lines(image, cells: true), height: image.height)
        })
        // English text only needs the check that its letters did not stay pinyin when the keyboard was not seen
        let stop = try await typer.attempt(text, checkLetters: han || layout == .none)
        if let stop { log("type: \(stop.note)") }
        return stop
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
        var pressedAgain = false
        for _ in 0..<3 {
            if layout == .none || (layout == .pinyin) == pinyin { return layout }
            log("type: the keyboard is \(layout == .pinyin ? "pinyin" : "English"); switching")
            let before = layout
            try await toggleKeyboard()
            layout = await changedLayout(from: before)
            // iPad: the first ctrl+space right after Spotlight opened did nothing, the next one switched (2026-11-17
            // trace); it reads its keyboard reliably (KeyboardLayout.padLayout), so one more press is safe there
            if layout == before && DeviceKind.isPad && !pressedAgain {
                pressedAgain = true
                log("type: the keyboard still reads \(before == .pinyin ? "pinyin" : "English") after ctrl+space; once more (iPad)")
                try await toggleKeyboard()
                layout = await changedLayout(from: before)
            }
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

    /// The keyboard read until it differs from `before`, for up to 3.5 s (the switch animates). A frame with no
    /// keyboard to read is not taken as "another keyboard" until the window ends: 2026-11-17 a frame caught
    /// mid-switch read as none, was taken for emoji, and one more ctrl+space went on round to emoji.
    private func changedLayout(from before: KeyboardLayout) async -> KeyboardLayout {
        guard let screen else { return .none }
        let until = Date().addingTimeInterval(3.5)
        var layout = before
        repeat {
            if let frame = screen.frame { layout = await KeyboardLayout.read(frame) }
            if layout != before && (layout != .none || before == .none) { return layout }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < until
        return layout
    }

    /// ctrl+space (pinyin <-> English), waited for until the screen shows it. Frames are looked at from when the
    /// board answered, not from when the key was sent: on a slow link (2026-11-17: 1.6 s to answer) frames from
    /// before the switch arrived in between and read as "still pinyin".
    private func toggleKeyboard() async throws {
        try await key("ctrl+space")
        let done = now()
        guard let screen, screen.live else { return }
        _ = await screen.fresh(since: done, timeout: 2.0)
        await screen.settled(quiet: 0.2, least: 0.4, most: 1.5)
    }

    /// "卫生纸 3卷" → "weishengzhi 3juan", "西岸" → "xi'an": Han characters to joined pinyin, accents folded, the rest dropped.
    /// `trim` false keeps spaces at the ends (a piece of a longer text).
    nonisolated static func typeable(_ text: String, trim: Bool = true) -> String {
        guard !text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else { return text }
        var out = ""
        var prevHan = false
        for ch in text {
            let s = String(ch)
            let isHan = s.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) || (0x3400...0x4dbf).contains($0.value) }
            let latin = (s.applyingTransform(.toLatin, reverse: false) ?? s)
                .applyingTransform(.stripDiacritics, reverse: false) ?? s
            let kept = String(String.UnicodeScalarView(latin.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }))
            if isHan {
                let syllable = kept.replacingOccurrences(of: " ", with: "")
                // xi'an, not xian: a syllable starting with a vowel after another Han syllable gets the pinyin
                // keyboard's separator, else 西岸 reads as xian (先, 现) and the word is never among the candidates
                // (2026-11-20, 上海西岸艺术中心 stopped at 西 in every run)
                if prevHan, let first = syllable.first, "aeo".contains(first) { out += "'" }
                out += syllable
            } else { out += kept }
            prevHan = isHan
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
    func homeKey() async throws {
        if absolute || swipeHome { return try await homeSwipe() }
        if (try? await device.send("homescreen")) == nil { try await key("cmd+h") }
    }

    func goHome(again: Bool = false) async throws {
        if AssistiveButton.oldIPhone, try await assistiveHome() { return }
        // An absolute mouse (#99): iOS ignored AC Home there, and an animated screen (Weather) looked like it worked.
        // A Bluetooth HID board: iOS ignores AC Home over Bluetooth too (2026-11-19).
        if absolute || swipeHome { return try await homeSwipe() }
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
        let stayed = !again && changed && !overlayStays ? await Self.keyMissed(before, after) : false
        guard Self.needsFlick(changed: changed, again: again, stayed: stayed) else { return }
        log(again ? "home: the Home key again changed little; flicking up from the home bar"
                  : stayed ? "home: the Home key left the app's words on screen; flicking up from the home bar"
                  : "home: the Home key left the screen unchanged; flicking up from the home bar")
        try await homeSwipe()
        if overlayStays { return }  // its words never leave: no second flick
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
            // iPad: no Search pill on its Home Screen, but a swipe down in its middle opens Spotlight. cmd+space did
            // nothing for a whole run on an iPad Air M3 (2026-11-17: both tries, then the model tapped the icon)
            if DeviceKind.isPad {
                log("open: cmd+space brought nothing up; swiping down on the Home Screen (iPad)")
                try await swipe(0.5, 0.3, 0.5, 0.55, hold: false)
                return true
            }
            log("open: cmd+space brought nothing up and no Search button is on screen")
            return false
        }
        log("open: cmd+space brought nothing up this time; tapping the Search button")
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

// MARK: - Home through the AssistiveTouch menu (iPhones on iOS 16 and older)

extension Pointer {
    /// Opens the AssistiveTouch menu and taps its Home. false: no button on screen, or no Home in the menu (closed
    /// again). iPhone X on iOS 16.7 (2026-11-22): five home-bar strokes from the board's mouse, none went Home; the
    /// menu's Home did at once. A mouse on an iPhone needs AssistiveTouch, so its button is on screen.
    func assistiveHome() async throws -> Bool {
        guard let screen else { return false }
        // 2026-11-22: the run left the app before the first frame came (the stream was frozen), found no button and
        // fell back to the home-bar flick, which never works here. Wait for a frame; else the last spot it was seen at.
        if !screen.live || screen.frame == nil { _ = await screen.fresh(since: now() - 1, timeout: 6) }
        var spot: CGPoint?
        let looked = now()
        if screen.live, let jpeg = screen.frame {
            spot = await Vision.off({ Vision.image(jpeg).flatMap(AssistiveButton.find) })
        }
        if let spot { AssistiveButton.lastSpot = spot }
        guard let spot = spot ?? AssistiveButton.lastSpot else {
            log("home: no AssistiveTouch button found on screen")
            return false
        }
        try await tap(Double(spot.x), Double(spot.y))
        // AirPlay leaves the menu out of the mirrored screen (2026-11-22: no new frame for 17 s after it opened), so
        // its Home is where iOS puts it: the menu centred on the button, kept on screen.
        let home = AssistiveButton.homeSpot(button: spot, screen: await MainActor.run { UIScreen.main.bounds.size })
        try await Task.sleep(nanoseconds: 400_000_000)  // the menu opens with an animation
        try await tap(Double(home.x), Double(home.y))
        log(String(format: "home: AssistiveTouch (%.2f, %.2f, found in %.0f ms) › Home (%.2f, %.2f)", spot.x, spot.y,
                   (now() - looked) * 1000, home.x, home.y))
        return true
    }
}

/// The AssistiveTouch button, found with no model (Henry 2026-11-22: the user drags it anywhere, and it fades when
/// idle): normalised cross-correlation with a 31×31 picture of it at 150 px across the screen, at three sizes. It does
/// not care about brightness or contrast, so the faded button matches like the solid one. On iPhone X screenshots the
/// button scored 0.88-1.0 (faded on light apps, solid, over a Home Screen icon, at the top and bottom edge), the best
/// other spot 0.52 (a round play button scored highest with the earlier ring test). Only spots at an edge count.
enum AssistiveButton {
    /// iPhones on iOS 16 and older go Home this way; newer ones and iPads keep the home-bar flick.
    @MainActor static var oldIPhone: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 17 && UIDevice.current.userInterfaceIdiom == .phone
    }
    /// Where the button was last seen: it stays put unless the user drags it.
    @MainActor static var lastSpot: CGPoint?
    static let width = 150
    static let minScore: Float = 0.7
    static let size = 31
    /// The solid button, 31×31 gray bytes (base64) cut from an iPhone X screenshot scaled to 150 px across.
    static let templateBase64 = "///////////////////////////////////////////////////////////////////////////////////////////////////9"
        + "9u7r7/j+/////////////////////////////uu7hF9OSVBljsby////////////////////////8KhTLiYmJiYmJicyYbr3////"
        + "///////////////+22stJiYmJicoJyYmJiYygun/////////////////1FMmJiYrOEhRU1BFNSkmJilq5v//////////////4lgm"
        + "JSc5VmNpbm9taGFRNCYlJ3Pw////////////93wnJShEYW2AjI+Qj4p8al48JiUrnf3//////////8EzJSZBY3WNl7HL08erlIpw"
        + "XzklJUPc//////////hwJSUzX3OPpuH8////+dadjG1ZLSUnlP7////////cPSUnTWmKo+z////////+35mEZkIlJVXw////////"
        + "tiolLl13k9b///////////3DkHBWKSU21f///////5QlJThkhKD0////////////55d8Xy8lKrr///////6CJSU+Z4mt/P//////"
        + "//////SfgmI0JSer///////+gSUlPmeJrv3////////////1oIJiNCUnqv///////5ElJTlkhaL2////////////6ph9XzAlKrf/"
        + "//////+wKSUvX3qU3P///////////sqRcVgqJTTR////////1zklJ1BrjKny/////////+edh2dGJSVP7P////////VmJSU3YXeQ"
        + "r+v+/////eKkjnBcLyUmiv3/////////ti8lJ0dleo+dv9ng1biYjXRiPSYlPNT///////////NtJiUpSmNxhY6Sk5GNgm1hQicl"
        + "KY77////////////10olJSlAW2ZscnVya2RXOiclJmLq//////////////7ERSYmJi4/T1dZV008LCYmJ1na////////////////"
        + "/ctYKSYmJicpKiknJiYmLGze////////////////////5o9DKSYmJiYmJiYrTaPw///////////////////////83aJqSz46P1B0"
        + "r+f+////////////////////////////+evg3OHu+///////////////////////////////////////////////////////////"
        + "/////////////////////////////////////////////////////////////////////////////////w=="
    static let template: [Float] = {
        let bytes = Data(base64Encoded: templateBase64) ?? Data()
        var t = bytes.map { Float($0) / 255 }
        let mean = t.reduce(0, +) / Float(max(t.count, 1))
        let sd = (t.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(t.count, 1))).squareRoot()
        for i in t.indices { t[i] = (t[i] - mean) / max(sd, 1e-6) }
        return t
    }()

    static func find(_ image: CGImage) -> CGPoint? {
        let k = size, n = Float(k * k)
        guard template.count == k * k, image.width > 0 else { return nil }
        var best: (score: Float, spot: CGPoint)?
        for scale in [0.85, 1.0, 1.15] {  // the button scaled, by scaling the screen the other way
            let w = Int((Double(width) / scale).rounded())
            let h = Int((Double(image.height) * Double(w) / Double(image.width)).rounded())
            guard h > k, let px = gray(image, w, h) else { continue }
            // sums of the pixels and their squares up to each corner: any window's mean and spread at once
            let iw = w + 1
            var s1 = [Double](repeating: 0, count: iw * (h + 1)), s2 = s1
            for y in 0..<h {
                var r1 = 0.0, r2 = 0.0
                for x in 0..<w {
                    let v = Double(px[y * w + x]); r1 += v; r2 += v * v
                    s1[(y + 1) * iw + x + 1] = s1[y * iw + x + 1] + r1
                    s2[(y + 1) * iw + x + 1] = s2[y * iw + x + 1] + r2
                }
            }
            func box(_ s: [Double], _ x: Int, _ y: Int) -> Double {
                s[(y + k) * iw + x + k] - s[y * iw + x + k] - s[(y + k) * iw + x] + s[y * iw + x]
            }
            px.withUnsafeBufferPointer { p in template.withUnsafeBufferPointer { t in
                for y in 0...(h - k) { for x in 0...(w - k) {
                    let mean = box(s1, x, y) / Double(n)
                    let sd = Float((max(box(s2, x, y) / Double(n) - mean * mean, 0)).squareRoot())
                    guard sd > 0.02 else { continue }  // a flat patch
                    var dot: Float = 0
                    for ty in 0..<k {
                        let row = (y + ty) * w + x, trow = ty * k
                        for tx in 0..<k { dot += p[row + tx] * t[trow + tx] }
                    }
                    let score = dot / n / sd  // the template's mean is 0, so the window's mean drops out
                    let spot = CGPoint(x: (Double(x) + Double(k) / 2) / Double(w), y: (Double(y) + Double(k) / 2) / Double(h))
                    if score > (best?.score ?? minScore), atEdge(spot) { best = (score, spot) }
                } }
            } }
        }
        return best?.spot
    }

    /// Left alone, the button always rests against an edge of the screen; a round icon mid-screen can look much like
    /// it (a dark disc with a white play mark scored 0.81).
    static func atEdge(_ p: CGPoint) -> Bool { p.x <= 0.14 || p.x >= 0.86 || p.y <= 0.08 || p.y >= 0.92 }

    private static func gray(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        return (0..<(w * h)).map { Float(px[$0]) / 255 }
    }

    /// Where Home is once the menu opened for the button at `button` (0-1) on a portrait screen `screen` points large.
    /// The default six-item menu (~292×293 pt) is centred on the button and kept 12 pt from the sides and 71 pt from
    /// top and bottom; Home is 79 pt below its centre. Measured on an iPhone X with the button at the top, middle and
    /// bottom of the right edge (2026-11-22).
    static func homeSpot(button: CGPoint, screen: CGSize) -> CGPoint {
        let (mw, mh, side, edge, below) = (292.0, 293.0, 12.0, 71.0, 79.0)
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi) }
        let cx = clamp(button.x * screen.width, side + mw / 2, screen.width - side - mw / 2)
        let cy = clamp(button.y * screen.height, edge + mh / 2, screen.height - edge - mh / 2)
        return CGPoint(x: cx / screen.width, y: (cy + below) / screen.height)
    }
}
