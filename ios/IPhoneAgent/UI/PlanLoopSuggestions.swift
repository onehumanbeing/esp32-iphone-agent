import SwiftUI

/// Two ready-made requests. Side by side when there is room, stacked when there is not. Each is at least 44 points tall.
struct PlanLoopSuggestions: View {
    var count: Int
    var busy: Bool
    var send: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) {
                loop
                stop
            }
            VStack(spacing: Space.s) {
                loop
                stop
            }
        }
        .disabled(busy)
    }

    private var loop: some View {
        Button("Make it a loop", systemImage: "repeat", action: askLoop)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var stop: some View {
        Button("Stop before step \(count)", systemImage: "arrow.uturn.backward", action: askStop)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func askLoop() {
        send("Turn this into a loop. Repeat the steps until the list shows its end.")
    }

    private func askStop() {
        send("Turn this into a loop, repeat until before step \(count).")
    }
}
