import AVFoundation

/// "Listen to phone audio" (Settings › Runs), off by default.
enum ListenSetting {
    static let key = "listenAudio"
    static var on: Bool { UserDefaults.standard.bool(forKey: key) }
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
    }

    static let soundDB = -50.0       // quieter frames count as silence
    static let maxSegment = 30.0     // a longer stretch of sound is cut here so its words arrive in time
    static let keep = 60.0           // seconds of segments kept

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var state: SpeechSetup.State?  // nil until enabled once
    private(set) var frames = 0, gaps = 0, undecoded = 0

    var enabled = false { didSet { if !enabled { endSegment() } } }
    var clock: () -> Double = { now() }
    /// The phone mirrors and the board's Wi-Fi video link is up: the only way its audio reaches the app.
    var linked: () -> Bool = { true }
    private var engine: SpeechEngine?
    private var decoder: AudioDecoder?
    private var session: SpeechSession?
    private var pending: [AVAudioPCMBuffer]?  // frames that came while the session was starting
    private var lastSeq: UInt16?
    private var segmentFrom = (frames: 0, undecoded: 0)  // counters when the segment started
    private var preparing: Task<Void, Never>?

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
        segmentFrom = (frames, undecoded)
        DebugLog.write("audio: segment started (\(engine == nil ? "no speech engine" : "transcribing"))")
        segments.removeAll { ($0.end ?? clock()) < clock() - Self.keep }
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
                setText(await s.finish().text, started: started, final: true)
            }
        }
    }

    private func endSegment() {
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
        Task { setText(await s.finish().text, started: started, final: true) }
    }

    private func setText(_ text: String, started: Double, final: Bool) {
        guard let i = segments.firstIndex(where: { $0.start == started }) else { return }
        if !text.isEmpty { segments[i].text = text }
        if final { segments[i].final = true; DebugLog.write("audio: transcript \"\(segments[i].text.prefix(200))\"") }
    }

    var summary: String {
        let last = segments.last.map { "last \($0.end == nil ? "going on" : "ended"), \($0.loud ? "loud" : "quiet"), \"\($0.text.prefix(80))\"" } ?? "none"
        return "audio: \(enabled ? "on" : "off"), speech \(state.map { "\($0)" } ?? "not set up"), \(segments.count) segments (\(last)), \(frames) frames, \(gaps) gaps"
    }
}
