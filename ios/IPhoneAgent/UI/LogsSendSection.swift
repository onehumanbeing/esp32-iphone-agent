import MessageUI
import SwiftUI

/// At the top of Files › Logs: send the logs to us. The diagnostics upload when this build has one (the user gets a
/// report id); otherwise a mail to support with the folder zipped, or the share sheet when Mail isn't set up.
struct LogsSendSection: View {
    @ObservedObject var app: AppModel
    @State private var zip: URL?
    @State private var mailing = false
    @State private var shareURL: URL?
    @State private var preparing = false

    static let address = "support@manina.ai"

    var body: some View {
        Section {
            Button(action: send) {
                HStack {
                    Label("Send to Developer", systemImage: "paperplane")
                    Spacer()
                    if preparing { ProgressView() }
                }
            }
            .disabled(preparing)
        } footer: {
            Text(Trial.available
                 ? "Sends the debug log, the board's state and log, and crash reports, so a problem can be looked into. No runs, screenshots or API keys."
                 : "Mails this folder to \(Self.address). Logs can mention your tasks; you see the mail before it is sent.")
        }
        .sheet(isPresented: $mailing) {
            if let zip {
                MailComposer(to: Self.address, subject: "\(AppName.current) logs",
                             body: "What went wrong, and when:\n\n", attachment: zip, mimeType: "application/zip") { _ in }
                    .ignoresSafeArea()
            }
        }
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }

    private func send() {
        if Trial.available { app.askDiagnostics = true; return }
        preparing = true
        Task {
            let made = await Task.detached(priority: .userInitiated) { FolderZip.make(FilesLayout.logs) }.value
            preparing = false
            guard let made else { return }
            zip = made
            if MFMailComposeViewController.canSendMail() { mailing = true } else { shareURL = made }
        }
    }
}
