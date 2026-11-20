import AVFoundation

/// One chunk of a StopWatch's microphone (docs/ble-protocol.md, "StopWatch voice"), on the BLE `video`
/// characteristic: [seq u16 LE][flags 0xC0 | start 1 | end 2][payload]. Start: the board's speech locale ("zh-CN").
/// Sound: [pred i16 LE][step index u8][IMA ADPCM, 16 kHz mono, low nibble first]. End: nothing.
struct VoiceChunk: Equatable {
    static let mask: UInt8 = 0xC0
    enum Kind: Equatable { case start(locale: String), sound([Int16]), end }

    let seq: UInt16
    let kind: Kind

    /// The board's mic, not video (never sets 0x80) nor AirPlay audio (0x80 without 0x40).
    static func isVoice(_ chunk: Data) -> Bool { chunk.count >= 3 && chunk[chunk.startIndex + 2] & mask == mask }

    init(seq: UInt16, kind: Kind) { (self.seq, self.kind) = (seq, kind) }

    init?(_ chunk: Data) {
        let b = [UInt8](chunk)
        guard b.count >= 3, b[2] & Self.mask == Self.mask else { return nil }
        seq = UInt16(b[0]) | UInt16(b[1]) << 8
        if b[2] & 1 != 0 {
            kind = .start(locale: String(decoding: b[3...], as: UTF8.self))
        } else if b[2] & 2 != 0 {
            kind = .end
        } else {
            guard b.count >= 6 else { return nil }
            let pred = Int16(bitPattern: UInt16(b[3]) | UInt16(b[4]) << 8)
            kind = .sound(IMAADPCM.decode(pred: pred, index: b[5], Array(b[6...])))
        }
    }
}

/// IMA ADPCM, as the board's encoder (hardware/hid_bridge/src/ui/ima_adpcm.c).
enum IMAADPCM {
    private static let indexTable: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]
    private static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
        24623, 27086, 29794, 32767]

    static func decode(pred: Int16, index: UInt8, _ data: [UInt8]) -> [Int16] {
        var p = Int(pred), i = min(Int(index), 88)
        var out: [Int16] = []
        out.reserveCapacity(data.count * 2)
        for byte in data {
            for code in [Int(byte & 15), Int(byte >> 4)] {
                let st = steps[i]
                var diff = st >> 3
                if code & 4 != 0 { diff += st }
                if code & 2 != 0 { diff += st >> 1 }
                if code & 1 != 0 { diff += st >> 2 }
                p = max(-32768, min(32767, code & 8 != 0 ? p - diff : p + diff))
                i = max(0, min(88, i + indexTable[code]))
                out.append(Int16(p))
            }
        }
        return out
    }
}

/// Voice from an M5Stack StopWatch (yellow held): its mic arrives as VoiceChunks, is transcribed on the phone in the
/// board's language, and the text goes back to the board's screen. Yellow there then runs it (`take()`), blue drops it.
@MainActor final class BoardVoice {
    enum Result: Equatable {
        case heard(String)
        case failed(String)  // `voice fail <code>`: none, denied, unavailable, start
    }

    /// The text for the board (`voice heard` / `voice fail`).
    var onResult: ((Result) -> Void)?
    /// Speech for one locale; tests swap it.
    var makeEngine: (String) async -> (SpeechEngine?, SpeechSetup.State) = { await SpeechSetup.engine(languages: [$0]) }
    /// The last text heard, until yellow runs it or blue drops it.
    private(set) var text: String?

    static let rate = 16000.0
    private var engine: (locale: String, engine: SpeechEngine)?
    private var session: SpeechSession?
    private var pending: [[Int16]]? = nil  // sound while the session starts
    private var ended = false                      // END came while it started
    private var generation = 0
    private var lastSeq: UInt16?
    private(set) var samples = 0, gaps = 0

    func receive(_ chunk: Data) {
        guard let c = VoiceChunk(chunk) else { return }
        if let last = lastSeq, c.seq != last &+ 1 { gaps += 1 }
        lastSeq = c.seq
        switch c.kind {
        case .start(let locale): begin(locale.isEmpty ? SpeechLanguages.first : locale)
        case .sound(let pcm): append(pcm)
        case .end: end()
        }
    }

    /// Yellow on the board: the text to run, once.
    func take() -> String? {
        defer { text = nil }
        return text
    }

    /// Blue on the board: the recording or its text is dropped (a transcript still coming is ignored).
    func cancel() {
        generation += 1
        let s = session
        (session, pending, text, ended) = (nil, nil, nil, false)
        if let s { Task { _ = await s.finish() } }
    }

    private func begin(_ locale: String) {
        cancel()
        let gen = generation
        (pending, samples, gaps) = ([], 0, 0)
        DebugLog.write("stopwatch: voice started (\(locale))")
        Task {
            if engine?.locale != locale {
                let (made, state) = await makeEngine(locale)
                guard gen == generation else { return }
                guard let made else {
                    DebugLog.write("stopwatch: no speech engine for \(locale): \(state)")
                    pending = nil
                    return report(.failed(state == .denied ? "denied" : "unavailable"))
                }
                engine = (locale, made)
            }
            guard let e = engine?.engine, let s = try? await e.begin(onPartial: { _ in }) else {
                if gen == generation { pending = nil; report(.failed("unavailable")) }
                return
            }
            guard gen == generation else { _ = await s.finish(); return }
            pending?.forEach { if let b = Self.buffer($0, format: e.format) { s.append(b) } }
            pending = nil
            session = s
            if ended { end() }
        }
    }

    private func append(_ pcm: [Int16]) {
        samples += pcm.count
        guard let session else { pending?.append(pcm); return }
        if let b = Self.buffer(pcm, format: engine?.engine.format) { session.append(b) }
    }

    private func end() {
        guard let s = session else {
            if pending != nil { ended = true }  // still starting: it finishes once the session is there
            return
        }
        let gen = generation
        (session, ended) = (nil, false)
        DebugLog.write(String(format: "stopwatch: voice ended, %.1f s, %d gaps", Double(samples) / Self.rate, gaps))
        Task {
            let r = await s.finish()
            guard gen == generation else { return }
            let words = Self.unlabelled(r.text)
            DebugLog.write("stopwatch: heard \"\(words.prefix(200))\"")
            text = words.isEmpty ? nil : words
            report(words.isEmpty ? .failed("none") : .heard(words))
        }
    }

    private func report(_ r: Result) { onResult?(r) }

    /// MultiEngine labels a reading "[zh] …" when it ran several languages; the task gets the words only.
    static func unlabelled(_ text: String) -> String {
        guard let r = text.range(of: #"^\[[a-z]{2,3}\] "#, options: .regularExpression) else { return text }
        return String(text[r.upperBound...])
    }

    /// 16 kHz mono PCM in the engine's format (nil format: Float32 16 kHz mono, converted later if it differs).
    static func buffer(_ pcm: [Int16], format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard !pcm.isEmpty, let float = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.count))
        else { return nil }
        float.frameLength = AVAudioFrameCount(pcm.count)
        for (i, v) in pcm.enumerated() { float.floatChannelData![0][i] = Float(v) / 32768 }
        guard let format, format != source else { return float }
        if format.commonFormat == .pcmFormatInt16, format.sampleRate == rate, format.channelCount == 1,
           let int = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)) {
            int.frameLength = AVAudioFrameCount(pcm.count)
            pcm.withUnsafeBufferPointer { int.int16ChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
            return int
        }
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(pcm.count) * format.sampleRate / rate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return float
        }
        return error == nil ? out : nil
    }
}
