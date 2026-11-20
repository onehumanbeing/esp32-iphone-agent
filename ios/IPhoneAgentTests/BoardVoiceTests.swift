import AVFoundation
import XCTest
@testable import IPhoneAgent

/// A StopWatch's voice: its chunks, the ADPCM, the transcript back to the board, yellow and blue.
@MainActor final class BoardVoiceTests: XCTestCase {
    /// The board's encoder on 0, 1000, 3000, 2000, -500, -4000, 100, 32000 from (0, 0) gives these bytes
    /// (hardware/tests test_ima); decoding them follows the samples.
    func testADPCMDecodesTheBoardsVector() {
        let out = IMAADPCM.decode(pred: 0, index: 0, [0x70, 0x77, 0xff, 0x75])
        XCTAssertEqual(out.count, 8)
        XCTAssertEqual(out.last, 1063)  // the encoder's state after the 8th sample
        XCTAssertGreaterThan(out[2], out[1])
        XCTAssertLessThan(out[5], out[4])
    }

    func testChunksParseAndOnlyVoiceIsVoice() {
        let start = Data([5, 0, 0xC1] + Array("zh-CN".utf8))
        XCTAssertTrue(VoiceChunk.isVoice(start))
        XCTAssertEqual(VoiceChunk(start), VoiceChunk(seq: 5, kind: .start(locale: "zh-CN")))
        let sound = Data([6, 0, 0xC0, 0, 0, 0, 0x70, 0x77])
        XCTAssertEqual(VoiceChunk(sound)?.kind, .sound(Array(IMAADPCM.decode(pred: 0, index: 0, [0x70, 0x77]))))
        XCTAssertEqual(VoiceChunk(Data([7, 1, 0xC2]))?.kind, .end)
        XCTAssertEqual(VoiceChunk(Data([7, 1, 0xC2]))?.seq, 263)
        XCTAssertFalse(VoiceChunk.isVoice(Data([1, 0, 0x81, 0, 0])))  // AirPlay audio
        XCTAssertFalse(VoiceChunk.isVoice(Data([1, 0, 0x45])))        // video, IDR + resume
        XCTAssertNil(VoiceChunk(Data([1, 0, 0xC0, 1])))               // sound without its state
    }

    func testLinesForTheBoardAndItsButtons() {
        XCTAssertEqual(StopWatchUI.voiceLine(.heard("打开\n微信"), max: 200), "voice heard 打开 微信")
        XCTAssertEqual(StopWatchUI.voiceLine(.failed("none"), max: 200), "voice fail none")
        let long = StopWatchUI.voiceLine(.heard(String(repeating: "中", count: 60)), max: 200)
        XCTAssertEqual(long.utf8.count, "voice heard ".utf8.count + 120)  // the board shows 120 bytes
        XCTAssertLessThanOrEqual(StopWatchUI.voiceLine(.heard(String(repeating: "a", count: 300)), max: 60).utf8.count, 60)
        XCTAssertEqual(StopWatchUI.action("voice go", picks: []), .voice(true))
        XCTAssertEqual(StopWatchUI.action("voice cancel", picks: []), .voice(false))
        XCTAssertNil(StopWatchUI.action("voice", picks: []))
        XCTAssertEqual(BoardVoice.unlabelled("[zh] 打开微信"), "打开微信")
        XCTAssertEqual(BoardVoice.unlabelled("[x] keep"), "[x] keep")
    }

