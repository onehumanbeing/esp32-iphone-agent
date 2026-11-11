import Foundation
import UIKit

#if DEBUG
/// Explicit developer input, separate from UserDefaults' temporary argument overrides.
struct ModelLaunchConfiguration {
    let baseURL: String
    let model: String
    let apiKey: String
    let extraBody: String

    enum ParseError: LocalizedError {
        case arguments, endpoint, extraBody
        var errorDescription: String? {
            switch self {
            case .arguments: return "Use -llm-base-url and -llm-model together, once each, with nonempty values. The optional -llm-extra-body must also have one value and appear only once."
            case .endpoint: return "The model endpoint must be an HTTP or HTTPS URL with a host and no credentials, query, or fragment."
            case .extraBody: return "The extra request body must be a valid JSON object."
            }
        }
    }

    static func parse(_ args: [String], environment: [String: String] = [:]) throws -> Self? {
        let flags = ["-llm-base-url", "-llm-model"]
        let extraFlag = "-llm-extra-body"
        guard (flags + [extraFlag]).contains(where: args.contains) else { return nil }
        func value(_ flag: String) throws -> String {
            let positions = args.indices.filter { args[$0] == flag }
            guard positions.count == 1, let index = positions.first, index + 1 < args.count else {
                throw ParseError.arguments
            }
            let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("-") else { throw ParseError.arguments }
            return value
        }
        let baseURL = try value(flags[0]), model = try value(flags[1])
        guard let parts = URLComponents(string: baseURL), let url = parts.url,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ParseError.endpoint
        }
        var extraBody = "{}"
        if args.contains(extraFlag) {
            let raw = try value(extraFlag)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw ParseError.extraBody
            }
            extraBody = String(decoding: data, as: UTF8.self)
        }
        return Self(baseURL: baseURL, model: model,
                    apiKey: environment["IA_LLM_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    extraBody: extraBody)
    }
}
#endif

/// Drive the app without touching the phone, for development:
///   iphoneagent://run?task=<urlencoded>   iphoneagent://calibrate   iphoneagent://stop
///   iphoneagent://bench?kb=256             iphoneagent://snap
/// or launch arguments: -run "<task>", -calibrate, -bench 256, -snap (Debug also -harness-ota <dir>, HarnessOTA.swift; -hid "<cmd>; …")
/// (e.g. `xcrun devicectl device process launch --device <id> <bundle id> -run "Open Clock"`).
/// Commands that need the board wait up to 30 s for it (and mirroring, for a run) before giving up.
/// The URL commands exist in Debug builds only: in a release any web page could open them.
extension AppModel {
    /// True when the URL was a debug command (iphoneagent://run/<id> from the Live Activity is not).
    @discardableResult
    func handleDebug(_ url: URL) -> Bool {
        #if !DEBUG
        return false
        #endif
        guard url.scheme == "iphoneagent", let host = url.host else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch host {
        case "run":
            guard let task = arg("task"), !task.isEmpty else { return false }
            debugCommand("run", task: task)
        case "calibrate", "stop", "snap":
            debugCommand(host)
        case "status":
            say(statusSummary)
        case "bench":
            debugCommand("bench", kb: Int(arg("kb") ?? "") ?? 256)
        case "tree":
            guard let source = arg("source").flatMap(TreeSource.init(rawValue:)) else { return false }
            setTreeSource(source)
        default:
            return false
        }
        return true
    }

