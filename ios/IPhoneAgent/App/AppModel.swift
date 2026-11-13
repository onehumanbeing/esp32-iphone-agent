import Combine
import Foundation
import UIKit

/// Wires the board, the screen feed, the pointer, the agent and the metrics together.
@MainActor final class AppModel: ObservableObject {
    /// One per process: the UI, App Intents (also when iOS launches the app in the background) and widgets use it.
    static let shared = AppModel()

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    let settings = Settings()
    let board = BoardLink(mock: MockMode.on)
    let feed = VideoFeed()
    private var lastVideoToken: String?
    private var lastNetRead = 0.0
    let wifiVideo: WifiVideoLink = VideoTransport.current.init()  // video over the board's Wi-Fi; BLE carries it while this is down
    let audio = AudioFeed()  // AirPlay audio over that link, transcribed on the phone (Settings › Listen to phone audio)
    private var hearSent: Bool?  // last `hear on|off` the board got on this link
    let metrics = Metrics()
    let traces = MockMode.on
        ? TraceStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("demo-traces"))
        : TraceStore()
    let intents = IntentStore()
    private(set) lazy var runs = RunStore(traces: traces)
    private(set) lazy var threads = ThreadStore()
    let pointer: Pointer
    let agent: AgentLoop
    @Published private(set) var log: [LogLine] = []
    @Published var refreshingStatus = false
    @Published var statusRefreshError: String?
    private var lastStatusRefresh = 0.0
    @Published var modelError: String?
    @Published var modelTestStarted: Date?
    @Published var modelTestSeconds: Double?
    @Published var modelFirstTokenSeconds: Double?
    @Published var modelResponseSeconds: Double?
    @Published var modelOK: Bool?  // last LLM ping result
    @Published var hotspotSSID: String?
    @Published var otherWiFi: String?  // the phone is on this network, not the board's
    /// The character's mood during and right after a run; nil = resting (idle or sleeping, see `mood`).
    @Published var runMood: Mood?
    @Published var tab = AppTab.agent
    /// Setup page to show (onboarding, or a Home status chip deep link); nil = hidden.
    @Published var setupPage: SetupPage?
    /// Store builds: a run was started before the user agreed to the AI service; Agree starts it.
    @Published var aiConsentRun: String?
    /// The review editor on screen (after a run, a recording, or editing an intent).
    @Published var review: ReviewDraft?
    /// Paused for the user: why (nil = not paused), and whether they are doing it by hand right now.
    @Published var help: String?
    @Published var recovering: Recovery.Stage?  // the run is paused for a lost link (board, hotspot, mirroring)
    var recoverySince = Date()
    @Published var takingOver = false
    @Published var paused = false  // Pause on the Dynamic Island: the run holds before its next look
    @Published var startingAgent = false
    @Published var notice: String?  // a one-off message, e.g. how many intents a file added
    @Published var askDiagnostics = false  // "Send diagnostics?" from a trouble notification
    /// A short line over Home when Start can't go ahead (the free line is busy, …); the Start button shakes.
    @Published var toast: Toast?
    struct Toast: Equatable { let id = UUID(); let text: String }
    @Published var departing = false  // the character's take-off before a run
    @Published var quickAsk = false  // QuickAskSheet: the island's New Task, the Control Center control
    var startupTask: Task<Void, Never>?
    var returningInput = false
    @Published var stopping = false  // Stop was tapped; input is being handed back
    var handoffStop = AsyncStream<Void>.makeStream()
    var lastPartialReleaseNoticeLink: Int?
    var runModelRevision = 0
    var startupBoardIssue = false
    var startupDeadline = 0.0
    var backgroundEnteredAt = 0.0
    /// Whether the app is in the background (tests stand in for UIKit's application state).
    var isBackground: () -> Bool = { UIApplication.shared.applicationState == .background }
    var linkRecoveryDisplay: Recovery?
    var lastRunDoing: AgentLoop.Doing?
    /// A banner on Home: the app could not leave by itself (swipe up), or the run waits while the app is in front.
    /// Published only when it changes: wait loops set the same line many times a second, also in the background,
    /// and every change notice re-renders the whole app on the main thread.
    var homeHint: String? {
        get { shownHomeHint }
        set {
            probeCounts.hintWrites += 1
            guard newValue != shownHomeHint else { return }
            probeCounts.hintChanges += 1
            shownHomeHint = newValue
        }
    }
    @Published private var shownHomeHint: String?
    /// Counts behind the once-a-minute background summary (BackgroundProbe.swift).
    var probeCounts = BackgroundCounters()
    private var backgroundSummary = MinuteSummary()
    private var noticeSink: AnyCancellable?
    var resumeAsked = 0.0  // when Continue was tapped in the app
    /// Text the agent's `write` wants on the clipboard; written the next time the app is in front (ClipboardHop).
    var pendingClipboard: String?
    var clipboardWritten = false
    let live = LiveActivityController()
    let notifier = Notifier()
    private(set) lazy var recorder = DemoRecorder(app: self)
    private(set) lazy var firmware = FirmwareUpdater(app: self)
    var mockJob: Task<Void, Never>?
    @Published var mockMirroring = false
    var moodReset: Task<Void, Never>?
    var helpWait: CheckedContinuation<AgentLoop.HelpChoice, Never>?
    var currentIntent: SavedTask?
    var lastTask = ""
    var runStarted = Date()
    var runUsage = ModelUsage()
    private var settingsSink: AnyCancellable?
    var videoSink: AnyCancellable?
    var videoDir: URL?
    private(set) lazy var calibrator = AutoCalibrator(app: self)
    let probe = TouchProbe()
    private var lastStatus = ""
    private var lastBoardBoot = 0.0
    private var lastTick = now()
    private var lastStreamLog = 0.0
    private var timers: [Task<Void, Never>] = []
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The idle pre-warm (stream on + one snap for an IDR); a starting run waits for it before its first frame.
    var prewarmJob: Task<Void, Never>?
    static let prewarmKey = "prewarmStream"
    static var prewarmOn: Bool { UserDefaults.standard.object(forKey: prewarmKey) as? Bool ?? true }
    var lastWidgetReload = 0.0

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        pointer = Pointer(device: board.commands, calibrationFile: support.appendingPathComponent("calibration.json"),
                          screen: feed)
        agent = AgentLoop(phone: pointer, screen: feed, actor: nil, planner: nil, trace: traces)
        PhoneMouse.start()
        agent.metrics = metrics
        agent.island = { DeviceScreen.island }
        agent.heard = { [weak self] in self?.audio.heard() ?? "" }
        feed.device = board.commands
        feed.metrics = metrics

        let say: (String) -> Void = { [weak self] in self?.say($0) }
        board.log = say
        board.commands.log = say
        pointer.log = say
        pointer.screenAspect = { DeviceScreen.aspect }
        pointer.locate = { [weak self] jpeg in await self?.locatePointer(jpeg) }
        pointer.ownAppInFront = { [weak self] in self.map { !$0.appIsBackgrounded } ?? false }
        // Lines come from any thread (a firmware check, MetricKit's crash report): hop to the main actor when
        // needed instead of asserting, which crashed build 24 and then every launch that got the report.
        DebugLog.relay = { [weak self] line in
            guard !MockMode.on else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.board.commands.relayLog(line) }
            } else {
                Task { @MainActor in self?.board.commands.relayLog(line) }
            }
        }
        board.commands.onAppCommand = { [weak self] line in
            #if DEBUG
            self?.handleAppCommand(line)  // the Mac harness (harness/), developer builds only
            #else
            DebugLog.write("app command ignored in this build: \(line.prefix(20))")
            #endif
        }
        let previous = RunMarker.takePrevious().map {
            String(format: "; the previous process ended mid-run (last stage: %@, set %.0f s before this launch)", $0.stage, $0.ago)
        } ?? ""
        DebugLog.write("app launched \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "")"
                       + " (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? ""))" + previous)
        noticeSink = objectWillChange.sink { [weak self] _ in self?.probeCounts.modelNotices += 1 }
        #if DEBUG
        startHarnessLink()
        #endif
        startRemoteLog()  // off (no network) until an endpoint and token are set: RemoteLog.swift
        settingsSink = settings.$configurationRevision.dropFirst().sink { [weak self] _ in
            self?.modelOK = nil
            self?.modelError = nil
            self?.modelTestSeconds = nil
            self?.modelFirstTokenSeconds = nil
            self?.modelResponseSeconds = nil
        }
        board.onVideo = { [weak self] in self?.feed.receive($0) }
        wifiVideo.onChunk = { [weak self] in self?.feed.receive($0, via: "wifi") }
        wifiVideo.onAudio = { [weak self] in self?.audio.receive($0) }
        wifiVideo.wantsAudio = { ListenSetting.on }
        audio.onFinal = { [weak self] text in self?.shareHeard(text) }
        audio.linked = { [weak self] in self.map { $0.wifiVideo.active && $0.feed.mirroring } ?? false }
        setListening(ListenSetting.on)
        feed.continuous = { [weak self] in self?.wifiVideo.active ?? false }
        wifiVideo.resumeAt = { [weak self] in self?.feed.resumeMs }
        feed.onGap = { [weak self] in self?.wifiVideo.resume() }
        wifiVideo.onActive = { [weak self] on in
            self?.feed.resetStream()  // the board resends from the IDR on the new path
            if on { LocalNetworkPermission.granted = true }
        }
        board.onStatus = { [weak self] s in
            self?.statusRefreshError = nil
            let started = s.ap == "streaming" && self?.feed.mirroring == false
            self?.feed.mirroring = s.ap == "streaming"
            self?.pointer.absolute = s.abs == 1
            let frozen = s.fz == 1
            if frozen != self?.feed.frozen {
                DebugLog.write(frozen ? "video: the board's GOP is full (overflows \(s.ovf ?? 0)); frozen until a keyframe"
                                      : "video: unfrozen (new keyframe)")
            }
            self?.feed.frozen = frozen
            if s.ap == "streaming" { Analytics.captureOnce("mirroring_started") }
            if started { DebugLog.write("mirroring started"); self?.prewarmStream() }  // a pre-warm at link-up fails until mirroring runs
            if let up = s.up { self?.feed.boardClock(ms: up) }
            self?.metrics.status(s)
            self?.logStatus(s)
            self?.refreshLinkRecoveryDisplay()
        }
        board.onLinkUp = { [weak self] in
            guard let self else { return }
            Analytics.captureOnce("board_connected")
            feed.resetStream()
            metrics.mtu = board.mtu
            updateWifiVideo()
            readBoardPace()
            if agent.running && !MockMode.on && FrameMode.current == .stream {  // the board forgot `stream on`: the paused run needs the screen back
                Task { [weak self] in
                    do { try await self?.feed.stream(true); DebugLog.write("recover: BLE back, stream on again") } catch {
                        DebugLog.write("recover: stream on after reconnect failed: \(error.localizedDescription)")
                    }
                }
            }
            prewarmStream()
        }
        board.onLinkDown = { [weak self] in
            self?.pointer.boardPace = nil; self?.pointer.flickInOne = nil
            self?.pointer.absolute = false  // the board may come back with other firmware
            self?.wifiVideo.stop()  // the board stops streaming without BLE
            self?.feed.linkLost()
            self?.startupBoardUnavailable(disconnected: true)
            self?.beginLinkRecoveryDisplay()
        }
        board.commands.onTimeout = { [weak self] command in await self?.commandTimedOut(command) }
        DebugLog.write("frame mode: \(FrameMode.current.rawValue)")
        board.commands.onTiming = { [weak self] name, ms in self?.metrics.hidMs[name] = ms }
        agent.beforeFinish = { [weak self] in
            guard let self else { return }
            await self.returnInput(checkKeyboard: true)
            try? await self.feed.stream(false)
        }
        agent.onFinish = { [weak self] in self?.agentFinished() }
        agent.onStep = { [weak self] in self?.stepped() }
        agent.onDoing = { [weak self] d in self?.doing(d) }
        agent.onModelCall = { [weak self] call in self?.modelCalled(call) }
        agent.onHelp = { [weak self] reason in await self?.needsHelp(reason) ?? .stop }
        agent.onConfirm = { [weak self] reason in await self?.needsHelp(reason, confirm: true) ?? .stop }
        agent.gate = { [weak self] in
            try await self?.holdWhileInFront()
            try await self?.holdWhilePaused()
        }
        agent.memory = MemoryStore.shared
        agent.onWrite = { [weak self] text in try await self?.putOnClipboard(text) ?? false }
        pointer.clipboard = agent.onWrite
        AgentControl.handle = { [weak self] command in await self?.control(command) }
        live.standbyPicks = { [weak self] in self?.standbyPicks }
        AgentControl.verdict = { [weak self] run, correct in self?.runVerdict(run, correct: correct) }
        Trial.shared.attach(self)  // free line
        AgentRequests.handle = { [weak self] request in await self?.handle(request) ?? AgentRequests.unavailable }
        notifier.onAction = { [weak self] action, run, kind in self?.notificationAction(action, run: run, kind: kind) }
        wireRecovery()

        timers.append(Task { [weak self] in
            await self?.board.commands.keepAwake {
                guard let self else { return false }
                return self.feed.live && !self.returningInput
            }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        })
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.backgroundEnteredAt = now()
                self?.metrics.enteredBackground()
                DebugLog.write("app: background")
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.metrics.enteredForeground(); DebugLog.write("app: foreground"); self?.wifiVideo.kick(); self?.prewarmStream() }
        }
        if MockMode.on { startMock() }
        runs.reload()
        handleLaunchArguments()
        publishWidget()
    }

    /// A new per-boot video token: the board rebooted, its GOP and timestamps are new, so no resume.
    private func updateWifiVideo() {
        // Read at connect while the board was still joining Wi-Fi after power-on, the address stays empty and the
        // video goes over BLE only (2026-11-06): read it again every 5 s until there is one.
        if [nil, "", "0.0.0.0"].contains(board.net?.ip), now() - lastNetRead > 5 {
            lastNetRead = now()
            Task { _ = try? await board.readNet(fresh: true) }
        }
        let token = board.net?.vtok
        if token != nil && token != lastVideoToken { feed.forgetResume() }
        lastVideoToken = token ?? lastVideoToken
        wifiVideo.update(ip: board.net?.ip, token: token)
    }

    /// Every second: metrics; a suspension note; the stream's numbers every 10 s while a run goes.
    private func tick() {
        refreshLinkRecoveryDisplay()
        summarizeBackground()
        let before = metrics.suspensions, gap = now() - lastTick
        metrics.tick()
        lastTick = now()
        publishWidget()
        #if DEBUG
        readHarnessInbox()
        #endif
        if board.connected && !MockMode.on { updateWifiVideo() }
        shareHearing()
        // Wi-Fi video not up on the idle home screen: maybe the Local Network permission was never given
        if !MockMode.on && !wifiVideo.active && !agent.running && UIApplication.shared.applicationState == .active {
            LocalNetworkPermission.askIfNeeded()
        }
        if metrics.suspensions > before { DebugLog.write(String(format: "app: resumed after %.0f s suspended", gap)) }
        if agent.running, now() - lastStreamLog >= 10 {
            lastStreamLog = now()
            let s = board.status
            let w = wifiVideo
            DebugLog.write(String(format: "stream: via %@, decoded %.1f fps, video in %.0f kbps (wifi %.0f, board BLE %.0f / UDP %.0f kbps out, AirPlay %.0f kbps %.1f fps), frame age %.1f s, drops %d, wifi nack %d lost %d, board udp drop %d",
                                  w.active ? "wifi" : "BLE", metrics.fps, metrics.bleKbps, w.kbps, s?.ble?.kbps ?? 0,
                                  s?.udp?.kbps ?? 0, s?.kbps ?? 0, s?.fps ?? 0, feed.updated > 0 ? now() - feed.updated : -1,
                                  metrics.drops, w.nacks, w.lost, s?.udp?.drop ?? 0))
        }
    }

    /// Once a minute while a run (or its start) is in the background: what kept the main thread busy.
    private func summarizeBackground() {
        let active = (startingAgent || agent.running) && appIsBackgrounded
        var totals = probeCounts  // two cheap syscalls a second
        totals.videoUnits = feed.unitsReceived
        totals.framesDecoded = feed.framesShown
        totals.faceTicks = FaceTicks.count
        totals.cpu = ProcessCPU.seconds()
        totals.mainCPU = ProcessCPU.mainThreadSeconds()
        guard let line = backgroundSummary.tick(totals, at: now(), active: active) else { return }
        DebugLog.write(line)
        metrics.backgroundSummary = line
    }

    /// A command timed out: video may be starving the board's control traffic. Stop the stream and run
    /// snap-per-step for the rest of this run (the next run streams again).
    private func commandTimedOut(_ command: String) async {
        startupBoardUnavailable(disconnected: !board.connected)
        DebugLog.write("cmd timeout on '\(command.prefix(30))': stream off, snap-per-step for this run")
        FrameMode.fallback = .snap
        if feed.streamOn { _ = try? await feed.stream(false) }
    }

    /// Stream while the app is open and idle, and snap once for an IDR, so Start finds the decoder in step.
    /// Starting mid-GOP meant a snap of the whole GOP at Start (up to ~570 KB at ~140 kbps over BLE, 20-60 s
    /// before the first frame; 2026-10-17 runs); now that wait overlaps typing the task. Off in Advanced.
    func prewarmStream() {
        guard Self.prewarmOn, !MockMode.on, FrameMode.current == .stream, board.connected, !agent.running,
              prewarmJob == nil, UIApplication.shared.applicationState != .background else { return }
        prewarmJob = Task { [weak self] in
            defer { self?.prewarmJob = nil }
            guard let self else { return }
            do {
                if !feed.streamOn { try await feed.stream(true) }
                let source = try await feed.currentFrame(maxAge: 2, wait: 3)
                DebugLog.write("stream pre-warm: in step (\(source))")
            } catch { DebugLog.write("stream pre-warm failed: \(error.localizedDescription)") }
        }
    }

    func setFrameMode(_ mode: FrameMode) {
        FrameMode.current = mode
        say("frame mode: \(mode.rawValue)")
        if mode == .stream && agent.running { Task { try? await feed.stream(true) } }
        if mode == .stream { prewarmStream() }
        if mode == .snap && feed.streamOn { Task { try? await feed.stream(false) } }
    }

    /// How the board paces moves; a calibration made under another pace is redone before the next run.
    private func readBoardPace() {
        guard !MockMode.on else { return }
        Task { [weak self] in
            guard let self else { return }
            let pace: Int
            do { pace = Int(try await board.commands.send("pace", timeout: 3).trimmingCharacters(in: .whitespaces)) ?? 1 }
            catch is BoardTimeout { return } catch { pace = 1 }  // "err unknown command": firmware before pacing
            pointer.boardPace = pace
            DebugLog.write("pointer: board pace \(pace), calibrated under \(pointer.pace)\(pointer.calibrated ? "" : ": calibrate again")")
        }
    }

    /// The run paused for the board (line) or goes on (nil).
    /// Board status changes go to the debug log (not every identical notify).
    private func logStatus(_ s: BoardStatus) {
        let line = "board status: ap \(s.ap ?? "-") usb \(s.usb ?? "-") sta \(s.sta.map(String.init) ?? "-")"
            + " screen \(s.w.map(String.init) ?? "-")x\(s.h.map(String.init) ?? "-") rst \(s.rst ?? "-")"
        guard line != lastStatus else { return }
        let wasOnBoardWiFi = lastStatus.contains(" sta ") && !lastStatus.contains(" sta 0") && !lastStatus.contains(" sta -")
        lastStatus = line
        DebugLog.write(line)
        if let up = s.up, up < 30_000 {  // a link drop that is really the board rebooting (crash, brownout, ...)
            DebugLog.write("board: booted \(up / 1000) s ago (reset: \(s.rst ?? "?"), heap \((s.heap ?? 0) / 1024) KB)")
            reportBoardReboot(s, up: up)
            // On another Wi-Fi with the board (station mode, harness/board.py net sta) there is no hotspot to rejoin.
            if (wasOnBoardWiFi || hotspotSSID != nil) && board.net?.mode != "sta" { rejoinAfterReboot() }
        }
    }

    /// Every board reboot goes to usage stats, with the
    /// board's crash dump when it has one (`crash`: task, PC, backtrace, and whether the dump is this build's). The
    /// board erases the dump once read at boot, so each one is reported for the boot it belongs to.
    private func reportBoardReboot(_ s: BoardStatus, up: Int) {
        let bootedAt = now() - Double(up) / 1000
        guard abs(bootedAt - lastBoardBoot) > 60 else { return }  // the same boot, seen again
        lastBoardBoot = bootedAt
        Task { [weak self] in
            guard let self else { return }
            let crash = await BoardLogDump.crash(self.board.commands)
            DebugLog.write("board: crash record: \(crash ?? "-")")
            Analytics.capture("board_reboot", ["reset": s.rst ?? "?", "fw": Firmware.version(of: s), "up_s": up / 1000,
                                               "heap_kb": (s.heap ?? 0) / 1024, "dump": crash ?? ""])
        }
    }

    /// The character's mood right now.
    var mood: Mood { runMood ?? (board.connected ? .idle : .sleeping) }

    /// The model endpoint is filled in (demo data simulates one).
    var modelReady: Bool {
        MockMode.on || (settings.isConfigured && settings.currentModel != nil
            && (settings.provider == .others || settings.provider == .handsyTrial || !settings.apiKey.isEmpty))
    }

    func say(_ text: String) {
        log = Array((log + [LogLine(text: text)]).suffix(200))
        DebugLog.write(text)
    }

    // MARK: - setup and diagnostics

    /// The one-tap join of the board's Wi-Fi (state machine in HotspotJoin.swift).
    @Published var join = JoinState.idle
    var joinTask: Task<Void, Never>?

    /// Set when one-tap join failed: the user joins in Settings with the shown password.
    @Published var manualHotspot: NetConfig?

    func bench(kb: Int = 256) async {
        do {
            let reply = try await board.commands.send("bench \(kb)")
            let ms = Double(reply.split(separator: " ").first ?? "") ?? 0
            metrics.benchKbps = ms > 0 ? Double(kb) * 8 * 1024 / ms : nil
            say(String(format: "BLE bench: %d KB in %.0f ms", kb, ms))
        } catch {
            say("bench: \(error.localizedDescription)")
        }
    }

    func snapTest() async {
        do { say(String(format: "snap -> decoded in %.0f ms", try await feed.snap())) } catch {
            say("snap: \(error.localizedDescription)")
        }
    }

    /// Shared by pull-to-refresh and character interactions; rapid pokes coalesce.
    func refreshHomeStatus() async {
        guard !refreshingStatus, now() - lastStatusRefresh > 2 else { return }
        refreshingStatus = true
        statusRefreshError = nil
        defer { refreshingStatus = false; lastStatusRefresh = now(); publishWidget() }
        do {
            try await board.refreshStatus()
            runs.reload()
            say("Home status refreshed")
        } catch is CancellationError {
            return
        } catch {
            statusRefreshError = error.localizedDescription
            say("Home status refresh: \(error.localizedDescription)")
        }
    }

    func pingLLM() async {
        guard modelTestStarted == nil else { return }
        if settings.provider == .handsyTrial { _ = await Trial.shared.refresh(); return }  // free line: status, never a run
        if MockMode.on {
            try? await Task.sleep(nanoseconds: 900_000_000)
            modelOK = true
            return say("LLM ok (demo data)")
        }
        guard AIConsent.granted(settings.baseURL) else {
            modelOK = false
            modelError = String(localized: "Tap \"Allow sending to \(AIConsent.host(settings.baseURL))…\" above first.")
            return
        }
        let started = now()
        let revision = settings.configurationRevision
        modelError = nil
        modelOK = nil
        modelTestSeconds = nil
        modelFirstTokenSeconds = nil
        modelResponseSeconds = nil
        modelTestStarted = Date()
        defer {
            modelTestStarted = nil
            if revision == settings.configurationRevision { modelTestSeconds = now() - started }
            Analytics.flush()
        }
        do {
            let client = try await settings.client("actor")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }.jpegData(compressionQuality: 0.8)
            let r = try await client.chat(system: "Name the dominant color in the image. Reply with one English word.",
                                          text: "What color is this image?", image: image, maxTokens: 600, temperature: 0)
            guard revision == settings.configurationRevision else { return }
            modelFirstTokenSeconds = r.firstToken
            modelResponseSeconds = r.responseSeconds
            try ModelConnectionCheck.validate(r)
            metrics.llmPingMs = (now() - started) * 1000
            metrics.llm(first: r.firstToken, total: r.total)
            modelOK = true
            Analytics.capture("model_test", settings.analyticsModel(ModelCall(role: "test", model: client.model, reply: r,
                                                                              error: nil, imageKB: 0)))
            say(String(format: "LLM ok in %.0f ms: %@", metrics.llmPingMs ?? 0, String(r.text.prefix(40))))
        } catch {
            guard revision == settings.configurationRevision else { return }
            modelOK = false
            Analytics.capture("model_test", settings.analyticsModel(ModelCall(role: "test", model: settings.currentModel ?? "",
                                                                              reply: nil, error: error, imageKB: 0)))
            modelError = ModelRequestFailure.message(error)
            say("LLM: \(error.localizedDescription)")
        }
    }

    /// Ping the LLM every 2 s for `seconds` (switch to another app meanwhile) and report what survived.
    /// The free line is shared: there it asks the line's status every 10 s instead, never a model call or a lease.
    func backgroundTest(seconds: Double = 600) async {
        let id = UIApplication.shared.beginBackgroundTask(withName: "bgtest")
        defer { UIApplication.shared.endBackgroundTask(id) }
        let freeLine = settings.provider == .handsyTrial
        let client = freeLine ? nil : try? await settings.client("actor")
        guard freeLine || client != nil else { return say("background test: no model") }
        let started = now()
        var ok = 0, failed = 0, decodedBefore = metrics.decodeErrors
        say("background test: \(Int(seconds)) s, switch to another app now")
        try? await feed.stream(true)
        while now() - started < seconds && !Task.isCancelled {
            var reached = false
            if let client {
                reached = (try? await client.chat(system: "Reply with OK.", text: "ping", image: nil, maxTokens: 600, temperature: 0)) != nil
            } else { reached = await Trial.shared.reachable() }
            if reached { ok += 1 } else { failed += 1 }
            try? await Task.sleep(nanoseconds: freeLine ? 10_000_000_000 : 2_000_000_000)
        }
        try? await feed.stream(false)
        decodedBefore = metrics.decodeErrors - decodedBefore
        say("background test: \(freeLine ? "free line status" : "LLM") \(ok) ok / \(failed) failed, decode errors \(decodedBefore), "
            + "suspensions \(metrics.suspensions), background alive \(Int(metrics.backgroundAlive)) s")
    }
}

