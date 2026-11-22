import Foundation
import UserNotifications

/// macOS notifications; clicking one jumps to the session.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ a: Alert) {
        let c = UNMutableNotificationContent()
        c.title = a.title
        c.subtitle = a.subtitle
        c.body = a.body
        if a.sound { c.sound = .default }
        c.userInfo = ["key": a.key]
        c.threadIdentifier = a.key
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo["key"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let key, let item = Store.shared.items.first(where: { $0.id == key }) {
                    Jumper.jump(item)
                }
            }
            completionHandler()
        }
    }
}
