import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Annex-B access units -> VideoToolbox -> JPEG (q 0.75). Runs on its own serial queue.
final class H264Decoder: @unchecked Sendable {  // confined to `queue`
    struct Frame {
        let jpeg: Data
        let width: Int, height: Int
        let decodeMs: Double
        let unit: AccessUnit
        /// The decoded frame's size when black bars were cropped off it (Letterbox); nil: the frame is as decoded.
        var uncropped: CGSize? = nil
    }

    var onFrame: ((Frame) -> Void)?
    var onError: ((String) -> Void)?
    /// iOS dropped the session and the cached GOP was decoded again (on the main thread; for the `vdiag` line).
    var onSessionLost: (() -> Void)?
    var quality: Double = 0.75
    let queue = DispatchQueue(label: "video.decode")

    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// Every unit since the last IDR. A still screen gets an IDR only every few minutes, so when iOS drops
    /// the session (e.g. going to background) the GOP is decoded again from here instead of fetched again
    /// over BLE (a snap of a long GOP takes up to a minute).
    private var gop: [AccessUnit] = []
    private var gopBytes = 0
    private static let gopMax = 64 << 20
    /// At most one JPEG per `emitGap`, the newest always last: a GOP resent on reconnect (1276 frames after a
    /// still screen, 2026-11-02) made a JPEG and a SwiftUI redraw per frame, 48 s of CPU, and iOS killed the app.
    /// The live stream is ≤5 fps, so it is not thinned.
    static let emitGap = 0.15
    private var lastEmit = 0.0
    private var held: (CVImageBuffer, Double, AccessUnit)?
    /// Black bars cropped off before the JPEG (on `queue`); `screen` set by `setScreen`.
    private var letterbox = Letterbox()
    private var lastCrop: CGRect?

    /// The device screen's pixels (UIScreen.nativeBounds), for cropping black bars; any thread.
    func setScreen(_ size: CGSize) {
        queue.async { [self] in letterbox.screen = size }
    }

    /// Board time of the last IDR, and whether a unit from before it was dropped since (logged once per IDR).
    private var idrMs: UInt32?, droppedOld = false

    /// A P-frame stamped before the last IDR belongs to the GOP that IDR ended. Board firmware up to 0.2.5 sent the
    /// tail it kept past a full GOP once more after the next IDR (an iPad's rotation after its 4 MB GOP filled,
    /// 2026-11-17): decoded on top of the new IDR, every later frame failed (-12909) until mirroring restarted.
    static func belongsToAnEarlierGOP(_ unit: AccessUnit, idrMs: UInt32?) -> Bool {
        guard !unit.idr, !unit.config, let idrMs, unit.boardMs < idrMs else { return false }
        return idrMs - unit.boardMs < 600_000  // not a board that restarted its clock (its next IDR comes first anyway)
    }

    /// Decode one access unit (call on `queue`).
    func decode(_ unit: AccessUnit) {
        if Self.belongsToAnEarlierGOP(unit, idrMs: idrMs) {
            if !droppedOld {
                droppedOld = true
                let (at, idr) = (unit.boardMs, idrMs ?? 0)
                DispatchQueue.main.async { DebugLog.write("decoder: dropped units from before the last IDR (\(at) < \(idr) ms)") }
            }
            return
        }
        if unit.idr { (idrMs, droppedOld) = (unit.boardMs, false) }
        if unit.idr { (gop, gopBytes) = ([], 0) }
        if gopBytes + unit.data.count <= Self.gopMax, unit.idr || !gop.isEmpty {
            gop.append(unit)
            gopBytes += unit.data.count
        }
        let status = decodeOne(unit, emit: true)
        guard status != noErr else { return }
        resetSession()
        if gop.last?.data == unit.data, gop.first?.idr == true, replay() {
            let n = gop.count
            DispatchQueue.main.async { [weak self] in
                DebugLog.write("decoder: session lost (\(status)); decoded the GOP again (\(n) units)")
                self?.onSessionLost?()
            }
            return
        }
        onError?("decode failed \(status)" + (status == kVTInvalidSessionErr ? " (session lost, e.g. in background)" : ""))
        resetSession()  // rebuilt at the next IDR/config
    }

    /// A fresh session at once when the app goes to the background, the cached GOP decoded into it. The session
    /// from the foreground hung there: no frame and no error for 10 s, until iOS ended it (-12903) and the GOP was
    /// decoded again (2026-11-25, iPhone 13 Pro: the first frame of a run took 11 s). A session made in the
    /// background decodes on.
    /// Right at the background notification the new session fails too (2026-11-25: failed, then iOS ended the old
    /// one 2.7 s later): tried again every 0.5 s, up to `renewTries` times (3 s), then the decode-error path as before.
    static let renewTries = 6
    func renew(_ why: String, attempt: Int = 1) {
        queue.asyncAfter(deadline: .now() + (attempt == 1 ? 0 : 0.5)) { [self] in
            guard session != nil || attempt > 1 else { return }
            resetSession()
            guard gop.first?.idr == true else { return }
            let started = CFAbsoluteTimeGetCurrent(), ok = replay(), n = gop.count
            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            DispatchQueue.main.async { DebugLog.write("decoder: new session \(why) (try \(attempt)); GOP decoded again (\(n) units, \(ms) ms, \(ok ? "ok" : "failed"))") }
            if !ok, attempt < Self.renewTries { renew(why, attempt: attempt + 1) }
        }
    }

