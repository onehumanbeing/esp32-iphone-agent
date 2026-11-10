import CoreImage
import CoreMedia
import ImageIO
import UIKit
import UniformTypeIdentifiers
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

struct ScreenCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// User-authorized screen source. Holds only the latest JPEG; never records a video.
@available(iOS 27.0, *)
@MainActor final class ScreenCaptureFeed: NSObject, ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    private(set) var size = CGSize.zero
    private var choosing = false
    private var capturing = false
    private var note = ""
    private(set) var updated = 0.0
    private(set) var capturedAt = 0.0
    #if canImport(ScreenCaptureKit)
    private lazy var picker = SCContentSharingPicker.shared
    private var callbacks: CaptureCallbacks!
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var generation: UUID?
    private var selection: CheckedContinuation<Void, Error>?
    private var registered = false
    #endif

    static var isAvailable: Bool {
        #if canImport(ScreenCaptureKit)
        SCContentSharingPicker.shared.isAvailable
        #else
        false
        #endif
    }

    /// Preserve the selected content aspect ratio while limiting capture bandwidth.
    static func captureSize(for content: CGSize) -> CGSize {
        CGSize(width: 960, height: (960 * content.height / content.width).rounded())
    }

    override init() {
        super.init()
        #if canImport(ScreenCaptureKit)
        callbacks = CaptureCallbacks(owner: self)
        #endif
    }
    // A quiet display need not produce new pixels. Session/status callbacks, rather
    // than the age of unchanged content, determine whether its latest image is usable.
    var live: Bool { capturing && frame != nil }
    var aspect: Double { size.height > 0 ? size.width / size.height : DeviceScreen.aspect }

    /// Ending sharing needs a new foreground authorization, rather than AirPlay recovery.
    func checkAvailability() throws {
        guard capturing else {
            throw ScreenCaptureError(message: note.isEmpty
                ? String(localized: "Screen sharing stopped. Start the task again to allow sharing.") : note)
        }
    }

    func afterAction(since: Double, ignoring spots: [CGPoint]) async {
        await settled(ignoring: spots)
        _ = await fresh(since: since, timeout: 1)
    }

    /// The picker is always presented in front; a cancelled request cannot start a late stream.
    func start() async throws {
        #if canImport(ScreenCaptureKit)
        guard Self.isAvailable else {
            throw ScreenCaptureError(message: String(localized: "Screen recording is unavailable on this device. Use AirPlay instead."))
        }
        if capturing { return }
        guard !choosing, stream == nil else { throw ScreenCaptureError(message: String(localized: "Screen sharing is already starting.")) }
        guard UIApplication.shared.applicationState == .active else {
            throw ScreenCaptureError(message: String(localized: "Open the app to allow screen sharing."))
        }
        try Task.checkCancellation()
        let id = UUID()
        generation = id; note = ""; frame = nil; updated = 0; capturedAt = 0
        let began = now()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    selection = continuation
                    var config = SCContentSharingPickerConfiguration()
                    config.showsMicrophoneControl = false
                    picker.defaultConfiguration = config
                    picker.add(callbacks); registered = true
                    choosing = true; picker.isActive = true
                    DebugLog.write("capture: presenting full-display picker")
                    picker.present()
                }
            } onCancel: { Task { @MainActor [weak self] in if self?.generation == id { await self?.stop() } } }
            try Task.checkCancellation()
            _ = try await image(timeout: 5)
            choosing = false
            DebugLog.write(String(format: "capture: authorized and ready in %.3f s", now() - began))
        } catch {
            if generation == id {
                await stop()
                if !(error is CancellationError) { note = error.localizedDescription }
            }
            throw error
        }
        #else
        note = String(localized: "Screen capture requires a physical iPhone.")
        throw ScreenCaptureError(message: note)
        #endif
    }

    #if canImport(ScreenCaptureKit)
    fileprivate func selected(_ filter: SCContentFilter) async {
        guard choosing, stream == nil, let id = generation else { return }
        let receiver = CaptureOutput(publish: { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.frame = image.jpeg; self.size = image.size
                self.updated = now(); self.capturedAt = image.capturedAt
            }
        }, unavailable: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.invalidateFrame()
            }
        })
        let content = filter.contentRect.size
        guard content.width > 0, content.height > 0 else {
            await failed(ScreenCaptureError(message: String(localized: "No screen image arrived. Stop sharing and try again.")))
            return
        }
        let dimensions = Self.captureSize(for: content)
        let config = SCStreamConfiguration()
        config.width = Int(dimensions.width)
        config.height = Int(dimensions.height)
        config.capturesAudio = false
        let next = SCStream(filter: filter, configuration: config, delegate: callbacks)
        output = receiver; stream = next
        do {
            try next.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await next.startCapture()
            guard generation == id else { try? await next.stopCapture(); return }
            capturing = true
            let continuation = selection; selection = nil
            continuation?.resume()
            DebugLog.write("capture: stream started")
        } catch { await failed(error, stream: next) }
    }

    fileprivate func cancelledSelection() async {
        // Cancelling a picker update must not revoke a stream that was already authorized.
        guard choosing, stream == nil else { return }
        await failed(ScreenCaptureError(message: String(localized: "Screen sharing was cancelled. Start again and allow sharing, or choose AirPlay in Settings.")))
    }

    #endif

    func stop() async {
        choosing = false; capturing = false
        #if canImport(ScreenCaptureKit)
        generation = nil
        output?.disable(); output = nil
        let previous = stream; stream = nil
        let continuation = selection; selection = nil
        continuation?.resume(throwing: CancellationError())
        if registered { picker.isActive = false; picker.remove(callbacks); registered = false }
        #endif
        // A stopped session must never supply a cached screenshot to a later run.
        invalidateFrame()
        #if canImport(ScreenCaptureKit)
        try? await previous?.stopCapture()
        #endif
    }

    #if canImport(ScreenCaptureKit)
    fileprivate func failed(_ error: Error, stream stopped: SCStream? = nil) async {
        if let stopped, stream !== stopped { return }
        let message = error.localizedDescription
        let continuation = selection; selection = nil
        continuation?.resume(throwing: error)
        await stop()
        note = message
        DebugLog.write("capture: stopped: \(message)")
    }

    #endif

    func invalidateFrame() {
        frame = nil; size = .zero; updated = 0; capturedAt = 0
    }

    func image(timeout: Double) async throws -> Data {
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            try checkAvailability()
            if let frame { return frame }
            guard now() < deadline else {
                throw ScreenCaptureError(message: String(localized: "No screen image arrived. Stop sharing and try again."))
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
private final class CaptureCallbacks: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, @unchecked Sendable {
    weak var owner: ScreenCaptureFeed?
    init(owner: ScreenCaptureFeed) { self.owner = owner }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.owner?.selected(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in await self?.owner?.cancelledSelection() }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in await self?.owner?.failed(error) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in await self?.owner?.failed(error, stream: stream) }
    }
}

