import AppKit
import Foundation
import UserNotifications

nonisolated enum AppNotificationError: LocalizedError {
    case emptyBody
    case denied
    case deliveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "A notification body is required."
        case .denied:
            return "Notifications are turned off for Chat. Enable them in System Settings → Notifications → Chat."
        case .deliveryFailed(let message):
            return "The notification could not be sent. \(message)"
        }
    }
}

final class ChatAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.prepare()
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
        Task {
            await requestAuthorizationIfNeeded()
        }
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
            throw AppNotificationError.deliveryFailed(error.localizedDescription)
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

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: authorizationOptions)
    }

    private static func ensureAuthorized() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            let granted = try await center.requestAuthorization(options: authorizationOptions)
            guard granted else {
                throw AppNotificationError.denied
            }
        case .denied:
            throw AppNotificationError.denied
        @unknown default:
            throw AppNotificationError.denied
        }
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
