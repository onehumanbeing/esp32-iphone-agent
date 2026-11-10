import SwiftUI

@main
enum AppEntry {
    /// The unit tests' host process: they build their own objects, so the app itself (Bluetooth, the video
    /// listener, analytics) stays off. UI tests launch the app normally, without this variable.
    static let hostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func main() {
        if hostingUnitTests { TestHostApp.main() } else { IPhoneAgentApp.main() }
    }
}

struct TestHostApp: App {
    var body: some Scene { WindowGroup { Color.clear } }
}

struct IPhoneAgentApp: App {
    @StateObject private var app = AppModel.shared

    init() {
        CrashTrace.install()
        _ = AppModel.shared  // also on a background launch for an App Intent, which shows no scene
        CrashReports.shared.start()
        Analytics.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app, settings: app.settings)
        }
    }
}

enum AppTab: Hashable { case agent, runs, settings }

/// The setup screens; Home's status chips open the one that fixes a problem.
enum SetupPage: Int, CaseIterable, Identifiable {
    case welcome, connect, see, act, brain
    var id: Int { rawValue }
}

struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.scenePhase) private var scene
    @AppStorage(RunShare.askedKey) private var privacyAsked = false
    @State private var consent = false

    var body: some View {
        TabView(selection: $app.tab) {
            HomeView(app: app, board: app.board, feed: app.feed, agent: app.agent, settings: settings,
                     intents: app.intents, recorder: app.recorder)
                .tabItem { Label("Agent", image: "AgentGlyph") }  // the character, not an SF smiley
                .tag(AppTab.agent)
            RunsView(app: app, runs: app.runs, agent: app.agent)
                .tabItem { Label("Runs", systemImage: "play.rectangle.on.rectangle") }
                .tag(AppTab.runs)
            SettingsView(app: app, settings: settings, board: app.board)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .alert(Text(verbatim: app.notice ?? ""), isPresented: Binding(get: { app.notice != nil }, set: { if !$0 { app.notice = nil } })) {
            Button("OK") {}
        }
        .confirmationDialog("Send diagnostics?", isPresented: $app.askDiagnostics, titleVisibility: .visible) {
            Button("Send") { Task { app.notice = await DiagnosticReport.send(app) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: DiagnosticReport.contents.map { "• " + $0 }.joined(separator: "\n"))
        }
        .fullScreenCover(item: $app.review) { draft in
            if draft.showSaveOnOpen {
                SaveIntentSheet(draft: draft, intents: app.intents) { app.review = nil }
            } else {
                ReviewView(draft: draft, app: app)
            }
        }
        .background {
            Color.clear.fullScreenCover(item: $app.setupPage) { page in
            OnboardingView(app: app, board: app.board, feed: app.feed, settings: settings, calibrator: app.calibrator,
                               pointer: app.pointer, start: page)
                .id(page)  // a fresh setup (its own page state) for every start page, e.g. "Run setup again"
            }
        }
        .background { Color.clear.sheet(isPresented: $consent, onDismiss: setUp) { ConsentSheet() } }
        .sheet(item: Binding(get: { app.aiConsentRun.map(PendingRun.init) }, set: { app.aiConsentRun = $0?.task })) { pending in
            SendConsentSheet(settings: settings, model: settings.pendingConsent.model, jev: settings.pendingConsent.jev) {
                Task { await app.startAgent(pending.task) }
            }
        }
        .onChange(of: scene) { old, new in DebugLog.write("scene: \(Self.name(old)) -> \(Self.name(new))") }
        .onAppear {
            if privacyAsked { setUp() } else { consent = true }  // what is kept, before setup
            app.probe.install(CalibrationOverlay(calibrator: app.calibrator, probe: app.probe, pointer: app.pointer))
        }
        .onOpenURL { url in
            if url.isFileURL && url.pathExtension.lowercased() == IntentArchive.fileExtension {  // shared intents
                app.importIntents(url)
                return
            }
            if url.isFileURL && url.pathExtension.lowercased() == "zip" {  // a shared run archive
                do { try app.importRuns(url) } catch { app.say("import: \(error.localizedDescription)") }
                return
            }
            if app.handleDebug(url) { return }  // iphoneagent://run?task=…, calibrate, stop, bench, snap
            // iphoneagent://run/<id> from the Live Activity
            guard url.scheme == "iphoneagent", url.host == "run" else { return }
            let id = url.lastPathComponent
            if id.hasPrefix("rec-") { return }  // a recording: its draft opens by itself
            if app.agent.running {
                app.live.opened()  // stale ("Paused by iOS — tap to continue"): the run sends the app away again
                app.tab = .agent
            } else { app.openReview(run: id) }
        }
    }

    private func setUp() {
        privacyAsked = true
        if !settings.onboarded && app.setupPage == nil { app.setupPage = .welcome }
    }
}

private struct PendingRun: Identifiable {
    let task: String
    var id: String { task }
}

extension RootView {
    static func name(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
