import Foundation

/// Demo data for looking at the UI without a board: launch with `-mock`, or turn on Settings > Demo data
/// (takes effect on the next launch). Walks the whole setup (board found → paired → mirroring → calibrated),
/// has one finished run to replay, and Start plays a fake run with a Live Activity. Nothing reaches a phone.
enum MockMode {
    static let key = "demoData"
    /// Read once at launch, so turning the switch on mid-session never mixes real and fake state.
    static let on: Bool = ProcessInfo.processInfo.arguments.contains("-mock") || UserDefaults.standard.bool(forKey: key)
}

extension AppModel {
    func startMock() {
        writeMockRun()
        if settings.onboarded {
            mockReady()
        } else {
            board.mockFound()
        }

        Task { [weak self] in
            var up = 812_000, n = 0
            while !Task.isCancelled {
                guard let self else { return }
                n += 1
                up += 1000
                if self.settings.onboarded && !self.board.connected { self.mockReady() }  // setup skipped with "Later"
                if self.board.connected {
                    if self.mockMirroring && self.feed.frame == nil { self.showMockFrame() }
                    self.board.updateStatus(Self.status(up: up, n: n, mirroring: self.mockMirroring))
                }
                self.metrics.videoBytes(Int.random(in: 38_000...46_000))
                for _ in 0..<5 { self.metrics.frameDecoded(ms: Double.random(in: 3.5...6)) }
                if n % 2 == 0 { self.metrics.idrSeen() }
                if n % 4 == 0 { self.metrics.snapLatency(Double.random(in: 420...690)) }
                if n % 3 == 0 {
                    self.metrics.llm(first: Double.random(in: 0.35...0.6), total: Double.random(in: 1.2...2.1))
                    self.metrics.step(Metrics.Step(frameMs: .random(in: 300...520), llmMs: .random(in: 1200...2100),
                                                   hidMs: .random(in: 250...700)))
                    self.metrics.hidMs = ["move": .random(in: 18...40), "click": .random(in: 9...16)]
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Demo data after setup: everything is ready, whatever was skipped.
    func mockReady() {
        if !board.connected {
            board.mockConnect(name: "ESP32 Agent 7C3E",
                              net: NetConfig(mode: "ap", ssid: "ESP32Agent-7C3E", pass: nil, ip: "192.168.4.1"))
        }
        hotspotSSID = "ESP32Agent-7C3E"
        mockMirroring = true
        modelOK = true
        if feed.frame == nil { showMockFrame() }
        board.updateStatus(Self.status(up: 812_000, n: 0, mirroring: true))
        if !pointer.calibrated { pointer.mockCalibrated(quality: 0.006) }
    }

    /// Demo: Screen Mirroring "starts" a moment after the hotspot is joined.
    func mockStartMirroring() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.mockMirroring = true
        }
    }

    private func showMockFrame() {
        if let jpeg = Self.mockFrame { feed.show(jpeg, width: 480, height: 1075) }
    }

    static var mockFrame: Data? {
        Bundle.main.url(forResource: "mock-frame", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) }
    }

    /// Plays the demo steps as a run: trace and video on disk, Live Activity, one "needs your help" pause,
    /// notifications, then the review.
    func mockRun(_ task: String) {
        guard !agent.running else { return }
        traces.start(task: task)
        agent.showMock(task: task, plan: "", steps: [], running: true)
        began(task)
        let video = traces.dir?.appendingPathComponent("video")
        if let video { try? FileManager.default.createDirectory(at: video, withIntermediateDirectories: true) }
        mockJob = Task { [weak self] in
            var shown: [JObject] = []
            for (i, step) in (Self.mockSteps + [["action": .str("done"), "answer": .str("The alarm is saved.")]]).enumerated() {
                self?.doing(.thinking)  // the island's eyes dart while the "model" thinks, then look at the target
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard let self, !Task.isCancelled, self.agent.running else { break }
                if i == 6 {  // a demo of the help pause
                    let fail: JObject = ["action": .str("fail"), "reason": .str("A passcode prompt appeared.")]
                    self.traces.write(kind: "step", fail)
                    shown.append(fail)
                    self.agent.showMock(task: task, plan: Self.mockPlan, steps: shown, running: true)
                    let choice = await self.needsHelp("A passcode prompt appeared.")
                    let rec: JObject = ["action": .str(choice == .stop ? "stopped" : choice == .skip ? "skipped" : "takeover")]
                    self.traces.write(kind: "step", rec)
                    shown.append(rec)
                    if choice == .stop { break }
                }
                if !StepText.notMoves.contains(step["action"]?.str ?? "") {
                    self.doing(.acting(step))
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
                guard !Task.isCancelled, self.agent.running else { break }
                self.traces.write(Self.mockFrame, kind: "llm", ["role": .str("actor"), "seconds": .num(1.3)])
                self.traces.write(kind: "step", step.merging(["think_s": .num(1.3), "act_s": .num(0.4)]))
                if let video, let frame = Self.mockFrame {
                    try? frame.write(to: video.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).jpg"))
                }
                shown.append(JObject([("t", .num(now()))]).merging(step))
                self.agent.showMock(task: task, plan: Self.mockPlan, steps: shown, running: true)
                self.stepped()
            }
            guard let self else { return }
            if (Task.isCancelled || !self.agent.running) && shown.last?["action"]?.str != "stopped" {
                self.traces.write(kind: "step", ["action": .str("stopped")])
                shown.append(["action": .str("stopped")])
            }
            self.agent.showMock(task: task, plan: Self.mockPlan, steps: shown, running: false)
            self.ended()
        }
    }

    /// One finished run in the demo traces folder, so Runs and the replay player have something to show.
    private func writeMockRun() {
        let id = "20261015-071500"
        let dir = traces.root.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: dir.path), let frame = Self.mockFrame else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [String] = [], n = 0, t = 1_760_483_700.0
        func add(_ kind: String, _ rec: JObject, shot: Bool = false) {
            n += 1
            t += kind == "step" ? 1.6 : 0.9
            var line = JObject([("n", .int(n)), ("t", .num(t)), ("kind", .str(kind))]).merging(rec)
            if shot {
                let name = String(format: "%03d.jpg", n)
                try? frame.write(to: dir.appendingPathComponent(name))
                line["frame"] = .str(name)
                let video = dir.appendingPathComponent("video")
                try? FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
                try? frame.write(to: video.appendingPathComponent("\(Int(t * 1000)).jpg"))
            }
            lines.append(PyJSON.dumps(line, ascii: false))
        }
        add("task", ["task": .str(String(localized: "Example: ") + IntentStore.alarm.prompt)])  // labeled sample run
        for step in Self.mockSteps + [["thought": .str("Every day is checked and the alarm is saved."),
                                       "action": .str("done"), "answer": .str("The 7:00 AM alarm repeats every day.")]] {
            add("llm", ["role": .str("actor"), "seconds": .num(1.4)], shot: true)
            add("step", step.merging(["think_s": .num(1.4), "act_s": .num(0.5)]))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("steps.jsonl"),
                                                          atomically: true, encoding: .utf8)
    }

    private static func status(up: Int, n: Int, mirroring: Bool) -> BoardStatus {
        // a board on released firmware: without `fw` it reads as pre-OTA and the required Board Update covers the app
        BoardStatus(fw: FirmwareVersion([0, 2, 1]), up: up, rst: "power-on", heap: 81_234 - n % 7 * 120, psram: 6_200_000, usb: "ok",
                    net: "ap", ip: "192.168.4.1", sta: 1, ap: mirroring ? "streaming" : "idle", w: 480, h: 1040,
                    kbps: Double.random(in: 150...230), fps: Double.random(in: 4.4...5), idr: 2000,
                    gop: 42_000 + n % 5 * 3000,
                    ble: .init(mtu: 247, phy: 2, kbps: Double.random(in: 320...380), drop: n / 30))
    }

    static let mockPlan = """
    1. Open the Clock app with Search.
    2. Go to the Alarms tab and tap +.
    3. Set the time to 7:00 AM.
    4. Tap Repeat and check every day.
    5. Go back and tap Save.
    """

    static let mockSteps: [JObject] = [
        ["action": .str("plan"), "plan": .str(mockPlan)],
        ["thought": .str("I am on the home screen. I tap the Search pill to find Clock."), "action": .str("tap"),
         "x": .int(500), "y": .int(814), "changed": .bool(true)],
        ["action": .str("type"), "text": .str("Clock"), "changed": .bool(true)],
        ["thought": .str("Clock is the top result, so I open it."), "action": .str("tap"), "x": .int(152),
         "y": .int(212), "changed": .bool(true)],
        ["thought": .str("The Alarms tab is open. I tap + to add an alarm."), "action": .str("tap"), "x": .int(905),
         "y": .int(88), "precise": .bool(true), "changed": .bool(true)],
        ["thought": .str("I scroll the hour wheel to 7."), "action": .str("swipe"), "x1": .int(397), "y1": .int(300),
         "x2": .int(397), "y2": .int(200), "changed": .bool(true)],
        ["action": .str("type"), "text": .str("0700"), "changed": .bool(true)],
        ["thought": .str("The time is 07:00. I open Repeat."), "action": .str("tap"), "x": .int(150), "y": .int(395),
         "changed": .bool(true)],
        ["thought": .str("I check every day from Sunday to Saturday."), "action": .str("tap"), "x": .int(210),
         "y": .int(204), "changed": .bool(true)],
        ["action": .str("tap"), "x": .int(210), "y": .int(260), "changed": .bool(true)],
        ["action": .str("tap"), "x": .int(210), "y": .int(315), "changed": .bool(false)],
    ]
}
