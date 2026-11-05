import Foundation

/// Compare capture time with the actual background transition, not a later polling observation.
struct StartupFrameBoundary {
    let requestedAt: Double

    func threshold(backgroundEnteredAt: Double) -> Double {
        max(requestedAt, backgroundEnteredAt)
    }

    func accepts(capturedAt: Double, backgroundEnteredAt: Double) -> Bool {
        capturedAt > 0 && capturedAt > threshold(backgroundEnteredAt: backgroundEnteredAt)
    }
}
