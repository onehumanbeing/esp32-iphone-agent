import SwiftUI

/// Select a source; the parent presents its destination after this sheet dismisses.
struct RecordSheet: View {
    @ObservedObject var app: AppModel
    @ObservedObject var recorder: DemoRecorder
    @ObservedObject var board: BoardLink
    @ObservedObject var agent: AgentLoop
    @ObservedObject var runs: RunStore
    @ObservedObject var settings: Settings
    let selectedRun: (Run) -> Void
    let selectedSetup: (SetupPage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize

    private var blocker: (String, SetupPage?)? {
        if recorder.busy { return (String(localized: "Finish the current recording first."), nil) }
        if recorder.canRetry { return (String(localized: "Retry or discard the unfinished recording on the Agent tab."), nil) }
        if agent.running || app.startingAgent { return (String(localized: "Wait for the current task to finish."), nil) }
        if !board.connected { return (String(localized: "Connect the board"), .connect) }
        if board.status?.ap != "streaming" { return (String(localized: "Start Screen Mirroring"), .see) }
        if !app.modelReady { return (String(localized: "Set up the model"), .brain) }
        return nil
    }

    private var lastRun: Run? { runs.runs.first { !$0.imported && !$0.steps.isEmpty } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: record) {
                        IntentSourceRow(title: "Record me doing it", symbol: "record",
                                        detail: "Do the task yourself after a 5-second countdown.")
                    }
                    .disabled(blocker != nil)
                    if let blocker, let page = blocker.1 {
                        Button { selectedSetup(page); dismiss() } label: {
                            HStack {
                                Text(verbatim: blocker.0)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    if let blocker, blocker.1 == nil {
                        Text(verbatim: blocker.0)
                    } else if let error = recorder.error, !recorder.canRetry {
                        Text(verbatim: error)
                    } else {
                        Text("Steps are worked out from screen changes, not touches. Check the uncertain ones before saving.")
                    }
                }
                Section {
                    Button(action: saveRun) {
                        IntentSourceRow(title: "Save last run as intent", symbol: "bookmark",
                                        detail: "Turn your latest run into a reusable task.")
                    }
                    .disabled(lastRun == nil || agent.running || app.startingAgent || recorder.busy)
                } footer: {
                    if lastRun == nil { Text("Run a task first, then save it here.") }
                }
            }
            .contentMargins(.top, Space.s, for: .scrollContent)
            .navigationTitle("New Intent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { runs.reload() }
        }
        .tint(.primary)  // monochrome sheet: no accent color
        .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.height(420), .large])
    }

    private func record() {
        if recorder.start() { dismiss() }
    }

    private func saveRun() {
        guard let lastRun else { return }
        selectedRun(lastRun)
        dismiss()
    }
}
