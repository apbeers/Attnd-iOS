// TicketsStore.swift
// Attnd
//
// **App only.** State for My tickets (`TicketsStore`) and door mode (`DoorController`), both
// owned by `AppState` (`tickets`, `door`) and independent of the joined event. Tokens and the
// signed-in emails live in the Keychain; everything shown offline lives in
// `Application Support/attnd-tickets/` (excluded from backup, `TicketFiles`):
//   mine.json                     My tickets (`SavedMyTickets`: raw response + ETag)
//   door-<id>-manifest.json       the door manifest (`SavedDoorManifest`: raw response + ETag)
//   door-<id>-state.json          gate, revocations, every scan + the upload queue, counts
// Logging: only `tickets.*` names from LOG_EVENTS.md, never emails, names, codes, tokens or QR strings.

import Foundation
import Network
import Observation
import UIKit

// MARK: - Files

/// The door manifest on disk: the raw body (a newer build reads what it knows) + ETag.
struct SavedDoorManifest: Codable, Sendable {
    var etag: String?
    var downloadedAt: Date
    var json: Data
}

actor TicketFiles {
    static let shared = TicketFiles()

    private let directory: URL?

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("attnd-tickets", isDirectory: true)
    }

    func read(_ name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func write(_ data: Data, to name: String) {
        guard let directory else { return }
        StorageDirectory.prepare(directory)
        do {
            try data.write(to: directory.appendingPathComponent(name),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.caught(error, .tickets, "ticket_file_write")
        }
    }

    func delete(_ name: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// Every door file (sign-out of door mode).
    func deleteDoorFiles() {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("door-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

private enum TicketKeychain {
    static let buyerToken = "attnd.tickets.buyerToken"
    static let buyerEmail = "attnd.tickets.buyerEmail"
    static let doorToken = "attnd.tickets.doorToken"
    static let doorEmail = "attnd.tickets.doorEmail"
}

private enum TicketDefaults {
    /// Door mode: the events this email works (JSON `[DoorEvent]`) and the one picked.
    static let doorEvents = "pref.door.events"
    static let doorEventId = "pref.door.eventId"
}

/// The device's name for the server's token list ("iPhone"; iOS no longer reveals the user's name).
@MainActor
private var ticketDeviceName: String { UIDevice.current.model }

// MARK: - My tickets

@MainActor
@Observable
final class TicketsStore {
    /// The signed-in email (nil: signed out).
    private(set) var email: String?
    private(set) var payload: MyTicketsPayload?
    private(set) var fetchedAt: Date?
    private(set) var isRefreshing = false
    /// The last refresh failed for lack of network (the stored copy is shown).
    private(set) var isOffline = false
    private(set) var errorMessage: String?

    /// Sign-in: the address a code was sent to.
    private(set) var pendingEmail: String?
    private(set) var isWorking = false

    private var etag: String?
    private var loaded = false

    init() {
        email = KeychainHelper.read(key: TicketKeychain.buyerEmail)
    }

    var isSignedIn: Bool { email != nil && KeychainHelper.read(key: TicketKeychain.buyerToken) != nil }

    /// The stored copy, once (works with no network).
    func loadStored() async {
        guard !loaded else { return }
        loaded = true
        guard let data = await TicketFiles.shared.read("mine.json"),
              let saved = try? SavedMyTickets.decode(data), let decoded = saved.decoded(),
              saved.email == email else { return }
        payload = decoded
        etag = saved.etag
        fetchedAt = saved.fetchedAt
    }

    /// GET tickets/mine/ with the stored ETag; keeps the stored copy on any failure.
    func refresh() async {
        await loadStored()
        guard let email, let token = KeychainHelper.read(key: TicketKeychain.buyerToken), !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let started = ContinuousClock.now
        do {
            switch try await APIClient.shared.myTickets(buyerToken: token, etag: payload == nil ? nil : etag) {
            case .notModified:
                fetchedAt = .now
                log(status: 304, started: started, cache: "304", offline: false)
            case let .updated(decoded, newEtag, data):
                payload = decoded
                etag = newEtag
                fetchedAt = .now
                let saved = SavedMyTickets(email: email, etag: newEtag, fetchedAt: fetchedAt, json: data)
                if let file = try? SavedMyTickets.encode(saved) { await TicketFiles.shared.write(file, to: "mine.json") }
                log(status: 200, started: started, cache: "none", offline: false)
            }
            isOffline = false
            errorMessage = nil
        } catch APIError.ticketSignInExpired {
            await clearLocal()
            errorMessage = TicketErrorText.message(APIError.ticketSignInExpired)
        } catch {
            isOffline = TicketErrorText.isOffline(error)
            if !isOffline { errorMessage = TicketErrorText.message(error) }
            AppLog.caught(error, .tickets, "tickets_mine", level: .notice)
            log(status: 0, started: started, cache: "none", offline: true)
        }
    }

    private func log(status: Int, started: ContinuousClock.Instant, cache: String, offline: Bool) {
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        AppLog.info(.tickets, "tickets.mine.fetched", "My tickets: \(status)", [
            "status": .int(status), "count": .int(payload?.tickets.count ?? 0), "ms": .int(ms),
            "cache": .string(cache), "offline": .bool(offline),
        ])
    }

    func requestCode(email raw: String) async {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isWorking = true
        defer { isWorking = false }
        do {
            try await APIClient.shared.requestTicketCode(email: address, for: .buyer)
            pendingEmail = address
            errorMessage = nil
            AppLog.info(.tickets, "tickets.mine.signin", "Code sent", ["step": "code_sent"])
        } catch {
            errorMessage = TicketErrorText.message(error)
            AppLog.notice(.tickets, "tickets.mine.signin", "Code request failed", ["step": "failed", "error": .string(TicketErrorText.kind(error))])
        }
    }

    func verify(code raw: String) async {
        guard let address = pendingEmail else { return }
        let code = raw.filter(\.isNumber)
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await APIClient.shared.verifyTicketCode(email: address, code: code, deviceName: ticketDeviceName, for: .buyer)
            let signIn = try JSONDecoder().decode(APIClient.BuyerSignIn.self, from: data)
            let signedInEmail = signIn.email ?? address
            KeychainHelper.save(key: TicketKeychain.buyerToken, value: signIn.buyerToken)
            KeychainHelper.save(key: TicketKeychain.buyerEmail, value: signedInEmail)
            if signedInEmail != email {
                payload = nil
                etag = nil
                await TicketFiles.shared.delete("mine.json")
            }
            email = signedInEmail
            pendingEmail = nil
            errorMessage = nil
            AppLog.info(.tickets, "tickets.mine.signin", "Signed in", ["step": "verified"])
            await refresh()
        } catch {
            errorMessage = TicketErrorText.message(error)
            AppLog.notice(.tickets, "tickets.mine.signin", "Verify failed", ["step": "failed", "error": .string(TicketErrorText.kind(error))])
        }
    }

    func cancelSignIn() {
        pendingEmail = nil
        errorMessage = nil
    }

    /// Revokes the token (best effort) and deletes the stored copy.
    func signOut() async {
        if let token = KeychainHelper.read(key: TicketKeychain.buyerToken) {
            Task.detached { try? await APIClient.shared.ticketSignOut(token: token, for: .buyer) }
        }
        await clearLocal()
    }

    private func clearLocal() async {
        KeychainHelper.delete(key: TicketKeychain.buyerToken)
        KeychainHelper.delete(key: TicketKeychain.buyerEmail)
        email = nil
        payload = nil
        etag = nil
        fetchedAt = nil
        isOffline = false
        await TicketFiles.shared.delete("mine.json")
    }
}

// MARK: - Door mode

@MainActor
@Observable
final class DoorController {
    private(set) var email: String?
    private(set) var events: [DoorEvent] = []
    private(set) var pendingEmail: String?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// The picked event's manifest and local state (nil until downloaded).
    private(set) var eventId: Int?
    private(set) var manifest: DoorManifest?
    private(set) var manifestDownloadedAt: Date?
    private(set) var state: DoorLocalState?
    private(set) var isDownloading = false
    private(set) var isSyncing = false

    /// Network path (NWPathMonitor), for "Offline · N waiting to sync".
    private(set) var isOnline = true

    /// The last scan's verdict (the full-screen result) and when it was made.
    private(set) var lastVerdict: DoorVerdict?
    private(set) var lastVerdictAt: Date?
    /// Scan out instead of in (re-entry types).
    var scanKind: DoorScanKind = .in

    private var manifestEtag: String?
    private var debounce = DoorScanDebounce()
    private var syncLoop: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private let deviceId: String

    init(deviceId: String) {
        self.deviceId = deviceId
        email = KeychainHelper.read(key: TicketKeychain.doorEmail)
        if let data = UserDefaults.standard.data(forKey: TicketDefaults.doorEvents),
           let saved = try? JSONDecoder().decode([DoorEvent].self, from: data) {
            events = saved
        }
        let saved = UserDefaults.standard.integer(forKey: TicketDefaults.doorEventId)
        eventId = saved == 0 ? nil : saved
    }

    var isSignedIn: Bool { email != nil && token != nil }
    private var token: String? { KeychainHelper.read(key: TicketKeychain.doorToken) }
    var event: DoorEvent? { manifest?.event ?? events.first { $0.id == eventId } }
    var timeZone: TimeZone { event?.timeZone ?? .current }
    var pendingCount: Int { state?.pending.count ?? 0 }
    var gate: String { state?.gate ?? "" }

    // MARK: Sign-in

    func requestCode(email raw: String) async {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isWorking = true
        defer { isWorking = false }
        do {
            try await APIClient.shared.requestTicketCode(email: address, for: .door)
            pendingEmail = address
            errorMessage = nil
            AppLog.info(.tickets, "tickets.door.signin", "Door code sent", ["step": "code_sent"])
        } catch {
            errorMessage = TicketErrorText.message(error)
            AppLog.notice(.tickets, "tickets.door.signin", "Door code request failed", ["step": "failed", "error": .string(TicketErrorText.kind(error))])
        }
    }

    func verify(code raw: String) async {
        guard let address = pendingEmail else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await APIClient.shared.verifyTicketCode(email: address, code: raw.filter(\.isNumber),
                                                                   deviceName: ticketDeviceName, for: .door)
            let signIn = try JSONDecoder().decode(DoorSignIn.self, from: data)
            KeychainHelper.save(key: TicketKeychain.doorToken, value: signIn.doorToken)
            KeychainHelper.save(key: TicketKeychain.doorEmail, value: signIn.email.isEmpty ? address : signIn.email)
            email = signIn.email.isEmpty ? address : signIn.email
            pendingEmail = nil
            errorMessage = nil
            setEvents(signIn.events)
            AppLog.info(.tickets, "tickets.door.signin", "Door mode signed in", ["step": "verified", "events": .int(signIn.events.count)])
        } catch {
            errorMessage = TicketErrorText.message(error)
            AppLog.notice(.tickets, "tickets.door.signin", "Door verify failed", ["step": "failed", "error": .string(TicketErrorText.kind(error))])
        }
    }

    func cancelSignIn() {
        pendingEmail = nil
        errorMessage = nil
    }

    func refreshEvents() async {
        guard let token else { return }
        do {
            setEvents(try await APIClient.shared.doorEvents(doorToken: token))
        } catch {
            handle(error, "door_events")
        }
    }

    private func setEvents(_ list: [DoorEvent]) {
        events = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: TicketDefaults.doorEvents) }
    }

    /// Signs out of door mode and deletes every manifest and scan log on this device.
    /// The UI confirms first while scans are waiting to sync.
    func signOut() async {
        stop()
        if let token {
            Task.detached { try? await APIClient.shared.ticketSignOut(token: token, for: .door) }
        }
        KeychainHelper.delete(key: TicketKeychain.doorToken)
        KeychainHelper.delete(key: TicketKeychain.doorEmail)
        UserDefaults.standard.removeObject(forKey: TicketDefaults.doorEvents)
        UserDefaults.standard.removeObject(forKey: TicketDefaults.doorEventId)
        email = nil
        events = []
        eventId = nil
        manifest = nil
        manifestEtag = nil
        manifestDownloadedAt = nil
        state = nil
        lastVerdict = nil
        await TicketFiles.shared.deleteDoorFiles()
    }

    // MARK: Event, manifest

    /// Picks the event and opens what is stored for it (works offline).
    func select(_ id: Int) async {
        guard id != eventId || manifest == nil else { return }
        eventId = id
        UserDefaults.standard.set(id, forKey: TicketDefaults.doorEventId)
        manifest = nil
        manifestEtag = nil
        manifestDownloadedAt = nil
        lastVerdict = nil
        await loadStored()
    }

    func loadStored() async {
        guard let id = eventId else { return }
        if let data = await TicketFiles.shared.read("door-\(id)-manifest.json"),
           let saved = try? JSONDecoder().decode(SavedDoorManifest.self, from: data),
           let decoded = try? JSONDecoder().decode(DoorManifest.self, from: saved.json), decoded.event.id == id {
            manifest = decoded
            manifestEtag = saved.etag
            manifestDownloadedAt = saved.downloadedAt
        }
        if let data = await TicketFiles.shared.read("door-\(id)-state.json"),
           let saved = try? JSONDecoder().decode(DoorLocalState.self, from: data), saved.eventId == id {
            state = saved
        } else {
            state = DoorLocalState(eventId: id)
        }
    }

    /// GET manifest/ (ETag); keeps the stored copy on failure.
    func downloadManifest() async {
        guard let id = eventId, let token, !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }
        let started = ContinuousClock.now
        do {
            let answer = try await APIClient.shared.doorManifest(eventId: id, doorToken: token,
                                                                 etag: manifest == nil ? nil : manifestEtag)
            let ms = (ContinuousClock.now - started).wholeMilliseconds
            switch answer {
            case .notModified:
                manifestDownloadedAt = .now
                AppLog.info(.tickets, "tickets.door.manifest", "Manifest unchanged", [
                    "event_id": .int(id), "tickets": .int(manifest?.tickets.count ?? 0), "status": 304, "ms": .int(ms), "cache": "304",
                ])
            case let .updated(decoded, etag, data):
                guard decoded.event.id == id else { return }
                manifest = decoded
                manifestEtag = etag
                manifestDownloadedAt = .now
                if var current = state { current.adopt(decoded); state = current }
                let saved = SavedDoorManifest(etag: etag, downloadedAt: .now, json: data)
                if let file = try? JSONEncoder().encode(saved) { await TicketFiles.shared.write(file, to: "door-\(id)-manifest.json") }
                await saveState()
                AppLog.info(.tickets, "tickets.door.manifest", "Manifest downloaded", [
                    "event_id": .int(id), "tickets": .int(decoded.tickets.count), "status": 200, "ms": .int(ms),
                    "bytes": .int(data.count), "cache": "none",
                ])
            }
            errorMessage = nil
        } catch {
            handle(error, "door_manifest")
        }
    }

    func setGate(_ name: String) {
        guard var current = state else { return }
        current.gate = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        state = current
        Task { await saveState() }
    }

    private func saveState() async {
        guard let state, let data = try? JSONEncoder().encode(state) else { return }
        await TicketFiles.shared.write(data, to: "door-\(state.eventId)-state.json")
    }

    // MARK: Scanning (offline)

    /// One QR from the camera. Returns the verdict, or nil when it was the same code again
    /// within a few seconds (the camera sees it many times).
    @discardableResult
    func scan(_ raw: String) -> DoorVerdict? {
        guard let manifest, var current = state else { return nil }
        let now = Date.now
        guard debounce.accept(raw, at: now) else { return nil }
        let started = ContinuousClock.now
        let verdict = DoorRules.evaluate(scanned: raw, manifest: manifest, state: current, kind: scanKind, now: now)
        if let scan = DoorRules.scan(for: verdict, gate: current.gate, at: now) {
            current.record(scan)
            state = current
            Task { await saveState() }
        }
        show(verdict, manual: false, started: started)
        return verdict
    }

    /// A manual check-in from search.
    @discardableResult
    func checkIn(ticketId: Int) -> DoorVerdict? {
        guard let manifest, var current = state else { return nil }
        let now = Date.now
        let started = ContinuousClock.now
        let verdict = DoorRules.evaluate(ticketId: ticketId, manifest: manifest, state: current, kind: scanKind, now: now)
        if let scan = DoorRules.scan(for: verdict, gate: current.gate, at: now, manual: true) {
            current.record(scan)
            state = current
            Task { await saveState() }
        }
        show(verdict, manual: true, started: started)
        return verdict
    }

    func dismissVerdict() { lastVerdict = nil }

    private func show(_ verdict: DoorVerdict, manual: Bool, started: ContinuousClock.Instant) {
        lastVerdict = verdict
        lastVerdictAt = .now
        AppLog.info(.tickets, "tickets.door.scan", "Scan: \(verdict.result.rawValue)", [
            "result": .string(verdict.result.rawValue), "offline": .bool(!isOnline), "kind": .string(verdict.kind.rawValue),
            "manual": .bool(manual), "ms": .int((ContinuousClock.now - started).wholeMilliseconds),
        ])
        if isOnline, verdict.isQueued {
            Task { await uploadPending() }
        }
    }

    func search(_ query: String) -> [DoorTicket] {
        guard let manifest else { return [] }
        return DoorSearch.find(query, in: manifest)
    }

    func typeName(_ ticket: DoorTicket) -> String { manifest?.type(ticket.typeId)?.name ?? "" }

    // MARK: Sync

    /// While the door screen is open: network monitor + a loop (upload ~15 s, revocations ~30 s,
    /// manifest ~5 min). Everything is skipped while offline; scanning never waits for it.
    func start() {
        guard syncLoop == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.arcu.attnd.door.path"))
        self.monitor = monitor
        syncLoop = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isOnline {
                    if tick % 20 == 0 { await self.downloadManifest() }
                    await self.uploadPending()
                    if tick % 2 == 0 { await self.pollRevocations() }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        syncLoop?.cancel()
        syncLoop = nil
        monitor?.cancel()
        monitor = nil
    }

    private func setOnline(_ online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { Task { await uploadPending(); await pollRevocations() } }
    }

    /// Uploads the queue in batches of ≤ 500, oldest first, until it is empty or a call fails.
    func uploadPending() async {
        guard let id = eventId, let token, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        while let current = state, current.eventId == id {
            let batch = DoorSync.nextBatch(current)
            guard !batch.isEmpty else { break }
            let started = ContinuousClock.now
            do {
                let body = try DoorSync.body(batch, deviceId: deviceId, gate: current.gate)
                let response = try await APIClient.shared.doorCheckins(eventId: id, body: body, doorToken: token)
                guard var latest = state, latest.eventId == id else { return }
                let outcome = DoorSync.merge(response, into: &latest, now: .now)
                state = latest
                await saveState()
                AppLog.info(.tickets, "tickets.door.sync", "Uploaded \(batch.count) check-ins", [
                    "sent": .int(batch.count), "status": 200, "flagged": .int(outcome.flagged),
                    "queued": .int(latest.pending.count), "ms": .int((ContinuousClock.now - started).wholeMilliseconds),
                ])
                if let cursor = response.revocationsCursor, cursor > latest.revocationsCursor { await pollRevocations() }
                // Nothing got a result (an old server, a malformed answer): try again next tick.
                if outcome.merged == 0 { break }
            } catch {
                AppLog.notice(.tickets, "tickets.door.sync", "Upload failed", [
                    "sent": .int(batch.count), "status": .int(0), "queued": .int(current.pending.count),
                    "ms": .int((ContinuousClock.now - started).wholeMilliseconds),
                ])
                handle(error, "door_sync")
                break
            }
        }
    }

    func pollRevocations() async {
        guard let id = eventId, let token, state != nil else { return }
        do {
            var more = true
            var pages = 0
            while more, pages < 10, let since = state?.revocationsCursor {
                let page = try await APIClient.shared.doorRevocations(eventId: id, since: since, doorToken: token)
                guard var latest = state, latest.eventId == id else { return }
                latest.apply(page)
                state = latest
                more = page.more
                pages += 1
                AppLog.debug(.tickets, "tickets.door.revocations", "Revocations", [
                    "count": .int(page.revocations.count), "cursor": .int(latest.revocationsCursor),
                ])
            }
            await saveState()
            if let counts = try? await APIClient.shared.doorCounts(eventId: id, doorToken: token), var latest = state {
                latest.counts = counts
                state = latest
            }
        } catch {
            handle(error, "door_revocations")
        }
    }

    private func handle(_ error: Error, _ context: String) {
        if let apiError = error as? APIError, case .ticketSignInExpired = apiError {
            errorMessage = TicketErrorText.message(error)
            KeychainHelper.delete(key: TicketKeychain.doorToken)
            email = nil
            stop()
        } else if TicketErrorText.isOffline(error) {
            // Offline: the stored manifest and queue carry on.
        } else {
            errorMessage = TicketErrorText.message(error)
        }
        AppLog.caught(error, .tickets, context, level: .notice)
    }
}
