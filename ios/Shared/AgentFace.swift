import SwiftUI

/// The agent's mood; drives the character on Home, in onboarding, in the replay player and in the Live Activity.
enum Mood: String, Codable, Hashable {
    case sleeping, idle, listening, thinking, acting, success, failure
    /// Poke reactions (Home): spiral eyes after a flurry of taps, closed smiling eyes while petted, a wink.
    case dizzy, content, wink
}

/// The character: the logo redrawn as vectors (rounded black board, two glowing eyes, a USB-C tab), so it can
/// blink, look around and hop. Animations are short springs and stop under Reduce Motion.
/// How often the animated face was drawn (the app's background summary logs it; a count only).
enum FaceTicks { nonisolated(unsafe) static var count = 0 }

struct AgentFace: View {
    var mood: Mood
    /// Where the eyes look, -1...1 on each axis (e.g. toward a tap point).
    var look: CGPoint = .zero
    /// How far the eyes travel for a full look (1 = Home size; the tiny island face needs more to read).
    var lookRange: CGFloat = 1
    var animated = true
    var showsTab = true
    /// Hop / shake by itself when the mood changes (off while a poke drives the face).
    var reacts = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop: CGFloat = 0
    @State private var shake: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height / (showsTab ? 1.12 : 1))
            Group {
                if animated && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { t in
                        FaceTicks.count += 1
                        return face(s, t: t.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    face(s, t: 0)
                }
            }
            .offset(x: shake, y: hop)
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(showsTab ? 1 / 1.12 : 1, contentMode: .fit)
        .onChange(of: mood) { _, m in react(to: m) }
        .accessibilityElement()
        .accessibilityLabel(Text("ESP32 Agent"))
        .accessibilityValue(Text(LocalizedStringKey(mood.rawValue)))
    }

    private func react(to m: Mood) {
        guard animated && !reduceMotion && reacts else { return }
        switch m {
        case .acting:
            jump(1)
        case .success:
            jump(2)
        case .failure:
            withAnimation(.spring(response: 0.12, dampingFraction: 0.2)) { shake = 6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) { shake = 0 }
            }
        default:
            break
        }
    }

    private func jump(_ times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.32) {
                withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { hop = -14 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hop = 0 }
                }
            }
        }
    }

    // MARK: - drawing

    private func face(_ s: CGFloat, t: Double) -> some View {
        let breathe = mood == .idle ? 1 + 0.012 * sin(t * 1.6) : 1
        let float = mood == .thinking ? 3 * sin(t * 2.4) : 0
        let lean: Double = mood == .listening ? 6 : 0
        return VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.55), Color(white: 0.8)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                    .fill(Color.black)
                    .padding(s * 0.045)
                RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)  // glass highlight
                    .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .center))
                    .padding(s * 0.045)
                eyes(s, t: t)
                if mood == .sleeping { zz(s, t: t) }
            }
            .frame(width: s, height: s)
            if showsTab {
                UnevenRoundedRectangle(bottomLeadingRadius: s * 0.04, bottomTrailingRadius: s * 0.04)
                    .fill(Color(white: 0.7))
                    .frame(width: s * 0.2, height: s * 0.1)
                    .overlay(HStack(spacing: s * 0.025) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color(red: 0.86, green: 0.66, blue: 0.2)).frame(width: s * 0.022, height: s * 0.05)
                        }
                    })
                    .padding(.top, -s * 0.01)
            }
        }
        .scaleEffect(breathe)
        .rotation3DEffect(.degrees(lean), axis: (x: 1, y: 0, z: 0))
        .offset(y: float)
    }

    private static let glow = Color(red: 1, green: 0.96, blue: 0.86)

    @ViewBuilder private func eyes(_ s: CGFloat, t: Double) -> some View {
        let w = s * 0.14, h = s * 0.25, gap = s * 0.37
        let gaze = gazeOffset(t: t)
        let dx = gaze.x * s * 0.05 * lookRange, dy = gaze.y * s * 0.04 * lookRange
        switch mood {
        case .sleeping:
            HStack(spacing: gap - w) {
                ForEach(0..<2, id: \.self) { _ in Capsule().fill(Self.glow.opacity(0.55)).frame(width: w, height: s * 0.025) }
            }
            .offset(y: s * 0.05)
        case .success:
            HStack(spacing: gap - w) {
                ForEach(0..<2, id: \.self) { _ in Caret().stroke(Self.glow, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round, lineJoin: .round))
                    .frame(width: w * 1.3, height: h * 0.45) }
            }
            .shadow(color: Self.glow.opacity(0.8), radius: s * 0.04)
            .offset(y: -s * 0.02)
        case .dizzy:
            HStack(spacing: gap - w * 1.4) {
                ForEach(0..<2, id: \.self) { i in
                    Spiral().stroke(Self.glow, style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round))
                        .frame(width: w * 1.7, height: w * 1.7)
                        .rotationEffect(.radians((i == 0 ? 1 : -1) * t * 9))
                }
            }
            .shadow(color: Self.glow.opacity(0.8), radius: s * 0.04)
        case .content:
            HStack(spacing: gap - w * 1.3) {
                ForEach(0..<2, id: \.self) { _ in
                    Smile().stroke(Self.glow, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
                        .frame(width: w * 1.3, height: h * 0.28)
                }
            }
            .shadow(color: Self.glow.opacity(0.8), radius: s * 0.04)
            .offset(y: s * 0.04)
        case .wink:
            HStack(spacing: gap - w * 1.15) {
                Capsule().fill(Self.glow).frame(width: w, height: h)
                Caret().stroke(Self.glow, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round, lineJoin: .round))
                    .frame(width: w * 1.3, height: h * 0.35)
            }
            .shadow(color: Self.glow.opacity(0.9), radius: s * 0.05)
            .offset(y: -s * 0.02)
        case .failure:
            HStack(alignment: .bottom, spacing: gap - w) {
                Capsule().fill(Self.glow).frame(width: w * 1.1, height: h * 0.85)
                Capsule().fill(Self.glow).frame(width: w * 0.8, height: h * 0.55)
            }
            .shadow(color: Self.glow.opacity(0.7), radius: s * 0.04)
            .offset(y: s * 0.05)
        default:
            let scale: CGFloat = mood == .listening ? 1.15 : 1
            HStack(spacing: gap - w) {
                ForEach(0..<2, id: \.self) { i in
                    let tilt = mood == .thinking ? (i == 0 ? -1.0 : 1.0) * s * 0.02 * sin(t * 2.4) : 0
                    Capsule().fill(Self.glow)
                        .frame(width: w * scale, height: h * scale * blink(t))
                        .offset(y: tilt)
                }
            }
            .shadow(color: Self.glow.opacity(0.9), radius: s * 0.05)
            .offset(x: dx, y: dy - s * 0.02)
        }
    }

    /// 1 = open; closes briefly every few seconds while idle or listening.
    private func blink(_ t: Double) -> CGFloat {
        guard mood == .idle || mood == .listening, animated else { return 1 }
        let phase = t.truncatingRemainder(dividingBy: 4.3)
        return phase < 0.13 ? max(0.08, abs(phase - 0.065) / 0.065) : 1
    }

    private func gazeOffset(t: Double) -> CGPoint {
        switch mood {
        case .acting: return look
        case .listening: return CGPoint(x: 0, y: 0.6)
        case .thinking: return animated ? CGPoint(x: sin(t * 2.4), y: -0.2) : look  // static (island): the app moves it
        case .idle where animated:  // a look around now and then
            let p = t.truncatingRemainder(dividingBy: 9)
            return CGPoint(x: p > 6 && p < 7 ? -0.7 : p > 7.4 && p < 8.2 ? 0.7 : 0, y: 0)
        default: return .zero
        }
    }

    private func zz(_ s: CGFloat, t: Double) -> some View {
        let p = animated ? t.truncatingRemainder(dividingBy: 3) / 3 : 0.5
        return Text(verbatim: "z")
            .font(.system(size: s * 0.12, weight: .bold, design: .rounded))
            .foregroundStyle(Self.glow.opacity(1 - p))
            .offset(x: s * 0.24 + p * s * 0.08, y: -s * 0.18 - p * s * 0.12)
    }
}

/// "^" for the happy eyes.
struct Caret: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}

/// "‿" for closed, contented eyes.
struct Smile: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2 - r.minY))
        return p
    }
}

/// A spiral for dizzy eyes.
struct Spiral: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), maxR = min(r.width, r.height) / 2
        for i in 0...60 {
            let a = Double(i) / 60 * 2.6 * 2 * .pi
            let rad = maxR * Double(i) / 60
            let pt = CGPoint(x: c.x + rad * Foundation.cos(a), y: c.y + rad * Foundation.sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
