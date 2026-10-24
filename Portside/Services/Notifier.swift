import Foundation
import UserNotifications

/// Posts "process exited" and "command finished" notifications whose "Show logs" action reopens
/// that site's logs on the tab the notification is about.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let crashCategory = "process-exited"
    private static let showLogsAction = "show-logs"
    private static let siteKey = "site"
    private static let tabKey = "tab"

    /// Called on the main actor with the site whose logs the user asked to see, and the tab to select.
    var onShowLogs: (@MainActor (Site.ID, UUID?) -> Void)?

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
        post(
            title: "\(site.name) · \(process.label.isEmpty ? process.command : process.label) exited with code \(code)",
            body: lastLine ?? "Show logs to see what happened.", site: site.id, tab: process.id
        )
    }

    func postCommandFinished(site: Site, command: SiteCommand, code: Int32, lastLine: String?) {
        let outcome = code == 0 ? "finished" : "failed with code \(code)"
        post(title: "\(site.name) · \(command.name) \(outcome)", body: lastLine ?? "Show logs to see the output.", site: site.id, tab: command.id)
    }

    private func post(title: String, body: String, site: Site.ID, tab: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.categoryIdentifier = Self.crashCategory
        content.userInfo = [Self.siteKey: site.uuidString, Self.tabKey: tab.uuidString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.showLogsAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = info[Self.siteKey] as? String, let id = UUID(uuidString: raw) else { return }
        let tab = (info[Self.tabKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { onShowLogs?(id, tab) }
    }
}
