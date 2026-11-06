import AVFoundation
import XCTest
@testable import IPhoneAgent

/// AirPlay audio: records off the TCP link, AAC-ELD decoding, sound segments, and the Heard block in the prompt.
@MainActor final class AudioTests: XCTestCase {
    private func record(seq: UInt16, flags: UInt8, frame: Data = Data(), ms: UInt32 = 7, ts: UInt32 = 44100) -> Data {
        var d = Data([UInt8(seq & 0xff), UInt8(seq >> 8), AudioRecord.flag | flags])
        guard flags & AudioRecord.endFlag == 0 else { return d }
        for v in [ms, ts] { d.append(contentsOf: (0..<4).map { UInt8(v >> (8 * $0) & 0xff) }) }
        return d + frame
    }

    func testRecordsParseAndNeverLookLikeVideo() {
        let r = AudioRecord(record(seq: 0x0102, flags: AudioRecord.startFlag, frame: Data([9, 8, 7]), ms: 1000, ts: 0x01020304))
        XCTAssertEqual(r?.seq, 0x0102)
        XCTAssertEqual(r?.start, true)
        XCTAssertEqual(r?.end, false)
        XCTAssertEqual(r?.boardMs, 1000)
        XCTAssertEqual(r?.rtpTs, 0x01020304)
        XCTAssertEqual(r?.frame, Data([9, 8, 7]))
        let end = AudioRecord(record(seq: 3, flags: AudioRecord.endFlag))
        XCTAssertEqual(end?.end, true)
        XCTAssertEqual(end?.frame, Data())
        XCTAssertTrue(AudioRecord.isAudio(record(seq: 1, flags: 0, frame: Data([1]))))
        let video = Data([5, 0, 0x01 | 0x04, 0xaa])  // START | IDR
        XCTAssertFalse(AudioRecord.isAudio(video))
        XCTAssertNil(AudioRecord(video))
        XCTAssertNil(AudioRecord(Data([1, 0, 0x80, 1, 2])))  // truncated header
    }

    /// The video assembler never sees audio: a seq gap there would drop video until the next keyframe.
    func testStreamSplitsAudioFromVideo() {
        var video: [Data] = [], audio: [Data] = []
        let stream = VideoStream()
        stream.onChunk = { video.append($0) }
        stream.onAudio = { audio.append($0) }
        let a = record(seq: 0, flags: AudioRecord.startFlag, frame: Data([1, 2])), v = Data([0, 0, 0x01, 0xaa])
        var bytes = Data([0, 0])  // the hello ack
        for chunk in [v, a] { bytes += Data([UInt8(chunk.count), 0]) + chunk }
        stream.received(bytes)
        XCTAssertEqual(video, [v])
        XCTAssertEqual(audio, [a])
    }

    /// Encode a tone and silence with the system AAC-ELD encoder in the mirroring format, then decode them.
    func testDecoderTurnsAACELDIntoPCM() throws {
        let frames = try Self.encodeELD(seconds: 0.5, tone: true) + Self.encodeELD(seconds: 0.5, tone: false)
        XCTAssertGreaterThan(frames.count, 20)
        let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let decoder = try XCTUnwrap(AudioDecoder(output: out))  // the stream's fixed config, as AirPlay sends no cookie
        let levels = frames.compactMap { decoder.decode($0) }.map(AudioDecoder.level)
        XCTAssertGreaterThan(levels.count, frames.count - 3)
        XCTAssertGreaterThan(levels[levels.count / 4], AudioFeed.soundDB)  // the tone
        XCTAssertLessThan(levels[levels.count - 2], AudioFeed.soundDB)     // the silence
        XCTAssertNil(decoder.decode(Data()))
    }

    func testMirroringConfigIsWhatTheEncoderMakes() throws {
        _ = try Self.encodeELD(seconds: 0.05, tone: true)
        // The encoder's cookie is an ESDS; its DecoderSpecificInfo (tag 05, length 4) is the AudioSpecificConfig.
        let cookie = try XCTUnwrap(Self.lastConfig)
        XCTAssertNotNil(cookie.range(of: Data([0x05, 0x80, 0x80, 0x80, 0x04]) + AudioDecoder.config))
    }

    func testSegmentsBecomeTheHeardBlock() async throws {
        let feed = AudioFeed()
        var t = 100.0
        feed.clock = { t }
        let engine = FakeSpeech(text: "Your code is 4 2 7 1")
        feed.use(engine)
        XCTAssertEqual(feed.heard(), "")  // off: no audio part at all
        feed.enabled = true
        XCTAssertEqual(feed.heard(), "Phone audio: listening; no sound in the last 30 s.")
        let tone = try Self.encodeELD(seconds: 0.3, tone: true)
        feed.receive(record(seq: 0, flags: AudioRecord.startFlag, frame: tone[0]))
        await Task.yield()
        for (i, f) in tone.dropFirst().enumerated() { feed.receive(record(seq: UInt16(i + 1), flags: 0, frame: f)) }
        t = 104
        XCTAssertTrue(feed.heard().contains("now, 4 s so far"))
        feed.receive(record(seq: UInt16(tone.count), flags: AudioRecord.endFlag))
        for _ in 0..<20 where feed.segments.last?.final != true { try await Task.sleep(nanoseconds: 10_000_000) }
        t = 110
        XCTAssertEqual(feed.heard(), "Heard (phone audio, last 30 s; words transcribed on the phone):\n- 6 s ago, 4 s long: \"Your code is 4 2 7 1\"")
        XCTAssertGreaterThan(engine.appended, 0)
        XCTAssertEqual(feed.gaps, 0)
        t = 200
        XCTAssertEqual(feed.heard(), "Phone audio: listening; no sound in the last 30 s.")  // older than 30 s
        feed.linked = { false }
        XCTAssertTrue(feed.heard().hasPrefix("Phone audio: not reaching the app"))
    }

