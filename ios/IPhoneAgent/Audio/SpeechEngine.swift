import AVFoundation
import NaturalLanguage
import Speech

/// What one engine made of a segment: the text and how sure it was (0…1, mean over the words; 0 if unknown).
struct Reading: Equatable {
    var text: String
    var confidence: Double
    static let empty = Reading(text: "", confidence: 0)
}

/// Speech to text for one segment of phone audio, on the phone. Feed PCM in `format`, then `finish()` for the text.
protocol SpeechSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// The final reading (empty if nothing was recognized).
    func finish() async -> Reading
}

/// Makes sessions. Partial text arrives on `onPartial` (any thread) while the segment goes on.
protocol SpeechEngine: AnyObject {
    var format: AVAudioFormat { get }
    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession
}

/// A later server-side engine (a new API) plugs in here when the phone can't transcribe; none exists yet.
protocol RemoteTranscriber: SpeechEngine {}

/// Settings › Listen to phone audio › Second language: English is always recognized, plus this one ("" = none).
enum SpeechLanguages {
    static let key = "listenSecondLanguage"
    static let first = "en-US"

    static let automatic = "auto"
    /// Automatic: the language last seen on the screen while sound played (AudioFeed sets it).
    static var seen: String?

    /// The chosen second language. Automatic (the default) follows the screen, the phone's own language until one is
    /// seen: 2026-11-07 a Japanese Duolingo lesson was transcribed as Chinese ("お汉です" for ごはんです).
    static var second: String {
        let chosen = UserDefaults.standard.string(forKey: key) ?? automatic
        guard chosen == automatic else { return chosen }
        return seen ?? choices().first.flatMap { c in Locale.preferredLanguages.contains { Locale(identifier: c).matches($0) } ? c : nil } ?? ""
    }
    static var isAutomatic: Bool { (UserDefaults.standard.string(forKey: key) ?? automatic) == automatic }

    /// The non-English language of the screen's text, among `choices` (nil: none worth switching to). A line counts
    /// when it has non-Latin letters or 3+ words: single English words read as Dutch or Spanish ("rice", "General").
    static func language(of lines: [String], among choices: [String]) -> String? {
        var chars: [String: Int] = [:]
        for line in lines {
            let latin = line.unicodeScalars.allSatisfy { $0.value < 0x250 }
            guard !latin || line.split(separator: " ").count >= 3 else { continue }
            let r = NLLanguageRecognizer()
            r.processString(line)
            guard let l = r.dominantLanguage, l != .english, l != .undetermined else { continue }
            chars[tag(l.rawValue), default: 0] += line.count
        }
        guard let (code, n) = chars.max(by: { $0.value < $1.value }), n >= 2 else { return nil }
        return choices.first { tag($0) == code }
    }

    static var all: [String] { second.isEmpty ? [first] : [first, second] }

    /// Languages the phone can recognize besides English, the phone's own languages first.
    static func choices() -> [String] {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier).filter { tag($0) != "en" }
        var out: [String] = []
        for p in Locale.preferredLanguages {
            if let m = supported.first(where: { Locale(identifier: $0).matches(p) }), !out.contains(m) { out.append(m) }
        }
        return out + supported.filter { !out.contains($0) }.sorted { name($0) < name($1) }
    }

    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }
    static func tag(_ id: String) -> String { Locale(identifier: id).language.languageCode?.identifier ?? id }
}

private extension Locale {
    /// Same language and, when both say, the same script and region (zh-Hans-CN matches zh-CN, not zh-TW).
    func matches(_ preferred: String) -> Bool {
        let p = Locale(identifier: preferred)
        guard language.languageCode == p.language.languageCode else { return false }
        if let a = language.script, let b = p.language.script, a != b { return false }
        if let a = region, let b = p.region, a != b { return false }
        return true
    }
}

enum SpeechSetup {
    enum State: Equatable {
        case ready, denied, unavailable(String)
    }

    /// Asks for speech recognition (once) and returns an on-device engine for `languages`, or why not.
    static func engine(languages: [String] = SpeechLanguages.all) async -> (SpeechEngine?, State) {
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { return (nil, .denied) }
        var engines: [(String, SpeechEngine)] = []
        for id in languages {
            if let e = await single(Locale(identifier: id)) { engines.append((SpeechLanguages.tag(id), e)) }
        }
        DebugLog.write("audio: speech in \(engines.map(\.0)) (asked for \(languages))")
        guard let engine = MultiEngine(engines) else {
            return (nil, .unavailable(String(localized: "On-device speech recognition isn't available for this language.")))
        }
        return (engine, .ready)
    }

    private static func single(_ locale: Locale) async -> SpeechEngine? {
        if #available(iOS 26, *), let engine = await AnalyzerEngine.make(locale: locale) { return engine }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        return RecognizerEngine(recognizer)
    }
}

// MARK: English and a second language over the same sound

/// Nothing says which language a segment is in, so each language transcribes it and only the surer reading is
/// kept, labelled "[zh] …" (no label with one language). While it goes on, the longer partial text shows.
final class MultiEngine: SpeechEngine {
    let format: AVAudioFormat
    let languages: [String]
    private let engines: [SpeechEngine]

    /// nil without engines; engines wanting another audio format than the first are left out.
    init?(_ engines: [(String, SpeechEngine)]) {
        guard let format = engines.first?.1.format else { return nil }
        let same = engines.filter { $0.1.format == format }
        (self.format, languages, self.engines) = (format, same.map(\.0), same.map(\.1))
    }

