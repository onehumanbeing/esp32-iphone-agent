import AVFoundation

/// "Listen to phone audio" (Settings › Runs), off by default.
enum ListenSetting {
    static let key = "listenAudio"
    static let shareKey = "listenShareCLI"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Share what the app hears with a computer's esp32agent CLI (through the board); on unless switched off.
    static var share: Bool { UserDefaults.standard.object(forKey: shareKey) as? Bool ?? true }
}

/// AirPlay audio from the board, one segment per stretch of sound (the board starts one with the first sounding
/// frame and ends it 500 ms after the last). Each segment is decoded, checked for real sound (the sender also
/// streams quiet frames), and transcribed on the phone. The agent sees the recent segments as `heard(within:)`.
@MainActor final class AudioFeed: ObservableObject {
    struct Segment: Equatable {
        var start: Double, end: Double? = nil  // seconds (now() clock); end nil while it goes on
        var text = ""
        var loud = false                  // some frame above `soundDB`
        var final = false                 // the engine is done with it
        var confidence = 0.0              // of the final reading (0…1)
        var redone = false                // transcribed again in the screen's language: later text from the old engine is stale
    }

    static let soundDB = -50.0       // quieter frames count as silence
    static let maxSegment = 30.0     // a longer stretch of sound is cut here so its words arrive in time
    static let keep = 60.0           // seconds of segments kept

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var state: SpeechSetup.State?  // nil until enabled once
    private(set) var frames = 0, gaps = 0, undecoded = 0

    var enabled = false { didSet { if !enabled { endSegment() }; watchScreen() } }
    var clock: () -> Double = { now() }
    /// Each segment's final text, when there is some (shared with the CLI).
    var onFinal: ((String) -> Void)?
    /// The phone mirrors and the board's Wi-Fi video link is up: the only way its audio reaches the app.
    var linked: () -> Bool = { true }
    private var engine: SpeechEngine?
    private var decoder: AudioDecoder?
    private var session: SpeechSession?
    private var pending: [AVAudioPCMBuffer]?  // frames that came while the session was starting
    private var lastSeq: UInt16?
    private var segmentFrom = (frames: 0, undecoded: 0)  // counters when the segment started
    private var preparing: Task<Void, Never>?
    /// The screen's text lines (OCR of the shown frame), for Second language › Automatic. Set by the app.
    var screenLines: () async -> [String] = { [] }

    /// Speech permission and engine; called when the setting is switched on (and at launch if it is on).
    func prepare() {
        guard engine == nil, preparing == nil else { return }
        preparing = Task {
            let (engine, state) = await SpeechSetup.engine()
            guard !Task.isCancelled else { return }  // reset() while it started: that one's languages are stale
            self.state = state
            if let engine { use(engine) }
            DebugLog.write("audio: speech \(state)")
            preparing = nil
        }
    }

    /// Settings › Second language changed: the next segment uses an engine for the new languages.
    func reset() {
        endSegment()
        preparing?.cancel()
        (engine, decoder, state, preparing) = (nil, nil, nil, nil)
        if enabled { prepare() }
    }

    /// Tests and later engines (RemoteTranscriber).
    func use(_ engine: SpeechEngine) {
        self.engine = engine
        state = .ready
        decoder = AudioDecoder(output: engine.format)
        if decoder == nil { DebugLog.write("audio: no AAC-ELD decoder for \(engine.format)") }
    }

    /// One record from the TCP video link.
    func receive(_ chunk: Data) {
        guard enabled, let r = AudioRecord(chunk) else { return }
        if let last = lastSeq, r.seq != last &+ 1 { gaps += 1 }
        lastSeq = r.seq
        if r.end { return endSegment() }
        if r.start || segments.last?.end != nil || segments.isEmpty { startSegment() }
        guard let pcm = decoder?.decode(r.frame) else { undecoded += 1; return }
        frames += 1
        if AudioDecoder.level(pcm) > Self.soundDB { segments[segments.count - 1].loud = true }
        if let session { session.append(pcm) } else { pending?.append(pcm) }
        if heardPCM.count < Int(Self.maxSegment * 50) { heardPCM.append(pcm) }  // ~20 ms frames
        if let s = segments.last, clock() - s.start >= Self.maxSegment { endSegment() }
    }

