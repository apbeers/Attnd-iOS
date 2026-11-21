// AppDelegate.swift
// Attnd + AttndAppClip
//
// UIKit hooks SwiftUI doesn't cover: APNs registration and push delivery.
// Installed with @UIApplicationDelegateAdaptor in AttndApp. Owns the AppState
// so push callbacks can reach it.
//
// Pushes (see API_V2.md):
//   - type "notification": visible alert. Tapping it opens the Updates tab.
//   - type "content_updated": silent (content-available), sent to every device in
//     the event with a token, opted in or not (API-007). Refetch the bundle when its
//     content_version is newer, after a random 0–10 s delay.
//
// The app and the App Clip register with APNs at every launch, whatever the notification opt-in:
// silent pushes need no permission. The opt-in only controls alerts (`subscribed`).
//
// The app's own local notifications (reminders before hearted items, "tap to follow on your
// Lock Screen"; LiveFollowController) carry `attnd_local` instead of `type`: a tap opens the
// item (and starts following), and they never trigger a bundle refresh.

import CoreSpotlight
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
        // MetricKit: crash / hang and other diagnostic reports (API-013); launch times are LaunchTiming's.
        MetricKitReporter.shared.start()
        UNUserNotificationCenter.current().delegate = self
        // Live Activity and reminders; also handles Live Activity buttons, which
        // may launch the app in the background.
        LiveFollowController.shared.install(appState: appState)
        appState.registerForRemoteNotifications()
        Self.removeOldShortcuts(application)
        return true
    }

    /// Siri, Shortcuts and Spotlight were removed on Nov 19, 2026 (App Intents can't run in the
    /// App Clip), but what older builds left behind stayed on the phone and failed when used
    /// ("Happening now", "Up next"): Spotlight items, Home Screen quick actions and saved user
    /// activities. Removed once per build.
    private static func removeOldShortcuts(_ application: UIApplication) {
        let key = "pref.oldShortcutsRemovedBuild"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        UserDefaults.standard.set(build, forKey: key)
        application.shortcutItems = nil
        NSUserActivity.deleteAllSavedUserActivities {}
        CSSearchableIndex.default().deleteAllSearchableItems { error in
            if let error { AppLog.caught(error, .lifecycle, "spotlight_cleanup") }
        }
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
        // The .remoteNotification key is deprecated in iOS 26 (scene-based launch handling); its
        // raw value still arrives here, and this only labels the log line.
        if options?[UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsRemoteNotificationKey")] != nil { return "silent_push" }
        // A Live Activity button (LiveActivityIntent).
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
// The completion-handler variants, answered synchronously on the thread the system called us on
// (the main thread). The async variants returned on a cooperative-pool thread, and UIKit's
// handler then asserted it was on the main thread: tapping a notification crashed the app
// (MetricKit report, TestFlight 2.0.169). Each callback parses userInfo into a Sendable
// PushPayload right away and hands only that to the main actor; the bundle refresh runs in its
// own task so the system isn't kept waiting for the network.

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// A notification arrived while the app is open: show it and refresh.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        // A reminder or "tap to follow" while the app is open: just show it.
        if let local = LocalNotificationInfo(userInfo: userInfo) {
            if local.kind == LiveFollowKeys.reminderCategory {
                AppLog.info(.live, "live.reminder.shown", "Reminder shown", ["item_id": .int(local.itemId ?? 0)])
            }
            completionHandler([.banner, .list, .sound])
            return
        }
        let payload = PushPayload(userInfo: userInfo)
        let title = notification.request.content.title
        let body = notification.request.content.body
        Task { @MainActor in
            await self.appState.handlePush(payload, opened: false)
        }
        // An organizer update while the app is open: the app's own banner at the top (swipe up to
        // dismiss, tap to open), the system's only in Notification Center.
        if payload.kind == .notification, let id = payload.notificationId, !title.isEmpty || !body.isEmpty {
            let urgent = (userInfo["priority"] as? String) == "urgent"
            Task { @MainActor in
                self.appState.showInAppBanner(InAppBanner(notificationId: id, title: title, body: body, urgent: urgent))
            }
            completionHandler([.list, .sound])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    /// The user tapped a notification: open the Notifications tab for that event (also when the
    /// tap launched the app: `handlePush` waits for the saved event to be restored).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let local = LocalNotificationInfo(userInfo: userInfo) {
            AppLog.info(.push, "push.opened", "Local notification tapped (\(local.kind))", ["type": .string(local.kind)])
            Task { @MainActor in
                _ = await LiveFollowController.shared.handleNotificationTap(local)
            }
            completionHandler()
            return
        }
        let payload = PushPayload(userInfo: userInfo)
        Task { @MainActor in
            await self.appState.handlePush(payload, opened: true)
        }
        completionHandler()
    }
}
