import AVFoundation

/// AirPlay mirroring audio: raw AAC-ELD access units (44.1 kHz, stereo, 480 samples each) to PCM in the format
/// the speech engine wants (usually 16 kHz mono).
final class AudioDecoder {
    /// AudioSpecificConfig of the mirroring stream: AAC-ELD, 44.1 kHz, 2 channels, 480-sample frames.
    static let config = Data([0xF8, 0xE8, 0x50, 0x00])
    static let samplesPerFrame: AVAudioFrameCount = 480

    let output: AVAudioFormat
    private let input: AVAudioFormat
    private let decoder: AVAudioConverter
    private let pcm: AVAudioFormat
    private var resampler: AVAudioConverter?

    init?(output: AVAudioFormat, config: Data = AudioDecoder.config) {
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: Self.samplesPerFrame, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false),
              let decoder = AVAudioConverter(from: input, to: pcm) else { return nil }
        decoder.magicCookie = config
        (self.input, self.pcm, self.decoder, self.output) = (input, pcm, decoder, output)
        if output != pcm {
            guard let resampler = AVAudioConverter(from: pcm, to: output) else { return nil }
            resampler.primeMethod = .none  // no leading silence, timestamps stay put
            self.resampler = resampler
        }
    }

    /// One frame to PCM in `output`; nil if it does not decode.
    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty, let decoded = decodeAAC(frame) else { return nil }
        guard let resampler else { return decoded }
        let ratio = output.sampleRate / pcm.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(decoded.frameLength) * ratio) + 16)
        else { return nil }
        var fed = false
        var error: NSError?
        resampler.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return decoded
        }
        return error == nil ? out : nil
    }

    private func decodeAAC(_ frame: Data) -> AVAudioPCMBuffer? {
        let packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: frame.count)
        frame.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: frame.count) }
        packet.byteLength = UInt32(frame.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(frame.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Self.samplesPerFrame * 2) else { return nil }
        var fed = false
        var error: NSError?
        let status = decoder.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return packet
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }

    /// Loudness of a buffer in dBFS (all channels); -160 for silence.
    static func level(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength), channels = Int(b.format.channelCount)
        guard n > 0 else { return -160 }
        var sum = 0.0
        if let f = b.floatChannelData {
            for c in 0..<channels { for i in 0..<n { sum += Double(f[c][i] * f[c][i]) } }
        } else if let s = b.int16ChannelData {
            for c in 0..<channels { for i in 0..<n { let v = Double(s[c][i]) / 32768; sum += v * v } }
        }
        let rms = (sum / Double(n * channels)).squareRoot()
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}
