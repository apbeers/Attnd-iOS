// TicketsTests.swift
// AttndTests
//
// API-017 tickets: Get tickets, My tickets decoding / offline copy, QR tokens (a fixed key and
// tokens made with the server's exact format, attnd-web tickets/signing.py, plus keys generated
// here), the offline door rules, manual search, the upload queue and merging the server's results.

import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import Attnd

final class TicketsTests: XCTestCase {

    // MARK: Fixture

    /// Ed25519 key from the seed bytes 1…32 (kid 1) and 101…132 (kid 2), tokens signed by
    /// Python `cryptography` exactly like `tickets.signing.token_for`.
    static let publicKey1 = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
    static let publicKey2 = "2inpWwLgD_oVZFd1-x0roiKhlDOV7qBrlOLAV7e-adA"
    /// e=12 k=1 n=1 t=345 y=7
    static let token345 = "ATK1.eyJlIjoxMiwiayI6MSwibiI6MSwidCI6MzQ1LCJ5Ijo3fQ.z_rId2CMw2jg11CK6Z8he1_VnqxgemIOghGkNJ5cq_nHEo1KEtroMur7zNs5xMoGtLnX6O8wpllAKVeO1Zc7AA"
    /// e=12 k=1 n=1 t=346 y=7 (the manifest has version 2: reissued)
    static let token346 = "ATK1.eyJlIjoxMiwiayI6MSwibiI6MSwidCI6MzQ2LCJ5Ijo3fQ.cP0JfErDr0bUVZJT6SKrkiYQY8tmvuLbJynY1oq5PUUJANdOFekV1gnTcs3MQorfTfY08oaRCQoc9KNGCt6RDA"
    /// e=12 k=1 n=1 t=347 y=8 (re-entry type)
    static let token347 = "ATK1.eyJlIjoxMiwiayI6MSwibiI6MSwidCI6MzQ3LCJ5Ijo4fQ.UQn2a5jQ7lIfAv4Jne2KR2YPYaT_iTqkAHu7s6J1poSykyoc4LQSQhdIUz_Wfbx5tLeMtVbELN3TE0Oz8xCrBw"
    /// e=12 k=1 n=1 t=348 y=9 (a day ticket for Sunday)
    static let token348 = "ATK1.eyJlIjoxMiwiayI6MSwibiI6MSwidCI6MzQ4LCJ5Ijo5fQ.QTXb4FI6FsqB4nZapCabyPL4kZ5VFCnKI3ebzupgmxr-UedPZTBP_LCtRzSYpxrPRs2OLs0FGnFNyMj5sXPXCA"
    /// e=12 k=1 n=1 t=900 y=7 (bought after the manifest was downloaded)
    static let token900 = "ATK1.eyJlIjoxMiwiayI6MSwibiI6MSwidCI6OTAwLCJ5Ijo3fQ.rIo0iyU5EhTVBA-D1JrVbF7gg7rhr9AhIXWD8X-fWpgv_OI2PdQsKpWyrLBxh9_FpUb3QUk__-LlTw4Ig8j3Ag"
    /// e=13 (another event), signed with key 1
    static let tokenOtherEvent = "ATK1.eyJlIjoxMywiayI6MSwibiI6MSwidCI6MzQ1LCJ5Ijo3fQ.0eGh9vfDe127IB33Hkd0n6utdnT_WzXwt0hgJQuXea_RpkFMjZNHMO9BRvH5L5l5bqhZlMG8oTOu_ZlHTBC6CQ"
    /// k=2: a key the manifest doesn't have
    static let tokenKey2 = "ATK1.eyJlIjoxMiwiayI6MiwibiI6MSwidCI6MzQ1LCJ5Ijo3fQ.ViJsdkxRhzLbJ4pTC36uSOCEUX-4fvUo3Gy7PTrnhILNjD8SpGJxGzErKq7GWYi8_GL17B0BcjIf6PFAa_XuDg"

    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let locale = Locale(identifier: "en_US_POSIX")
    /// Sat Nov 21 2026, 7:50 PM in Chicago.
    static let now = ISODate.parse("2026-11-22T01:50:00Z")!