    /// Decode the cached GOP into a fresh session; only its last frame is shown. The frames before it are only
    /// references: decoded without an output image, asynchronously, and the ones no later frame refers to are
    /// skipped. One by one with an image each, a 15362-unit GOP (a mirroring session 2 hours old) took 69 s in the
    /// background, the whole wait before a run's first step (2026-11-26).
    private func replay() -> Bool {
        let failed = Flag()
        for (i, u) in gop.enumerated() {
            let last = i == gop.count - 1
            if !last, !u.idr, Self.unreferenced(u.data) { continue }
            if last, let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
            if decodeOne(u, emit: last, quiet: last ? nil : failed) != noErr || failed.on { return false }
        }
        return true
    }

    /// Set from VideoToolbox's callback thread during a replay.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Every slice in the unit has nal_ref_idc 0: no later frame is decoded from it.
    static func unreferenced(_ data: Data) -> Bool {
        var slices = 0
        for nal in annexBUnits(data) {
            let header = nal[nal.startIndex]
            guard [1, 5].contains(header & 0x1f) else { continue }
            if header & 0x60 != 0 { return false }
            slices += 1
        }
        return slices > 0
    }

    /// noErr also when there is nothing to decode yet (no slices, no SPS/PPS).
    /// `quiet`: a reference frame of a replay, decoded without an output image and asynchronously; a failure sets it.
    private func decodeOne(_ unit: AccessUnit, emit: Bool, quiet: Flag? = nil) -> OSStatus {
        var slices: [Data] = []
        for nal in annexBUnits(unit.data) {
            switch nal[nal.startIndex] & 0x1f {
            case 7: if nal != sps { sps = nal; resetSession() }
            case 8: if nal != pps { pps = nal; resetSession() }
            case 9, 6: break  // access unit delimiter, SEI
            default: slices.append(nal)
            }
        }
        guard !slices.isEmpty else { return noErr }
        guard ensureSession(), let session, let format else { return noErr }
        var avcc = Data()
        for s in slices {
            var len = UInt32(s.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(s)
        }
        guard let sample = makeSample(avcc, format) else { return noErr }
        let started = CFAbsoluteTimeGetCurrent()
        var flags = VTDecodeInfoFlags()
        let decodeFlags: VTDecodeFrameFlags = quiet == nil ? [] : [._EnableAsynchronousDecompression, ._DoNotOutputFrame]
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: decodeFlags,
                                                       infoFlagsOut: &flags) { [weak self] status, _, image, _, _ in
            if let quiet {
                if status != noErr { quiet.set() }
                return
            }
            guard let self else { return }
            guard status == noErr, let image else {
                self.onError?("decode callback status \(status)")
                return
            }
            guard emit else { return }
            self.emitThinned(image, ms: (CFAbsoluteTimeGetCurrent() - started) * 1000, unit: unit)
        }
        let callMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        if callMs > 500 { DispatchQueue.main.async { DebugLog.write(String(format: "decoder: a decode call took %.0f ms (status %d)", callMs, status)) } }
        return status
    }

    func emitThinned(_ image: CVImageBuffer, ms: Double, unit: AccessUnit) {
        let wait = lastEmit + Self.emitGap - CFAbsoluteTimeGetCurrent()
        guard wait > 0 else { return emitNow(image, ms: ms, unit: unit) }
        let flushPending = held != nil
        held = (image, ms, unit)
        guard !flushPending else { return }
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let (image, ms, unit) = self.held else { return }
            self.emitNow(image, ms: ms, unit: unit)
        }
    }

    private func emitNow(_ image: CVImageBuffer, ms: Double, unit: AccessUnit) {
        held = nil
        lastEmit = CFAbsoluteTimeGetCurrent()
        if let frame = jpeg(image, ms: ms, unit: unit) { onFrame?(frame) }
    }

    private func resetSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }
        var desc: CMFormatDescription?
        let ok = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard ok == noErr, let desc else { onError?("bad SPS/PPS \(ok)"); return false }
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &made)
        guard status == noErr, let made else { onError?("decoder create failed \(status)"); return false }
        format = desc
        session = made
        return true
    }

    private func makeSample(_ avcc: Data, _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    private func jpeg(_ buffer: CVImageBuffer, ms: Double, unit: AccessUnit) -> Frame? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard var image else { onError?("frame -> image failed"); return nil }
        let decoded = CGSize(width: image.width, height: image.height)
        let full = image
        let crop = letterbox.content(width: image.width, height: image.height) { Letterbox.isBlack(full, $0) }
        if crop != lastCrop {
            lastCrop = crop
            let line = crop.map { "video: cropping black bars: \(image.width)x\(image.height) -> \(Int($0.width))x\(Int($0.height))" }
                ?? "video: frames are the screen (\(image.width)x\(image.height)), nothing cropped"
            DispatchQueue.main.async { DebugLog.write(line) }
        }
        if let crop, let cropped = image.cropping(to: crop) { image = cropped }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Frame(jpeg: out as Data, width: image.width, height: image.height, decodeMs: ms, unit: unit,
                     uncropped: crop == nil ? nil : decoded)
    }
}
