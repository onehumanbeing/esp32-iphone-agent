import SwiftUI

/// Review and editor, one screen for a finished run, a demonstration and an intent: media on top (step
/// screenshots with overlays, or the run video), the timeline below, and per step ✓ / ✗, Fix, Insert after,
/// Delete and Re-run from here. "Optimize with AI" and "Save as Intent" are pinned at the bottom.
struct ReviewView: View {
    @ObservedObject var draft: ReviewDraft
    @ObservedObject var app: AppModel
    @ObservedObject var agent: AgentLoop
    @ObservedObject var runs: RunStore

    init(draft: ReviewDraft, app: AppModel) {
        self.draft = draft
        self.app = app
        self.agent = app.agent
        self.runs = app.runs
    }

    private var outcome: Outcome? {
        guard let id = draft.runID, let run = runs.run(id) else { return draft.outcome }
        return app.outcome(for: run)
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var playing = false
    @State private var speed = 1.0
    @State private var showVideo = false
    @State private var videoTime = 0.0
    @State private var expanded = false
    @State private var fixing: DraftStep?
    @State private var inserting = false
    @State private var insertText = ""
    @State private var saving = false
    @State private var optimizing = false
    @State private var shareURL: URL?
    @State private var retrying = false
    @State private var retryError: String?

    private var steps: [DraftStep] { draft.steps }
    private var step: DraftStep? { steps.indices.contains(index) ? steps[index] : nil }
    @State private var video: [(url: URL, t: Double)] = []

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if outcome == .running {
                VStack(spacing: Space.s) {
                    ProgressView()
                    Text(verbatim: app.recovering?.status.full ?? app.homeHint
                         ?? String(localized: "The run is still active. Return to the Home Screen to continue."))
                        .font(.subheadline).multilineTextAlignment(.center)
                    if !app.startingAgent {
                        Button("Stop", systemImage: "stop.fill") { Task { await app.stopAgent() } }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(Space.l)
            }
            if outcome == .failed {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label("Could not finish", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(verbatim: failureMessage).font(.subheadline)
                    if failureMessage != failureReason {
                        DisclosureGroup("Error details") {
                            Text(verbatim: failureReason).font(.caption).textSelection(.enabled)
                        }
                    }
                    if let retryError {
                        Text(verbatim: retryError).font(.subheadline).foregroundStyle(Palette.stop)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.xl).padding(.vertical, Space.s)
            }
            if outcome == .done, let result = draft.runID.flatMap({ runs.run($0) })?.result {
                ResultCard(text: result)
            }
            if steps.isEmpty {
                if outcome == .running { Spacer() }
                else { IntentWordsView(draft: draft) }
            } else {
                if !video.isEmpty {
                    Picker("View", selection: $showVideo) {
                        Text("Steps").tag(false)
                        Text("Video").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.xs)
                }
                if DeviceKind.isPad {  // iPad: side by side in landscape (an iPhone is always portrait)
                    GeometryReader { g in padContent(columns: g.size.width > g.size.height) }
                } else if showVideo && !video.isEmpty {  // continuous video, scrubbed in seconds
                    RunVideoView(frames: video, time: videoTime, caption: step.map { StepText.title($0.action) })
                    VideoScrubber(start: video[0].t, end: video[video.count - 1].t, time: $videoTime, playing: $playing)
                        .padding(.horizontal, Space.xl)
                    controls
                } else {  // one screenshot per step, with its action drawn on it
                    media
                    stepCard
                    ReviewTimeline(steps: steps, index: $index, playing: $playing).padding(.horizontal, Space.xl)
                    controls
                }
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { if !draft.readOnly && outcome != .running { bottomBar } }
        .task(id: [playing, showVideo]) { await autoplay() }
        .onChange(of: showVideo) { playing = false }
        .onChange(of: videoTime) { _, t in  // the step follows the video
            guard showVideo, let i = steps.lastIndex(where: { ($0.t ?? 0) <= t }), i != index else { return }
            index = i
        }
        .onChange(of: index) { _, i in
            Haptics.tick()
            if !playing, let t = steps[safe: i]?.t { videoTime = t }
        }
        .onAppear {
            video = draft.runID.flatMap { app.runs.run($0) }?.video ?? []
            videoTime = steps.first?.t ?? 0
            if let firstUnsure = steps.firstIndex(where: \.uncertain) { index = firstUnsure }
        }
        .alert("Could not save changes", isPresented: Binding(get: { draft.persistenceError != nil }, set: { if !$0 { draft.persistenceError = nil } })) {
            Button("Try Again") { draft.saveEdits() }
            Button("Cancel", role: .cancel) { draft.persistenceError = nil }
        } message: { Text(verbatim: draft.persistenceError ?? "") }
        .sheet(item: $fixing) { s in FixSheet(draft: draft, step: s) }
        .sheet(isPresented: $saving) { SaveIntentSheet(draft: draft, intents: app.intents) { app.recorder.markSaved(draft); dismiss() } }
        .sheet(isPresented: $optimizing) { OptimizeSheet(draft: draft, app: app) }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
        .alert("Insert a step", isPresented: $inserting) {
            TextField("e.g. Tap Save at the top right", text: $insertText)
            Button("Insert") {
                draft.insert(after: step?.id, text: insertText)
                index = min(index + 1, steps.count - 1)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Describe what should happen after this step.")
        }
    }

    // MARK: - top

    private var topBar: some View {
        HStack(spacing: Space.m) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 32)).symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .tint(.secondary)
            .accessibilityLabel(Text("Close"))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: draft.title).font(.headline).lineLimit(1)
                subtitle.font(.caption)
            }
            Spacer()
            Menu {
                if let folder = draft.folder {
                    Button { shareURL = try? TraceStore.zip(folder) } label: {
                        Label("Export trace", systemImage: "square.and.arrow.up")
                    }
                }
                Button { inserting = true; insertText = "" } label: { Label("Add a step at the end", systemImage: "plus") }
                if resumable {
                    Button(action: retryRun) { Label("Start Over", systemImage: "arrow.clockwise") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }

    @ViewBuilder private var subtitle: some View {
        switch draft.source {
        case .recording: Label("Demonstration · check the yellow steps", systemImage: "record.circle").foregroundStyle(.secondary)
        case .intent:
            if let o = outcome { OutcomeLabel(outcome: o) }
            else { Label("Intent", systemImage: draft.icon).foregroundStyle(.secondary) }
        case .run:
            if draft.readOnly { Label("Imported", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
            else if let o = outcome { OutcomeLabel(outcome: o) }
        }
    }

    // MARK: - media and step

    private var media: some View {
        TabView(selection: $index) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                StepFrame(step: s, active: i == index).tag(i).padding(.horizontal, Space.l)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// iPad: the iPhone's column, or in landscape the screenshot (or video) on the left and the step, timeline and
    /// controls on the right, so the wide screenshot isn't squeezed into a strip above them.
    @ViewBuilder private func padContent(columns: Bool) -> some View {
        let videoView = showVideo && !video.isEmpty
        if columns {
            HStack(spacing: 0) {
                if videoView {
                    VStack(spacing: 0) {
                        RunVideoView(frames: video, time: videoTime, caption: step.map { StepText.title($0.action) })
                        VideoScrubber(start: video[0].t, end: video[video.count - 1].t, time: $videoTime, playing: $playing)
                            .padding(.horizontal, Space.xl)
                            .padding(.bottom, Space.xs)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    controls.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    media.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            stepCard
                            ReviewTimeline(steps: steps, index: $index, playing: $playing).padding(.horizontal, Space.xl)
                            controls
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(spacing: 0) {
                if videoView {
                    RunVideoView(frames: video, time: videoTime, caption: step.map { StepText.title($0.action) })
                    VideoScrubber(start: video[0].t, end: video[video.count - 1].t, time: $videoTime, playing: $playing)
                        .padding(.horizontal, Space.xl)
                } else {
                    media
                    stepCard
                    ReviewTimeline(steps: steps, index: $index, playing: $playing).padding(.horizontal, Space.xl)
                }
                controls
            }
        }
    }

    @ViewBuilder private var stepCard: some View {
        if let step {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Image(systemName: StepText.symbol(step.name)).foregroundStyle(.secondary)
                    Text(verbatim: StepText.title(step.action)).font(.headline).lineLimit(1)
                    if step.uncertain {
                        Label("Unsure", systemImage: "questionmark.circle").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow.opacity(0.35)))
                    }
                    Spacer()
                }
                if let thought = step.action["thought"]?.str ?? step.action["plan"]?.str ?? step.action["reason"]?.str {
                    Text(verbatim: thought).font(.subheadline).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                        .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() } }
                }
                if !step.note.isEmpty {
                    Label { Text(verbatim: step.note) } icon: { Image(systemName: "pencil.line") }
                        .font(.subheadline).foregroundStyle(Palette.ok)
                }
                if expanded { StepDetails(step: step) }
                if !draft.readOnly { stepActions(step) }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
    }

    /// Was this step right? Wrong opens the fix at once: where it should have tapped, or what should have happened.
    private func stepActions(_ step: DraftStep) -> some View {
        HStack(spacing: Space.s) {
            VerdictChip(title: "Correct", symbol: "hand.thumbsup", on: step.verdict == true, tint: Palette.ok) {
                draft.mark(step.id, true)
            }
            VerdictChip(title: "Wrong", symbol: "hand.thumbsdown", on: step.verdict == false, tint: Palette.stop) {
                let fix = step.verdict != false
                draft.mark(step.id, false)
                if fix { fixing = step }
            }
            Spacer()
            Menu {
                Button { fixing = step } label: { Label("Correct This Step…", systemImage: "scope") }
                Button { inserting = true; insertText = "" } label: { Label("Add a Step After", systemImage: "plus") }
                if draft.source != .recording {
                    Button { rerun(from: step) } label: { Label("Re-run from Here", systemImage: "arrow.clockwise") }
                }
                Button(role: .destructive) {
                    draft.delete(step.id)
                    index = min(index, max(0, steps.count - 1))
                } label: { Label("Delete Step", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").font(.subheadline.weight(.semibold)).frame(width: 36, height: 32)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
            }
            .accessibilityLabel(Text("More"))
        }
    }

    private var controls: some View {
        HStack {
            Menu {
                Picker("Speed", selection: $speed) {
                    Text(verbatim: "0.5×").tag(0.5)
                    Text(verbatim: "1×").tag(1.0)
                    Text(verbatim: "2×").tag(2.0)
                }
            } label: {
                Text(verbatim: speed == 0.5 ? "0.5×" : speed == 2 ? "2×" : "1×")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(width: 52, height: 32)
                    .background(Capsule().fill(Palette.surface))
            }
            .accessibilityLabel(Text("Playback speed"))
            Spacer()
            if videoMode {
                Button { seek(-5) } label: { Image(systemName: "gobackward.5") }.accessibilityLabel(Text("Back 5 seconds"))
            } else {
                Button { go(-1) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(index == 0).accessibilityLabel(Text("Previous step"))
            }
            Button {
                if videoMode {
                    if videoTime >= video[video.count - 1].t { videoTime = video[0].t }
                } else if index >= steps.count - 1 { index = 0 }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
            }
            .padding(.horizontal, Space.m)
            .accessibilityLabel(Text(playing ? "Pause" : "Play"))
            if videoMode {
                Button { seek(5) } label: { Image(systemName: "goforward.5") }.accessibilityLabel(Text("Forward 5 seconds"))
            } else {
                Button { go(1) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(index >= steps.count - 1).accessibilityLabel(Text("Next step"))
            }
            Spacer()
            Text(verbatim: "\(index + 1)/\(steps.count)")
                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52)
        }
        .font(.title3)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.xs)
    }

    private func go(_ d: Int) {
        playing = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { index = max(0, min(steps.count - 1, index + d)) }
    }

    private var videoMode: Bool { showVideo && !video.isEmpty }

    private func seek(_ seconds: Double) {
        playing = false
        videoTime = min(max(videoTime + seconds, video[0].t), video[video.count - 1].t)
    }

    private func autoplay() async {
        if videoMode { return await playVideo() }
        while playing && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(1_200_000_000 / speed))
            guard playing, !Task.isCancelled else { return }
            if index >= steps.count - 1 { playing = false; return }
            withAnimation(reduceMotion ? .none : .spring(response: 0.45, dampingFraction: 0.9)) { index += 1 }
        }
    }

    /// Video view: a clock runs at real time (times the speed); the frame and the step follow it.
    private func playVideo() async {
        guard let end = video.last?.t else { return }
        var last = now()
        while playing && !Task.isCancelled && videoTime < end {
            try? await Task.sleep(nanoseconds: 66_000_000)  // ~15 fps of clock; frames change at their own times
            guard playing else { return }
            videoTime = min(end, videoTime + (now() - last) * speed)
            last = now()
        }
        playing = false
    }

    // MARK: - bottom

    /// One filled button: Continue when the run can go on from its screen, else Retry; the rest tinted.
    private var bottomBar: some View {
        BottomBar {
            VStack(spacing: Space.s) {
                if resumable {
                    Button("Continue from Here", systemImage: "play.fill") {
                        guard let run = currentRun else { return }
                        dismiss(); Task { await app.resumeRun(run) }
                    }
                        .buttonStyle(BigButton())
                    Text("Then switch back to the app it was in.").font(.footnote).foregroundStyle(.secondary)
                } else if retryable {
                    Button("Retry", systemImage: "arrow.clockwise", action: retryRun)
                        .buttonStyle(BigButton())
                        .disabled(retrying || app.startingAgent || app.agent.running || app.recorder.busy)
                    if retrying { ProgressView("Reconnecting…") }
                }
                HStack(spacing: Space.m) {
                    Button { optimizing = true } label: { Label("Optimize with AI", systemImage: "sparkles") }
                    Button { saving = true } label: {
                        Label(draft.intentID == nil ? "Save as Intent" : "Save Intent", systemImage: "bookmark")
                    }
                }
                .buttonStyle(BigButton.tinted)
            }
        }
    }

    /// A stopped or failed run: it can go on from the screen in front.
    private var resumable: Bool { !draft.readOnly && currentRun.map(app.canResume) == true }
    private var currentRun: Run? { draft.runID.flatMap { runs.run($0) } }
    private var retryable: Bool { draft.runID != nil && (outcome == .failed || outcome == .stopped) }

    private func retryRun() {
        guard !retrying, !app.startingAgent, !app.agent.running, !app.recorder.busy,
              let id = draft.runID, let run = app.runs.run(id) else { return }
        let intent = app.intents.item(draft.intentID)
        playing = false
        retrying = true
        retryError = nil
        Task {
            defer { retrying = false }
            do {
                try await app.board.refreshStatus()
                dismiss()
                await app.run(run.task, intent: intent)
            } catch {
                retryError = error.localizedDescription
            }
        }
    }

    private var failureReason: String {
        steps.last(where: { $0.name == "error" || $0.name == "fail" })?.action["reason"]?.str
            ?? String(localized: "The run ended before it could finish. Retry to start again.")
    }

    private var failureMessage: String {
        if failureReason.contains("board link lost") || failureReason.contains("board disconnected") {
            return String(localized: "The board connection was lost. Move the board closer and keep it powered on, then tap Retry.")
        }
        return failureReason
    }

    private func rerun(from step: DraftStep) {
        let intent = app.intents.item(draft.intentID)
        let task = draft.prompt + "\n\n" + String(localized: "Start from this step: \(StepText.title(step.action)). The steps before it are already done.")
        dismiss()
        Task { await app.run(task, intent: intent) }
    }
}

/// THINK / DO / CHANGED / TIME of one step.
struct StepDetails: View {
    let step: DraftStep

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Divider().padding(.vertical, Space.xs)
            if let t = step.action["thought"]?.str { row("THINK", t) }
            row("DO", PyJSON.dumps(Actions.key(step.action).without(["plan", "plan_zh"]), ascii: false))
            if let c = step.action["changed"]?.bool { row("CHANGED", c ? "yes" : "no") }
            let think = step.action["think_s"]?.double, act = step.action["act_s"]?.double
            if think != nil || act != nil {
                row("TIME", [think.map { String(format: "model %.1f s", $0) }, act.map { String(format: "action %.1f s", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(verbatim: key).font(.caption2.weight(.bold).monospaced()).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

/// A labeled yes/no answer for a step; filled with its color once chosen.
struct VerdictChip: View {
    let title: LocalizedStringKey
    let symbol: String
    let on: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button { action(); Haptics.tick() } label: {
            Label(title, systemImage: on ? symbol + ".fill" : symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, Space.m).frame(height: 32)
                .foregroundStyle(on ? tint : .secondary)
                .background(Capsule().fill(on ? tint.opacity(0.15) : Color(uiColor: .tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
