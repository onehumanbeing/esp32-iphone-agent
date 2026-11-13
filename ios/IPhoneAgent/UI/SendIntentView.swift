import MessageUI
import SwiftUI

/// Send to Developer: builds the anonymized file, then opens Mail addressed to intents@handsy.tech with it
/// attached. Without a Mail account, the file goes to the share sheet with the address shown.
struct SendIntentView: View {
    @ObservedObject var app: AppModel
    let intent: SavedTask
    @State private var screenshots = false
    @State private var file: URL?
    @State private var mailing = false
    @State private var sent = false

    private var hasScreens: Bool { intent.steps?.contains { $0.frame != nil } ?? false }

    var body: some View {
        List {
            Section {
                Toggle("Include blurred screenshots", isOn: $screenshots).disabled(!hasScreens)
            } footer: {
                Text("Screenshots are your choice and off by default. If you include them, text on them is pixelated and the status bar is blacked out on your iPhone, and the mail asks our model to blur anything left, like faces and photos, before anyone looks. Typed text, your model key and network names are removed. You see the mail before it is sent.")
            }
            Section {
                Label("We use what you send only to improve intents in \(AppName.current), and never for anything else.",
                      systemImage: "hand.raised")
                    .font(.subheadline)
            }
            Section {
                if sent {
                    Label("Thanks! We read every intent.", systemImage: "checkmark.circle")
                } else if let file {
                    if MFMailComposeViewController.canSendMail() {
                        Button { mailing = true } label: { Label("Write Mail", systemImage: "envelope") }
                    } else {
                        ShareLink(item: file) { Label("Share File", systemImage: "square.and.arrow.up") }
                        Text("Send it to \(IntentShare.address).").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Send to Developer")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: screenshots) {
            file = nil
            let item = await IntentShare.prepare(intent, screenshots: screenshots, redactor: app.shareRedactor)
            file = try? IntentArchive.write([item], note: screenshots ? IntentShare.reviewNote : nil)
        }
        .sheet(isPresented: $mailing) {
            if let file {
                MailComposer(to: IntentShare.address, subject: "Intent: \(intent.name)", body: IntentShare.mailBody(screenshots: screenshots),
                             attachment: file) { result in
                    if result == .sent { sent = true; Analytics.capture("intent_sent", ["screens": screenshots]) }
                }
                .ignoresSafeArea()
            }
        }
    }
}

private struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let attachment: URL
    let done: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([to])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let data = try? Data(contentsOf: attachment) {
            vc.addAttachmentData(data, mimeType: "application/json", fileName: attachment.lastPathComponent)
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: (MFMailComposeResult) -> Void
        init(done: @escaping (MFMailComposeResult) -> Void) { self.done = done }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            done(result)
            controller.dismiss(animated: true)
        }
    }
}
