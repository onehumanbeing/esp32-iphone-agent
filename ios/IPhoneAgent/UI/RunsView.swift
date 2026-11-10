import SwiftUI
import UniformTypeIdentifiers

/// The Runs tab: every run as a row with its last screen, outcome, steps and time; tap to replay.
struct RunsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var runs: RunStore
    @ObservedObject var agent: AgentLoop
    @State private var importing = false
    @State private var importError: String?
    @State private var showingDeleteError = false
    @State private var deleteError = ""

    var body: some View {
        NavigationStack {
            List {
                if runs.runs.isEmpty {
                    EmptyState(mood: .idle, title: "No runs yet",
                               message: "Every run is recorded here step by step, so you can replay what I did.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(runs.runs) { run in
                            Button { app.openReview(run: run.id) } label: { RunRow(run: run, running: isRunning(run)) }
                                .buttonStyle(.plain)
                                .deleteDisabled(!app.canDeleteRun(run))
                                .handsyRunAnnotation(run.id)  // Siri: "replay this one"
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Runs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import run", systemImage: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                do { try app.importRuns(result.get()) } catch { importError = error.localizedDescription }
            }
            .alert("Could not import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(verbatim: importError ?? "") }
            .alert("Could not delete run", isPresented: $showingDeleteError) {} message: {
                Text(verbatim: deleteError)
            }
            .refreshable { runs.reload() }
            .onAppear { runs.reload() }
        }
    }

    private func isRunning(_ run: Run) -> Bool {
        app.outcome(for: run) == .running
    }

    private func delete(at offsets: IndexSet) {
        let selected = offsets.map { runs.runs[$0] }
        do { for run in selected { try app.deleteRun(run) } }
        catch { deleteError = error.localizedDescription; showingDeleteError = true }
    }
}

struct RunRow: View {
    let run: Run
    var running = false

    var body: some View {
        HStack(spacing: Space.m) {
            if DeviceKind.isPad { Thumb(url: run.cover, fitted: true) } else { Thumb(url: run.cover).frame(width: 52, height: 112) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: run.task.isEmpty ? String(localized: "Untitled run") : run.task)
                    .font(.headline).lineLimit(2)
                if run.imported {
                    Label("Imported", systemImage: "square.and.arrow.down").foregroundStyle(.secondary)
                } else {
                    OutcomeLabel(outcome: running ? .running : run.outcome)
                }
                if let result = run.result {
                    Text(verbatim: result).font(.subheadline).lineLimit(2)
                }
                Text(details).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title).foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the replay"))
    }

    private var details: String {
        run.stats + " · " + run.date.formatted(.relative(presentation: .named))
    }
}

struct OutcomeLabel: View {
    let outcome: Outcome

    var body: some View {
        switch outcome {
        case .running: Label("Running", systemImage: "circle.dotted").foregroundStyle(Color.accentColor)
        case .done: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        case .failed: Label("Failed", systemImage: "xmark.circle.fill").foregroundStyle(Palette.stop)
        case .stopped: Label("Stopped", systemImage: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// A screenshot from disk, phone-shaped.
struct Thumb: View {
    let url: URL?
    /// iPad: shown whole at its own aspect ratio, 112 pt tall and at most 160 pt wide, so a landscape screenshot is
    /// neither cropped nor spills over the row. Otherwise it fills the frame the caller gives it.
    var fitted = false

    var body: some View {
        let image = url.flatMap { UIImage(contentsOfFile: $0.path) }
        if fitted {
            let size = Self.fitted(image?.size)
            content(image, fill: false).frame(width: size.width, height: size.height)
        } else {
            content(image, fill: true)
        }
    }

    private func content(_ image: UIImage?, fill: Bool) -> some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable() }
            } else {
                Color(uiColor: .tertiarySystemFill)
                    .overlay(Image(systemName: DeviceKind.isPad ? "ipad" : "iphone").foregroundStyle(.tertiary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }

    /// The image's size at 112 pt tall, or at 160 pt wide if that is narrower; phone-shaped with no image.
    static func fitted(_ image: CGSize?) -> CGSize {
        let aspect = image.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 52 / 112
        let width = min(112 * aspect, 160)
        return CGSize(width: width, height: width / aspect)
    }
}