    /// What the phone played lately, for the actor's prompt; "" when there was no sound.
    /// The audio part of a step's prompt: what was heard, or why nothing can be, so the model knows how far to trust
    /// it. "" when listening is off (the model then has no audio at all).
    func heard(within seconds: Double = 30) -> String {
        guard enabled else { return "" }
        let t = clock()
        let lines = segments.filter { $0.loud && ($0.end ?? t) >= t - seconds }.map { s -> String in
            let length = Int(((s.end ?? t) - s.start).rounded())
            let when = s.end == nil ? "now, \(length) s so far" : "\(Int((t - s.end!).rounded())) s ago, \(length) s long"
            let words = s.text.isEmpty ? (s.final || engine == nil ? "(sound, no words recognized)" : "(sound, still transcribing)")
                                       : "\"\(s.text.prefix(400))\"" + (s.final ? "" : " (still transcribing)")
            return "- \(when): \(words)"
        }
        let words: String
        switch state {
        case .ready?: words = (engine as? MultiEngine).map { $0.languages.count > 1
            ? "words transcribed on the phone by \($0.languages.joined(separator: " and ")) recognizers, the surer one kept and labelled"
            : "words transcribed on the phone" } ?? "words transcribed on the phone"
        case .denied?: words = "speech recognition is not allowed, so no words, only whether there was sound"
        case .unavailable(let why)?: words = "no words (\(why)), only whether there was sound"
        case nil: words = "speech recognition still starting, so no words yet"
        }
        if !lines.isEmpty { return "Heard (phone audio, last \(Int(seconds)) s; \(words)):\n" + lines.joined(separator: "\n") }
        guard linked() else { return "Phone audio: not reaching the app right now (no mirroring or no Wi-Fi link to the board), so sound is not heard." }
        return "Phone audio: listening; no sound in the last \(Int(seconds)) s."
    }

    private func startSegment() {
        endSegment()
        segments.append(Segment(start: clock()))
        heardPCM = []
        segmentFrom = (frames, undecoded)
        DebugLog.write("audio: segment started (\(engine == nil ? "no speech engine" : "transcribing"))")
        segments.removeAll { ($0.end ?? clock()) < clock() - Self.keep }
        Task { await followScreen() }
        guard let engine else { return }
        let started = segments[segments.count - 1].start
        pending = []
        Task {
            let s = try? await engine.begin(onPartial: { text in
                Task { @MainActor [weak self] in self?.setText(text, started: started, final: false) }
            })
            let current = segments.last?.start == started
            if current {
                pending?.forEach { s?.append($0) }
                pending = nil
            }
            guard let s else { return setText("", started: started, final: true) }
            if current && segments.last?.end == nil {
                session = s
            } else {
                let r = await s.finish()
                setText(r.text, started: started, final: true, confidence: r.confidence)
            }
        }
    }

