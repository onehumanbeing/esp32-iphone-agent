import SwiftUI

/// A run's result (the done step's answer) with a copy button; shown only when there is one.
struct ResultCard: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Result").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: text).font(.body).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = text
                Haptics.success()
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Copy result"))
        }
        .padding(Space.m)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
    }
}