    func testAnswerGoesInPartsOfWholeCharacters() {
        let text = String(repeating: "天气很好。", count: 30)  // 450 bytes
        let lines = StopWatchUI.answerLines(text, room: 100)
        XCTAssertTrue(lines.first!.hasPrefix("answer ") && lines.dropFirst().allSatisfy { $0.hasPrefix("answer+ ") })
        XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 100 })
        XCTAssertEqual(lines.map { $0.split(separator: " ", maxSplits: 1)[1] }.joined(), text)
        let long = StopWatchUI.answerLines(String(repeating: "a", count: 900), room: 170)
        XCTAssertEqual(long.map { $0.split(separator: " ", maxSplits: 1)[1].count }.reduce(0, +), StopWatchUI.maxAnswer)
        XCTAssertEqual(StopWatchUI.answerLines("  ", room: 100), [])
    }

    func testAConfirmIsMarkedAndBlueSkipsIt() throws {
        var state = StopWatchUI.idle
        state.phase = .help
        let (line, _) = try XCTUnwrap(StopWatchUI.command(.show(state), confirm: true))
        XCTAssertTrue(line.contains(#""h":1"#), line)
        state.phase = .running
        XCTAssertFalse(try XCTUnwrap(StopWatchUI.command(.show(state), confirm: true)).0.contains(#""h""#))
        XCTAssertEqual(StopWatchUI.action("skip", picks: []), .command(.skip))
    }

    func testTheRunsTimeGoesWithItsLinesNotWithStandby() throws {
        var state = StopWatchUI.idle
        XCTAssertFalse(try XCTUnwrap(StopWatchUI.command(.show(state), elapsed: 12)).0.contains(#""e""#))
        state.phase = .running
        XCTAssertTrue(try XCTUnwrap(StopWatchUI.command(.show(state), elapsed: 12)).0.contains(#""e":12"#))
        state.finished = true
        XCTAssertTrue(try XCTUnwrap(StopWatchUI.command(.show(state), elapsed: 95)).0.contains(#""e":95"#))
    }

    func testALostLinkTheUserFixesGoesToTheBoard() throws {
        var state = StopWatchUI.idle
        state.phase = .running
        XCTAssertTrue(try XCTUnwrap(StopWatchUI.command(.show(state), warn: "mirror")).0.contains(#""w":"mirror""#))
        XCTAssertFalse(try XCTUnwrap(StopWatchUI.command(.show(state))).0.contains(#""w""#))
        XCTAssertEqual(StopWatchUI.warning(.frames), "mirror")
        XCTAssertEqual(StopWatchUI.warning(.locked), "locked")
        XCTAssertEqual(StopWatchUI.warning(.pointer), "hid")
        XCTAssertNil(StopWatchUI.warning(.hotspot))
    }

    func testTheUILineSaysTheAppTakesVoice() throws {
        let (line, _) = try XCTUnwrap(StopWatchUI.command(.show(StopWatchUI.idle)))
        XCTAssertTrue(line.contains(#""v":1"#), line)
    }

    /// Start, sound, end: one session in the board's locale, the text back, yellow takes it once; blue drops it.
    func testARecordingIsTranscribedInTheBoardsLanguage() async throws {
        let voice = BoardVoice()
        let engine = FakeEngine()
        var locales: [String] = [], results: [BoardVoice.Result] = []
        voice.makeEngine = { locale in locales.append(locale); return (engine, .ready) }
        voice.onResult = { results.append($0) }
        engine.reading = "打开微信"
        voice.receive(Data([0, 0, 0xC1] + Array("zh-CN".utf8)))
        voice.receive(Data([1, 0, 0xC0, 0, 0, 0] + [UInt8](repeating: 0x11, count: 100)))  // while the session starts
        try await wait { engine.sessions == 1 }
        voice.receive(Data([2, 0, 0xC0, 0, 0, 0] + [UInt8](repeating: 0x22, count: 100)))
        voice.receive(Data([3, 0, 0xC2]))
        try await wait { !results.isEmpty }
        XCTAssertEqual(locales, ["zh-CN"])
        XCTAssertEqual(engine.frames, 400)
        XCTAssertEqual(results, [.heard("打开微信")])
        XCTAssertEqual(voice.take(), "打开微信")
        XCTAssertNil(voice.take())

        // nothing heard: `fail none`; blue mid-way: no text at all, the engine is reused
        engine.reading = ""
        voice.receive(Data([4, 0, 0xC1] + Array("zh-CN".utf8)))
        try await wait { engine.sessions == 2 }
        voice.receive(Data([5, 0, 0xC2]))
        try await wait { results.count == 2 }
        XCTAssertEqual(results.last, .failed("none"))
        engine.reading = "never shown"
        voice.receive(Data([6, 0, 0xC1] + Array("zh-CN".utf8)))
        try await wait { engine.sessions == 3 }
        voice.cancel()
        voice.receive(Data([7, 0, 0xC2]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(results.count, 2)
        XCTAssertNil(voice.take())
        XCTAssertEqual(locales, ["zh-CN"])
    }

    func testNoSpeechPermissionTellsTheBoard() async throws {
        let voice = BoardVoice()
        var results: [BoardVoice.Result] = []
        voice.makeEngine = { _ in (nil, .denied) }
        voice.onResult = { results.append($0) }
        voice.receive(Data([0, 0, 0xC1] + Array("en-US".utf8)))
        try await wait { !results.isEmpty }
        XCTAssertEqual(results, [.failed("denied")])
    }

    func testPCMGoesIntoTheEnginesFormat() throws {
        let pcm: [Int16] = [0, 16384, -16384, 32767]
        let f = try XCTUnwrap(BoardVoice.buffer(pcm, format: nil))
        XCTAssertEqual(f.frameLength, 4)
        XCTAssertEqual(f.floatChannelData![0][1], 0.5, accuracy: 0.001)
        let int16 = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let i = try XCTUnwrap(BoardVoice.buffer(pcm, format: int16))
        XCTAssertEqual(i.int16ChannelData![0][3], 32767)
        let other = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let up = try XCTUnwrap(BoardVoice.buffer([Int16](repeating: 1000, count: 1600), format: other))
        XCTAssertGreaterThan(up.frameLength, 4000)
    }

    private func wait(_ condition: () -> Bool, timeout: Double = 2) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class FakeEngine: SpeechEngine, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var reading = ""
    var sessions = 0
    var frames = 0

    func begin(onPartial: @escaping @Sendable (String) -> Void) async throws -> SpeechSession {
        sessions += 1
        return Session(engine: self)
    }

    final class Session: SpeechSession {
        let engine: FakeEngine
        init(engine: FakeEngine) { self.engine = engine }
        func append(_ buffer: AVAudioPCMBuffer) { engine.frames += Int(buffer.frameLength) }
        func finish() async -> Reading { Reading(text: engine.reading, confidence: 0.9) }
    }
}