    /// A line from the Mac harness, relayed by the board: "run <task>", "calibrate", "stop", "bench <kb>",
    /// "snap", "status", "log <n>", "mode <m>", "audio", "audiotest <lang>" or "ota [dir]".
    func handleAppCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
        switch name {
        case "run" where !rest.isEmpty: debugCommand("run", task: rest)
        case "calibrate", "stop", "snap": debugCommand(name)
        case "bench": debugCommand("bench", kb: Int(rest) ?? 256)
        case "status": say(statusSummary)
        case "audio": say(audio.summary + (audio.heard().isEmpty ? "" : "\n" + audio.heard()))  // the phone audio the agent hears
        case "audiotest":  // says a phrase twice over mirroring, then reports what the app heard
            let language = AudioTest.phrases[rest] != nil ? rest : "en-US"
            homeHint = AudioTest.phrases[language]  // on screen, for Second language › Automatic
            Task { [weak self] in
                let streaming = self?.feed.streamOn ?? false  // idle on Home, no frames come: the screen can't be read
                if !streaming { try? await self?.feed.stream(true) }
                for _ in 0..<3 where SpeechLanguages.second != language {  // a frame showing the phrase (the first may be old)
                    _ = await self?.feed.fresh(since: now() + 0.5, timeout: 2)
                    await self?.audio.followScreen(verbose: true)
                }
                await AudioTest.run(language)
                if !streaming { try? await self?.feed.stream(false) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.homeHint = nil
                self.say(self.audio.summary + "\n" + self.audio.heard(within: 60))
            }
        case "log": relayHistory(Int(rest) ?? 50)
        case "ota":  // a test build staged in Documents/<rest or firmware>, sent over Wi-Fi like Update Board does
            if !rest.isEmpty { Firmware.localDir = rest }
            Task { [weak self] in
                guard let self else { return }
                await self.firmware.check()
                if let blocker = self.firmware.blocker { return self.say("ota: \(blocker)") }
                guard let release = self.firmware.release else { return self.say("ota: no release found") }
                self.say("ota: installing \(release.version)")
                self.firmware.install()
            }
        #if DEBUG
        case "treebench": treeBench(Int(rest) ?? 30)
        #endif
        case "mode":
            if let mode = FrameMode(rawValue: rest) { setFrameMode(mode) } else { say("frame mode: \(FrameMode.current.rawValue)") }
        default: say("debug: unknown app command \"\(line.prefix(40))\"")
        }
    }