    /// Second language › Automatic: read the screen every few seconds while listening (and when sound starts), so the
    /// engine is in the lesson's language before its first word: checked only at sound, the first phrase was lost.
    private var watcher: Task<Void, Never>?
    private func watchScreen() {
        watcher?.cancel()
        guard enabled else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.followScreen()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Another language on the screen than the engine's: a new engine (once the current segment ends).
    func followScreen(verbose: Bool = false) async {
        guard SpeechLanguages.isAutomatic, engine != nil, !switching, linked() else {
            if verbose { DebugLog.write("audio: screen not read (automatic \(SpeechLanguages.isAutomatic), engine \(engine != nil), busy \(switching), linked \(linked()))") }
            return
        }
        switching = true
        defer { switching = false }
        let t0 = now()
        let lines = await screenLines()
        let t1 = now(), choices = SpeechLanguages.choices(), t2 = now()
        if verbose { DebugLog.write(String(format: "audio: screen text (OCR %.0f ms, choices %.0f ms) ", (t1 - t0) * 1000, (t2 - t1) * 1000) + "\(lines.prefix(12))") }
        guard let (id, line) = SpeechLanguages.language(of: lines, among: choices),
              id != SpeechLanguages.second else { return }
        DebugLog.write("audio: the screen is in \(id) (\"\(line.prefix(40))\"); transcribing that from the next sound")
        SpeechLanguages.seen = id
        seenAt = clock()
        // build the new engine first and swap it in between sounds: reset() left sound without an engine meanwhile
        let t3 = now()
        let (next, state) = await SpeechSetup.engine()
        DebugLog.write(String(format: "audio: %@ engine built in %.0f ms (OCR %.0f ms)", id, (now() - t3) * 1000, (t1 - t0) * 1000))
        guard let next, state == .ready else { return }
        adopt(next)
    }

    /// The screen's language engine: from the next sound on (now, between sounds), and the last sound again.
    func adopt(_ next: SpeechEngine) {
        let current = (engine as? MultiEngine)?.languages
        if let a = (next as? MultiEngine)?.languages, a == current { return }  // the same languages (a fallback): nothing to redo
        if segments.last?.end == nil { nextEngine = next } else { use(next); redoLast() }
    }
    private var nextEngine: SpeechEngine?
    private var seenAt = 0.0  // when the screen's language was last read: only sound from shortly before is redone
    /// The current (or last) segment's sound, to transcribe it again once the screen's language engine is ready:
    /// the first phrase of a lesson starts before the screen has been read.
    private var heardPCM: [AVAudioPCMBuffer] = []
    private var switching = false  // one look at the screen at a time (the 4 s watch and sound starting)

    /// The last segment again with the new engine, if it ended within 10 s (same audio format only).
    private func redoLast() {
        guard let engine, let i = segments.indices.last, let end = segments[i].end, clock() - end < 10,
              segments[i].start >= seenAt - 5,  // the lesson's sound, not the one before the screen changed
              segments[i].loud, let first = heardPCM.first, first.format == engine.format else { return }
        let started = segments[i].start, buffers = heardPCM
        Task {
            guard let s = try? await engine.begin(onPartial: { _ in }) else { return }
            buffers.forEach { s.append($0) }
            let r = await s.finish(), text = r.text
            // a surer reading only: a fallback engine (the screen's language had no model) read worse than the first
            guard !text.isEmpty, let j = segments.firstIndex(where: { $0.start == started }),
                  !segments[j].final || r.confidence > segments[j].confidence else { return }
            DebugLog.write("audio: retranscribed in the screen's language: \"\(text.prefix(200))\" (was \"\(segments[j].text.prefix(80))\")")
            segments[j].text = text
            segments[j].redone = true
            segments[j].confidence = r.confidence
            segments[j].final = true
            onFinal?(text)
        }
    }

    private func endSegment() {
        defer { if let next = nextEngine { nextEngine = nil; use(next); redoLast() } }
        guard let i = segments.indices.last, segments[i].end == nil else { return }
        segments[i].end = clock()
        let started = segments[i].start
        DebugLog.write(String(format: "audio: segment ended after %.1f s, %@, %d frames, %d undecoded, %d gaps since launch",
                              clock() - started,
                              segments[i].loud ? "loud" : "quiet", frames - segmentFrom.frames,
                              undecoded - segmentFrom.undecoded, gaps))
        guard let s = session else {
            if pending == nil { segments[i].final = true }  // else the starting session finishes it
            return
        }
        session = nil
        Task {
            let r = await s.finish()
            setText(r.text, started: started, final: true, confidence: r.confidence)
        }
    }

    private func setText(_ text: String, started: Double, final: Bool, confidence: Double = 0) {
        guard let i = segments.firstIndex(where: { $0.start == started }), !segments[i].redone else { return }
        if !text.isEmpty { segments[i].text = text }
        if final {
            segments[i].final = true
            segments[i].confidence = confidence
            DebugLog.write("audio: transcript \"\(segments[i].text.prefix(200))\"")
            if !segments[i].text.isEmpty { onFinal?(segments[i].text) }
        }
    }

    var summary: String {
        let last = segments.last.map { "last \($0.end == nil ? "going on" : "ended"), \($0.loud ? "loud" : "quiet"), \"\($0.text.prefix(80))\"" } ?? "none"
        return "audio: \(enabled ? "on" : "off"), speech \(state.map { "\($0)" } ?? "not set up"), \(segments.count) segments (\(last)), \(frames) frames, \(gaps) gaps"
    }
}

/// Settings › Developer › Audio test (and the harness `audiotest <lang>`): the phone says a phrase twice while it
/// shows it, so the sound goes out over Screen Mirroring and comes back through the board without another app.
/// Shown on screen too, so Second language › Automatic switches on the first and transcribes the second.
@MainActor enum AudioTest {
    static let phrases: [String: String] = [
        "en-US": "Please book a table for two at seven tonight.",
        "ja-JP": "ごはんとおちゃをください。",
        "zh-CN": "我想喝一杯热茶。",
        "es-ES": "Quiero un vaso de agua, por favor.",
    ]
    private static let voice = AVSpeechSynthesizer()

    static func run(_ language: String, times: Int = 2) async {
        let text = phrases[language] ?? phrases["en-US"]!
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // the phrase is on screen (and mirrored) before it sounds
        for _ in 0..<times {
            let u = AVSpeechUtterance(string: text)
            u.voice = AVSpeechSynthesisVoice(language: language)
            voice.speak(u)
            while !voice.isSpeaking { try? await Task.sleep(nanoseconds: 50_000_000) }
            while voice.isSpeaking { try? await Task.sleep(nanoseconds: 100_000_000) }
            try? await Task.sleep(nanoseconds: 2_500_000_000)  // the segment ends and is transcribed
        }
    }
}
