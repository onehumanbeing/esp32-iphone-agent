import CoreGraphics
import Foundation

/// The recommendations feed under a page (猜你喜欢 / 为你推荐 under an order, a product, a cart): it scrolls on forever,
/// so a scroll past the page's own end lands in it and every further scroll shows new cards. Henry 2026-11-18: in
/// Meituan, Taobao and many apps the model scrolled into it and kept going. After a swipe that brings its header up,
/// the step says so; collect, find and each stop paging there.
enum Feed {
    static let headers = ["猜你喜欢", "为你推荐", "你可能还喜欢", "你可能喜欢", "你可能也喜欢", "大家都在买", "大家还在看",
                          "更多推荐", "相关推荐", "热门推荐", "推荐商品", "看了又看", "为你精选", "精选推荐", "附近推荐",
                          "you may also like", "you might also like", "recommended for you", "more to explore",
                          "customers also bought", "related products"]

    /// The header line on a screen: a short line (a title, not a sentence) holding one of the phrases.
    static func header(_ lines: [String]) -> String? {
        lines.first { line in
            let t = line.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "您", with: "你")
            return headers.contains { t.contains($0) && t.count <= $0.count + 8 }
        }
    }

    /// A header the screen did not show before the swipe.
    static func reached(_ lines: [String], before: [String]) -> String? {
        guard let h = header(lines), header(before) == nil else { return nil }
        return h
    }

    static func result(_ header: String) -> String {
        "this scroll reached \"\(header.prefix(16))\": below it is a recommendations feed, not this page. What this page "
            + "has is above it: scroll back up; never scroll further down here"
    }
}

extension AgentLoop {
    /// After a swipe: the feed header it brought up, and how far the page really went (ScrollMeter), written into
    /// the step's result for the next round.
    func noteFeed(seen: Data?) async {
        guard let act = steps.last, act["action"]?.str == "swipe", let seen, let now = screen?.frame else { return }
        // the model's copies, read once: the look's tree already has the lines before the swipe, and the next look's
        // tree finds the lines after it in the cache (2026-11-19: two full-size reads here took 7-9 s per swipe)
        let sent = ModelImage.forModel(now)
        guard let b = Vision.image(sent) else { return }
        let before: [(text: String, box: [Int])]
        if let tree = lookTree, tree.h == b.height { before = tree.lines }
        else if let a = Vision.image(ModelImage.forModel(seen)) { before = await UITreeOCR.lines(a) } else { return }
        let after: [(text: String, box: [Int])]
        if let cached = UITree.ocrCache.lines(for: sent) { after = cached } else {
            after = await UITreeOCR.lines(b)
            UITree.ocrCache.store(sent, after)
        }
        var said: [String] = []
        if let swiped = ScrollMeter.swiped(act) {
            let moved = ScrollMeter.moved(before.map { ($0.text, $0.box) }, after.map { ($0.text, $0.box) }, height: Double(b.height))
            scrollGain = ScrollMeter.gain(scrollGain, swiped: swiped, moved: moved)
            DebugLog.write(String(format: "scroll: swiped %.0f, moved %@, gain %.2f", swiped, moved.map { String(format: "%.0f", $0) } ?? "off screen", scrollGain))
            if let note = ScrollMeter.result(swiped: swiped, moved: moved) { said.append(note) }
        }
        if let h = Feed.reached(after.map(\.text), before: before.map(\.text)) {
            DebugLog.write("feed: the swipe reached \"\(h)\"")
            said.append(Feed.result(h))
        }
        guard !said.isEmpty else { return }
        let had = steps[steps.count - 1]["result"]?.str
        steps[steps.count - 1]["result"] = .str(([had].compactMap { $0 } + said).joined(separator: "; "))
    }

    /// The screen now shows the feed header (collect / find / each stop paging).
    func feedShown() async -> String? {
        guard let frame = screen?.frame, let image = Vision.image(frame) else { return nil }
        return Feed.header(await UITreeOCR.lines(image).map(\.text))
    }
}
