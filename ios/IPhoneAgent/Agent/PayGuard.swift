import Foundation

/// The code's own check before a tap that pays or cannot be undone, when the model tapped it without `confirm`
/// first. The label under the tap decides: 立即支付 / 提交订单 / Pay now ask in every mode but Never; 删除 / 注销 /
/// Delete account ask in the "Payments, sending, deleting" mode. Nothing is sent; the user is asked as if the
/// model had confirmed, and the model sees the answer (confirmed / skipped) before it taps again.
enum PayGuard {
    enum Kind { case money, irreversible }

    static let money = ["立即支付", "确认支付", "确认付款", "去支付", "去付款", "提交订单", "立即购买", "确认购买", "立即下单",
                        "支付", "付款", "pay now", "place order", "buy now", "confirm payment", "complete purchase",
                        "confirm and pay", "pay"]
    static let irreversible = ["彻底删除", "永久删除", "确认删除", "删除", "注销账号", "注销", "清空", "delete account",
                               "delete", "erase", "remove"]
    static let recent = 6  // a money confirm covers the taps of the next few steps, not the rest of the run

    /// What the label under a tap commits to; only a short label (a button), not a sentence that mentions it.
    /// A short word (支付, pay, 删除) counts alone or followed by a price ("支付 ¥99.00"); a longer phrase may sit
    /// in a slightly longer label ("立即支付 ¥41"). "支付方式" (a picker) is not a payment.
    static func kind(_ label: String?) -> Kind? {
        guard let label = label?.lowercased().trimmingCharacters(in: .whitespaces), label.count >= 2 else { return nil }
        func names(_ words: [String]) -> Bool {
            words.contains { w in
                if label == w { return true }
                if label.hasPrefix(w), label.dropFirst(w.count).allSatisfy({ " ¥￥$.,:：".contains($0) || $0.isNumber }) { return true }
                let long = w.allSatisfy(\.isASCII) ? w.count >= 6 : w.count >= 3
                return long && label.count <= w.count + 6 && label.contains(w)
            }
        }
        if names(money) { return .money }
        return names(irreversible) ? .irreversible : nil
    }

    /// Whether the code asks: by the mode, and not when the user already said yes (a payment: in the last few
    /// steps; a delete: once in the run covers a bulk delete) or no to this very label.
    static func asks(_ kind: Kind, mode: AskMode, steps: [JObject], label: String) -> Bool {
        switch (kind, mode) {
        case (_, .never), (.irreversible, .payments): return false
        default: break
        }
        let window = kind == .money ? Array(steps.suffix(recent)) : steps
        if window.contains(where: { $0["action"]?.str == "confirmed" }) { return false }
        return !steps.suffix(recent).contains { $0["action"]?.str == "skipped" && ($0["reason"]?.str ?? "").contains(label) }
    }

    /// The confirm's reason: what the tap would do, in the words the confirm dialog shows.
    static func reason(_ kind: Kind, _ label: String) -> String {
        kind == .money ? "tap “\(label)”: this pays or places an order" : "tap “\(label)”: this deletes or cannot be undone"
    }
}

extension AgentLoop {
    /// The label under the tap, from the background read of this screen when it is the one the model saw.
    func payGuardReason(_ act: JObject, on shot: Data?) async -> String? {
        guard act["action"]?.str == "tap", let x = act["x"]?.int, let y = act["y"]?.int, let shot else { return nil }
        let mode = askMode ?? .current
        guard mode != .never else { return nil }
        let lines = await lookLines(for: shot)
        guard let label = IntentLearner.label(at: x, y, in: lines), let kind = PayGuard.kind(label),
              PayGuard.asks(kind, mode: mode, steps: steps, label: label) else { return nil }
        DebugLog.write("pay guard: a tap on \"\(label)\" without confirm; asking the user")
        return PayGuard.reason(kind, label)
    }
}
