import SwiftUI

/// Settings › Listen to phone audio: the agent also hears what the phone plays while it mirrors (a video, a call),
/// as words transcribed on the phone. Off by default.
struct ListenSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var audio: AudioFeed
    @AppStorage(ListenSetting.key) private var listen = false

    var body: some View {
        Section {
            Toggle(isOn: $listen) { SettingsLabel(title: "Listen to phone audio", symbol: "waveform", color: .mint) }
                .onChange(of: listen) { _, on in app.setListening(on) }
        } footer: {
            footer
        }
    }

    private var footer: Text {
        switch listen ? audio.state : nil {
        case .denied?: return Text("Speech recognition is off for ESP32 Agent. Turn it on in Settings › ESP32 Agent.")
        case .unavailable(let why)?: return Text(verbatim: why)  // already localized
        default: return Text("While the screen is mirrored, the agent also hears sound from the phone, such as a video or a call. Speech is turned into text on this iPhone.")
        }
    }
}
