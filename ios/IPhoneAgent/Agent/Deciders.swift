import SwiftUI  // Array.move(fromOffsets:toOffset:)

/// Who decides each step of a run: Jev (the decision model) and the model, in the order the user dragged them
/// into, each one on or off (Settings › Model). Kept per line: the free line starts with Jev first, your own
/// model starts with Jev off (Jev needs its own consent there, see JevConsent).
enum Decider: String, CaseIterable, Codable {
    case jev, model
}

struct Deciders: Equatable, Codable {
    var order: [Decider]
    var off: Set<Decider>

    enum Mode: Equatable { case modelOnly, jevFirst, modelFirst, jevOnly }

    var mode: Mode {
        let on = order.filter { !off.contains($0) }
        switch on {
        case [.jev, .model]: return .jevFirst
        case [.model, .jev]: return .modelFirst
        case [.jev]: return .jevOnly
        default: return .modelOnly
        }
    }

    func isOn(_ decider: Decider) -> Bool { !off.contains(decider) }

    /// At least one stays on; on the free line the model always does (the gateway has no Jev-only mode).
    mutating func set(_ decider: Decider, on: Bool, freeLine: Bool) {
        if on { off.remove(decider); return }
        guard !(freeLine && decider == .model), off.count + 1 < Decider.allCases.count else { return }
        off.insert(decider)
    }

    mutating func move(from: IndexSet, to: Int) { order.move(fromOffsets: from, toOffset: to) }

    /// The free line's X-Handsy-Jev header for the actor: Jev first ("race": Jev and the model at once).
    func freeLineHeader(race: Bool, threshold: Double = JevConfig.threshold) -> [String: String] {
        guard mode == .jevFirst, !JevGate.hold else { return [:] }
        return ["X-Handsy-Jev": race ? "race" : "1", "X-Handsy-Jev-Threshold": String(format: "%.2f", threshold)]
    }

    static let raceKey = "jevRace"
    /// Ask both at once unless the user turned it off: a step Jev leaves then costs no time.
    static func race(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: raceKey) as? Bool ?? true }
    static func key(freeLine: Bool) -> String { freeLine ? "deciders.free" : "deciders.own" }
    static func standard(freeLine: Bool) -> Deciders { Deciders(order: [.jev, .model], off: freeLine ? [] : [.jev]) }

    static func load(freeLine: Bool, defaults: UserDefaults = .standard) -> Deciders {
        guard let data = defaults.data(forKey: key(freeLine: freeLine)),
              var saved = try? JSONDecoder().decode(Deciders.self, from: data),
              Set(saved.order) == Set(Decider.allCases), saved.order.count == Decider.allCases.count
        else { return standard(freeLine: freeLine) }
        if freeLine || saved.off.count == Decider.allCases.count { saved.off.remove(.model) }
        return saved
    }

    func save(freeLine: Bool, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(freeLine: freeLine))
    }
}

/// Steps go to Jev only after this separate yes, per target: Handsy (Holomix, Inc. and its provider TypeSafe),
/// or TypeSafe on the user's own key. Handsy Free's own agreement already covers Jev on Handsy.
enum JevConsent {
    static let key = "jevConsentVersion"
    static let version = "2026-11-06"
    static let handsy = "handsy"
    static var target: String { UserDefaults.standard.bool(forKey: JevConfig.ownKey) ? "api.typesafe.ai" : handsy }
    static var granted: Bool { UserDefaults.standard.string(forKey: key) == "\(version) \(target)" }
    static func needed(freeLine: Bool) -> Bool { !(freeLine && target == handsy) && !granted }
    static func grant() { UserDefaults.standard.set("\(version) \(target)", forKey: key) }

    static func revoke() {
        UserDefaults.standard.removeObject(forKey: key)
        var own = Deciders.load(freeLine: false)
        own.set(.jev, on: false, freeLine: false)
        own.save(freeLine: false)
    }
}

/// After a round of several gestures the model's plan is behind: its first items were done in that round, but
/// Jev reads the plan from the top and redid them (2026-11-07, Duolingo: "Tap Rice" again took Rice back out of
/// the answer). The next step then goes to the model, which brings its plan up to date. Set by AgentLoop.
enum JevGate {
    nonisolated(unsafe) static var hold = false
}
