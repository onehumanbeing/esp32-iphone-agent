import SwiftUI

/// Lives in the overlay window above every page: the calibration board while it is open, and a small toast
/// at the top after a successful calibration.
struct CalibrationOverlay: View {
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var probe: TouchProbe
    @ObservedObject var pointer: Pointer

    var body: some View {
        ZStack(alignment: .top) {
            if calibrator.boardOpen {
                CalibrationBoard(calibrator: calibrator, probe: probe).transition(.opacity)
            }
            if calibrator.toast {
                CalibratedToast(pointer: pointer)
                    .padding(.top, Space.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: calibrator.toast)
        .animation(.easeOut(duration: 0.25), value: calibrator.boardOpen)
    }
}

/// The full-screen calibration board: a white grid (so the dark pointer stands out, for the pixel finder,
/// the vision model and the user), Back at the top right, and a card at the bottom with progress, or after
/// a failure the problem, Try Again and "Tap the pointer yourself".
struct CalibrationBoard: View {
    @ObservedObject var calibrator: AutoCalibrator
    @ObservedObject var probe: TouchProbe

    var body: some View {
        ZStack {
            ProbeGrid(flashes: probe.flashes)
            VStack {
                HStack {
                    Spacer()
                    Button { calibrator.cancel() } label: {
                        Text("Back").font(.body.weight(.semibold)).foregroundStyle(.black)
                            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                            .background(Color.white, in: Capsule())
                            .overlay(Capsule().stroke(Color.black, lineWidth: 1.5))
                    }
                    .area("back", probe)
                }
                .padding(.trailing, Space.xl)
                .padding(.top, Space.s)
                Spacer()
                card.padding(.horizontal, Space.l).padding(.bottom, Space.xs)
            }
        }
        .environment(\.colorScheme, .light)
        .onChange(of: calibrator.phase) { _, p in if p == .failed { Haptics.stop() } }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: Space.m) {
            AgentFace(mood: mood, showsTab: false).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: Space.s) {
                switch calibrator.phase {
                case .failed:
                    Text("Calibration didn't work").font(.subheadline.weight(.semibold))
                    if let problem = calibrator.problem {
                        Text(verbatim: problem).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s) {
                        Button("Try Again") { calibrator.calibrate() }
                            .buttonStyle(.borderedProminent).area("retry", probe)
                        Button("Tap the pointer yourself") { calibrator.startManual() }
                            .buttonStyle(.bordered).area("manual", probe)
                    }
                    .controlSize(.small).buttonBorderShape(.capsule).padding(.top, Space.xs)
                case .needsTap:
                    Text("Tap exactly where the pointer is").font(.subheadline.weight(.semibold))
                    Group {
                        if calibrator.manualRetry {
                            Text("It was on the edge of the screen, so it moved less this time. Tap the grey dot again.")
                        } else {
                            Text("It's the grey dot, usually near the top left.")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                default:
                    Group {
                        if let p = calibrator.progress {
                            Text("Calibrating pointer… \(p.done)/\(p.total)")
                        } else {
                            Text("Calibrating pointer…")
                        }
                    }
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text("Hands off the screen for a few seconds.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .frame(maxWidth: 440)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private var mood: Mood {
        switch calibrator.phase {
        case .failed: return .failure
        case .needsTap: return .listening
        default: return .acting
        }
    }
}

private extension View {
    /// Register this button's frame so the board lets touches through to it.
    func area(_ id: String, _ probe: TouchProbe) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.setButtonArea(id, $0) }
            .onDisappear { probe.setButtonArea(id, nil) }
    }
}

/// White, lines every 10% (darker every 50%), labels 100-900 on the top and left edges, a coloured square
/// in each corner (red, green, blue, orange from top-left, clockwise from the top) to register a frame, and a
/// dot where each probe tap landed.
struct ProbeGrid: View {
    let flashes: [CGPoint]
    static let corners: [Color] = [.red, .green, .orange, .blue]  // TL, TR, BR, BL

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for i in 1..<10 {
                let x = size.width * Double(i) / 10, y = size.height * Double(i) / 10
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.black.opacity(i == 5 ? 0.55 : 0.28)), lineWidth: i == 5 ? 1.5 : 1)
                let label = Text(verbatim: "\(i * 100)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.black.opacity(0.7))
                ctx.draw(label, at: CGPoint(x: x + 2, y: size.height * 0.035), anchor: .leading)
                ctx.draw(label, at: CGPoint(x: 4, y: y - 1), anchor: .bottomLeading)
            }
            let m: CGFloat = 26, inset = min(size.width, size.height) * 0.03
            let origins = [CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset - m, y: inset),
                           CGPoint(x: size.width - inset - m, y: size.height - inset - m),
                           CGPoint(x: inset, y: size.height - inset - m)]
            for (o, color) in zip(origins, Self.corners) {
                ctx.fill(Path(CGRect(x: o.x, y: o.y, width: m, height: m)), with: .color(color))
                ctx.fill(Path(CGRect(x: o.x + 8, y: o.y + 8, width: m - 16, height: m - 16)), with: .color(.white))
            }
            for f in flashes {
                let r = CGRect(x: f.x * size.width - 7, y: f.y * size.height - 7, width: 14, height: 14)
                ctx.fill(Path(ellipseIn: r), with: .color(.green.opacity(0.75)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// "Pointer calibrated ±0.6%", briefly, at the top.
struct CalibratedToast: View {
    @ObservedObject var pointer: Pointer

    var body: some View {
        Label {
            Text("Pointer calibrated \(pointer.quality.map(CalibrationText.percent) ?? "")").monospacedDigit()
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .onAppear { Haptics.success() }
    }
}
