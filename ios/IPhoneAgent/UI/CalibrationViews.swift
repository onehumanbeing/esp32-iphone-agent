import SwiftUI

/// The calibration state in words, e.g. "±0.6%".
struct CalibrationText: View {
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var pointer: Pointer

    var body: some View {
        Group {
            if calibrator.busy {
                Text("Calibrating…")
            } else if let q = pointer.quality, calibrator.hasValidCalibration {
                Text(verbatim: Self.percent(q))
            } else if calibrator.hasValidCalibration {
                Text("Calibrated")
            } else {
                Text("Not calibrated")
            }
        }
        .monospacedDigit()
    }

    static func percent(_ q: Double) -> String { String(format: "±%.1f%%", q * 100) }
}

/// A round Calibrate button under the record button, shown only when calibration is due and the mouse and
/// mirroring are up; it wiggles every few seconds. The first time, a small hint says why. Tapping it opens
/// the calibration board.
struct CalibrateButton: View {
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var board: BoardLink  // re-evaluates `offer` on status changes
    @ObservedObject var pointer: Pointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("calibrateHintSeen") private var hintSeen = false
    @State private var wiggles = 0

    var body: some View {
        if calibrator.offer {
            HStack(alignment: .top, spacing: Space.s) {
                if !hintSeen && !pointer.calibrated {
                    Text("Calibrate before first use")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Button {
                    hintSeen = true
                    calibrator.calibrate()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "scope")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        Text("Calibrate").font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { view, angle in
                    view.rotationEffect(.degrees(angle))
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(-12, duration: 0.1)
                        SpringKeyframe(10, duration: 0.12)
                        SpringKeyframe(-6, duration: 0.12)
                        SpringKeyframe(0, duration: 0.2)
                    }
                }
                .accessibilityLabel(Text("Calibrate"))
                .accessibilityHint(Text("Calibrates the pointer on a grid; takes a few seconds."))
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if !reduceMotion { wiggles += 1 }
                }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}
