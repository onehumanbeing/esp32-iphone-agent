import SwiftUI

/// Keep recording controls reachable while the user scrolls or uses larger text.
struct RecordingControls: View {
    @ObservedObject var recorder: DemoRecorder

    var body: some View {
        BottomBar {
            if recorder.countdownEnds != nil {
                Button { Task { await recorder.cancel() } } label: {
                    Label("Cancel Recording", systemImage: "xmark").padding(.vertical, Space.s)
                }
                .buttonStyle(BigButton(tint: Color(.secondarySystemFill), ink: .primary))
            } else {
                Button { Task { await recorder.stop() } } label: {
                    Label("Stop Recording", systemImage: "stop.fill").padding(.vertical, Space.s)
                }
                .buttonStyle(BigButton(tint: Color(.label), ink: Color(.systemBackground)))
                Button("Cancel", role: .destructive) { Task { await recorder.cancel() } }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .padding(.vertical, Space.xs)
            }
        }
    }
}
