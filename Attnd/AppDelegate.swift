// AppDelegate.swift
// Attnd
//
// UIKit hooks SwiftUI doesn't cover: APNs registration and push delivery.
// Installed with @UIApplicationDelegateAdaptor in AttndApp. Owns the AppState
// so push callbacks can reach it.
//
// Pushes (see API_V2.md):
//   - type "notification": visible alert. Tapping it opens the Notifications tab.
//   - type "content_updated": silent (content-available), sent to every device in
//     the event with a token, opted in or not (API-007). Refetch the bundle when its
//     content_version is newer, after a random 0–10 s delay.
//
// The app registers with APNs at every launch, whatever the notification opt-in:
// silent pushes need no permission. The opt-in only controls alerts (`subscribed`).
//
// The app's own local notifications (reminders before hearted items, "tap to follow on your
// Lock Screen"; LiveFollowController) carry `attnd_local` instead of `type`: a tap opens the
// item (and starts following), and they never trigger a bundle refresh.

import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    let appState = AppState()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLog.setForeground(application.applicationState != .background)
        if application.applicationState == .background {
            AppLog.info(.background, "background.wake", "Launched in the background", ["reason": .string(Self.launchReason(launchOptions))])
        }
        // MetricKit: crash / hang reports (API-013) and launch-time buckets (API-014).
        MetricKitReporter.shared.start()
        UNUserNotificationCenter.current().delegate = self
        // Siri, Shortcuts and Spotlight intents (EventIntents.swift) read the joined event from here.
        IntentBridge.appState = appState
        // Live Activity, reminders, venue arrival; also handles Live Activity buttons, which
        // may launch the app in the background.
        LiveFollowController.shared.install(appState: appState)
        appState.registerForRemoteNotifications()
        return true
    }

    // MARK: - APNs registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        appState.updatePushToken(hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulators without APNs and devices without the entitlement end up here.
        // The app keeps working; it polls every 60 s instead of waiting for pushes.
        appState.pushRegistrationDidFail(error)
    }

    /// Why iOS launched the app in the background (`background.wake` reason).
    private static func launchReason(_ options: [UIApplication.LaunchOptionsKey: Any]?) -> String {
        guard let options else { return "app_refresh" }
        // The .remoteNotification / .location keys are deprecated in iOS 26 (scene-based launch handling);
        // their raw values still arrive here, and this only labels the log line.
        if options[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsRemoteNotificationKey")] != nil { return "silent_push" }
        if options[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsLocationKey")] != nil { return "region" }
        return "intent"
    }

    // MARK: - Silent pushes (content_updated)

    /// Foreground and background. Returns once the refresh (and its save to disk) is done,
    /// which is when iOS may suspend the app again.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let payload = PushPayload(userInfo: userInfo)
        if application.applicationState != .active {
            AppLog.info(.background, "background.wake", "Silent push (\(payload.kindName))", ["reason": "silent_push"])
        }
        guard payload.kind == .contentUpdated || payload.kind == .notification else { return .noData }
        let refreshed = await appState.handlePush(payload, opened: false)
        return refreshed ? .newData : .noData
    }
}

// MARK: - UNUserNotificationCenterDelegate
//
// These callbacks are nonisolated: each parses userInfo into a Sendable PushPayload
// right away and hands only that to the main actor. The bundle refresh runs in its
// own task so the system isn't kept waiting for the network.

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// A notification arrived while the app is open: show it and refresh.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        // A reminder or "tap to follow" while the app is open: just show it.
        if let local = LocalNotificationInfo(userInfo: userInfo) {
            if local.kind == LiveFollowKeys.reminderCategory {
                AppLog.info(.live, "live.reminder.shown", "Reminder shown", ["item_id": .int(local.itemId ?? 0)])
            }
            return [.banner, .list, .sound]
        }
        let payload = PushPayload(userInfo: userInfo)
        Task { @MainActor in
            await self.appState.handlePush(payload, opened: false)
        }
        return [.banner, .list, .sound]
    }

    /// The user tapped a notification: open the Notifications tab for that event.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let local = LocalNotificationInfo(userInfo: userInfo) {
            AppLog.info(.push, "push.opened", "Local notification tapped (\(local.kind))", ["type": .string(local.kind)])
            Task { @MainActor in
                _ = await LiveFollowController.shared.handleNotificationTap(local)
            }
            return
        }
        let payload = PushPayload(userInfo: userInfo)
        Task { @MainActor in
            await self.appState.handlePush(payload, opened: true)
        }
    }
}