extension AppModel {
    /// Settings › Listen to phone audio. Asks for speech recognition the first time it is switched on.
    func setListening(_ on: Bool) {
        audio.enabled = on && !MockMode.on
        audio.screenLines = { [weak self] in
            guard let jpeg = self?.feed.frame, let image = Vision.image(jpeg) else { return [] }
            return await UITreeOCR.lines(image, languages: nil).map(\.text)
        }
        if audio.enabled { audio.prepare() }
        shareHearing()
    }

    /// Tells the board whether the app shares what it hears with the CLI (docs/cli-protocol.md, "Phone audio").
    func shareHearing() {
        guard board.connected else { hearSent = nil; return }
        let on = audio.enabled && ListenSetting.share
        guard on != hearSent else { return }
        hearSent = on
        Task { [weak self] in
            if (try? await self?.board.commands.send(on ? "hear on" : "hear off")) == nil { self?.hearSent = nil }
        }
    }

    /// One final transcript for the CLI. Not while the app runs a task: the CLI can't use the board then anyway.
    private func shareHeard(_ text: String) {
        guard hearSent == true, !agent.running, board.connected else { return }
        var line = ""
        for c in text.replacingOccurrences(of: "\n", with: " ") where line.utf8.count + String(c).utf8.count <= 400 { line.append(c) }
        Task { [weak self] in _ = try? await self?.board.commands.send("heard " + line) }
    }
}
