import MessageUI
import SwiftUI

/// Mail with one attached file (an intent, the logs). Check `MFMailComposeViewController.canSendMail()` first.
struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let attachment: URL
    var mimeType = "application/json"
    let done: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([to])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        if let data = try? Data(contentsOf: attachment) {
            vc.addAttachmentData(data, mimeType: mimeType, fileName: attachment.lastPathComponent)
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
