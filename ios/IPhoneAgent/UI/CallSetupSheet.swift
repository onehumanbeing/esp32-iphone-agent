import AVKit
import SwiftUI

/// Every call shows how to set the iPhone up before it runs (until Don't Show Again): a call is spoken by Live Speech and heard through
/// Live Captions, both opened from Control Center at fixed spots (Calls.spots), so they must be large and at the
/// bottom. Shown again from Settings › Phone Calls.
@MainActor final class CallGuide: ObservableObject {
    static let shared = CallGuide()
    static let seenKey = "callGuideHidden"  // set only by Don't Show Again
    /// handsy.tech's Phone calls page (the setup video and these steps), in the app's language.
    static var page: URL {
        let zh = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true  // the language the app shows
        return URL(string: "https://handsy.tech/" + (zh ? "zh/" : "") + "docs/phone-calls")!
    }

    struct Pending: Identifiable {
        let id = UUID()
        let task: String?  // nil: opened from Settings, nothing runs after
        let intent: SavedTask?
    }
    @Published var pending: Pending?
    /// "It's Set Up, Call Now": the run it starts goes through once; the next call shows the guide again.
    var passOnce = false

    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// True when the call has to wait for the guide (shown now).
    func holds(_ task: String, intent: SavedTask?) -> Bool {
        if passOnce { passOnce = false; return false }
        guard !Self.seen else { return false }
        pending = Pending(task: task, intent: intent)
        return true
    }
}

struct CallSetupSheet: View {
    let pending: CallGuide.Pending
    let start: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    LoopingClip(name: "call-setup")
                        .aspectRatio(360 / 782, contentMode: .fit)
                        .frame(maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: .infinity)
                    step(1, "Turn on Live Speech", "Settings › Accessibility › Live Speech.")
                    step(2, "Add Live Speech and Live Captions to Control Center",
                         "Touch and hold Control Center, tap Add a Control, search for each one.")
                    step(3, "Make both large, on the bottom row",
                         "Live Speech on the left, Live Captions on the right, as in the video. The agent taps them at those spots to be ready in seconds.")
                    Text("Phone calls are in beta: they may miss a word or take a moment to answer.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Calls work best in English: Live Captions understands it best. Call audio never goes through Screen Mirroring.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link(destination: CallGuide.page) {
                        Label("Watch the setup video", systemImage: "play.rectangle")
                    }
                    Button { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                }
                .padding(Space.l)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Space.s) {
                    Button {
                        dismiss()
                        if pending.task != nil { CallGuide.shared.passOnce = true; start() }
                    } label: {
                        Text(pending.task == nil ? "Done" : "It's Set Up, Call Now").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if pending.task != nil {
                        Button("Don't Show Again") {  // shown before every call until this is tapped
                            CallGuide.seen = true
                            dismiss()
                            start()
                        }
                    }
                }
                .padding(Space.l)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: Space.s) { Text("Before You Call").font(.headline); BetaBadge() }
                }
            }
        }
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text(verbatim: "\(n)").font(.headline).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// A short bundled clip, muted and looping.
private struct LoopingClip: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp4") else { return view }
        let player = AVQueuePlayer()
        player.isMuted = true
        // Never to the AirPlay receiver: during Screen Mirroring iOS hands a playing video to the receiver, and the
        // board got no mirrored frames for 12 s after the sheet closed (2026-11-13, startup +14.6 s).
        player.allowsExternalPlayback = false
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        view.layer.player = player
        view.layer.videoGravity = .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var looper: AVPlayerLooper? }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        override var layer: AVPlayerLayer { super.layer as! AVPlayerLayer }
    }
}
