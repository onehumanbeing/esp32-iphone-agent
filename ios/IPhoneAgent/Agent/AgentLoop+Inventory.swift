import Foundation

/// Henry 2026-11-13: a task over many items, or one that deletes, is listed first and confirmed before anything
/// goes. The prompt asks for it (app-rules: read the matching items, then one confirm with how many and which);
/// the code holds the first destructive tap that comes before such a confirm once, and tells the model why. The
/// confirm of such a task always waits for the user unless Ask first is Never.
struct Inventory: Equatable {
    /// Words of a task over many items or that cannot be undone.
    static let batchWords = ["删除", "批量", "全部", "所有", "清空", "取消关注", "退出", "清理", "每一", "每个",
                             "delete", "remove", "clear", "unfollow", "unsubscribe", "every", "all of", "each of", "bulk"]
    /// What a destructive control reads (OCR at the tap's spot).
    static let destructive = ["删除", "移除", "清空", "取消关注", "退出群聊", "彻底删除", "删除文章", "不再关注",
                              "delete", "remove", "clear all", "unfollow", "erase"]
    static let advice = "Before deleting or changing many items: list the matching items with read first, then confirm " +
        "with how many and which. This tap was not sent."

    var needed = false
    var held = false  // the one hold done

    init(task: String = "", until: Bool = false) {
        let lower = task.lowercased()
        needed = until || Self.batchWords.contains { lower.contains($0) }
    }

    static func isDestructive(_ label: String?) -> Bool {
        guard let label = label?.lowercased(), label.count >= 2 else { return false }
        return destructive.contains { label == $0 || (label.count <= $0.count + 4 && label.contains($0)) }
    }

    /// The user already said yes to a confirm in this run.
    static func confirmed(_ steps: [JObject]) -> Bool {
        steps.contains { $0["action"]?.str == "confirmed" }
    }

    /// Hold this tap? Once per run, only before the first confirm the user answered.
    mutating func holds(label: String?, steps: [JObject]) -> Bool {
        guard needed, !held, !Self.confirmed(steps), Self.isDestructive(label) else { return false }
        held = true
        return true
    }
}

extension AgentLoop {
    /// The reason a tap is held for the inventory, or nil. Reads the text at the tap's spot on the screen it was
    /// planned on, only while a hold is still possible.
    func inventoryHold(_ act: JObject, on shot: Data?) async -> String? {
        guard inventory.needed, !inventory.held, !Inventory.confirmed(steps),
              let shot, let x = act["x"]?.int, let y = act["y"]?.int else { return nil }
        let label = IntentLearner.label(at: x, y, in: await DemoAnalysis.texts(shot, limit: 80))
        guard inventory.holds(label: label, steps: steps) else { return nil }
        DebugLog.write("inventory: held a tap on \"\(label ?? "")\" before any confirm")
        return Inventory.advice
    }

    /// A confirm of a task over many items shows the items collected so far (at most 5).
    func inventoryReason(_ reason: String) -> String {
        guard inventory.needed, !notebook.items.isEmpty else { return reason }
        let shown = notebook.items.prefix(5).map { "• " + $0.prefix(80) }.joined(separator: "\n")
        let more = notebook.items.count > 5 ? "\n" + String(localized: "and \(notebook.items.count - 5) more") : ""
        return reason + "\n" + shown + more
    }
}
