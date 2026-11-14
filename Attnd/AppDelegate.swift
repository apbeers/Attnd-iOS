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
        UNUserNotificationCenter.current().delegate = self
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
        appState.pushRegistrationDidFail()
    }

    // MARK: - Silent pushes (content_updated)

    /// Foreground and background. Returns once the refresh (and its save to disk) is done,
    /// which is when iOS may suspend the app again.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let payload = PushPayload(userInfo: userInfo)
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
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
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
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            await self.appState.handlePush(payload, opened: true)
        }
    }
}
