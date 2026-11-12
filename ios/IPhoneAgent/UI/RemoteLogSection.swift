import SwiftUI

/// Settings › Developer › Remote debug log: the endpoint URL and token for RemoteLog (both empty = off).
struct RemoteLogSection: View {
    @State private var url = RemoteLogConfig.load().url
    @State private var token = RemoteLogConfig.load().token

    private var config: RemoteLogConfig { RemoteLogConfig(url: url, token: token) }

    var body: some View {
        Section {
            TextField("Endpoint URL", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Token", text: $token)
            HStack {
                Text("Status")
                Spacer()
                Text(config.endpoint == nil ? "Off" : "On").foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote debug log")
        } footer: {
            Text("For debugging your own iPhone: when both are set, the app checks this server about every 30 seconds while it is open or a run is going and, when asked, uploads the end of its text debug log, with keys and tokens removed. Never screenshots. Leave empty to turn it off.")
        }
        .onChange(of: config) { config.save() }
    }
}
