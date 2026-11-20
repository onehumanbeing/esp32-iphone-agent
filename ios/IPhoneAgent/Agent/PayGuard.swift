import Foundation

/// The code's own check before a tap that pays or cannot be undone, when the model tapped it without `confirm`
/// first. The label under the tap decides: 立即支付 / 提交订单 / Pay now ask in every mode but "Only what can't be
/// undone"; 删除 / 卸载 / 同意 / 挂断 / Delete account ask in every mode. Nothing is sent; the user is asked as if
/// the model had confirmed, and the model sees the answer (confirmed / skipped) before it taps again.
enum PayGuard {
    enum Kind { case money, irreversible }

    static let money = ["立即支付", "确认支付", "确认付款", "去支付", "去付款", "提交订单", "立即购买", "确认购买", "立即下单",
                        "支付", "付款", "pay now", "place order", "buy now", "confirm payment", "complete purchase",
                        "confirm and pay", "pay"]
    static let irreversible = ["彻底删除", "永久删除", "确认删除", "删除", "注销账号", "注销", "清空", "delete account",
                               "delete", "erase", "remove", "delete from this iphone", "delete app", "offload app",
                               "卸载应用", "卸载", "同意", "批准", "驳回", "approve", "reject", "接听", "挂断",
                               "decline", "end call"]
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
        if kind == .money, mode == .never { return false }
        let window = kind == .money ? Array(steps.suffix(recent)) : steps
        if window.contains(where: { $0["action"]?.str == "confirmed" }) { return false }
        return !steps.suffix(recent).contains { $0["action"]?.str == "skipped" && ($0["reason"]?.str ?? "").contains(label) }
    }

    /// The confirm's reason: what the tap would do, in the words the confirm dialog shows.
    static func reason(_ kind: Kind, _ label: String) -> String {
        kind == .money ? "tap “\(label)”: this pays or places an order" : "tap “\(label)”: this deletes or cannot be undone"
    }

    /// The first label that pays or cannot be undone: the text under the tap's spot, then a text tap's own words,
    /// which count even when no line is read there (2026-11-20, 高德: `tap "清空"` was placed by a fresh read of the
    /// screen, the look's lines held no "清空" at that spot, and the search history was wiped unasked).
    static func guarded(_ labels: [String?]) -> (kind: Kind, label: String)? {
        for case let label? in labels {
            let label = label.trimmingCharacters(in: .whitespaces)
            if let found = Self.kind(label) { return (found, label) }
        }
        return nil
    }
}

extension AgentLoop {
    /// The label under the tap, from the background read of this screen when it is the one the model saw; for a
    /// tap by words also those words.
    func payGuardReason(_ act: JObject, on shot: Data?) async -> String? {
        guard act["action"]?.str == "tap" else { return nil }
        var under: String?
        if let x = act["x"]?.int, let y = act["y"]?.int, let shot {
            under = IntentLearner.label(at: x, y, in: await lookLines(for: shot))
        }
        let mode = askMode ?? .current
        guard let hit = PayGuard.guarded([under, act["text"]?.str]),
              PayGuard.asks(hit.kind, mode: mode, steps: steps, label: hit.label) else { return nil }
        DebugLog.write("pay guard: a tap on \"\(hit.label)\" without confirm; asking the user")
        return PayGuard.reason(hit.kind, hit.label)
    }
}
