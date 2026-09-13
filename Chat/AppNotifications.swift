import AppKit
import Combine
import Foundation
import OSLog
@preconcurrency import UserNotifications

nonisolated enum AppNotificationError: LocalizedError {
    case emptyBody
    case denied
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "A notification body is required."
        case .denied:
            return "Chat isn’t authorized to send notifications. Enable it in System Settings → Notifications → Chat. If Chat isn’t listed, run a signed app build first."
        case .deliveryFailed(let message):
            return "The notification could not be sent. \(message)"
        }
    }
}

final class ChatAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.prepare()
        DockBadgeController.shared.applicationDidFinishLaunching()
    }
}

@MainActor
final class DockBadgeController {
    static let shared = DockBadgeController()
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Chat",
        category: "DockBadge"
    )

    private var unreadCountCancellable: AnyCancellable?
    private var latestUnreadCount = 0
    private var didRequestBadgeAuthorization = false

    private init() {}

    func observe(_ chatStore: ChatStore) {
        unreadCountCancellable = chatStore.$totalUnreadCount.sink { [weak self] count in
            guard let self else { return }
            latestUnreadCount = max(0, count)
            updateDockBadgeIfReady()
        }
    }

    func applicationDidFinishLaunching() {
        updateDockBadge()
    }

    private func updateDockBadgeIfReady() {
        updateDockBadge()
    }

    private func updateDockBadge() {
        guard let application = NSApp else { return }
        let count = latestUnreadCount
        let dockTile = application.dockTile
        dockTile.badgeLabel = count == 0 ? nil : String(count)
        dockTile.display()

        // Keep the notification-center badge in sync as well. On recent macOS
        // releases this is the system-owned path that persists across Dock tile
        // refreshes, while NSDockTile keeps the running app responsive immediately.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.setBadgeCount(count) { error in
            if let error {
                Self.logger.error(
                    "System badge update to \(count) failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                Self.logger.debug("System badge updated to \(count)")
            }
        }

        if count > 0, !didRequestBadgeAuthorization {
            didRequestBadgeAuthorization = true
            notificationCenter.getNotificationSettings { settings in
                guard settings.badgeSetting != .enabled,
                      settings.authorizationStatus != .denied else { return }
                notificationCenter.requestAuthorization(options: [.badge]) { granted, error in
                    if let error {
                        Self.logger.error(
                            "Badge authorization request failed: \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    guard granted else { return }
                    notificationCenter.setBadgeCount(count) { retryError in
                        if let retryError {
                            Self.logger.error(
                                "System badge retry to \(count) failed: \(retryError.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                }
            }
        }
    }
}

nonisolated final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresentationDelegate()

    @objc func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        print("presenting notification: \(notification.request.content.title): \(notification.request.content.body)")
        completionHandler([.banner, .list, .sound])
    }

    @objc func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            NSApplication.shared.activate()
        }
        completionHandler()
    }
}

enum AppNotifications {
    private static let maxTitleLength = 120
    private static let maxBodyLength = 500
    private static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound, .badge]

    static func prepare() {
        UNUserNotificationCenter.current().delegate = NotificationPresentationDelegate.shared
    }

    static func resolvedTitle(title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return clamped(trimmed, maxLength: maxTitleLength)
        }
        let fallbackTitle = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTitle.isEmpty ? "Chat" : clamped(fallbackTitle, maxLength: maxTitleLength)
    }

    static func send(title: String, body: String) async throws -> String {
        print("sending \(title): \(body)")

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw AppNotificationError.emptyBody
        }

        prepare()
        try await ensureAuthorized()

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("notification settings: \(diagnosticSummary(settings))")

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? "Chat" : clamped(trimmedTitle, maxLength: maxTitleLength)
        let resolvedBody = clamped(trimmedBody, maxLength: maxBodyLength)

        let content = UNMutableNotificationContent()
        content.title = resolvedTitle
        content.body = resolvedBody
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            throw mappedError(error)
        }

        return "Notification sent."
    }

    static func sendDeveloperTest() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let diagnostics = diagnosticSummary(settings)
        do {
            _ = try await send(
                title: "Chat",
                body: "Test notification from the Developer menu."
            )
            presentAlert(
                title: "Notification scheduled",
                text: """
                \(diagnostics)

                A system banner should appear at the top-right, or in Notification Center.

                This is not an entitlement issue — local notifications do not need the Push capability. If nothing appears, open System Settings → Notifications → Chat and allow notifications with a Desktop/banner style.
                """
            )
        } catch {
            presentAlert(
                title: "Notification failed",
                text: "\(error.localizedDescription)\n\n\(diagnostics)"
            )
        }
    }

    private static func ensureAuthorized() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: authorizationOptions)
            } catch {
                throw mappedError(error)
            }
            guard granted else {
                throw AppNotificationError.denied
            }
        case .denied:
            throw AppNotificationError.denied
        @unknown default:
            throw AppNotificationError.denied
        }
    }

    private static func mappedError(_ error: Error) -> AppNotificationError {
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain,
           nsError.code == UNError.Code.notificationsNotAllowed.rawValue {
            return .denied
        }
        return .deliveryFailed(error.localizedDescription)
    }

    private static func presentAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.runModal()
    }

    private static func diagnosticSummary(_ settings: UNNotificationSettings) -> String {
        "auth=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue) alertStyle=\(settings.alertStyle.rawValue) sound=\(settings.soundSetting.rawValue)"
    }

    private static func clamped(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength - 1)
        return String(text[..<end]) + "…"
    }
}