    static let manifestJSON = """
    {"schema": 1, "generated_at": "2026-11-22T01:00:00+00:00", "future_key": {"x": 1},
     "event": {"id": 12, "name": "Fall Fair", "event_code": "FWFM2026", "timezone": "America/Chicago",
               "start_time": "2026-11-21T23:00:00+00:00", "end_time": null},
     "keys": [{"kid": 1, "alg": "Ed25519", "public_key": "\(publicKey1)", "active": true}, {"kid": "bad"}],
     "ticket_types": [{"id": 7, "name": "General Admission", "reentry": false, "add_on": false, "valid_on": null},
                      {"id": 8, "name": "Parking", "reentry": true, "add_on": true, "valid_on": null},
                      {"id": 9, "name": "Sunday pass", "reentry": false, "add_on": false, "valid_on": "2026-11-22"}],
     "tickets": [
       {"id": 345, "code": "K7Q29XPM", "type_id": 7, "status": "valid", "version": 1, "name": "Bea Buyer",
        "email_hash": "8c0c75e826287f077c72f4002aee3fab958a7988127030a8f2d52dc6720b31b1", "order_ref": "A7K2Q9",
        "checked_in_at": "2026-11-22T01:42:00+00:00", "checked_in_gate": "Gate B", "inside": true},
       {"id": 346, "code": "M3X8PQ2Z", "type_id": 7, "status": "valid", "version": 2, "name": "Cal Ortiz",
        "email_hash": "00", "order_ref": "B8R4T1", "checked_in_at": null, "checked_in_gate": null, "inside": false},
       {"id": 347, "code": "P4RK1NG7", "type_id": 8, "status": "valid", "version": 1, "name": "Dee Driver",
        "email_hash": "01", "order_ref": "C2D2E2", "checked_in_at": "2026-11-22T00:10:00+00:00",
        "checked_in_gate": "Lot", "inside": false},
       {"id": 348, "code": "SUNDAY01", "type_id": 9, "status": "valid", "version": 1, "name": "Émile Zola",
        "email_hash": "02", "order_ref": "D3", "checked_in_at": null, "checked_in_gate": null, "inside": false},
       {"id": 349, "code": "REFUND01", "type_id": 7, "status": "refunded", "version": 2, "name": "Rae Fund",
        "email_hash": "03", "order_ref": "E4", "checked_in_at": null, "checked_in_gate": null, "inside": false},
       {"id": "broken"}],
     "revocations_cursor": 88, "gates": ["Gate A", "Gate B"]}
    """

    private var manifest: DoorManifest { try! JSONDecoder().decode(DoorManifest.self, from: Data(Self.manifestJSON.utf8)) }

    private func verdict(_ token: String, _ state: DoorLocalState? = nil, kind: DoorScanKind = .in, now: Date = TicketsTests.now) -> DoorVerdict {
        DoorRules.evaluate(scanned: token, manifest: manifest, state: state ?? DoorLocalState(eventId: 12), kind: kind, now: now)
    }

    // MARK: Tokens

    func testParsesAndVerifiesServerToken() throws {
        let token = try XCTUnwrap(TicketToken.parse(Self.token345))
        XCTAssertEqual([token.eventId, token.keyId, token.version, token.ticketId], [12, 1, 1, 345])
        XCTAssertEqual(token.typeId, 7)
        XCTAssertEqual(token.signature.count, 64)
        let keys = [1: try XCTUnwrap(Base64URL.decode(Substring(Self.publicKey1)))]
        XCTAssertTrue(token.isSigned(by: keys))
        XCTAssertFalse(TicketToken.parse(Self.tokenKey2)!.isSigned(by: keys), "key 2 isn't in the manifest")
        XCTAssertTrue(TicketToken.parse(Self.tokenKey2)!.isSigned(by: [2: Base64URL.decode(Substring(Self.publicKey2))!]))
    }

    func testTamperedTokensFail() throws {
        let keys = [1: Base64URL.decode(Substring(Self.publicKey1))!]
        // Another ticket id in the payload, same signature.
        let parts = Self.token345.split(separator: ".")
        let forged = "ATK1.\(Base64URL.encode(Data(#"{"e":12,"k":1,"n":1,"t":999,"y":7}"#.utf8))).\(parts[2])"
        XCTAssertFalse(try XCTUnwrap(TicketToken.parse(forged)).isSigned(by: keys))
        var flipped = Array(Self.token345)
        flipped[flipped.count - 3] = flipped[flipped.count - 3] == "A" ? "B" : "A"
        XCTAssertFalse(TicketToken.parse(String(flipped))?.isSigned(by: keys) ?? false)
        for junk in ["", "hello", "ATK2.e30.AA", "ATK1.e30.AA", "ATK1.!!.AA", "https://attnd.app/join/DEMO/", "ATK1.a.b.c"] {
            XCTAssertNil(TicketToken.parse(junk), junk)
        }
    }

