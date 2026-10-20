import Foundation
import UserNotifications

/// Posts "process exited" notifications whose "Show logs" action reopens that site's logs.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let crashCategory = "process-exited"
    private static let showLogsAction = "show-logs"
    private static let siteKey = "site"

    /// Called on the main actor with the site whose logs the user asked to see.
    var onShowLogs: (@MainActor (Site.ID) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func activate() {
        center.delegate = self
        let showLogs = UNNotificationAction(identifier: Self.showLogsAction, title: "Show logs", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.crashCategory, actions: [showLogs], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Portside: notification authorization failed: \(error)") }
        }
    }

    func postExit(site: Site, process: ProcessConfig, code: Int32, lastLine: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(site.name) · \(process.label.isEmpty ? process.command : process.label) exited with code \(code)"
        content.body = lastLine.map { String($0.prefix(200)) } ?? "Show logs to see what happened."
        content.categoryIdentifier = Self.crashCategory
        content.userInfo = [Self.siteKey: site.id.uuidString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.showLogsAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = info[Self.siteKey] as? String, let id = UUID(uuidString: raw) else { return }
        await MainActor.run { onShowLogs?(id) }
    }
}
