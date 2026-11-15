import SwiftUI

/// Whether the review pass was satisfied. The symbol carries the same meaning as the color.
struct PlanReviewStatus: View {
    var passed: Bool

    var body: some View {
        if passed {
            Label("Review passed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.ok)
        } else {
            Label("Review found something to check", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
        }
    }
}
