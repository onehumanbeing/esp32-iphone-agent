import SwiftUI

/// Intent detail: its last runs (tap to review) and the files those runs saved (RunOutputs).
struct IntentRunsSection: View {
    @ObservedObject var app: AppModel
    let item: SavedTask
    @State private var files: [String] = []
    @State private var open: RunOutput?
    private static let shown = 5

    var body: some View {
        let runs = Array(item.runs.reversed())
        if !runs.isEmpty {
            Section {
                ForEach(runs.prefix(Self.shown), id: \.run) { stat in
                    IntentRunRow(app: app, stat: stat)
                }
                if runs.count > Self.shown {
                    NavigationLink {
                        List { ForEach(runs, id: \.run) { IntentRunRow(app: app, stat: $0) } }
                            .navigationTitle(Text(verbatim: item.name))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text("All Runs (\(runs.count))")
                    }
                }
            } header: {
                Text("Runs")
            }
            .task(id: item.runs.last?.run) { files = outputs(runs) }
            if !files.isEmpty {
                Section("Files") {
                    ForEach(files, id: \.self) { file in
                        Button { open = RunOutput(item: file) } label: { RunOutputLabel(item: file) }
                            .foregroundStyle(.primary)
                    }
                }
                .sheet(item: $open) { output in
                    NavigationStack {
                        RunOutputPage(app: app, item: output.item)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { open = nil } } }
                    }
                }
            }
        }
    }

    /// What the last 20 runs saved, newest first, at most 10.
    private func outputs(_ runs: [RunStat]) -> [String] {
        var out: [String] = []
        for stat in runs.prefix(20) {
            guard let run = app.runs.run(stat.run) else { continue }
            for item in RunOutputs.items(run) where !out.contains(item) { out.append(item) }
            if out.count >= 10 { break }
        }
        return Array(out.prefix(10))
    }
}

/// One past run of an intent: ✓/✗, when, how long; a tap opens its review.
struct IntentRunRow: View {
    @ObservedObject var app: AppModel
    let stat: RunStat

    var body: some View {
        Button { app.openReview(run: stat.run) } label: {
            HStack(spacing: Space.s) {
                Image(systemName: stat.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(stat.ok ? Palette.ok : Palette.stop)
                Text(verbatim: stat.date.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 0)
                Text(verbatim: stat.seconds.durationText).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .foregroundStyle(.primary)
    }
}
