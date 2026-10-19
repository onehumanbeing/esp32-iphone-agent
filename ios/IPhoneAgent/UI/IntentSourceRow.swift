import SwiftUI

/// One way to make an intent: a monochrome glyph on a neutral block, title and a line of detail.
struct IntentSourceRow: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.isEnabled) private var enabled
    let title: LocalizedStringKey
    let symbol: String
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            IntentSourceGlyph(symbol: symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(enabled ? Color.primary : Color.secondary)
                if !textSize.isAccessibilitySize {
                    Text(detail).font(.subheadline).foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(detail))
    }
}

/// "record" draws a ring with a small red dot, the only color on the sheet; other names are SF Symbols.
struct IntentSourceGlyph: View {
    @Environment(\.isEnabled) private var enabled
    let symbol: String

    var body: some View {
        ZStack {
            if symbol == "record" {
                Circle().strokeBorder(.primary, lineWidth: 1.8).frame(width: 18, height: 18)
                RecordDot(size: 8).opacity(enabled ? 1 : 0.4)
            } else {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            }
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .frame(width: 34, height: 34)
        .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 9, style: .continuous))
    }
}

struct RecordDot: View {
    var size: CGFloat = 8
    var body: some View { Circle().fill(Color.red).frame(width: size, height: size) }
}