    /// The highest-confidence non-empty reading (ties: the earlier language), labelled when there are several.
    static func pick(_ languages: [String], _ readings: [Reading]) -> String {
        var best: (String, Reading)?
        for (l, r) in zip(languages, readings) where !r.text.isEmpty && r.confidence > (best?.1.confidence ?? -1) { best = (l, r) }
        guard let best else { return "" }
        return languages.count > 1 ? "[\(best.0)] \(best.1.text)" : best.1.text
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession {
        let parts = Parts(languages)
        var sessions: [SpeechSession] = []
        for (i, e) in engines.enumerated() {
            sessions.append(try await e.begin { text in onPartial(parts.set(i, text)) })
        }
        return Session(languages: languages, sessions: sessions)
    }

    private final class Parts: @unchecked Sendable {
        private let lock = NSLock()
        private let languages: [String]
        private var texts: [String]
        init(_ languages: [String]) { (self.languages, texts) = (languages, languages.map { _ in "" }) }
        func set(_ i: Int, _ text: String) -> String {
            lock.lock(); defer { lock.unlock() }
            texts[i] = text
            return MultiEngine.pick(languages, texts.map { Reading(text: $0, confidence: Double($0.count)) })
        }
    }

    private final class Session: SpeechSession {
        let languages: [String]
        let sessions: [SpeechSession]
        init(languages: [String], sessions: [SpeechSession]) { (self.languages, self.sessions) = (languages, sessions) }

        func append(_ buffer: AVAudioPCMBuffer) { sessions.forEach { $0.append(buffer) } }

        func finish() async -> Reading {
            var readings: [Reading] = []
            for s in sessions { readings.append(await s.finish()) }
            if languages.count > 1 {
                DebugLog.write("audio: confidence " + zip(languages, readings)
                    .map { String(format: "%@ %.2f", $0.0, $0.1.confidence) }.joined(separator: ", "))
            }
            return Reading(text: MultiEngine.pick(languages, readings), confidence: readings.map(\.confidence).max() ?? 0)
        }
    }
}

// MARK: iOS 26: SpeechAnalyzer / SpeechTranscriber (on the device, the system downloads the model)

@available(iOS 26, *)
final class AnalyzerEngine: SpeechEngine {
    let format: AVAudioFormat
    private let locale: Locale

    private init(locale: Locale, format: AVAudioFormat) { (self.locale, self.format) = (locale, format) }

    /// progressiveTranscription's options, plus per-word confidence to choose between languages.
    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.transcriptionConfidence])
    }

    static func make(locale: Locale) async -> AnalyzerEngine? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let probe = transcriber(supported)
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await install.downloadAndInstall()
            }
        } catch {
            DebugLog.write("audio: speech model for \(supported.identifier) not installed: \(error.localizedDescription)")
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else { return nil }
        return AnalyzerEngine(locale: supported, format: format)
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession {
        let transcriber = Self.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        let results = Task<Reading, Never> {
            var final = "", volatile = ""
            var weighted = 0.0, chars = 0
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        (final, volatile) = (final + text, "")
                        for run in r.text.runs {
                            let n = r.text[run.range].characters.count
                            weighted += (run.transcriptionConfidence ?? 0) * Double(n)
                            chars += n
                        }
                    } else {
                        volatile = text
                    }
                    onPartial(final + volatile)
                }
            } catch {
                DebugLog.write("audio: transcriber stopped: \(error.localizedDescription)")
            }
            return Reading(text: (final + volatile).trimmingCharacters(in: .whitespacesAndNewlines),
                           confidence: chars > 0 ? weighted / Double(chars) : 0)
        }
        return Session(analyzer: analyzer, feed: feed, results: results)
    }

    private final class Session: SpeechSession {
        let analyzer: SpeechAnalyzer
        let feed: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<Reading, Never>

        init(analyzer: SpeechAnalyzer, feed: AsyncStream<AnalyzerInput>.Continuation, results: Task<Reading, Never>) {
            (self.analyzer, self.feed, self.results) = (analyzer, feed, results)
        }

        func append(_ buffer: AVAudioPCMBuffer) { feed.yield(AnalyzerInput(buffer: buffer)) }

        func finish() async -> Reading {
            feed.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            return await results.value
        }
    }
}

// MARK: iOS 18–25: SFSpeechRecognizer, on-device only (nothing leaves the phone)

final class RecognizerEngine: SpeechEngine {
    let format: AVAudioFormat
    private let recognizer: SFSpeechRecognizer

    init(_ recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let session = Session(request: request)
        session.task = recognizer.recognitionTask(with: request) { [weak session] result, error in
            if let result {
                let t = result.bestTranscription
                onPartial(t.formattedString)
                let c = t.segments.isEmpty ? 0 : t.segments.map { Double($0.confidence) }.reduce(0, +) / Double(t.segments.count)
                session?.update(Reading(text: t.formattedString, confidence: c), final: result.isFinal)
            }
            if error != nil { session?.update(nil, final: true) }
        }
        return session
    }

    private final class Session: SpeechSession, @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        private let lock = NSLock()
        private var reading = Reading.empty
        private var done = false
        private var waiter: CheckedContinuation<Reading, Never>?

        init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

        func update(_ new: Reading?, final: Bool) {
            lock.lock()
            if let new { reading = new }
            let w = final && !done ? waiter : nil
            if final { done = true; waiter = nil }
            let out = reading
            lock.unlock()
            w?.resume(returning: out)
        }

        func finish() async -> Reading {
            request.endAudio()
            var out = await withCheckedContinuation { (c: CheckedContinuation<Reading, Never>) in
                lock.lock()
                if done { let r = reading; lock.unlock(); c.resume(returning: r); return }
                waiter = c
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.update(nil, final: true) }
            }
            task = nil
            out.text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return out
        }
    }
}
