import SwiftUI

/// What the plan chat shows before the first message, including two ways to ask for a loop.
struct PlanEditIntro: View {
    @ObservedObject var session: PlanEditSession
    var send: (String) -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            AgentFace(mood: .thinking, animated: false).frame(width: 72, height: 80)
            Text("Edit this plan").font(.headline)
            Text(session.hasPlan
                 ? "Say what should change. A second pass checks the result, and you see the difference before it is saved."
                 : "This folder has no recorded steps to edit.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Uses the Planner model when one is set in Settings › Model, otherwise the selected model.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let count = PlanText.parse(session.planText)?.steps.count, count > 1 {
                PlanLoopSuggestions(count: count, busy: session.busy, send: send)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }
}
