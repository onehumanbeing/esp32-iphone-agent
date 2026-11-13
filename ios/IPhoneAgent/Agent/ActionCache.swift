import Foundation

/// Henry 2026-11-13: in a task over many items the same few taps follow each item ("…", "删除", "确定"). Once the
/// same taps followed the same tap twice, the third time the code does them itself: each found by its words on the
/// screen (OCR, near where it was last), each checked to change the screen; anything missing hands back to the
/// model at once. Taps only (never typing), never with prices or paying on the screen, this run only.
struct ActionCache: Equatable {
    struct Move: Hashable {
        var kind: String   // "tap"
        var label: String  // what reads at its spot
        static let gap = Move(kind: "gap", label: "")  // a move the cache cannot name: no tail runs across it
    }

    static let longest = 4
    private(set) var trail: [Move] = []
    private(set) var spots: [String: (x: Int, y: Int)] = [:]

    static func == (a: ActionCache, b: ActionCache) -> Bool { a.trail == b.trail }

    mutating func add(_ label: String, at spot: (x: Int, y: Int)) {
        trail.append(Move(kind: "tap", label: label))
        spots[label] = spot
    }

    mutating func gap() { if trail.last != .gap { trail.append(.gap) } }

    /// The taps that followed `label` the same way the last two times before this one, nil when none did.
    func tail(after label: String) -> [Move]? {
        let anchor = Move(kind: "tap", label: label)
        let starts = trail.indices.filter { trail[$0] == anchor }
        guard starts.count >= 3, starts.last == trail.count - 1 else { return nil }  // two earlier, and it is the last
        let tails = starts.dropLast().suffix(2).map { i -> [Move] in
            var tail: [Move] = [], j = i + 1
            while j < trail.count, tail.count < Self.longest, trail[j] != .gap, trail[j] != anchor {
                tail.append(trail[j]); j += 1
            }
            return tail
        }
        let common = zip(tails[0], tails[1]).prefix { $0 == $1 }.map(\.0)
        return common.isEmpty ? nil : common
    }

    func spot(_ label: String) -> (x: Int, y: Int) { spots[label] ?? (500, 500) }

    /// Prices or paying on the screen: the model decides those taps.
    static func paying(_ lines: [DemoAnalysis.Line]) -> Bool {
        let words = ["¥", "￥", "$", "€", "支付", "付款", "购买", "pay", "buy", "purchase", "checkout"]
        return lines.contains { line in let t = line.text.lowercased(); return words.contains { t.contains($0) } }
    }
}

extension AgentLoop {
    /// After a round whose last move was a tap that changed the screen, in a task over many items: name the tap
    /// (OCR on the screen it was planned on), then do the cached taps that follow it, if any.
    func followCache(seen: Data?) async throws {
        guard inventory.needed else { return }
        guard let last = steps.last, last["action"]?.str == "tap", last["changed"]?.bool == true,
              let x = last["x"]?.int, let y = last["y"]?.int, let seen,
              let label = IntentLearner.label(at: x, y, in: await DemoAnalysis.texts(seen, limit: 80)) else {
            return cache.gap()
        }
        cache.add(label, at: (x, y))
        guard let tail = cache.tail(after: label) else { return }
        DebugLog.write("cache: \(tail.count) taps after \"\(label)\" done by code")
        for move in tail {
            guard running, !Task.isCancelled else { return }
            await screen?.settled()
            guard let before = screen?.frame else { return cache.gap() }
            let lines = await DemoAnalysis.texts(before, limit: 80)
            let near = cache.spot(move.label)
            guard !ActionCache.paying(lines), let spot = Replay.locate(move.label, near: near.x, near.y, in: lines) else {
                DebugLog.write("cache: \"\(move.label)\" not on screen; the model goes on")
                return cache.gap()
            }
            let act: JObject = ["action": .str("tap"), "x": .int(spot.x), "y": .int(spot.y)]
            _ = try await perform(act)
            await screen?.settled()
            let after = screen?.frame
            let changed = await Vision.off { Vision.changed(before, after) }
            record(before, act.merging(["cached": .bool(true), "label": .str(move.label), "changed": .bool(changed)]))
            cachedSteps += 1
            guard changed else { return cache.gap() }
            cache.add(move.label, at: spot)
        }
    }
}
