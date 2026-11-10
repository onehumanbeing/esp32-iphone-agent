import SwiftUI
import UniformTypeIdentifiers

/// The Agent tab: the character, what is ready, the task, saved intents, and Start pinned at the bottom.
struct HomeView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    let feed: VideoFeed  // not observed: a new frame re-renders only the run card's thumbnail
    @ObservedObject var agent: AgentLoop
    @ObservedObject var settings: Settings
    @ObservedObject var intents: IntentStore
    @ObservedObject var recorder: DemoRecorder
    @State private var task = ""
    @State private var shakes: CGFloat = 0  // the Start button shakes when a start couldn't go ahead
    @State private var recordSheet = false
    @State private var pendingReview: ReviewDraft?
    @State private var pendingSetup: SetupPage?
    @State private var importingIntents = false
    @State private var exportingIntents = false
    @State private var askNotifications = false
    @State private var pending: (String, SavedTask?)?
    @State private var naming = false
    @State private var intentName = ""
    @FocusState private var editing: Bool
    @State private var renaming = false
    @State private var pullingToRefresh = false
    @State private var showingDeleteError = false
    @State private var deleteError = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            List {
                if MockMode.on {
                    Section {
                        Label("Demo data is on: no board, no model, nothing is tapped or sent. Turn it off in Settings.", systemImage: "theatermasks")
                            .font(.footnote)
                    }
                }
                if !recorder.busy && recorder.error == nil {
                    Section { hero }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .id("agent-top")
                }
                if recorder.busy || recorder.error != nil { RecordingPanel(recorder: recorder).id("recording") }
                if app.help != nil { HelpPanel(app: app).id("agent-help") }
                if let stage = app.recovering { RecoveryPanel(app: app, stage: stage) }
                if !recorder.busy && !recorder.canRetry {
                    if agent.running || app.runMood != nil, let card = runCard { liveSection(card) }
                    taskSection
                    intentSection
                }
            }
            .onChange(of: agent.running) { _, running in
                if running { scroll.scrollTo("agent-top", anchor: .top) }
            }
            .onChange(of: app.help) { _, help in
                if help != nil { scroll.scrollTo("agent-help", anchor: .top) }
            }
            .onChange(of: recorder.recording) { _, recording in
                if recording { scroll.scrollTo("recording", anchor: .top) }
            }
            .listStyle(.insetGrouped)
            .refreshable {
                pullingToRefresh = true
                defer { pullingToRefresh = false }
                await app.refreshHomeStatus()
            }
            .overlay(alignment: .top) {
                if app.refreshingStatus && !pullingToRefresh {
                    ProgressView()
                        .accessibilityLabel(Text("Refreshing status…"))
                        .padding(.top, Space.s)
                        .allowsHitTesting(false)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(verbatim: settings.agentName))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in IntentDetailView(app: app, intents: intents, id: id) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { renaming = true } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: settings.agentName).font(.headline).foregroundStyle(.primary)
                            Image(systemName: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel(Text("Rename \(settings.agentName)"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recordSheet = true } label: {
                        Image(systemName: recorder.recording ? "record.circle.fill" : "record.circle")
                            .foregroundStyle(recorder.recording ? Color.red : Color.primary)
                            .symbolEffect(.pulse, options: .repeating, isActive: recorder.recording)
                    }
                    .accessibilityLabel(Text("New intent"))
                    .disabled(recorder.busy)
                }
            }
            .sheet(isPresented: $recordSheet, onDismiss: finishSourceSelection) {
                RecordSheet(app: app, recorder: recorder, board: board, agent: agent, runs: app.runs, settings: settings,
                            selectedRun: { run in
                                // This entry creates a new intent, even if the source run belonged to one.
                                pendingReview = ReviewDraft(run: run)
                                pendingReview?.showSaveOnOpen = true
                            }, selectedSetup: { pendingSetup = $0 })
            }
            .sheet(isPresented: $renaming) { RenameSheet(settings: settings) }
            .sheet(isPresented: $exportingIntents) { IntentExportSheet(app: app, intents: intents.items) }
            .modifier(FirmwareGate(app: app, updater: app.firmware, board: board, agent: agent, recorder: recorder))
            .fileImporter(isPresented: $importingIntents, allowedContentTypes: [.esp32Intent, .json]) { result in
                if case .success(let url) = result { app.importIntents(url) }
            }
            .alert("Get notified?", isPresented: $askNotifications) {
                Button("Continue") { Task { await app.notifier.requestPermission(); go() } }
                Button("Not Now", role: .cancel) { UserDefaults.standard.set(true, forKey: Notifier.askedKey); go() }
            } message: {
                Text("I'll tell you when a run is done or needs your help, since you won't see this app while I work. Before paying, sending a message or deleting anything I stop and ask you in a notification: press and hold it to answer.")
            }
            .overlay {
                if app.departing {
                    DepartureOverlay(problem: app.homeHint) {
                        Task { await app.stopAgent() }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let hint = app.homeHint, !app.departing {
                    Label { Text(verbatim: hint) } icon: { Image(systemName: "arrow.up.to.line") }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, Space.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: app.homeHint)
            .overlay(alignment: .topTrailing) {  // right under the record button
                if !agent.running && !app.startingAgent && !recorder.busy && !recorder.canRetry {
                    CalibrateButton(calibrator: app.calibrator, board: board, pointer: app.pointer)
                        .padding(.trailing, Space.l).padding(.top, Space.xs)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if recorder.recording { RecordingControls(recorder: recorder) }
                else if !app.departing && !recorder.busy && !recorder.canRetry { bottomBar }
            }
            .overlay(alignment: .bottom) {
                if let toast = app.toast {
                    ToastView(text: toast.text)
                        .padding(.bottom, 96)  // just above the Start button
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            try? await Task.sleep(nanoseconds: 3_500_000_000)
                            if app.toast?.id == toast.id { app.toast = nil }
                        }
                        .onTapGesture { app.toast = nil }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: app.toast)
            .onChange(of: app.toast) { _, toast in
                if toast != nil { withAnimation(.linear(duration: 0.4)) { shakes += 1 } }
            }
            .alert("Save as intent", isPresented: $naming) {
                TextField("Name", text: $intentName)
                Button("Save") { intents.add(name: intentName, prompt: task); Haptics.success() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Run it again later with one tap.")
            }
            .alert("Could not delete run", isPresented: $showingDeleteError) {} message: {
                Text(verbatim: deleteError)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: agent.running)
            }
        }
    }

    private func finishSourceSelection() {
        if let pendingReview { app.review = pendingReview; self.pendingReview = nil }
        if let pendingSetup { app.setupPage = pendingSetup; self.pendingSetup = nil }
    }

    // MARK: - hero

    private var hero: some View {
        VStack(spacing: Space.m) {
            FirmwareBanner(updater: app.firmware)
            PokeableFace(mood: editing ? .listening : app.mood, look: lookAt, busy: app.agent.running,
                         onInteract: { Task { await app.refreshHomeStatus() } })
                .frame(width: 128, height: 143)
                .padding(.top, Space.s)
            Text(greeting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            StatusChips(app: app, board: board, pointer: app.pointer, calibrator: app.calibrator)
            if !app.refreshingStatus, let error = app.statusRefreshError {
                Text(verbatim: error).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, Space.l)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Space.s)
    }

    /// Where the eyes look while acting: toward the last tap.
    private var lookAt: CGPoint {
        guard let s = agent.steps.last, let x = s["x"]?.double, let y = s["y"]?.double else { return .zero }
        return CGPoint(x: x / 500 - 1, y: y / 500 - 1)
    }

    private var greeting: LocalizedStringKey {
        if app.help != nil { return "I need your help with one step." }
        if app.recovering != nil { return "The connection dropped. I'll go on when it's back." }
        if recorder.recording { return "I'm watching. Do the task, then stop the recording." }
        if agent.running { return "Working on it. Watch the Dynamic Island, or stop me anytime." }
        switch app.runMood {
        case .success: return "Done! Open Runs to replay what I did."
        case .failure: return "That did not work out. The replay shows where I got stuck."
        default: break
        }
        if !board.connected { return "Plug me into the USB-C port to wake me up." }
        if blocker != nil { return "Almost there. Tap an orange item to finish setup." }
        return "Hi, I'm \(settings.agentName). Tell me what to do on this iPhone."
    }

    // MARK: - sections

    private var runCard: RunCardSnapshot? {
        RunCardSnapshot.select(running: agent.running, liveTask: agent.task, liveSteps: agent.steps,
                               liveFrame: feed.frame, storedRun: agent.running ? nil : app.runs.run(app.runID))
    }

    private func liveSection(_ card: RunCardSnapshot) -> some View {
        Section {
            HStack(alignment: .top, spacing: Space.m) {
                RunThumbnail(feed: feed, card: card)
                .frame(width: 64, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(verbatim: card.task).font(.headline).lineLimit(2)
                    if let last = card.lastStep {
                        Label { Text(verbatim: StepText.line(last)).lineLimit(3) } icon: {
                            Image(systemName: StepText.symbol(last["action"]?.str))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(min(card.moveCount, agent.maxSteps)), total: Double(agent.maxSteps))
                    Text("Step \(card.moveCount) of up to \(agent.maxSteps)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if !agent.running && app.canResume {  // stopped before done: go on from its screen
                        Button { Task { await app.resumeRun() } } label: { Label("Continue", systemImage: "play.fill") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            .padding(.vertical, Space.xs)
            .handsyRunAnnotation(liveRunID)  // Siri: "replay this one"
        } header: {
            HStack {
                Text(agent.running ? "Now" : "Last run")
                Spacer()
                if let run = card.storedRun, app.canDeleteRun(run) {
                    Menu("Last run options", systemImage: "ellipsis") {
                        Button("Delete run", systemImage: "trash", role: .destructive) {
                            do { try app.deleteRun(run) }
                            catch { deleteError = error.localizedDescription; showingDeleteError = true }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                }
            }
        }
    }

    /// The run this card is about: the one in progress, else the newest recorded one.
    private var liveRunID: String {
        if agent.running, !app.runID.isEmpty { return app.runID }
        return app.runs.runs.first { !$0.id.hasPrefix("rec-") }?.id ?? ""
    }

    private var taskSection: some View {
        Section {
            TextField(app.threads.current.turns.isEmpty ? "What should I do on this iPhone?" : "Reply, or give a new task",
                      text: $task, axis: .vertical)
                .lineLimit(3...6)
                .focused($editing)
                .submitLabel(.done)
            if !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { intentName = ""; naming = true } label: {
                    Label("Save as intent", systemImage: "bookmark")
                }
            }
        } header: {
            HStack {
                Text("Task")
                Spacer()
                Menu {
                    ForEach(IntentStore.examples) { e in
                        Button(e.name) { task = e.prompt; Haptics.tick() }
                    }
                } label: {
                    Label("Examples", systemImage: "sparkles").font(.footnote.weight(.semibold)).textCase(nil)
                }
            }
        }
    }

    private var intentSection: some View {
        Section {
            ForEach(intents.items) { item in
                NavigationLink(value: item.id) {
                    HStack(spacing: Space.m) {
                        SettingsIcon(symbol: item.symbol, color: .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.name).font(.body).foregroundStyle(.primary)
                            Text(verbatim: item.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { run(item) } label: {
                            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                                .opacity(blocker == nil && !agent.running ? 1 : 0.35)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Run \(item.name)"))
                    }
                }
                .contextMenu {
                    Button { task = item.prompt } label: { Label("Edit as task", systemImage: "pencil") }
                    Button(role: .destructive) { intents.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { intents.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if intents.items.isEmpty {
                Label("Use New Intent to record a demonstration or save a run.", systemImage: "record.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("My intents")
                Spacer()
                Menu {
                    Button { importingIntents = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    Button { exportingIntents = true } label: { Label("Export All…", systemImage: "square.and.arrow.up") }
                        .disabled(intents.items.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body)
                }
                .accessibilityLabel(Text("Import or export intents"))
            }
        } footer: {
            Text("Tap ▶ to run, tap the row for details. Swipe left to delete.")
        }
    }

    // MARK: - bottom

    private var bottomBar: some View {
        BottomBar {
            if app.stopping {  // Stop was tapped: wait for input to be handed back
                Button {} label: { Label("Stopping…", systemImage: "stop.fill") }
                    .buttonStyle(BigButton(tint: Palette.stop))
                    .disabled(true)
            } else if app.startingAgent {
                Button { Task { await app.stopAgent() } } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(BigButton(tint: Palette.stop))
            } else if agent.running {
                Button {
                    Haptics.stop()
                    Task { await app.stopAgent() }
                } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(BigButton(tint: Palette.stop))
            } else {
                Button { start(task) } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(BigButton())
                    .modifier(Shake(shakes: shakes))
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocker != nil
                              || app.departing || app.startingAgent || recorder.busy)
                if let blocker {
                    Button { app.setupPage = blocker.page } label: {
                        Label(blocker.text, systemImage: "exclamationmark.circle").font(.footnote)
                    }
                    .tint(Palette.warning)
                }
            }
        }
    }

    private func run(_ item: SavedTask) {
        if item.builtin != nil { return start(item.prompt, intent: item) }  // runs in the app, needs no setup
        task = item.prompt
        guard blocker == nil, !agent.running, !recorder.busy else { return }
        start(item.prompt, intent: item)
    }

    /// The first Start asks for notifications (one line why), then the character takes off.
    private func start(_ text: String, intent: SavedTask? = nil) {
        Haptics.start()
        editing = false
        pending = (text, intent)
        if Notifier.asked { go() } else { askNotifications = true }
    }

    private func go() {
        guard let (text, intent) = pending else { return }
        pending = nil
        Task { await app.run(text, intent: intent) }
    }

    /// The first thing missing before a run, and the setup page that fixes it.
    private var blocker: (text: LocalizedStringKey, page: SetupPage)? {
        if !board.connected { return ("Connect the board", .connect) }
        if board.status?.ap != "streaming" { return ("Start Screen Mirroring", .see) }
        if !app.pointer.calibrated { return ("Calibrate the pointer", .act) }
        if !app.modelReady { return ("Set up the model", .brain) }
        return nil
    }
}

/// Rename the agent (title, greeting, Live Activity).
struct RenameSheet: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).submitLabel(.done).onSubmit(save)
                } footer: {
                    Text("Shown on the Agent tab, in greetings and in the Live Activity.")
                }
            }
            .navigationTitle("Rename Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear { name = settings.agentName }
        }
        .presentationDetents([.height(240)])
    }

    private func save() {
        settings.agentName = name
        dismiss()
    }
}

/// The run card's screen: the live frame while a run goes, else the run's cover. Its own view, so each new frame
/// re-renders only this thumbnail, and decodes nothing while the app is in the background.
private struct RunThumbnail: View {
    @ObservedObject var feed: VideoFeed
    let card: RunCardSnapshot
    @Environment(\.scenePhase) private var phase

    var body: some View {
        if let img = image {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            Color(uiColor: .tertiarySystemFill)
        }
    }

    private var image: UIImage? {
        guard card.storedRun == nil else { return card.cover.flatMap { UIImage(contentsOfFile: $0.path) } }
        guard phase != .background else { return nil }
        return (feed.frame ?? card.frame).flatMap { UIImage(data: $0) }
    }
}
