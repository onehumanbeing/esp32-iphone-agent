import AVFoundation
import Speech

/// Speech to text for one segment of phone audio, on the phone. Feed PCM in `format`, then `finish()` for the text.
protocol SpeechSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// The final text ("" if nothing was recognized).
    func finish() async -> String
}

/// Makes sessions. Partial text arrives on `onPartial` (any thread) while the segment goes on.
protocol SpeechEngine: AnyObject {
    var format: AVAudioFormat { get }
    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession
}

/// A later server-side engine (a new API) plugs in here when the phone can't transcribe; none exists yet.
protocol RemoteTranscriber: SpeechEngine {}

enum SpeechSetup {
    enum State: Equatable {
        case ready, denied, unavailable(String)
    }

    /// Asks for speech recognition (once) and returns an on-device engine for the phone's first two languages
    /// (Settings › Language & Region), or why not. Nothing says which language a segment is in, so each language
    /// transcribes it and the model gets every reading, labelled.
    static func engine(languages: [String] = Locale.preferredLanguages) async -> (SpeechEngine?, State) {
        let auth = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard auth == .authorized else { return (nil, .denied) }
        var engines: [(String, SpeechEngine)] = []
        for id in languages {
            let locale = Locale(identifier: id)
            let tag = locale.language.languageCode?.identifier ?? id
            guard engines.count < 2, !engines.contains(where: { $0.0 == tag }), let e = await single(locale) else { continue }
            engines.append((tag, e))
        }
        DebugLog.write("audio: speech in \(engines.map(\.0)) (phone languages \(languages))")
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

// MARK: several languages over the same sound

/// One session per language; the text is every non-empty reading, "[zh] … [en] …" (just the text for one language).
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

    static func label(_ languages: [String], _ texts: [String]) -> String {
        guard languages.count > 1 else { return texts.first ?? "" }
        return zip(languages, texts).filter { !$0.1.isEmpty }.map { "[\($0.0)] \($0.1)" }.joined(separator: " ")
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
            return MultiEngine.label(languages, texts)
        }
    }

    private final class Session: SpeechSession {
        let languages: [String]
        let sessions: [SpeechSession]
        init(languages: [String], sessions: [SpeechSession]) { (self.languages, self.sessions) = (languages, sessions) }

        func append(_ buffer: AVAudioPCMBuffer) { sessions.forEach { $0.append(buffer) } }

        func finish() async -> String {
            var texts: [String] = []
            for s in sessions { texts.append(await s.finish()) }
            return MultiEngine.label(languages, texts)
        }
    }
}

// MARK: iOS 26: SpeechAnalyzer / SpeechTranscriber (on the device, the system downloads the model)

@available(iOS 26, *)
final class AnalyzerEngine: SpeechEngine {
    let format: AVAudioFormat
    private let locale: Locale

    private init(locale: Locale, format: AVAudioFormat) { (self.locale, self.format) = (locale, format) }

    static func make(locale: Locale) async -> AnalyzerEngine? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let probe = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
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
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        let results = Task<String, Never> {
            var final = "", volatile = ""
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal { final += text; volatile = "" } else { volatile = text }
                    onPartial(final + volatile)
                }
            } catch {
                DebugLog.write("audio: transcriber stopped: \(error.localizedDescription)")
            }
            return final + volatile
        }
        return Session(analyzer: analyzer, feed: feed, results: results)
    }

    private final class Session: SpeechSession {
        let analyzer: SpeechAnalyzer
        let feed: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Never>

        init(analyzer: SpeechAnalyzer, feed: AsyncStream<AnalyzerInput>.Continuation, results: Task<String, Never>) {
            (self.analyzer, self.feed, self.results) = (analyzer, feed, results)
        }

        func append(_ buffer: AVAudioPCMBuffer) { feed.yield(AnalyzerInput(buffer: buffer)) }

        func finish() async -> String {
            feed.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            return await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let text = result.bestTranscription.formattedString
                onPartial(text)
                session?.update(text, final: result.isFinal)
            }
            if error != nil { session?.update(nil, final: true) }
        }
        return session
    }

    private final class Session: SpeechSession, @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        private let lock = NSLock()
        private var text = ""
        private var done = false
        private var waiter: CheckedContinuation<String, Never>?

        init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }

        func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

        func update(_ new: String?, final: Bool) {
            lock.lock()
            if let new { text = new }
            let w = final && !done ? waiter : nil
            if final { done = true; waiter = nil }
            let out = text
            lock.unlock()
            w?.resume(returning: out)
        }

        func finish() async -> String {
            request.endAudio()
            let out = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
                lock.lock()
                if done { let t = text; lock.unlock(); c.resume(returning: t); return }
                waiter = c
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.update(nil, final: true) }
            }
            task = nil
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
