// AppHandover.swift
// Attnd (app and App Clip; pure Foundation, unit tested in ScreenLayoutTests)
//
// App Clip → full app (batch 7, Nov 21, 2026). People scan the code, use the App Clip, and may
// install the app later; the app then opens on the same event with everything they did. Both
// targets have the App Group `group.com.arcu.Attnd` (entitlements only; the widget extensions
// don't need it):
//   - The App Clip exports a snapshot into the group after every saved bundle and when it goes to
//     the background: its `pref.*` preferences (event code, My schedule / hearts, plan, chat,
//     settings) and the device id as one dictionary in the shared suite, and its saved event
//     file (`attnd-event/event.json`) copied into the group container.
//   - The full app imports it once, at its first launch, before AppState reads anything, and
//     only when it has no event of its own: the preferences are copied (the device id too, so
//     the server keeps one device; its push token is the app's own) and the event file goes into
//     its Application Support, so the normal restore opens the event offline and rejoins it.
//   - The app marks itself installed in the group; the clip then ends its Live Activities and
//     reminders (TestFlight keeps both installed; in production the system removes the clip
//     when the app is installed) so only the app's own activity runs.

import Foundation

enum AppHandover {
    static let groupId = "group.com.arcu.Attnd"
    static let deviceIdKey = "com.arcu.attnd.deviceId"

    /// Shared suite keys.
    static let prefsKey = "handover.prefs"
    static let exportedAtKey = "handover.exportedAt"
    static let appInstalledKey = "handover.appInstalledAt"
    /// The app's own defaults: the import ran (once, whatever it found).
    static let importedKey = "pref.handover.imported"

    static let eventFileName = "handover-event.json"

    /// Preferences that belong to one install and are never handed over: the APNs token (the
    /// app's topic differs), pending scheduled Live Activities, this build's bookkeeping.
    static let excludedKeys: Set<String> = [
        "pref.pushToken", "pref.liveActivity.scheduledStarts", importedKey,
        "pref.oldShortcutsRemovedBuild", "pref.previewEventId",
    ]

    static func handsOver(_ key: String) -> Bool {
        key == deviceIdKey || (key.hasPrefix("pref.") && !excludedKeys.contains(key))
    }

    /// The values the clip hands over (property-list values only).
    static func snapshot(of defaults: [String: Any]) -> [String: Any] {
        defaults.filter { handsOver($0.key) && PropertyListSerialization.propertyList($0.value, isValidFor: .binary) }
    }

    // MARK: The clip

    /// Writes the clip's snapshot and its saved event file into the group.
    static func export(from defaults: UserDefaults, to shared: UserDefaults, eventFile: URL?, sharedDirectory: URL?, now: Date = .now) {
        shared.set(snapshot(of: defaults.dictionaryRepresentation()), forKey: prefsKey)
        shared.set(now, forKey: exportedAtKey)
        guard let eventFile, let sharedDirectory else { return }
        let target = sharedDirectory.appendingPathComponent(eventFileName)
        if let data = try? Data(contentsOf: eventFile) {
            try? data.write(to: target, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: target)
        }
    }

    // MARK: The app

    /// Imports the clip's snapshot once. Returns true when an event was handed over.
    @discardableResult
    static func importIfNeeded(into defaults: UserDefaults, from shared: UserDefaults, eventFile: URL?,
                               sharedDirectory: URL?, now: Date = .now) -> Bool {
        shared.set(now, forKey: appInstalledKey)
        guard !defaults.bool(forKey: importedKey) else { return false }
        defaults.set(true, forKey: importedKey)
        // The app has an event of its own (installed before the clip was used): keep it.
        guard defaults.string(forKey: "pref.savedEventCode") == nil,
              let prefs = shared.dictionary(forKey: prefsKey),
              let code = prefs["pref.savedEventCode"] as? String, !code.isEmpty else { return false }
        for (key, value) in prefs where handsOver(key) {
            defaults.set(value, forKey: key)
        }
        if let eventFile, let sharedDirectory,
           let data = try? Data(contentsOf: sharedDirectory.appendingPathComponent(eventFileName)) {
            try? FileManager.default.createDirectory(at: eventFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: eventFile, options: .atomic)
        }
        return true
    }

    /// The clip: the full app is installed (it launched once), so the clip stops following.
    static func appTookOver(_ shared: UserDefaults?) -> Bool {
        shared?.object(forKey: appInstalledKey) != nil
    }
}