    /// "app log <n>": the last n debug.log lines to the harness, paced under the relay's rate limit; a line
    /// is retried while the link is busy.
    func relayHistory(_ n: Int) {
        let lines = DebugLog.tail(min(n, 2000))
        Task { [weak self] in
            for line in lines {
                for _ in 0..<20 {
                    guard let self, self.board.connected else { return }
                    if self.board.commands.relayLog("hist " + line) { break }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }

    /// One line: board, mirroring, calibration, model and run.
    var statusSummary: String {
        let s = board.status
        let boardText = board.connected ? "connected usb \(s?.usb ?? "-") ap \(s?.ap ?? "-") sta \(s?.sta.map(String.init) ?? "-")"
            : "not connected"
        let mirror = feed.live ? String(format: "live %.2f", feed.aspect) : "off"
        let cal = pointer.span.map { "\($0.w)x\($0.h) " + (pointer.quality.map { String(format: "±%.1f%%", $0 * 100) } ?? "?") }
            ?? "none"
        let model = settings.isConfigured ? (settings.currentModel ?? "auto") : "not set"
        let run = agent.running ? "running step \(agent.steps.count)" : "idle"
        return "status: frames \(FrameMode.current.rawValue); board \(boardText); mirroring \(mirror); calibration \(cal) (\(calibrator.phase)); "
            + "model \(model); run \(run); screen \(Int(DeviceScreen.size.width))x\(Int(DeviceScreen.size.height))"
    }

    /// Debug: -tree-source device|server, iphoneagent://tree?source=device (Settings › Developer › Tree source).
    func setTreeSource(_ source: TreeSource) {
        TreeSource.set(source)
        say("debug: tree source \(source.rawValue) (next run)")
    }

    /// Launch arguments, once at startup.
    func handleLaunchArguments(_ args: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        #if DEBUG
        do {
            if try settings.importLaunchConfiguration(arguments: args, environment: ProcessInfo.processInfo.environment) {
                say("debug: model configuration imported")
            }
        } catch {
            say("debug: model configuration rejected: \(error.localizedDescription)")
            return  // never run a requested test against a stale endpoint after an invalid import
        }
        // Provider keys for a test phone: IA_KEY_<provider rawValue> in the launch environment, stored under
        // that provider's endpoint like a key typed in Settings. Values are never logged.
        let env = ProcessInfo.processInfo.environment
        let keyed = ModelProvider.allCases.filter { p in
            guard !p.baseURL.isEmpty, let key = env["IA_KEY_" + p.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else { return false }
            Keychain.set(key, for: "llm-endpoint-" + p.baseURL)
            return true
        }
        if !keyed.isEmpty { say("debug: keys stored for " + keyed.map(\.title).joined(separator: ", ")) }
        if args.contains("-delete-intent") {
            guard args.filter({ $0 == "-delete-intent" }).count == 1,
                  let raw = value(after: "-delete-intent"), let id = UUID(uuidString: raw) else {
                say("debug: intent deletion rejected; provide one valid saved intent UUID")
                return
            }
            if intents.item(id) != nil {
                intents.delete(id)
                say("debug: saved intent deleted")
            } else {
                say("debug: saved intent already absent")
            }
        }
        if let requested = value(after: "-setup"),
           let page = ["connect": SetupPage.connect, "brain": .brain][requested] { setupPage = page }
        if args.contains("-test-model") { Task { await pingLLM() } }
        if let dir = value(after: "-harness-ota") { harnessOTA(dir) }  // harness/fw.sh
        if let commands = value(after: "-hid") { harnessHID(commands) }  // harness/hid.sh
        if let source = value(after: "-tree-source").flatMap(TreeSource.init(rawValue:)) { setTreeSource(source) }
        if args.contains("-treebench") { treeBench(Int(value(after: "-treebench") ?? "") ?? 30) }
        #endif
        if let task = value(after: "-run") { debugCommand("run", task: task) }
        if args.contains("-calibrate") { debugCommand("calibrate") }
        if args.contains("-stop") { debugCommand("stop") }
        if args.contains("-pause") || args.contains("-continue") {  // harness/ctl.sh: hold the run while the Mac looks into a step
            if !agent.running { DebugLog.write("run: not running") }
            args.contains("-pause") ? pause() : unpause()
        }
        if args.contains("-bench") { debugCommand("bench", kb: Int(value(after: "-bench") ?? "") ?? 256) }
        if args.contains("-snap") { debugCommand("snap") }
        if let v = value(after: "-listen") {  // harness: Settings › Listen to phone audio
            UserDefaults.standard.set(v == "on", forKey: ListenSetting.key)
            setListening(v == "on")
            say("harness: listen \(v == "on" ? "on" : "off")")
        }
        #if DEBUG
        if let host = value(after: "-harness-host") { HarnessLink.shared.use(host: host) }  // harness/live.py's address
        #endif
        if let lang = value(after: "-audiotest") { handleAppCommand("audiotest " + lang) }  // harness: Settings › Developer › Audio test
        if args.contains("-audio") { say(audio.summary + (audio.heard().isEmpty ? "" : "\n" + audio.heard())) }
    }

    private func debugCommand(_ name: String, task: String = "", kb: Int = 256) {
        say("debug: \(name)\(task.isEmpty ? "" : " \"\(task)\"")\(name == "bench" ? " \(kb) KB" : "")")
        Task { [weak self] in
            guard let self else { return }
            switch name {
            case "stop":
                await stopAgent()
            case "run":
                guard await waitReady(mirroring: true) else { return say("debug: run not started, board/mirroring not ready in 30 s") }
                guard !agent.running else { return say("debug: a run is already going") }
                tab = .agent
                await run(task)
            case "calibrate":
                guard await waitReady(mirroring: false) else { return say("debug: board not ready in 30 s") }
                calibrator.calibrate()
            case "bench":
                guard await waitReady(mirroring: false) else { return say("debug: board not ready in 30 s") }
                await bench(kb: kb)
            case "snap":
                guard await waitReady(mirroring: true) else { return say("debug: mirroring not ready in 30 s") }
                await snapTest()
            default:
                break
            }
        }
    }

    #if DEBUG
    /// harness/lib.sh drops `Documents/harness-inbox/<time>.json` = ["-run", "<task>"] (launch arguments): iOS
    /// often restores the app for Bluetooth first, and devicectl's launch then only brings it to the front, without
    /// the arguments. Checked every second; each file is handled once and removed.
    func readHarnessInbox() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("harness-inbox")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") {
            let file = dir.appendingPathComponent(name)
            let args = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            try? FileManager.default.removeItem(at: file)
            guard let args else { say("harness: unreadable \(name)"); continue }
            say("harness: \(name)")
            handleLaunchArguments(["harness"] + args)
        }
    }

    /// harness/live.py on the Mac: the same commands as the inbox, over the network (HarnessLink).
    func startHarnessLink() {
        HarnessLink.shared.onCommand = { [weak self] args in
            self?.say("harness: live \(args.first ?? "")")
            self?.handleLaunchArguments(["harness"] + args)
        }
        HarnessLink.shared.start()
    }

    /// "-treebench n" / app command "treebench n": the on-device tree (UITree) of the mirrored frame n times
    /// ~1 s apart, at the model's 540-wide copy and at the full stream frame, then p50/p90 of total/ocr/cv ms
    /// into debug.log. No run, no taps. Without mirroring it uses Documents/treebench/*.jpg (still frames
    /// copied in with devicectl) and says so. cpu = the app's CPU time during a build (all its threads).
    func treeBench(_ n: Int) {
        Task { [weak self] in
            guard let self else { return }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("treebench")
            let live = await waitReady(mirroring: true, timeout: 10)
            let streaming = feed.streamOn
            if live && !streaming { try? await feed.stream(true) }
            if live { _ = await feed.fresh(since: now(), timeout: 3) }
            let stills = live ? [] : ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }.compactMap { try? Data(contentsOf: $0) }
            guard live || !stills.isEmpty else { return say("treebench: no mirroring and no Documents/treebench/*.jpg") }
            UIApplication.shared.isIdleTimerDisabled = true  // auto-lock suspends the app mid-bench
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            say("treebench: \(n) builds on \(live ? "live mirrored frames" : "\(stills.count) still frames (no mirroring)"), "
                + "thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
            var stats: [String: [(tree: UITree, cpu: Double)]] = [:]
            var idle: [Double] = []
            for i in 0..<n {
                guard let frame = live ? feed.frame : stills[i % stills.count] else { continue }
                let small = ModelImage.shrink(frame)
                for (name, jpeg) in [("model", small), ("full", frame)] where name == "model" || small != frame {
                    let c0 = Self.cpuSeconds()
                    let made = await Task.detached(priority: .userInitiated) { await UITree.build(jpeg: jpeg, cache: nil) }.value  // every build runs Vision
                    let cpu = Self.cpuSeconds() - c0
                    guard let tree = made else { continue }
                    stats[name, default: []].append((tree, cpu))
                    DebugLog.write("treebench \(i + 1)/\(n) \(name) " + tree.timingLine
                                   + String(format: ", cpu %.0f ms (%.0f%% of one core)", cpu * 1000, cpu / max(tree.totalSeconds, 1e-6) * 100))
                }
                let c0 = Self.cpuSeconds(), t0 = now()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                idle.append((Self.cpuSeconds() - c0) / max(now() - t0, 1e-6))
            }
            if live && !streaming { try? await feed.stream(false) }
            func pct(_ xs: [Double]) -> String {
                let s = xs.sorted()
                guard !s.isEmpty else { return "-" }
                return String(format: "p50 %.0f p90 %.0f max %.0f", s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)], s.last!)
            }
            for name in ["model", "full"] {
                guard let r = stats[name], let t = r.first?.tree else { continue }
                say("treebench \(name) \(t.w)x\(t.h), \(r.count) builds: total \(pct(r.map { $0.tree.totalSeconds * 1000 })) ms; "
                    + "ocr \(pct(r.map { $0.tree.ocrSeconds * 1000 })); cv \(pct(r.map { $0.tree.cvSeconds * 1000 })); "
                    + "elements \(pct(r.map { Double($0.tree.elements.count) })); "
                    + "compact \(pct(r.map { Double($0.tree.candidates.filter { $0.role != "container" }.count) })); "
                    + "cpu ms \(pct(r.map { $0.cpu * 1000 }))")
            }
            say("treebench: done; idle app cpu between builds \(pct(idle.map { $0 * 100 }))% of one core, "
                + "thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
        }
    }

    /// The app's CPU time so far (user + system, all threads).
    nonisolated static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Raw board commands ("key ctrl+space; type abc"), one after another, each reply logged: harness experiments.
    private func harnessHID(_ commands: String) {
        Task { [weak self] in
            guard let self else { return }
            guard await waitReady(mirroring: false) else { return say("harness hid: board not ready in 30 s") }
            var moved = false
            for command in commands.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !command.isEmpty {
                let reply: String
                if command.hasPrefix("wait "), let s = Double(command.dropFirst(5)) {  // "wait 1.2": seconds
                    try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                    reply = "ok"
                } else if command == "gop" {  // the board's GOP buffer: bytes, overflows, frozen for us
                    let st = board.status
                    reply = "gop \(st?.gop.map(String.init) ?? "?") B, overflows \(st?.ovf.map(String.init) ?? "?"), frozen \(st?.fz.map(String.init) ?? "?")"
                } else if command == "video-reconnect" {  // drop the Wi-Fi video session: it must come back resuming
                    wifiVideo.stop()
                    wifiVideo.update(ip: board.net?.ip, token: board.net?.vtok)
                    reply = "reconnecting, resume at \(feed.resumeMs.map(String.init) ?? "none")"
                } else if command.hasPrefix("point ") {  // "point 500 620": move there (no click), report the landing
                    let xy = command.split(separator: " ").dropFirst().compactMap { Double($0) }
                    if xy.count == 2, (try? await pointer.point(xy[0] / 1000, xy[1] / 1000)) != nil,
                       let p = await pointer.landing(xy[0] / 1000, xy[1] / 1000) {
                        reply = String(format: "landed %.0f %.0f", p.x * 1000, p.y * 1000)
                    } else { reply = "err not found" }
                } else if command == "shot" {  // the mirrored screen now, for harness/hid.sh to pull
                    await feed.settled(most: 1.5)
                    let name = "harness-shots/\(Int(Date().timeIntervalSince1970)).jpg"
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    reply = (try? feed.frame?.write(to: url)) != nil ? "saved " + name : "err no frame"
                    if let jpeg = feed.frame { HarnessLink.shared.sendFile(name, jpeg) }  // harness/live.py saves it
                } else {
                    do { reply = try await board.commands.send(command) } catch { reply = "err " + error.localizedDescription }
                    if command == "home" || command.hasPrefix("move") { moved = true }
                }
                say("harness hid: \(command) → \(reply)")
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            // raw moves leave the pointer where the app doesn't think it is: the next run's home-bar flick pressed
            // mid-screen and never left the app (2026-11-06). Once at the end, so "home; move …; move …" composes.
            if moved { try? await pointer.reset() }
            say("harness hid: done")
        }
    }
    #endif

    /// Board connected (and USB up), plus mirroring streaming when asked; waits up to `timeout` s.
    func waitReady(mirroring: Bool, timeout: Double = 30) async -> Bool {
        if MockMode.on { return true }
        let deadline = now() + timeout
        while now() < deadline {
            let s = board.status
            if board.connected && s?.usb == "ok" && (!mirroring || s?.ap == "streaming") { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
