import SwiftUI

struct LocalCopySettingsView: View {
    @ObservedObject var app: AppModel
    @AppStorage(LocalCopyConfig.verifiedKey) private var verified = false
    @AppStorage(LocalCopyConfig.shortcutCheckedKey) private var shortcutChecked = false
    @AppStorage(LocalCopyConfig.triggerKey) private var trigger = "keyboard"
    @AppStorage(LocalCopyConfig.comboKey) private var combo = "ctrl+alt+shift+v"
    @AppStorage(LocalCopyConfig.xKey) private var x = 0.1
    @AppStorage(LocalCopyConfig.yKey) private var y = 0.86
    @State private var testing = false
    @State private var shortcutResult = ""
    @State private var boardResult = ""
    @State private var sharing = false
    @State private var choosingPosition = false

    private var shortcut: URL? {
        Bundle.main.url(forResource: "Handsy Local Copy", withExtension: "shortcut", subdirectory: "LocalCopyAssets")
    }

    var body: some View {
        List {
            Section {
                Text("Unicode text stays on this iPhone. A local shortcut copies the full text and acknowledges it; the board pastes once in the original editor.")
                if let shortcut {
                    Button("Import Handsy Local Copy") { sharing = true }
                        .sheet(isPresented: $sharing) { ShareSheet(items: [shortcut]) }
                } else { Text("Shortcut file missing from this build.").foregroundStyle(.red) }
                Text("Import the shortcut into Shortcuts on this iPhone. Open it once to review its actions. Copy to Clipboard must have Local Only on.")
            } header: { Text("1. Install the local shortcut") }
            Section {
                Button("Test Shortcut directly (no board input)") { test(direct: true) }
                    .disabled(testing || app.agent.running)
                Text("Opens Handsy Local Copy on this iPhone. Allow its requested actions, then return here to see the result. This works while the phone is connected to your Mac; it does not move or click any pointer.")
                if !shortcutResult.isEmpty { Text(verbatim: shortcutResult).foregroundStyle(shortcutChecked ? .green : .secondary) }
                if shortcutChecked { Label("Shortcut copy verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            } header: { Text("2. Verify the shortcut") }
            Section {
                Text("For the board test, unplug ESP32 from the Mac and connect its USB data port directly to this iPhone. Bluetooth alone is not enough; otherwise the board controls the Mac.")
                Picker("Trigger", selection: $trigger) {
                    Text("Keyboard command").tag("keyboard")
                    Text("AssistiveTouch long press").tag("button")
                }
                if trigger == "keyboard" {
                    TextField("Key combination", text: $combo).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("In iPhone Settings > Accessibility > Keyboards & Typing > Full Keyboard Access > Commands, bind Handsy Local Copy to this combination. Check that normal typing and Space still work.")
                } else {
                    Text("In iPhone Settings > Accessibility > Touch > AssistiveTouch > Long Press, choose Handsy Local Copy. Set the floating button position below; moving it later requires updating this position.")
                    Text("Set the system Long Press Duration below 0.9 seconds.")
                    Button("Choose floating button position") { choosingPosition = true }
                        .fullScreenCover(isPresented: $choosingPosition) { LocalCopyPositionPicker(x: $x, y: $y) }
                    Slider(value: $x, in: 0.02...0.98) { Text("Horizontal position") }
                    Slider(value: $y, in: 0.08...0.94) { Text("Vertical position") }
                    Text("Button position: \(Int(x * 100))% from left, \(Int(y * 100))% from top").font(.caption)
                    if let spot = AssistiveTouchSpots.all.last {
                        Button("Use last calibrated button position") { x = spot.x; y = spot.y }
                    }
                }
            } header: { Text("3. Connect the phone and bind the trigger") }
            Section {
                Button("Test Board Trigger (does not paste)") { test(direct: false) }
                    .disabled(testing || !shortcutChecked || !app.board.connected || app.agent.running)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if testing { Text(verbatim: app.localCopy.progress) }
                    if let issue = app.localInputIssue { Text(verbatim: issue).font(.caption) }
                }
                if !boardResult.isEmpty { Text(verbatim: boardResult).foregroundStyle(verified ? .green : .secondary) }
                if verified { Label("Copy trigger verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            } header: { Text("4. Verify the board trigger") }
        }
        .navigationTitle("Unicode Input")
        .onChange(of: trigger) { _, _ in invalidateTrigger() }
        .onChange(of: combo) { _, _ in invalidateTrigger() }
        .onChange(of: x) { _, _ in invalidateTrigger() }
        .onChange(of: y) { _, _ in invalidateTrigger() }
    }

    private func invalidateTrigger() { verified = false; boardResult = "" }

    private func test(direct: Bool) {
        testing = true; verified = false; boardResult = ""
        if direct { shortcutChecked = false; shortcutResult = "" }
        Task {
            do {
                try await app.runLocalCopy("Handsy local copy test\n你好，world 🌍", trigger: direct ? .openShortcut : .configured)
                shortcutChecked = true
                if direct {
                    shortcutResult = "Shortcut copied and confirmed the exact text. Next connect ESP32 directly to this iPhone and test the board trigger."
                } else {
                    verified = true
                    boardResult = "Exact text acknowledged through the board trigger. Unicode input is ready. Test a new note next; iOS may still require your first paste approval in the receiving app."
                }
            } catch {
                if direct { shortcutResult = error.localizedDescription }
                else { boardResult = error.localizedDescription }
            }
            testing = false
        }
    }
}

/// The system floating button is above the app. Move this crosshair with sliders, rather than trying
/// to tap through that button; its coordinates include the entire screen, just like the absolute HID.
private struct LocalCopyPositionPicker: View {
    @Binding var x: Double
    @Binding var y: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemBackground)
                Image(systemName: "scope").font(.system(size: 70)).foregroundStyle(.red)
                    .position(x: x * geometry.size.width, y: y * geometry.size.height)
                VStack(spacing: 16) {
                    Text("Align the red target with the floating button").font(.headline)
                    Text("Keep the floating button in place. Use these sliders to move the target behind its centre.")
                    Slider(value: $x, in: 0.02...0.98) { Text("Horizontal position") }
                    Slider(value: $y, in: 0.08...0.94) { Text("Vertical position") }
                    Button("Save position") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 36)
            }
        }.ignoresSafeArea()
    }
}