/// Serialize conversion; retain the newest frame when JPEG output is rate-limited.
@available(iOS 27.0, *)
private final class CaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Image: Sendable { let jpeg: Data; let size: CGSize; let capturedAt: Double }
    let queue = DispatchQueue(label: "screen.capture", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private let publish: @Sendable (Image) -> Void
    private let unavailable: @Sendable () -> Void
    private var wasUnavailable = false
    private var enabled = true
    private lazy var throttle = FrameThrottle<(CVImageBuffer, Double)>(queue: queue, interval: 0.25) { [weak self] value in
        self?.convert(value.0, capturedAt: value.1)
    }
    init(publish: @escaping @Sendable (Image) -> Void, unavailable: @escaping @Sendable () -> Void) {
        self.publish = publish; self.unavailable = unavailable
    }
    func disable() { queue.sync { enabled = false; throttle.reset() } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard enabled, type == .screen, sample.isValid else { return }
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds, wall = now()
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let status = info[.status] as? Int else { return }
        if [SCFrameStatus.blank, .suspended, .stopped].contains(where: { $0.rawValue == status }) {
            throttle.reset()
            if !wasUnavailable { unavailable() }
            wasUnavailable = true
            return
        }
        guard status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue else { return }
        wasUnavailable = false
        guard let raw = info[.displayTime] as? NSNumber, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        // SDK declares displayTime as mach absolute time. Convert using CoreMedia's host clock,
        // then map into the wall clock used by HID actions. A missing/invalid clock never looks fresh.
        let displayed = CMClockMakeHostTimeFromSystemUnits(raw.uint64Value).seconds
        guard displayed.isFinite, displayed > 0, displayed <= host + 0.05 else { return }
        throttle.submit((pixels, wall + min(0, displayed - host)))
    }

    private func convert(_ pixels: CVImageBuffer, capturedAt: Double) {
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixels)
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            let bytes = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            publish(Image(jpeg: bytes as Data, size: CGSize(width: cg.width, height: cg.height),
                          capturedAt: capturedAt))
        }
    }
}

#endif
