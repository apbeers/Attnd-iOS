// AppDelegate.swift
// Attnd
//
// UIKit hooks SwiftUI doesn't cover: APNs registration and push delivery.
// Installed with @UIApplicationDelegateAdaptor in AttndApp. Owns the AppState
// so push callbacks can reach it.
//
// Pushes (see API_V2.md):
//   - type "notification": visible alert. Tapping it opens the Notifications tab.
//   - type "content_updated": silent (content-available). Refetch the bundle.

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
        appState.registerForPushIfEnabled()
        return true
    }

    // MARK: - APNs registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        appState.updatePushToken(hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulators without APNs and devices without the entitlement end up here.
        // The app keeps working; it just won't receive pushes.
    }

    // MARK: - Silent pushes (content_updated)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let payload = PushPayload(userInfo: userInfo)
        guard payload.kind == .contentUpdated || payload.kind == .notification else { return .noData }
        await appState.handlePush(payload, opened: false)
        return .newData
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
