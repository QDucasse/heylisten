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

    @MainActor
    func post(item: SessionItem, sound: Bool) {
        let c = UNMutableNotificationContent()
        let where_ = item.isLocal ? "" : " · \(item.host)"
        let state = item.wire.attention?.state
        let permission = state == "permission"
        let msg = item.wire.attention?.message ?? ""
        c.subtitle = "\(item.wire.name)\(where_)"
        if state == "error" {
            c.title = "\(item.project) stopped"
            c.body = "The turn ended on an API error: \(msg.isEmpty ? "unknown" : msg)."
        } else {
            c.title = permission ? "\(item.project) needs permission" : "\(item.project) is waiting for you"
            c.body = msg.isEmpty || msg == "Turn finished" ? (permission ? "Claude is asking to continue." : "Turn finished.") : msg
        }
        if sound { c.sound = .default }
        c.userInfo = ["key": item.id]
        c.threadIdentifier = item.id
        let req = UNNotificationRequest(identifier: "\(item.id)|\(item.wire.attention?.ts ?? 0)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
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