    func testQuietSegmentIsNotHeard() async throws {
        let feed = AudioFeed()
        feed.use(FakeSpeech(text: ""))
        feed.enabled = true
        let quiet = try Self.encodeELD(seconds: 0.2, tone: false)
        feed.receive(record(seq: 0, flags: AudioRecord.startFlag, frame: quiet[0]))
        for (i, f) in quiet.dropFirst().enumerated() { feed.receive(record(seq: UInt16(i + 1), flags: 0, frame: f)) }
        feed.receive(record(seq: UInt16(quiet.count), flags: AudioRecord.endFlag))
        XCTAssertEqual(feed.segments.count, 1)
        XCTAssertEqual(feed.heard(), "Phone audio: listening; no sound in the last 30 s.")
    }

    func testSurerLanguageReadingIsKept() {
        let zh = Reading(text: "验证码四七二九", confidence: 0.9), en = Reading(text: "Ching fei", confidence: 0.3)
        XCTAssertEqual(MultiEngine.pick(["en", "zh"], [en, zh]), "[zh] 验证码四七二九")
        XCTAssertEqual(MultiEngine.pick(["en", "zh"], [en, .empty]), "[en] Ching fei")
        XCTAssertEqual(MultiEngine.pick(["en", "zh"], [Reading(text: "a", confidence: 0.5), Reading(text: "b", confidence: 0.5)]), "[en] a")
        XCTAssertEqual(MultiEngine.pick(["en"], [en]), "Ching fei")
        XCTAssertEqual(MultiEngine.pick(["en", "zh"], [.empty, .empty]), "")
        XCTAssertEqual(MultiEngine([("en", FakeSpeech(text: "")), ("zh", FakeSpeech(text: ""))])?.languages, ["en", "zh"])
        XCTAssertNil(MultiEngine([]))
    }

    func testOffIgnoresAudio() {
        let feed = AudioFeed()
        feed.receive(record(seq: 0, flags: AudioRecord.startFlag, frame: Data([1])))
        XCTAssertTrue(feed.segments.isEmpty)
    }

    func testPromptCarriesHeardOnlyWithSound() async throws {
        let actor = FakeModel { _ in "THINK: ok\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        var sound = ""
        agent.heard = { sound }
        _ = try await agent.nextActions()
        XCTAssertFalse(actor.prompts[0].contains("Heard"))
        XCTAssertTrue(actor.prompts[0].hasSuffix("Recent actions:\n(none)\n\nNext action?"))
        sound = "Heard (phone audio, last 30 s):\n- now, 2 s so far: \"hello\""
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts[1].hasSuffix("Recent actions:\n(none)\n\n" + sound + "\n\nNext action?"))
    }

    // MARK: helpers

    private static var lastConfig: Data?

    /// AAC-ELD frames in the mirroring format (44.1 kHz, stereo, 480 samples): a 440 Hz tone or silence.
    static func encodeELD(seconds: Double, tone: Bool) throws -> [Data] {
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 480, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let eld = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd))
        let encoder = try XCTUnwrap(AVAudioConverter(from: pcm, to: eld))
        encoder.bitRate = 64000
        let n = AVAudioFrameCount(seconds * 44100)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: n))
        input.frameLength = n
        for c in 0..<2 { for i in 0..<Int(n) { input.floatChannelData![c][i] = tone ? 0.5 * sinf(Float(i) * 2 * .pi * 440 / 44100) : 0 } }
        var fed = false, frames: [Data] = []
        while true {
            let out = AVAudioCompressedBuffer(format: eld, packetCapacity: 8, maximumPacketSize: encoder.maximumOutputPacketSize)
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, s in
                if fed { s.pointee = .endOfStream; return nil }
                fed = true
                s.pointee = .haveData
                return input
            }
            for i in 0..<Int(out.packetCount) {
                let d = out.packetDescriptions![i]
                frames.append(Data(bytes: out.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        lastConfig = encoder.magicCookie
        return frames
    }
}

/// Collects PCM and answers with a fixed text.
final class FakeSpeech: SpeechEngine {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let text: String
    private(set) var appended = 0

    init(text: String) { self.text = text }

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession { Session(self) }

    private final class Session: SpeechSession {
        let owner: FakeSpeech
        init(_ owner: FakeSpeech) { self.owner = owner }
        func append(_ buffer: AVAudioPCMBuffer) { owner.appended += 1 }
        func finish() async -> Reading { Reading(text: owner.text, confidence: 0.5) }
    }
}
