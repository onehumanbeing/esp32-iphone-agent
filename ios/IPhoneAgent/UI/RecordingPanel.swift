import SwiftUI

/// A demonstration in progress: timer, screens captured, Stop / Cancel; then "working out the steps".
struct RecordingPanel: View {
    @ObservedObject var recorder: DemoRecorder

    var body: some View {
        Section {
            if recorder.recording, let ends = recorder.countdownEnds {
                HStack(spacing: Space.s) {
                    Text("Starting in")
                    Text(timerInterval: Date()...max(ends, Date()), countsDown: true)
                        .monospacedDigit()
                    Spacer()
                }
                .font(.title3.weight(.semibold))
                Text("Go to the Home Screen. Recording starts when the countdown in the Dynamic Island ends.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if recorder.recording {
                HStack(spacing: Space.s) {
                    RecordDot(size: 10)
                    Text(timerInterval: recorder.started...Date.distantFuture, countsDown: false)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Spacer()
                    Text("\(recorder.keyframes) screens").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Do the task on the Home Screen. Stop here or in the Dynamic Island.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if recorder.stopping {
                ProgressView("Finishing recording…")
            } else if recorder.inferring {
                if let p = recorder.progress {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1))) {
                        Text("Working out the steps from \(recorder.keyframes) screens…")
                    } currentValueLabel: {
                        HStack(spacing: Space.xs) {
                            Text("Part \(min(p.done + 1, p.total)) of \(p.total)")
                            Text(verbatim: "·")
                            Text(timerInterval: p.since...Date.distantFuture, countsDown: false)
                        }
                        .monospacedDigit()
                    }
                } else {
                    HStack(spacing: Space.m) {
                        ProgressView()
                        Text("Working out the steps from \(recorder.keyframes) screens…")
                    }
                }
            } else if let error = recorder.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.secondary)
                if recorder.canRetry {
                    Button(recorder.hasDraft ? "Review Draft" : "Create Draft Again") { Task { await recorder.retry() } }
                    Button("Discard Recording", role: .destructive) { Task { await recorder.cancel() } }
                } else {
                    Button("OK") { recorder.error = nil }
                }
            }
        } header: {
            Text("Recording")
        }
    }
}
