import SwiftUI

/// The timeline: a tick per step (green done, red ✗ or problems, yellow unsure, gray plans), filled up to the
/// current step. Drag or tap anywhere on it to jump; VoiceOver adjusts it step by step.
struct ReviewTimeline: View {
    let steps: [DraftStep]
    @Binding var index: Int
    @Binding var playing: Bool

    var body: some View {
        GeometryReader { g in
            let n = max(steps.count, 1)
            let w = g.size.width
            let x = { (i: Int) in n > 1 ? w * CGFloat(i) / CGFloat(n - 1) : w / 2 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: x(index), height: 4)
                ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                    Capsule().fill(tint(s, i))
                        .frame(width: s.verdict == false ? 5 : 3, height: i == index ? 18 : s.verdict == false ? 14 : 10)
                        .position(x: x(i), y: g.size.height / 2)
                }
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: 18, height: 18)
                    .position(x: x(index), y: g.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                playing = false
                let i = max(0, min(n - 1, Int(((v.location.x / max(w, 1)) * CGFloat(n - 1)).rounded())))
                if i != index { index = i }
            })
        }
        .frame(height: 32)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: index)
        .accessibilityElement()
        .accessibilityLabel(Text("Timeline"))
        .accessibilityValue(Text("Step \(index + 1) of \(steps.count)"))
        .accessibilityAdjustableAction { d in
            playing = false
            index = d == .increment ? min(steps.count - 1, index + 1) : max(0, index - 1)
        }
    }

    private func tint(_ s: DraftStep, _ i: Int) -> Color {
        if s.verdict == false { return Palette.stop }
        if s.uncertain { return .yellow }
        switch s.name {
        case "done": return Palette.ok
        case "fail", "error", "hiccup", "help": return Palette.stop
        case "plan", "replan (stuck)", "stopped", "takeover", "skipped": return Color(uiColor: .systemGray2)
        default: return i <= index ? Color.accentColor : Color(uiColor: .systemGray3)
        }
    }
}

/// The run's low-fps video (frames of the mirror stream), continuous in real time: the frame at `time`
/// (seconds since 1970), with the step running at that moment as a caption. No step screenshots, no overlays.
struct RunVideoView: View {
    let frames: [(url: URL, t: Double)]
    let time: Double
    let caption: String?

    private var current: URL? {
        (frames.last { $0.t <= time } ?? frames.first)?.url
    }

    var body: some View {
        Group {
            if let url = current, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().aspectRatio(img.size, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if let caption {
                            Text(verbatim: caption).font(.caption.weight(.semibold)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white).padding(10)
                        }
                    }
            } else {
                Text("No video for this run.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }
}

/// The video's scrubber, in seconds (elapsed / total), not steps.
struct VideoScrubber: View {
    let start: Double, end: Double
    @Binding var time: Double
    @Binding var playing: Bool

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { min(max(time - start, 0), end - start) },
                                  set: { playing = false; time = start + $0 }),
                   in: 0...max(end - start, 0.1))
            HStack {
                Text(verbatim: Self.clock(time - start))
                Spacer()
                Text(verbatim: Self.clock(end - start))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Video position"))
    }

    static func clock(_ s: Double) -> String {
        let n = max(0, Int(s.rounded(.down)))
        return String(format: "%d:%02d", n / 60, n % 60)
    }
}
