import AppKit
import UserNotifications

/// Posts Airbag's notifications and answers their buttons. Permission is asked at the first event worth a
/// notification, never at launch (spec §8), and a notification is posted only once permission is granted.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    enum Kind: String {
        /// An agent waits until the user approves (Allow Once / Show).
        case approval
        /// Servers left running by an ended session (Stop / Keep Running).
        case orphans
        /// A blocked command, or one that ran without asking (opens the Guard entry).
        case guardEntry = "guard"
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: String(localized: "Allow Once"))
        let show = UNNotificationAction(identifier: "show", title: String(localized: "Show"), options: [.foreground])
        let stop = UNNotificationAction(identifier: "stop", title: String(localized: "Stop"), options: [.destructive])
        let keep = UNNotificationAction(identifier: "keep", title: String(localized: "Keep Running"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.approval.rawValue, actions: [allow, show], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.orphans.rawValue, actions: [stop, keep], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.guardEntry.rawValue, actions: [], intentIdentifiers: []),
        ])
    }

    /// `passive` notifications go to Notification Center without a sound or banner interruption. The same `id`
    /// replaces an earlier notification instead of adding one.
    func post(_ kind: Kind, id: String, title: String, body: String, info: [String: String] = [:], passive: Bool = false, thread: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = kind.rawValue
            content.userInfo = info.merging(["kind": kind.rawValue]) { a, _ in a }
            content.interruptionLevel = passive ? .passive : .active
            if !passive { content.sound = .default }
            if let thread { content.threadIdentifier = thread }
            center.add(UNNotificationRequest(identifier: "\(kind.rawValue)-\(id)", content: content, trigger: nil))
        }
    }

    /// Takes back a notification whose item was handled in the app.
    func remove(_ kind: Kind, id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(kind.rawValue)-\(id)"])
    }

    /// Banners also while Airbag's own window is in front, but none while the popover already shows the item.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            let popover = MainActor.assumeIsolated { AppModel.shared.popoverVisible }
            completionHandler(popover ? [] : [.banner, .list, .sound])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppModel.shared.handleNotification(action: action, info: info) }
            completionHandler()
        }
    }
}
