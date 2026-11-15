import SwiftUI

/// The field under the plan chat. A wide window keeps the send button beside it; a narrow one stacks them.
struct PlanEditComposer: View {
    @ObservedObject var session: PlanEditSession
    @Binding var input: String
    var showDiff: () -> Void
    var send: () -> Void

    var body: some View {
        VStack(spacing: Space.s) {
            if let proposal = session.proposal {
                Button(action: showDiff) {
                    LabeledContent {
                        Text("See changes").foregroundStyle(.secondary)
                    } label: {
                        PlanReviewStatus(passed: proposal.verdictOK)
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Palette.surface, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: Space.s) {
                    field
                    sendButton
                }
                VStack(alignment: .trailing, spacing: Space.s) {
                    field
                    sendButton
                }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.s)
        .padding(.bottom, Space.s)
        .background(.bar)
    }

    private var field: some View {
        TextField("Ask for a change", text: $input, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Palette.surface, in: .rect(cornerRadius: 18))
            .accessibilityIdentifier("plan.message")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
            .labelStyle(.iconOnly)
            .font(.title)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(session.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.hasPlan)
    }
}
