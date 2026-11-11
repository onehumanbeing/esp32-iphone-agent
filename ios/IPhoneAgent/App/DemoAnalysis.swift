import Foundation

/// A demonstration, change by change: between each two kept screens, what the person did. The phone measures
/// where the screen changed (Vision) and reads the text on it (OCR); the model, `window` changes per call, names
/// the action. Henry 2026-11-12: the old way sent 12 of up to 120 screens in one call, so most taps were never
/// read. iOS gives no touch points (AirPlay never shows the finger): a tap is inferred from the change and the
/// text there, and the model says unsure when they disagree.
enum DemoAnalysis {
    static let window = 4  // changes per model call: five screens

    static let prompt = """
    You watch a person use an iPhone, screen by screen. Fingers are not visible. For each change between two \
    consecutive screens, name the one action that caused it. Coordinates are 0-1000 of the screen width and height.
    Reply with one line per change, in this format only:
    STEP <change number>: <command> | sure or unsure
    Commands: tap X Y "what was tapped", swipe X1 Y1 X2 Y2, type "text", home, back, ai "what to achieve", \
    read "what", none.
    After tap, name what was tapped as it reads on the screen (an app's name, a button, a row's title). Write \
    none when the person did nothing: an app still opening, an animation or a page still loading.
    Each change comes with what the phone measured (where the screen changed, or that the content scrolled) and \
    the text on the screen before it, with positions. For a tap, give the position of the text or control that was \
    tapped on the screen before. Use tap / swipe / type for controls that stay in the same place every time. When \
    a step depends on what the screen shows this time (a search result, an item in a list that changes, a \
    message), write ai "what to achieve" instead. When the person was reading information off the screen, write \
    read "what". Say unsure when the screens do not clearly show the action.
    """

    static let summaryPrompt = """
    These are the steps a person did on an iPhone, in order. Reply in this format only:
    NAME: <short name for the task>
    PROMPT: <one instruction that would make an AI agent repeat this task, naming the apps and the items by their \
    names, never by screen positions>
    """

    /// The model's STEP lines for changes `first` ... `first + screens.count - 2` (1-based: change n is screen n → n+1).
    static func ask(_ model: LLMClient, screens: [Data], first: Int) async throws -> String {
        var text = "These are \(screens.count) screens in order. Name the action of each change.\n"
        for k in 0..<(screens.count - 1) {
            let lines = await texts(screens[k])
            text += "\nChange \(first + k) (screen \(k + 1) to \(k + 2)): \(await hint(screens[k], screens[k + 1], lines))."
            text += "\nText on screen \(k + 1): " + (lines.isEmpty ? "(none)" : lines.map(\.listed).joined(separator: "; "))
        }
        return try await model.chat(system: prompt, text: text, images: screens, maxTokens: 600, temperature: 0).text
    }

    static func summarize(_ model: LLMClient, steps: [String]) async throws -> String {
        try await model.chat(system: summaryPrompt, text: steps.joined(separator: "\n"), maxTokens: 400, temperature: 0).text
    }

    struct Line { let text: String; let x: Int, y: Int
        var listed: String { "\"\(text.prefix(30))\" at \(x) \(y)" }
    }

    /// OCR lines of a screen, centres in 0-1000, top to bottom (at most `limit`).
    static func texts(_ jpeg: Data, limit: Int = 30) async -> [Line] {
        guard let img = Vision.image(jpeg) else { return [] }
        let w = Double(img.width), h = Double(img.height)
        let found: [(text: String, box: [Int])] = await UITreeOCR.lines(img)
        return found.prefix(limit).map { line -> Line in
            let b = line.box.map(Double.init)
            return Line(text: line.text, x: Int((b[0] + b[2]) / 2 / w * 1000), y: Int((b[1] + b[3]) / 2 / h * 1000))
        }
    }

    /// What the phone sees about one change: a scroll, a small change (and the text nearest it), or a new screen.
    static func hint(_ a: Data, _ b: Data, _ lines: [Line]) async -> String {
        let (dy, rects) = await Task.detached(priority: .utility) { (Vision.scroll(a, b), Vision.motion(a, b)) }.value
        if let dy, abs(dy) >= 0.05 {
            return String(format: "the content moved %@ by %.0f%% of the screen (a scroll)", dy > 0 ? "up" : "down", abs(dy) * 100)
        }
        guard let r = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return "most of the screen changed (a new screen)"
        }
        let (x, y) = (Int(r.midX * 1000), Int(r.midY * 1000))
        func distance(_ l: Line) -> Double { hypot(Double(l.x - x), Double(l.y - y)) }
        let near = lines.min { distance($0) < distance($1) }
        var text = ""
        if let near, distance(near) < 120 { text = ", near " + near.listed }
        return "a small change around \(x) \(y)\(text)"
    }
}
