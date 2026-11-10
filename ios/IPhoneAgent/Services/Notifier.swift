import Foundation
import UserNotifications

/// Local notifications for runs: done / failed / needs help / mirroring lost / board disconnected, with
/// actions (Review, Retry, Stop, Continue, Skip, Take over). Tapping one opens the run's review.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String { case done, failed, trouble, help, confirm, takeover, mirroring, board, wifi }
    enum Action: String { case review, retry, stop, resume, skip, takeOver, report }

    /// Called with the action (nil = the notification itself was tapped), the run id and the notification's kind.
    var onAction: ((Action?, String, Kind?) -> Void)?
    private let center = UNUserNotificationCenter.current()
    static let askedKey = "askedNotifications"

    override init() {
        super.init()
        center.delegate = self
        let review = UNNotificationAction(identifier: Action.review.rawValue, title: String(localized: "Review"),
                                          options: [.foreground])
        let retry = UNNotificationAction(identifier: Action.retry.rawValue, title: String(localized: "Retry"),
                                         options: [.foreground])
        let stop = UNNotificationAction(identifier: Action.stop.rawValue, title: String(localized: "Stop"),
                                        options: [.destructive])
        let resume = UNNotificationAction(identifier: Action.resume.rawValue, title: String(localized: "Continue"))
        let skip = UNNotificationAction(identifier: Action.skip.rawValue, title: String(localized: "Skip step"))
        let takeOver = UNNotificationAction(identifier: Action.takeOver.rawValue, title: String(localized: "Take over"))
        let report = UNNotificationAction(identifier: Action.report.rawValue, title: String(localized: "Send diagnostics"),
                                          options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.done.rawValue, actions: [review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.failed.rawValue, actions: [review, retry, report], intentIdentifiers: []),
            // The run couldn't start (board, mirroring, frames): tapping it asks to send diagnostics.
            UNNotificationCategory(identifier: Kind.trouble.rawValue, actions: [report, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.help.rawValue, actions: [takeOver, skip, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.confirm.rawValue, actions: [resume, skip, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.takeover.rawValue, actions: [resume, stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.mirroring.rawValue, actions: [stop, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.board.rawValue, actions: [stop, review], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.wifi.rawValue, actions: [stop, review], intentIdentifiers: []),
        ])
    }

    /// Asked once, on the first Start (with a one-line reason shown by the app first).
    static var asked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    func requestPermission() async {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ kind: Kind, title: String, body: String, run: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.rawValue
        content.userInfo = ["run": run]
        let urgent: Set<Kind> = [.help, .confirm, .mirroring, .board, .wifi]  // the run waits for the user
        content.sound = urgent.contains(kind) ? .default : nil
        content.interruptionLevel = urgent.contains(kind) ? .timeSensitive : .active
        center.removeDeliveredNotifications(withIdentifiers: [Kind.help.rawValue, Kind.confirm.rawValue, Kind.takeover.rawValue])
        center.add(UNNotificationRequest(identifier: kind.rawValue, content: content, trigger: nil))
    }

    func clearHelp() {
        center.removeDeliveredNotifications(withIdentifiers: [Kind.help.rawValue, Kind.confirm.rawValue, Kind.takeover.rawValue])
    }

    /// The link is back: the "start mirroring / check the board / join Wi-Fi" asks are stale.
    func clearLinkAsks() {
        center.removeDeliveredNotifications(withIdentifiers: [Kind.mirroring.rawValue, Kind.board.rawValue, Kind.wifi.rawValue])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let run = response.notification.request.content.userInfo["run"] as? String ?? ""
        let id = response.actionIdentifier
        let action = id == UNNotificationDefaultActionIdentifier ? nil : Action(rawValue: id)
        let kind = Kind(rawValue: response.notification.request.content.categoryIdentifier)
        await MainActor.run { onAction?(action, run, kind) }
    }
}