    func testTokensSignedHereVerify() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = Base64URL.encode(Data(#"{"e":5,"k":3,"n":2,"t":77,"y":1}"#.utf8))
        let message = "ATK1.\(body)"
        let signature = try key.signature(for: Data(message.utf8))
        let raw = "\(message).\(Base64URL.encode(signature))"
        let token = try XCTUnwrap(TicketToken.parse(raw))
        XCTAssertEqual(token.version, 2)
        XCTAssertTrue(token.isSigned(by: [3: key.publicKey.rawRepresentation]))
        XCTAssertFalse(token.isSigned(by: [3: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation]))
        XCTAssertFalse(TicketCrypto.isValidSignature(signature, of: Data(message.utf8), publicKey: Data([1, 2, 3])))
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(Base64URL.decode(""))
    }

    // MARK: Door rules (API_V2.md "Scanning offline")

    func testManifestDecodesLeniently() {
        let m = manifest
        XCTAssertEqual(m.event.id, 12)
        XCTAssertEqual(m.event.timeZoneIdentifier, "America/Chicago")
        XCTAssertEqual(Array(m.keys.keys), [1])
        XCTAssertEqual(m.tickets.map(\.id), [345, 346, 347, 348, 349], "a broken row is skipped")
        XCTAssertEqual(m.ticketTypes.map(\.reentry), [false, true, false])
        XCTAssertEqual(m.revocationsCursor, 88)
        XCTAssertEqual(m.gates, ["Gate A", "Gate B"])
    }

    func testAlreadyCheckedInFromManifest() {
        let v = verdict(Self.token345)
        XCTAssertEqual(v.result, .duplicate)
        XCTAssertEqual(v.tone, .amber)
        XCTAssertEqual(DoorText.title(v, timeZone: Self.chicago, now: Self.now, locale: Self.locale),
                       "Already checked in 7:42 PM at Gate B")
        XCTAssertEqual(DoorText.detail(v), "Bea Buyer · General Admission")
        XCTAssertEqual(DoorText.alreadyIn(ISODate.parse("2026-11-21T01:42:00Z"), gate: nil, timeZone: Self.chicago,
                                          now: Self.now, locale: Self.locale), "Already checked in Nov 20, 7:42 PM")
    }

    func testNewTicketAdmittedThenDuplicateFromLocalQueue() throws {
        var state = DoorLocalState(eventId: 12)
        let first = verdict(Self.token900, state)
        XCTAssertEqual(first.result, .ok, "valid signature, bought after the download")
        XCTAssertEqual(DoorText.title(first, timeZone: Self.chicago, now: Self.now), "Admitted")
        XCTAssertEqual(first.typeName, "General Admission", "type from the token's y")
        let scan = try XCTUnwrap(DoorRules.scan(for: first, gate: "Gate A", at: Self.now, clientId: "c1"))
        XCTAssertEqual(scan.token, Self.token900)
        XCTAssertEqual(scan.ticketId, 900)
        state.record(scan)
        let again = verdict(Self.token900, state, now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(again.result, .duplicate)
        XCTAssertEqual(DoorText.title(again, timeZone: Self.chicago, now: Self.now, locale: Self.locale),
                       "Already checked in 7:50 PM at Gate A")
    }

    func testRedResults() {
        XCTAssertEqual(verdict(Self.tokenOtherEvent).result, .invalid)
        XCTAssertEqual(verdict(Self.tokenKey2).result, .invalid)
        XCTAssertEqual(verdict(Self.token346).result, .revoked, "n 1 < manifest version 2")
        XCTAssertEqual(DoorText.title(verdict(Self.token346), timeZone: Self.chicago, now: Self.now), "Old QR code")
        let unreadable = verdict("WIFI:S:venue;;")
        XCTAssertEqual(unreadable.result, .unreadable)
        XCTAssertNil(DoorRules.scan(for: unreadable, gate: "A", at: Self.now), "unreadable codes aren't queued")
        XCTAssertNotNil(DoorRules.scan(for: verdict(Self.tokenOtherEvent), gate: "A", at: Self.now), "parsed tokens are")
        let wrongDay = verdict(Self.token348)
        XCTAssertEqual(wrongDay.result, .wrongDay)
        XCTAssertEqual(DoorText.title(wrongDay, timeZone: Self.chicago, now: Self.now), "Not valid today")
        XCTAssertEqual(verdict(Self.token348, now: ISODate.parse("2026-11-22T16:00:00Z")!).result, .ok, "Sunday in Chicago")
        // Refunded in the manifest (status before version, like the server).
        let refunded = DoorRules.evaluate(ticketId: 349, manifest: manifest, state: DoorLocalState(eventId: 12), now: Self.now)
        XCTAssertEqual(refunded.result, .void)
        XCTAssertEqual(DoorText.title(refunded, timeZone: Self.chicago, now: Self.now), "Refunded / void")
    }

    func testRevocationsPolledAfterTheDownload() {
        var state = DoorLocalState(eventId: 12)
        state.adopt(manifest)
        XCTAssertEqual(state.revocationsCursor, 88)
        state.apply(DoorRevocationsPage(revocations: [DoorRevocation(cursor: 89, ticketId: 900, version: 1, reason: "transfer")],
                                        cursor: 89, more: false))
        XCTAssertEqual(verdict(Self.token900, state).result, .revoked)
        // A lower version later doesn't undo it; a refund reads as void.
        state.apply(DoorRevocationsPage(revocations: [DoorRevocation(cursor: 90, ticketId: 900, version: 0, reason: "refund"),
                                                      DoorRevocation(cursor: 91, ticketId: 345, version: 1, reason: "refund")],
                                        cursor: 91, more: false))
        XCTAssertEqual(state.revocations[900]?.version, 1)
        XCTAssertEqual(state.revocationsCursor, 91)
        XCTAssertEqual(verdict(Self.token345, state).result, .void)
    }

    func testReentry() throws {
        // Parking (re-entry): checked in at 6:10 PM, outside now → admitted again.
        var state = DoorLocalState(eventId: 12)
        let back = verdict(Self.token347, state)
        XCTAssertEqual(back.result, .ok)
        state.record(try XCTUnwrap(DoorRules.scan(for: back, gate: "Lot", at: Self.now)))
        // Inside now → amber, first admission from the manifest.
        let inside = verdict(Self.token347, state, now: Self.now.addingTimeInterval(30))
        XCTAssertEqual(inside.result, .duplicate)
        XCTAssertEqual(DoorText.title(inside, timeZone: Self.chicago, now: Self.now, locale: Self.locale),
                       "Already checked in 6:10 PM at Lot")
        // Scan out, then in again.
        let out = verdict(Self.token347, state, kind: .out, now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(out.result, .ok)
        XCTAssertEqual(DoorText.title(out, timeZone: Self.chicago, now: Self.now), "Checked out")
        state.record(try XCTUnwrap(DoorRules.scan(for: out, gate: "Lot", at: Self.now.addingTimeInterval(60))))
        XCTAssertEqual(verdict(Self.token347, state, now: Self.now.addingTimeInterval(90)).result, .ok)
        // Without re-entry, out and back in is still a duplicate.
        XCTAssertEqual(verdict(Self.token345, state).result, .duplicate)
    }

    func testServerResultOverridesLocal() throws {
        var state = DoorLocalState(eventId: 12)
        let v = verdict(Self.token900, state)
        var scan = try XCTUnwrap(DoorRules.scan(for: v, gate: "Gate A", at: Self.now, clientId: "c1"))
        scan.server = DoorServerResult(result: .duplicate, flagged: true)
        state.record(scan)
        XCTAssertEqual(verdict(Self.token900, state).result, .ok, "the server said that scan wasn't an admission")
        XCTAssertEqual(state.flagged.map(\.clientId), ["c1"])
    }

    func testDebounce() {
        var d = DoorScanDebounce(interval: 3)
        XCTAssertTrue(d.accept("a", at: Self.now))
        XCTAssertFalse(d.accept("a", at: Self.now.addingTimeInterval(2)))
        XCTAssertTrue(d.accept("b", at: Self.now.addingTimeInterval(2)))
        XCTAssertTrue(d.accept("a", at: Self.now.addingTimeInterval(2.5)))
    }

    // MARK: Manual search

    func testManualSearch() {
        let m = manifest
        XCTAssertEqual(DoorSearch.find("bea", in: m).map(\.id), [345])
        XCTAssertEqual(DoorSearch.find("BUYER bea", in: m).map(\.id), [345])
        XCTAssertEqual(DoorSearch.find("emile", in: m).map(\.id), [348], "accents folded")
        XCTAssertEqual(DoorSearch.find("k7q2-9xpm", in: m).map(\.id), [345], "display code with a dash")
        XCTAssertEqual(DoorSearch.find("b8r4", in: m).map(\.id), [346], "order ref")
        XCTAssertEqual(DoorSearch.find(" Bea@Example.com ", in: m).map(\.id), [345], "email via the server's hash")
        XCTAssertEqual(DoorSearch.emailHash(eventId: 12, email: "bea@example.com"),
                       "8c0c75e826287f077c72f4002aee3fab958a7988127030a8f2d52dc6720b31b1")
        XCTAssertEqual(DoorSearch.find("nobody@example.com", in: m), [])
        XCTAssertEqual(DoorSearch.find("  ", in: m), [])
        XCTAssertEqual(DoorSearch.compact("K7Q2-9XPM"), "K7Q29XPM")
        let manual = DoorRules.evaluate(ticketId: 346, manifest: m, state: DoorLocalState(eventId: 12), now: Self.now)
        XCTAssertEqual(manual.result, .ok, "manual check-in has no token version")
        let scan = DoorRules.scan(for: manual, gate: "Gate A", at: Self.now, manual: true)
        XCTAssertNil(scan?.token)
        XCTAssertEqual(scan?.ticketId, 346)
    }

    // MARK: Queue, upload body, merge

    func testBatchBodyAndMerge() throws {
        var state = DoorLocalState(eventId: 12)
        for i in 0..<3 {
            state.record(DoorScan(clientId: "c\(i)", token: i == 1 ? nil : Self.token900, ticketId: 900,
                                  at: Self.now.addingTimeInterval(Double(10 - i)), kind: .in, gate: "Gate A",
                                  deviceResult: i == 0 ? .ok : .duplicate, manual: i == 1))
        }
        XCTAssertEqual(DoorSync.nextBatch(state).map(\.clientId), ["c2", "c1", "c0"], "oldest first")
        XCTAssertEqual(DoorSync.nextBatch(state, limit: 2).count, 2)

        let body = try DoorSync.body(DoorSync.nextBatch(state, limit: 2), deviceId: "dev-1", gate: "Gate A")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, "dev-1")
        let rows = try XCTUnwrap(json["checkins"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["client_id"] as? String, "c2")
        XCTAssertEqual(rows[0]["token"] as? String, Self.token900)
        XCTAssertNil(rows[0]["ticket_id"], "the token carries the ticket")
        XCTAssertEqual(rows[0]["at"] as? String, "2026-11-22T01:50:08Z")
        XCTAssertEqual(rows[0]["kind"] as? String, "in")
        XCTAssertEqual(rows[0]["device_result"] as? String, "duplicate")
        XCTAssertEqual(rows[1]["ticket_id"] as? Int, 900, "manual check-in")
        XCTAssertNil(rows[1]["token"])

        let response = try JSONDecoder().decode(DoorCheckinResponse.self, from: Data("""
        {"results": [{"client_id": "c0", "result": "ok", "ticket_id": 900, "flagged": false, "at": "…"},
                     {"client_id": "c2", "result": "duplicate", "flagged": true, "first_at": "2026-11-22T01:42:00+00:00", "first_gate": "Gate B"},
                     {"client_id": "zz", "result": "ok"}, {"client_id": null, "result": "rejected"},
                     {"client_id": "c1", "result": "something_new"}],
         "counts": {"total": 412, "checked_in": 180, "inside": 175, "flagged": 2,
                    "by_type": [{"type_id": 7, "name": "GA", "total": 400, "checked_in": 170}],
                    "by_gate": [{"gate": "Gate B", "checked_in": 90}], "updated_at": "2026-11-22T01:51:00+00:00"},
         "revocations_cursor": 89}
        """.utf8))
        XCTAssertEqual(response.revocationsCursor, 89)
        let outcome = DoorSync.merge(response, into: &state, now: Self.now)
        XCTAssertEqual(outcome.merged, 3)
        XCTAssertEqual(outcome.flagged, 1)
        XCTAssertTrue(state.pending.isEmpty)
        XCTAssertEqual(state.scans.first { $0.clientId == "c1" }?.effectiveResult, .rejected)
        XCTAssertEqual(state.counts?.checkedIn, 180)
        XCTAssertEqual(state.counts?.byGate.first?.gate, "Gate B")
        XCTAssertEqual(state.lastSyncAt, Self.now)
        let flagged = try XCTUnwrap(state.flagged.first)
        XCTAssertEqual(DoorText.flagged(flagged, timeZone: Self.chicago, locale: Self.locale), "Duplicate · first 7:42 PM at Gate B")
        XCTAssertEqual(state.localAdmissionsByGate().map(\.count), [1])
    }

    func testLocalStateRoundTripsOnDisk() throws {
        var state = DoorLocalState(eventId: 12)
        state.gate = "Gate A"
        state.apply(DoorRevocationsPage(revocations: [DoorRevocation(cursor: 5, ticketId: 1, version: 2, reason: "void")], cursor: 5))
        state.record(DoorScan(clientId: "x", token: nil, ticketId: 1, at: Self.now, kind: .out, gate: "Gate A", deviceResult: .ok))
        state.counts = DoorCounts(total: 3, checkedIn: 1)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(DoorLocalState.self, from: data), state)
        // An older file without new keys still opens.
        let old = try JSONDecoder().decode(DoorLocalState.self, from: Data(#"{"eventId": 4}"#.utf8))
        XCTAssertEqual(old.eventId, 4)
        XCTAssertTrue(old.scans.isEmpty)
    }

    func testSyncLine() {
        XCTAssertEqual(DoorText.syncLine(pending: 3, online: false, lastSync: nil), "Offline · 3 waiting to sync")
        XCTAssertEqual(DoorText.syncLine(pending: 0, online: false, lastSync: nil), "Offline · all scans synced")
        XCTAssertEqual(DoorText.syncLine(pending: 2, online: true, lastSync: nil), "2 waiting to sync")
        XCTAssertEqual(DoorText.syncLine(pending: 0, online: true, lastSync: Self.now, timeZone: Self.chicago, locale: Self.locale),
                       "All synced · 7:50 PM")
    }

    // MARK: Get tickets

    func testBundleTicketsDecoding() throws {
        let json = """
        {"event": {"id": 3, "name": "Fair", "tickets_url": "https://attnd.app/t/FAIR/"},
         "tickets": {"on_sale": true, "state": "open", "sold_out": false, "url": "https://attnd.app/t/FAIR/",
                     "min_price_cents": 0, "max_price_cents": 7808, "currency": "usd", "price_text": "From $26.06",
                     "prices_include_fees": true, "new_key": 1}}
        """
        let bundle = try JSONDecoder().decode(EventBundle.self, from: Data(json.utf8))
        XCTAssertEqual(bundle.event.ticketsUrl?.absoluteString, "https://attnd.app/t/FAIR/")
        let sales = try XCTUnwrap(bundle.tickets)
        XCTAssertEqual(sales.state, .open)
        XCTAssertEqual(sales.maxPriceCents, 7808)
        XCTAssertEqual(TicketSalesAction.of(sales, eventURL: bundle.event.ticketsUrl),
                       .buy(URL(string: "https://attnd.app/t/FAIR/")!, detail: "From $26.06"))

        let none = try JSONDecoder().decode(EventBundle.self, from: Data(#"{"event": {"id": 3, "tickets_url": "http://x"}, "tickets": null}"#.utf8))
        XCTAssertNil(none.tickets)
        XCTAssertNil(none.event.ticketsUrl, "only https")
        let odd = try JSONDecoder().decode(EventBundle.self, from: Data(#"{"event": {"id": 3}, "tickets": {"on_sale": "yes", "state": 4}}"#.utf8))
        XCTAssertEqual(odd.tickets?.onSale, false)
        XCTAssertNil(odd.tickets?.stateRaw)
    }

    func testSalesStates() {
        let url = URL(string: "https://attnd.app/t/FAIR/")!
        func action(_ state: String?, onSale: Bool = false, soldOut: Bool = false) -> TicketSalesAction {
            TicketSalesAction.of(TicketSales(onSale: onSale, stateRaw: state, soldOut: soldOut, url: url, priceText: "$25.00"), eventURL: nil)
        }
        XCTAssertEqual(action("open", onSale: true), .buy(url, detail: "$25.00"))
        XCTAssertEqual(action(nil, onSale: true), .buy(url, detail: "$25.00"))
        XCTAssertEqual(action("sold_out", soldOut: true), .status("Sold out", url: url))
        XCTAssertEqual(action("paused"), .status("Tickets aren’t on sale yet", url: url))
        XCTAssertEqual(action("cancelled"), .status("Event cancelled", url: nil))
        XCTAssertEqual(action("ended"), .status("Ticket sales have ended", url: nil))
        XCTAssertEqual(action("closed"), .status("Ticket sales have closed", url: nil))
        XCTAssertEqual(action("off"), .none)
        XCTAssertEqual(action("raffle", onSale: true), .none, "an unknown state never shows a buy button")
        XCTAssertEqual(TicketSalesAction.of(nil, eventURL: url), .buy(url, detail: nil))
        XCTAssertEqual(TicketSalesAction.of(nil, eventURL: nil), .none)
    }

    // MARK: My tickets

    static let mineJSON = """
    {"email": "bea@example.com", "tickets": [
      {"id": 345, "code": "K7Q2-9XPM", "status": "valid", "version": 1, "qr": "\(token345)",
       "type": {"id": 7, "name": "General Admission"}, "holder_name": "Bea Buyer", "order_ref": "A7K2Q9",
       "checked_in_at": "2026-11-22T01:42:00+00:00", "transferable": false,
       "ticket_url": "https://attnd.app/tickets/ticket/u/k/", "apple_wallet_url": "https://attnd.app/tickets/ticket/u/k/wallet.pkpass",
       "google_wallet_url": null,
       "event": {"id": 12, "name": "Fall Fair", "event_code": "FWFM2026", "timezone": "America/Chicago",
                 "start_time": "2026-11-21T23:00:00+00:00", "end_time": null, "address": "1 Main St",
                 "latitude": 32.75, "longitude": null, "cancelled": false}},
      {"id": 360, "code": "OLD1-2345", "status": "refunded", "version": 2, "qr": null, "type": {"id": 1, "name": "GA"},
       "holder_name": "Bea Buyer", "order_ref": "Z1", "checked_in_at": null, "transferable": false,
       "ticket_url": "https://attnd.app/tickets/ticket/v/k/", "apple_wallet_url": null, "google_wallet_url": null,
       "event": {"id": 2, "name": "Last Year", "timezone": "America/Chicago", "start_time": "2025-11-21T23:00:00+00:00",
                 "end_time": "2025-11-22T05:00:00+00:00", "cancelled": false}},
      {"id": "nope"},
      {"id": 361, "status": "valid", "qr": "ATK1.x.y", "type": {"id": 9}, "event": {"id": 20, "name": "Spring",
       "start_time": "2027-04-01T23:00:00+00:00", "cancelled": true}}]}
    """

    func testMyTicketsDecodingTextsAndGrouping() throws {
        let payload = try JSONDecoder().decode(MyTicketsPayload.self, from: Data(Self.mineJSON.utf8))
        XCTAssertEqual(payload.tickets.map(\.id), [345, 360, 361])
        let bea = payload.tickets[0]
        XCTAssertEqual(bea.qr, Self.token345)
        XCTAssertEqual(bea.typeName, "General Admission")
        XCTAssertNotNil(bea.appleWalletURL)
        XCTAssertNil(bea.googleWalletURL)
        XCTAssertNil(bea.event.longitude)
        XCTAssertEqual(MyTicketsText.status(bea, locale: Self.locale), "Checked in 7:42 PM")
        XCTAssertEqual(MyTicketsText.status(payload.tickets[1]), "Refunded")
        XCTAssertNil(payload.tickets[1].qr)
        XCTAssertEqual(MyTicketsText.status(payload.tickets[2]), "Event cancelled")
        XCTAssertEqual(MyTicketsText.eventDate(bea.event, locale: Self.locale), "Sat, Nov 21 · 5:00 PM")

        let sections = MyTicketsGrouping.sections(payload.tickets, now: Self.now)
        XCTAssertEqual(sections.map(\.event.id), [12, 20, 2], "upcoming by start, then past")
        XCTAssertEqual(sections.map(\.isPast), [false, false, true])
    }

    func testSavedMyTicketsRoundTrip() throws {
        let saved = SavedMyTickets(email: "bea@example.com", etag: "\"abc\"", fetchedAt: Self.now, json: Data(Self.mineJSON.utf8))
        let restored = try SavedMyTickets.decode(SavedMyTickets.encode(saved))
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.decoded()?.tickets.count, 3)
        var future = saved
        future.format = 99
        XCTAssertNil(future.decoded(), "an unknown format is ignored, not misread")
    }
}
