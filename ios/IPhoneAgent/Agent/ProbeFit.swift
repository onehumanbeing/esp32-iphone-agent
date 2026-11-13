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

    /// The line without its worst sample when that one alone is far off (a dropped report right after the board
    /// powered up, a tap caught late): with five or more samples, one over 2% off and well outside the rest's fit.
    static func robustLine(_ samples: [(Double, Double)]) -> Line? {
        guard let all = line(samples), samples.count >= 5 else { return line(samples) }
        let off = samples.map { abs($0.1 - (all.a * $0.0 + all.b)) }
        guard let worst = off.indices.max(by: { off[$0] < off[$1] }), off[worst] > 0.02 else { return all }
        var rest = samples
        let dropped = rest.remove(at: worst)
        guard let fit = line(rest), abs(dropped.1 - (fit.a * dropped.0 + fit.b)) > 3 * max(fit.rms, 0.005) else { return all }
        return fit
    }

    /// One sample and no offset: the line through home (0, 0).
    static func throughHome(_ s: (Double, Double)) -> Line? {
        s.0 > 0 && s.1 > 0 ? Line(a: s.1 / s.0, b: 0, rms: 0) : nil
    }

    /// A tap at the very edge may be the pointer stuck there: useless for a fit.
    static func usable(_ f: Double) -> Bool { 0.02 < f && f < 0.98 }
}

/// This device's screen, read at runtime (iPhone or iPad, current interface orientation).
@MainActor enum DeviceScreen {
    static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Points.
    static var size: CGSize { scene?.screen.bounds.size ?? CGSize(width: 390, height: 844) }
    static var scale: CGFloat { scene?.screen.scale ?? 3 }
    static var aspect: Double { size.height > 0 ? size.width / size.height : 9 / 19.5 }
    static var foreground: Bool { UIApplication.shared.applicationState == .active }
}
