import CoreGraphics
import Foundation

/// A tap that opened the AssistiveTouch menu instead of the app (the floating button sits at a screen edge, often
/// over a list's right column: a price, an arrow). Seen by the menu's own words, closed with esc, and remembered for
/// the rest of the run: a tap there again is not sent, and the model is told how to reach what is under the button.
/// Only spots this run really hit are guarded, so a button the user moved is never guarded where it was.
enum AssistiveTouchGuard {
    /// The menu's items, any language the menu shows here; two of them = the menu is open.
    static let items = ["主屏幕", "控制中心", "通知中心", "设备", "自定", "手势", "Home", "Control Center",
                        "Notification Center", "Device", "Custom", "Gestures"]
    /// A spot within this distance (0-1000 units) of a hit is the button.
    static let radius = 60.0

    /// Only taps near an edge can hit the button (it docks there): the OCR runs for those only.
    static func nearEdge(_ x: Double, _ y: Double) -> Bool { x < 150 || x > 850 || y < 100 || y > 900 }

    /// The AssistiveTouch menu is on screen: two or more of its items, in the middle of the screen.
    static func menuShown(_ lines: [(text: String, box: [Int])], size: CGSize) -> Bool {
        guard size.height > 0 else { return false }
        let found = Set(lines.compactMap { line -> String? in
            let y = Double(line.box[1] + line.box[3]) / 2 / size.height
            guard (0.15...0.85).contains(y) else { return nil }
            let text = line.text.trimmingCharacters(in: .whitespaces)
            return items.first { $0.caseInsensitiveCompare(text) == .orderedSame }
        })
        return found.count >= 2
    }

    /// Why a tap at x, y is not sent: it is on a spot this run found the button at. nil = send it.
    static func held(_ x: Double, _ y: Double, hits: [CGPoint]) -> String? {
        guard let hit = hits.first(where: { hypot($0.x - x, $0.y - y) <= radius }) else { return nil }
        return "not tapped: \(Int(x)), \(Int(y)) is on the AssistiveTouch button (found at \(Int(hit.x)), \(Int(hit.y)) "
            + "earlier in this run). " + reach
    }

    static let opened = "this tap hit the AssistiveTouch button and opened its menu (closed again). " + reach
    static let reach = "To reach what is under it, swipe the content up or down a little so it moves away from the "
        + "button, or tap another part of the same element."
}
