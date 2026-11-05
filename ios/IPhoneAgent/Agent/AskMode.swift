import Foundation

/// When a `confirm` from the actor reaches the user. The actor always asks before risky steps (the prompt does not
/// change, so its prefix stays cached); this setting decides which of those asks wait for the user.
enum AskMode: String, CaseIterable, Identifiable {
    case payments  // only paying, buying, transferring money (default)
    case risky     // also sending, posting, deleting, account settings
    case never

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
        case .payments: return String(localized: "Payments only")
        case .risky: return String(localized: "Payments, sending, deleting")
        case .never: return String(localized: "Never")
        }
    }

    private static let money = ["pay", "buy", "purchase", "order", "checkout", "transfer", "subscribe", "tip",
                                "付款", "支付", "购买", "下单", "转账", "充值", "订阅", "打赏", "买"]

    /// Whether this confirm waits for the user.
    func asks(_ reason: String) -> Bool {
        switch self {
        case .never: return false
        case .risky: return true
        case .payments:
            let lower = reason.lowercased()
            return Self.money.contains { word in
                word.allSatisfy(\.isASCII) ? lower.range(of: "\\b\(word)", options: .regularExpression) != nil : lower.contains(word)
            }
        }
    }
}
