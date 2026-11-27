import SwiftUI
import UIKit

/// Settings › Developer › Input probe, the harness's "app probe" or iphoneagent://probe (Debug): a tap pad that shows
/// what any app can read about each touch, plus the phone-wide signals (docs/input-probe.md). Developer only, English.
struct InputProbeView: View {
    @ObservedObject var log = InputProbeLog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProbePad(log: log)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .overlay { Text(verbatim: "Tap here").font(.title2).foregroundStyle(.secondary).allowsHitTesting(false) }
                List {
                    Section {
                        TextField(text: $log.label) { Text(verbatim: "Label (finger, board, finger+mirroring…)") }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button { copy() } label: { Text(verbatim: "Copy as JSON") }.buttonStyle(.bordered)
                            Button { save() } label: { Text(verbatim: "Write file") }.buttonStyle(.bordered)
                            Spacer()
                            Button(role: .destructive) { log.clear() } label: { Text(verbatim: "Clear") }.buttonStyle(.bordered)
                        }
                        if let note { Text(verbatim: note).font(.footnote).foregroundStyle(.secondary) }
                    } footer: {
                        Text(verbatim: "Set the label before tapping; each sample keeps the label it was taken with. Write file saves Documents/\(InputProbe.fileName).")
                    }
                    Section { signalRows } header: { Text(verbatim: "Signals (live)") }
                    Section {
                        ForEach(log.samples.reversed(), id: \.index) { SampleRow(sample: $0) }
                    } header: { Text(verbatim: "Samples (\(log.samples.count))") }
                }
            }
            .navigationTitle(Text(verbatim: "Input probe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Text(verbatim: "Done") } }
            }
        }
        .onAppear { log.start() }
    }

    @ViewBuilder private var signalRows: some View {
        let s = log.signals
        row("UIScreen.isCaptured", s.screenCaptured)
        if let state = s.sceneCaptureState { row("sceneCaptureState", state) }
        row("UIScreen.screens", "\(s.screens)")
        row("AssistiveTouch running", s.assistiveTouch)
        row("Guided Access", s.guidedAccess)
        row("VoiceOver", s.voiceOver)
        row("Switch Control", s.switchControl)
        row("GCMouse.current", s.mouseCurrent)
        row("GCMouse.mice()", "\(s.mice)")
        row("GCKeyboard", s.keyboard)
        row("SupportsIndirectInputEvents (this app)", s.indirectInputEvents)
        row("iOS", s.ios)
    }

    private func row(_ name: String, _ on: Bool) -> some View { row(name, on ? "yes" : "no") }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: name)
            Spacer()
            Text(verbatim: value).foregroundStyle(.secondary).monospaced()
        }
        .font(.footnote)
    }

    private func copy() {
        do {
            UIPasteboard.general.string = String(decoding: try log.json(), as: UTF8.self)
            note = "Copied \(log.samples.count) samples."
        } catch { note = "Copy failed: \(error.localizedDescription)" }
    }

    private func save() {
        do {
            try log.save()
            note = "Wrote \(log.samples.count) samples to Documents/\(InputProbe.fileName)."
        } catch { note = "Write failed: \(error.localizedDescription)" }
    }
}

private struct SampleRow: View {
    let sample: InputProbe.Sample

    var body: some View {
        let s = sample, began = s.phases.first, ended = s.phases.last
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "#\(s.index) \(s.label) · \(s.type) · tap \(s.tapCount) · \(Int(s.durationMs)) ms").font(.footnote.bold())
            Text(verbatim: "radius \(f(began?.majorRadius)) ±\(f(began?.majorRadiusTolerance)) → \(f(ended?.majorRadius)) · force \(f(began?.force))/\(f(began?.maximumPossibleForce))")
            Text(verbatim: "altitude \(f(began?.altitudeAngle)) azimuth \(f(began?.azimuth)) · at \(f(began?.x)), \(f(began?.y))")
            Text(verbatim: "phases \(s.phases.map(\.phase).joined(separator: ">")) · moved \(s.moved) · path \(f(s.pathPt)) pt")
            Text(verbatim: "event \(s.eventType)/\(s.eventSubtype) buttons \(s.buttonMask) · hover before \(s.hoverBefore ? "yes (\(s.hoverEvents))" : "no") · captured \(s.signals.screenCaptured ? "yes" : "no")")
        }
        .font(.caption.monospaced())
    }

    private func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
}

/// The tap pad: raw UIKit touches (SwiftUI hides UITouch) and a hover recognizer for the pointer.
private struct ProbePad: UIViewRepresentable {
    let log: InputProbeLog

    func makeUIView(context: Context) -> PadView {
        let v = PadView()
        v.log = log
        v.backgroundColor = .secondarySystemBackground
        v.isMultipleTouchEnabled = true
        v.addGestureRecognizer(UIHoverGestureRecognizer(target: v, action: #selector(PadView.hover(_:))))
        return v
    }

    func updateUIView(_ uiView: PadView, context: Context) {}

    final class PadView: UIView {
        weak var log: InputProbeLog?

        @objc func hover(_ g: UIHoverGestureRecognizer) {
            if g.state == .began || g.state == .changed { log?.hovered() }
        }

        private func record(_ touches: Set<UITouch>, _ event: UIEvent?) {
            touches.forEach { log?.touch($0, event, in: self) }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { record(touches, event) }
    }
}
