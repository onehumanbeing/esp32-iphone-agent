import SwiftUI

/// First-run setup: welcome + four screens (connect, see, act, brain). One thing per screen, the character
/// as the guide, animated demos for system settings, auto-advance when a step is detected, the main button
/// pinned at the bottom and "Later" on every step. Home's status chips open a single page directly.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var board: BoardLink
    @ObservedObject var feed: VideoFeed
    @ObservedObject var settings: Settings
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var pointer: Pointer
    let start: SetupPage
    @State private var page = SetupPage.welcome
    @State private var forward = true
    @State private var accepted = false
    @State private var onWiFi = false  // the user says they joined by hand
    @State private var testing = false

    init(app: AppModel, board: BoardLink, feed: VideoFeed, settings: Settings, calibrator: AutoCalibrator,
         pointer: Pointer, start: SetupPage) {
        self.app = app; self.board = board; self.feed = feed; self.settings = settings
        self.calibrator = calibrator; self.pointer = pointer; self.start = start
        _page = State(initialValue: start)
        _accepted = State(initialValue: settings.acceptedDisclaimer)
        _onWiFi = State(initialValue: app.hotspotSSID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                pageContent
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.xl)
                    .id(page)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }  // always pinned, whatever the page's height
        .background(Palette.grouped.ignoresSafeArea())
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: page)
        .onChange(of: page, initial: true) { _, now in Analytics.capture("setup_page", ["page": "\(now)"]) }
        .onChange(of: pageDone) { _, done in
            guard done, page != .welcome, page != .brain else { return }
            let from = page
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                if page == from { advance() }
            }
        }
    }

    // MARK: - chrome

    private var single: Bool { settings.onboarded }  // opened from a Home chip: just this page

    private var topBar: some View {
        HStack {
            if page != .welcome && !single {
                HStack(spacing: 6) {
                    ForEach(SetupPage.allCases.dropFirst()) { p in
                        Capsule().fill(p.rawValue <= page.rawValue ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                            .frame(width: p == page ? 22 : 8, height: 8)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Step \(page.rawValue) of 4"))
            }
            Spacer()
            if single || page != .welcome {
                Button(single ? "Done" : "Later") { later() }.fontWeight(single ? .semibold : .regular)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Space.xl)
    }

    private var bottomBar: some View {
        BottomBar {
            Button { primary() } label: {
                HStack(spacing: Space.s) {
                    if waiting { ProgressView().tint(primaryEnabled ? .white : .secondary) }
                    Text(primaryTitle)
                }
            }
            .buttonStyle(BigButton())
            .disabled(!primaryEnabled)
        }
    }

    private func advance() {
        forward = true
        if single || page == .brain { return finish() }
        if let next = SetupPage(rawValue: page.rawValue + 1) { page = next }
        Haptics.tick()
    }

    private func later() {
        if single || page == .brain { return finish() }
        advance()
    }

    private func finish() {
        Analytics.capture("setup_finished", ["last_page": "\(page)"])
        settings.acceptedDisclaimer = true
        settings.onboarded = true
        if MockMode.on { app.mockReady() }  // demo data: everything ready, even what was skipped
        app.setupPage = nil
    }

    // MARK: - per page state

    private var streaming: Bool { board.connected && board.status?.ap == "streaming" }

    /// The page's goal is reached (drives auto-advance).
    private var pageDone: Bool {
        switch page {
        case .welcome: return false
        case .connect: return board.connected
        case .see: return streaming
        case .act: return pointer.calibrated && !calibrator.busy
        case .brain: return app.modelOK == true
        }
    }

    /// Waiting on something the app detects by itself.
    private var waiting: Bool {
        switch page {
        case .connect: return !board.connected && (board.scanning || board.connecting || board.linking)
        case .see: return !streaming && (onHotspot || app.join.busy)
        case .act: return calibrator.busy
        case .brain: return testing
        default: return false
        }
    }

    /// The mouse and mirroring are up: calibration can run.
    private var actReady: Bool { MockMode.on || (calibrator.boardReady && calibrator.mirroring) }

    private var onHotspot: Bool { app.onBoardHotspot(manual: onWiFi) }

    private var primaryTitle: LocalizedStringKey {
        switch page {
        case .welcome: return "Get Started"
        case .connect: return board.connected ? "Continue" : waiting ? "Looking for the board…" : "Scan Again"
        case .see:
            if streaming { return "Continue" }
            if onHotspot { return "Waiting for mirroring…" }
            switch app.join {
            case .joining: return "Joining…"
            case .verifying: return "Checking…"
            case .failed: return "Try Again"
            default: return "Join the Board's Wi-Fi"
            }
        case .act:
            if pointer.calibrated { return "Continue" }
            if calibrator.busy { return "Calibrating…" }
            return actReady ? "Calibrate" : "Waiting for the mouse…"
        case .brain:
            if app.modelOK == true { return "Start Using ESP32 Agent" }
            return testing ? "Testing…" : "Test Connection"
        }
    }

    private var primaryEnabled: Bool {
        switch page {
        case .welcome: return accepted
        case .connect: return board.connected || (board.state == .poweredOn && !waiting)
        case .see: return streaming || (!onHotspot && !app.join.busy)
        case .act: return !calibrator.busy && (pointer.calibrated || actReady)
        case .brain: return !testing && (app.modelOK == true || app.modelReady)
        }
    }

    private func primary() {
        switch page {
        case .connect where !board.connected:
            board.retryDiscovery()
        case .see where !streaming:
            app.startJoin()
        case .act where !pointer.calibrated:
            calibrator.calibrate(why: String(localized: "first setup"))
        case .brain where app.modelOK != true:
            testing = true
            Task {
                await app.pingLLM()
                testing = false
                if app.modelOK == true { Haptics.success() }
            }
        default:
            advance()
        }
    }

    // MARK: - pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .welcome: WelcomePage(accepted: $accepted)
        case .connect: ConnectPage(board: board)
        case .see: SeePage(app: app, board: board, onWiFi: $onWiFi)
        case .act: ActPage(app: app, board: board, calibrator: calibrator, pointer: pointer)
        case .brain: BrainPage(app: app, settings: settings)
        }
    }
}

/// Title block shared by the pages: the character, a large title and one sentence.
struct PageHeader: View {
    let mood: Mood
    var look: CGPoint = .zero
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: Space.m) {
            PokeableFace(mood: mood, look: look).frame(width: 96, height: 108)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.l)
    }
}

/// A grouped, rounded container like an inset list section.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
    }
}

/// A row in a checklist: done, in progress (a spinner while the app waits for it) or to do, with an
/// optional line below.
struct CheckRow: View {
    let title: LocalizedStringKey
    let done: Bool
    var active = false
    var waiting = false
    var detail: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            ZStack {  // every state in the same box, as tall as the title's line, so it centres on the title
                if waiting && !done {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
                        .font(.title3)
                        .foregroundStyle(done ? Palette.ok : active ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                        .symbolEffect(.pulse, options: .repeating, isActive: active && !done)
                }
            }
            .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(active || waiting ? .semibold : .regular))
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding(.vertical, Space.xs)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: done)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: waiting)
    }
}
