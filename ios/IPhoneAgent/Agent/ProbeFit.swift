import UIKit

/// Least-squares line through touch-probe samples: landed = a * units + b, per axis.
enum ProbeFit {
    struct Line: Equatable {
        var a: Double, b: Double
        var rms: Double  // residual, fraction of the screen

        /// Mouse units (from home) that land on screen fraction f.
        func units(for f: Double) -> Int { Int(((f - b) / a).rounded()) }
    }

    /// samples: (mouse units from home, landed screen fraction). Nil with fewer than two distinct points.
    static func line(_ samples: [(Double, Double)]) -> Line? {
        let n = Double(samples.count)
        guard samples.count >= 2 else { return nil }
        let mu = samples.map(\.0).reduce(0, +) / n, mf = samples.map(\.1).reduce(0, +) / n
        let variance = samples.map { pow($0.0 - mu, 2) }.reduce(0, +)
        guard variance > 1e-6 else { return nil }
        let a = samples.map { ($0.0 - mu) * ($0.1 - mf) }.reduce(0, +) / variance
        guard a > 0 else { return nil }
        let b = mf - a * mu
        let rms = sqrt(samples.map { pow($0.1 - (a * $0.0 + b), 2) }.reduce(0, +) / n)
        return Line(a: a, b: b, rms: rms)
    }

    /// One sample and no offset: the line through home (0, 0).
    static func throughHome(_ s: (Double, Double)) -> Line? {
        s.0 > 0 && s.1 > 0 ? Line(a: s.1 / s.0, b: 0, rms: 0) : nil
    }

    /// A tap at the very edge may be the pointer stuck there: useless for a fit.
    static func usable(_ f: Double) -> Bool { 0.02 < f && f < 0.98 }
}

/// How the mirrored frame sits on the device's screen (iPad only: an iPhone is always portrait and its frame is its
/// screen). The frame may be letterboxed: `contentRect` is the screen's part of it, in frame fractions. The models
/// and Vision work in frame fractions, the pointer in screen fractions.
struct ScreenGeometry: Codable, Equatable {
    var screenAspect: Double  // width / height, current interface orientation
    var frameAspect: Double
    var orientation: Int      // UIInterfaceOrientation raw value

    var contentRect: CGRect {
        guard screenAspect.isFinite, frameAspect.isFinite, screenAspect > 0, frameAspect > 0 else { return .zero }
        if frameAspect > screenAspect {
            let width = screenAspect / frameAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = frameAspect / screenAspect
        return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    func screenPoint(fromFrame point: CGPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    func framePoint(fromScreen point: CGPoint) -> CGPoint {
        let rect = contentRect
        return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    func contains(framePoint point: CGPoint) -> Bool {
        let rect = contentRect.insetBy(dx: -0.001, dy: -0.001)
        return point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    var landscape: Bool { screenAspect > 1 }

    /// Same orientation and shape: a calibration or a model's look made on `other` still holds. Landscape left and
    /// right are the same to the pointer (it moves in the screen's current orientation), and so are both portraits.
    func matches(_ other: ScreenGeometry?) -> Bool {
        guard let other else { return false }
        return landscape == other.landscape && abs(screenAspect - other.screenAspect) < 0.01
            && abs(frameAspect - other.frameAspect) < 0.01
    }
}

/// This device's screen, read at runtime (iPhone or iPad, current interface orientation).
@MainActor enum DeviceScreen {
    /// The app's own window. On iPad never an external-display scene: iPadOS attached one for a 720x720 AirPlay
    /// display (2026-10-28), and while the app was in the background `scenes.first` picked it, so the screen read
    /// 720x720 pt @1x, every startup frame was "geometry changed" and taps fell in a "letterbox".
    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { !DeviceKind.isPad || $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Points.
    static var size: CGSize { scene?.screen.bounds.size ?? CGSize(width: 390, height: 844) }
    static var scale: CGFloat { scene?.screen.scale ?? 3 }
    static var aspect: Double { size.height > 0 ? size.width / size.height : 9 / 19.5 }
    static var foreground: Bool { UIApplication.shared.applicationState == .active }

    /// The frame's place on the screen now; nil on iPhone (portrait only, the frame is the screen) or without a scene.
    /// The orientation is the frame's: it shows the screen as it is turned now (1200x834 landscape, 580x834 portrait,
    /// 2026-11-10), while this app's own window may not turn while it is in the background during a run.
    static func geometry(frameAspect: Double) -> ScreenGeometry? {
        guard DeviceKind.isPad, let scene, frameAspect.isFinite, frameAspect > 0 else { return nil }
        let native = scene.screen.nativeBounds.size  // fixed, portrait
        guard native.width > 0, native.height > 0 else { return nil }
        let long = max(native.width, native.height), short = min(native.width, native.height)
        let landscape = frameAspect > 1
        return ScreenGeometry(screenAspect: landscape ? long / short : short / long, frameAspect: frameAspect,
                              orientation: (landscape ? UIInterfaceOrientation.landscapeRight : .portrait).rawValue)
    }
}
