import SwiftUI

/// A small "Beta" capsule next to a title (Tools, Henry 2026-11-12): hairline and secondary text, in the app's
/// black-and-white look.
struct BetaBadge: View {
    var body: some View {
        Text("Beta", comment: "Badge: the feature is new and may change.")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
    }
}

#Preview {
    BetaBadge()
}
