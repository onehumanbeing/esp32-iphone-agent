import SwiftUI

/// One review page: the screenshot the model decided on, with its action drawn on top (tap ripple, swipe
/// trail, typed-text bubble) and the user's fix (a green target). Coordinates are 0-1000 screen units.
struct StepFrame: View {
    let step: DraftStep
    var active = true
    private var moves: Bool { step.isMove || step.name == "note" }

    var body: some View {
        Group {
            if let url = step.frame, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(img.size, contentMode: .fit)
                    .overlay { if moves { ActionOverlay(action: step.action, active: active) } }
                    .overlay { if let fix = step.fix { FixMarker(point: fix) } }
                    .overlay {
                        if step.verdict == false {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.stop, lineWidth: 3)
                        } else if step.uncertain {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.yellow, lineWidth: 3)
                        }
                    }
                    .overlay(alignment: .bottom) { if moves { bubble } }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .tertiarySystemFill))
                    .aspectRatio(9 / 19.5, contentMode: .fit)
                    .overlay(Image(systemName: StepText.symbol(step.name)).font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Space.s)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: StepText.title(step.action)))
    }

    /// Typed text, keys and navigation shown as a bubble near the bottom.
    @ViewBuilder private var bubble: some View {
        let a = step.action
        switch step.name {
        case "type": Bubble(symbol: "keyboard", text: a["text"]?.str ?? "")
        case "key": Bubble(symbol: "command", text: a["combo"]?.str ?? "")
        case "home": Bubble(symbol: "house.fill", text: String(localized: "Home"))
        case "back": Bubble(symbol: "chevron.backward", text: String(localized: "Back"))
        case "wait": Bubble(symbol: "hourglass", text: String(localized: "Wait"))
        case "note": Bubble(symbol: "text.bubble", text: a["text"]?.str ?? "")
        default: EmptyView()
        }
    }
}

private struct Bubble: View {
    let symbol: String
    let text: String

    var body: some View {
        Label { Text(verbatim: text).lineLimit(2) } icon: { Image(systemName: symbol) }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .padding(.bottom, Space.xl)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Taps, swipes, paths and circles drawn in the image's own coordinate space.
struct ActionOverlay: View {
    let action: JObject
    var active = true
    @State private var t: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            let size = g.size
            let p = { (x: Double, y: Double) in CGPoint(x: x / 1000 * size.width, y: y / 1000 * size.height) }
            let n = { (k: String) in action[k]?.double ?? 0 }
            switch action["action"]?.str {
            case "tap":
                Ripple(t: t).position(p(n("x"), n("y")))
            case "swipe":
                Trail(points: [p(n("x1"), n("y1")), p(n("x2"), n("y2"))], t: t)
            case "path":
                Trail(points: points(action).map { p($0.x, $0.y) }, t: t)
            case "circle":
                let r = n("r") / 1000 * size.width
                Circle().trim(from: 0, to: t)
                    .stroke(ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: r * 2, height: r * 2)
                    .position(p(n("x"), n("y")))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            default:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .onAppear { if active { play() } }
        .onChange(of: active) { _, on in if on { play() } }
    }

    /// Draws the action in each time its step comes up.
    private func play() {
        guard !reduceMotion else { t = 1; return }
        t = 0
        withAnimation(.easeOut(duration: 0.6).delay(0.1)) { t = 1 }
    }
}

/// Action marks are red: they must stand out on any screenshot, whatever the accent colour.
private let ink = Color.red

/// A tap: three rings pulsing out from a solid red ring, and a pointing hand that keeps pressing the spot.
private struct Ripple: View {
    let t: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let time = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in  // staggered pulses, one every 0.4 s
                    let p = CGFloat((time / 1.2 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                    Circle().stroke(ink, lineWidth: 3)
                        .frame(width: 30, height: 30)
                        .scaleEffect(1 + 1.4 * p)
                        .opacity(Double(1 - p) * Double(t))
                }
                Circle().stroke(Color.white, lineWidth: 7).frame(width: 30, height: 30)
                Circle().stroke(ink, lineWidth: 4).frame(width: 30, height: 30)
                Circle().fill(ink).frame(width: 8, height: 8)
                Hand(press: reduceMotion ? 0 : CGFloat(max(0, sin(time * 2 * .pi / 1.2))))
                    .offset(x: 4, y: 26)
                    .opacity(min(1, 2 * t))
            }
            .shadow(color: .black.opacity(0.35), radius: 3)
        }
    }
}

/// 👆 with its fingertip at the anchor; press 0-1 nudges it in and shrinks it a little, like tapping.
private struct Hand: View {
    var press: CGFloat = 0

    var body: some View {
        Text(verbatim: "👆").font(.system(size: 34))
            .scaleEffect(1 - 0.08 * press, anchor: .top)
            .offset(y: -4 * press)
    }
}

/// A swipe or drag: the path drawn in (red on a white edge), a ring where the finger starts, an arrowhead
/// where it ends, and a hand that keeps sliding along it.
private struct Trail: View {
    let points: [CGPoint]
    let t: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let loop = CGFloat((tl.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1))
            ZStack {
                path.trim(from: 0, to: t)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                path.trim(from: 0, to: t)
                    .stroke(ink, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                if let first = points.first {
                    Circle().fill(Color.white).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(ink, lineWidth: 4))
                        .position(first)
                }
                if points.count >= 2, let last = points.last {
                    let prev = points[points.count - 2]
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ink)
                        .rotationEffect(.radians(Double(atan2(last.y - prev.y, last.x - prev.x)) + .pi / 2))
                        .position(last)
                        .opacity(Double(t))
                    Hand()
                        .position(at(reduceMotion ? 1 : min(t, loop)))
                        .offset(x: 4, y: 26)
                        .opacity(Double(t))
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 2)
        }
    }

    private var path: Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
    }

    /// The point a fraction f of the way along the polyline.
    private func at(_ f: CGFloat) -> CGPoint {
        let segs = zip(points, points.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
        var left = f * segs.reduce(0) { $0 + $1.2 }
        for (a, b, len) in segs {
            if left <= len, len > 0 { return CGPoint(x: a.x + (b.x - a.x) * left / len, y: a.y + (b.y - a.y) * left / len) }
            left -= len
        }
        return points.last ?? .zero
    }
}

/// Where the user says the tap should have gone.
struct FixMarker: View {
    let point: CGPoint

    var body: some View {
        GeometryReader { g in
            Image(systemName: "scope")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Palette.ok)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(x: point.x / 1000 * g.size.width, y: point.y / 1000 * g.size.height)
        }
        .allowsHitTesting(false)
    }
}
