import SwiftUI

/// A run's result (the done step's answer): a header with copy and collapse buttons, the text below.
/// Shown only when there is one.
struct ResultCard: View {
    let text: String
    @State private var expanded = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Result").font(.subheadline.weight(.semibold))
                        if !expanded {
                            Text(verbatim: text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(expanded ? "Collapses the result" : "Shows the result"))
                Button {
                    UIPasteboard.general.string = text
                    Haptics.success()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if expanded {
                Text(verbatim: text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.m)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
    }
}
