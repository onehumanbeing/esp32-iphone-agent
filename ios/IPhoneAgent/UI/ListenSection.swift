import SwiftUI

/// Settings › Listen to phone audio: the agent also hears what the phone plays while it mirrors (a video, a call),
/// as words transcribed on the phone. Off by default.
struct ListenSection: View {
    @ObservedObject var app: AppModel
    @ObservedObject var audio: AudioFeed
    @AppStorage(ListenSetting.key) private var listen = false
    @AppStorage(ListenSetting.shareKey) private var share = true
    @State private var second = UserDefaults.standard.string(forKey: SpeechLanguages.key) ?? SpeechLanguages.automatic
    @State private var choices: [String] = []

    var body: some View {
        Section {
            Toggle(isOn: $listen) { SettingsLabel(title: "Listen to phone audio", symbol: "waveform", color: .mint) }
                .onChange(of: listen) { _, on in app.setListening(on) }
            if listen {
                // English is always recognized; the second language is the other one the phone may play
                Picker("Second language", selection: $second) {
                    Text("Automatic (from the screen)").tag(SpeechLanguages.automatic)
                    Text("None").tag("")
                    ForEach(choices, id: \.self) { Text(verbatim: SpeechLanguages.name($0)).tag($0) }
                }
                .onAppear { if choices.isEmpty { choices = SpeechLanguages.choices() } }
                .onChange(of: second) { _, id in
                    UserDefaults.standard.set(id, forKey: SpeechLanguages.key)
                    app.audio.reset()
                }
                Toggle("Share with the computer (CLI)", isOn: $share)
                    .onChange(of: share) { _, _ in app.shareHearing() }
            }
        } footer: {
            footer
        }
    }

    private var footer: Text {
        switch listen ? audio.state : nil {
        case .denied?: return Text("Speech recognition is off for ESP32 Agent. Turn it on in Settings › ESP32 Agent.")
        case .unavailable(let why)?: return Text(verbatim: why)  // already localized
        default: return Text("While the screen is mirrored, the agent also hears sound from the phone, such as a video or a call. Speech in English and the second language is turned into text on this iPhone.")
        }
    }
}
