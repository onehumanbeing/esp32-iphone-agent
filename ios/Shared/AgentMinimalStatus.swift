import SwiftUI

/// The constrained agent bubble shown when another activity (Screen Mirroring, always on during a run) also
/// occupies the Dynamic Island: the face (mood and gaze), a one-word caption under it ("Tap", "Think"), and a
/// colored dot when it needs the user or has finished. Full sentences live in the expanded island.
struct AgentMinimalStatus: View {
    let state: AgentActivityAttributes.ContentState
    /// iOS suspended the app mid-run: "×" eyes and "Stuck" (`ContentState.stuck`).
    var stuck = false

    var body: some View {
        VStack(spacing: 0) {
            AgentFace(mood: state.mood, look: state.look, lookRange: 2.4, animated: false, showsTab: false, crossed: stuck)
                .frame(width: 15, height: 15)
                .overlay(alignment: .bottomTrailing) {
                    if let dot { Circle().fill(dot).frame(width: 5, height: 5).offset(x: 3) }
                }
            Text(verbatim: stuck ? StuckText.minimal : state.minimalStatusText)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(state.phase == .help ? .orange : .white)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.opacity)
        }
        .frame(width: 34, height: 24)
        .animation(.easeInOut(duration: 0.3), value: state)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: stuck ? StuckText.full : state.statusAccessibilityText))
    }

    private var dot: Color? {
        if state.phase == .help { return .orange }
        guard state.finished else { return nil }
        return state.mood == .success ? .green : state.mood == .failure ? .red : nil
    }
}
