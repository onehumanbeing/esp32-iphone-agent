import SwiftUI

/// One line in the plan chat: the person on the trailing side, the model on the leading side, a tool as a label.
struct PlanChatTurnView: View {
    let turn: PlanTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch turn.role {
            case .tool:
                Label { Text(verbatim: turn.text).lineLimit(4) } icon: { Image(systemName: "wrench.and.screwdriver") }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.l)
            case .user, .assistant:
                HStack {
                    if turn.role == .user { Spacer(minLength: 48) }
                    Text(verbatim: turn.text)
                        .font(.body)
                        .foregroundStyle(turn.role == .user ? Color.white : Color.primary)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                        .background(turn.role == .user ? Color.accentColor : Palette.surface, in: .rect(cornerRadius: 16))
                    if turn.role == .assistant { Spacer(minLength: 48) }
                }
                .padding(.horizontal, Space.l)
            }
        }
    }
}
