import Foundation

/// When a `confirm` from the actor reaches the user. The actor always asks before risky steps (the prompt does not
/// change, so its prefix stays cached); this setting decides which of those asks wait for the user.
/// A step that cannot be undone (deleting for good, approving for someone, a phone call, accepting terms, posting
/// publicly, account changes) waits in every mode: it is the user's to decide, whatever the setting.
enum AskMode: String, CaseIterable, Identifiable {
    case payments  // money and what cannot be undone (default)
    case risky     // also sending a message
    case never     // only what cannot be undone

    var id: String { rawValue }
    static let key = "askMode"

    /// The stored choice; the old on/off setting maps to payments / never.
    static var current: AskMode {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: key), let mode = AskMode(rawValue: raw) { return mode }
        return d.object(forKey: AgentLoop.askBeforeRiskyKey) as? Bool == false ? .never : .payments
    }

    var title: String {
        switch self {
        case .payments: return String(localized: "Payments and what can't be undone")
        case .risky: return String(localized: "Payments, sending, deleting")
        case .never: return String(localized: "Only what can't be undone")
        }
    }

    /// What a confirm is about: the model names it first, as the reason's verb ("confirm delete empty Recently
    /// Deleted"), so the user reads the reason as it is.
    enum Kind: String, CaseIterable { case pay, delete, approve, post, call, consent, account, send }

    /// Kinds that wait in every mode.
    static let undoable: Set<Kind> = [.delete, .approve, .post, .call, .consent, .account]

    private static let money = ["pay", "buy", "purchase", "order", "checkout", "transfer", "subscribe", "tip",
                                "付款", "支付", "购买", "下单", "转账", "充值", "订阅", "打赏", "买"]
    /// A confirm without a kind (an older prompt, or the model left it out) that still reads as one of them.
    private static let lasting = ["delete", "erase", "remove", "offload", "approve", "reject", "answer the call",
                                  "end the call", "hang up", "accept", "agree", "删除", "清空", "卸载", "注销",
                                  "同意", "批准", "审批", "驳回", "接听", "挂断", "协议"]

    /// The kind the model named as the reason's first word, if any.
    static func kind(_ reason: String) -> Kind? {
        let first = reason.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace && $0 != ":" }
        return Kind(rawValue: first.lowercased())
    }

    /// Whether this confirm waits for the user.
    func asks(_ reason: String) -> Bool {
        if let kind = Self.kind(reason) {
            if Self.undoable.contains(kind) { return true }
            switch self {
            case .never: return false
            case .risky: return true
            case .payments: return kind == .pay
            }
        }
        if Self.names(Self.lasting, in: reason) { return true }
        switch self {
        case .never: return false
        case .risky: return true
        case .payments: return Self.names(Self.money, in: reason)
        }
    }

    private static func names(_ words: [String], in reason: String) -> Bool {
        let lower = reason.lowercased()
        return words.contains { word in
            word.allSatisfy(\.isASCII) ? lower.range(of: "\\b\(word)", options: .regularExpression) != nil : lower.contains(word)
        }
    }
}
