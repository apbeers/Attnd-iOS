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

// MARK: - Assistant files (Nov 22, 2026)

/// The chat transcript, the plan's undo stack and the model's conversation, as files in the App
/// Group container (`attnd-assistant/<name>`) instead of UserDefaults: they grow to tens of KB
/// per event, and every UserDefaults write re-encodes the whole domain on the main thread. The
/// app and the App Clip read the same container, so the handover needs nothing more for them
/// (the app opens the clip's transcript for the same event). Without the container (tests,
/// a missing entitlement) Application Support is used.
///
/// Reads are synchronous (from memory after the first), writes are queued on one background
/// queue in order (atomic). The first read of a name moves an older build's UserDefaults value
/// into the file (written synchronously before the key is removed, so nothing is lost).
final class AssistantFiles: @unchecked Sendable {
    static let shared = AssistantFiles()

    let directory: URL?
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private let queue = DispatchQueue(label: "com.arcu.Attnd.assistant-files", qos: .utility)

    init(directory: URL? = AssistantFiles.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        #if canImport(Darwin)
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppHandover.groupId)
        #else
        let group: URL? = nil  // the Linux test harness
        #endif
        let base = group ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("attnd-assistant", isDirectory: true)
    }

    /// The file's text. `legacyKey`: the UserDefaults key older builds stored it under.
    func string(_ name: String, legacyKey: String? = nil, defaults: UserDefaults = .standard) -> String? {
        lock.lock()
        if let hit = cache[name] { lock.unlock(); return hit }
        lock.unlock()
        var value = directory.flatMap { try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }
        if value == nil, let legacyKey, let old = defaults.string(forKey: legacyKey) {
            value = old
            if write(old, name) { defaults.removeObject(forKey: legacyKey) }
        }
        lock.lock()
        // A write that raced this read wins.
        if let newer = cache[name] { lock.unlock(); return newer }
        cache[name] = .some(value)
        lock.unlock()
        return value
    }

    /// Stores (nil = deletes) the file's text; the write happens in the background, in order.
    func set(_ value: String?, _ name: String) {
        lock.lock()
        cache[name] = .some(value)
        lock.unlock()
        queue.async { [weak self] in _ = self?.write(value, name) }
    }

    /// Waits for queued writes (tests, going to the background, the handover export).
    func flush() {
        queue.sync {}
    }

    @discardableResult
    private func write(_ value: String?, _ name: String) -> Bool {
        guard let directory else { return false }
        let file = directory.appendingPathComponent(name)
        do {
            if let value {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(value.utf8).write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return true
        } catch {
            return false
        }
    }
}
