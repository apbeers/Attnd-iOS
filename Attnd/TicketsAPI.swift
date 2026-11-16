// TicketsAPI.swift
// Attnd
//
// **App only.** The ticket endpoints (API-017, attnd-web API_V2.md → Tickets) on the shared
// `APIClient`: My tickets (`X-Attnd-Buyer`) and door mode (`X-Attnd-Door`). Every call also
// carries the app's normal Authorization (App Attest JWT / static key) through `send`.
// A 401 with `buyer_token_invalid` / `door_token_invalid` throws `.ticketSignInExpired`.

import Foundation

extension APIClient {

    /// Which email-code flow: My tickets (`tickets/…`) or door mode (`door/…`).
    enum TicketAudience: String, Sendable {
        case buyer = "tickets"
        case door = "door"

        var header: String { self == .buyer ? "X-Attnd-Buyer" : "X-Attnd-Door" }
    }

    struct BuyerSignIn: Decodable, Sendable {
        var buyerToken: String
        var email: String?
        private enum CodingKeys: String, CodingKey { case email; case buyerToken = "buyer_token" }
    }

    enum Conditional<Value: Sendable>: Sendable {
        /// `data` is the raw body, stored for offline use.
        case updated(Value, etag: String?, data: Data)
        case notModified
    }

    private struct EmailBody: Encodable, Sendable { var email: String }
    private struct VerifyBody: Encodable, Sendable {
        var email: String
        var code: String
        var deviceName: String
        enum CodingKeys: String, CodingKey { case email, code; case deviceName = "device_name" }
    }

    /// POST tickets/code/ or door/code/. The server answers the same for any valid address.
    func requestTicketCode(email: String, for audience: TicketAudience) async throws {
        let body = try JSONEncoder().encode(EmailBody(email: email))
        _ = try await send("\(audience.rawValue)/code/", method: "POST", body: body)
    }

    /// POST tickets/verify/ or door/verify/ → the raw body (`BuyerSignIn` / `DoorSignIn`).
    func verifyTicketCode(email: String, code: String, deviceName: String, for audience: TicketAudience) async throws -> Data {
        let body = try JSONEncoder().encode(VerifyBody(email: email, code: code, deviceName: deviceName))
        let (data, _) = try await send("\(audience.rawValue)/verify/", method: "POST", body: body)
        return data
    }

    /// POST tickets/signout/ or door/signout/ (revokes the token).
    func ticketSignOut(token: String, for audience: TicketAudience) async throws {
        _ = try await send("\(audience.rawValue)/signout/", method: "POST", body: Data("{}".utf8),
                           headers: [audience.header: token])
    }

    /// GET tickets/mine/ (ETag).
    func myTickets(buyerToken: String, etag: String?) async throws -> Conditional<MyTicketsPayload> {
        var headers = [TicketAudience.buyer.header: buyerToken]
        if let etag { headers["If-None-Match"] = etag }
        let (data, http) = try await send("tickets/mine/", headers: headers)
        if http.statusCode == 304 { return .notModified }
        return .updated(try decodeTickets(MyTicketsPayload.self, data), etag: http.value(forHTTPHeaderField: "ETag"), data: data)
    }

    /// GET door/events/
    func doorEvents(doorToken: String) async throws -> [DoorEvent] {
        let (data, _) = try await send("door/events/", headers: [TicketAudience.door.header: doorToken])
        return try decodeTickets(DoorEventList.self, data).events
    }

    /// GET door/events/<id>/manifest/ (ETag).
    func doorManifest(eventId: Int, doorToken: String, etag: String?) async throws -> Conditional<DoorManifest> {
        var headers = [TicketAudience.door.header: doorToken]
        if let etag { headers["If-None-Match"] = etag }
        let (data, http) = try await send("door/events/\(eventId)/manifest/", headers: headers)
        if http.statusCode == 304 { return .notModified }
        return .updated(try decodeTickets(DoorManifest.self, data), etag: http.value(forHTTPHeaderField: "ETag"), data: data)
    }

    /// GET door/events/<id>/revocations/?since=
    func doorRevocations(eventId: Int, since: Int, doorToken: String) async throws -> DoorRevocationsPage {
        let (data, _) = try await send("door/events/\(eventId)/revocations/?since=\(since)",
                                       headers: [TicketAudience.door.header: doorToken])
        return try decodeTickets(DoorRevocationsPage.self, data)
    }

    /// POST door/events/<id>/checkins/ (`DoorSync.body`, ≤ 500, idempotent by client_id).
    func doorCheckins(eventId: Int, body: Data, doorToken: String) async throws -> DoorCheckinResponse {
        let (data, _) = try await send("door/events/\(eventId)/checkins/", method: "POST", body: body,
                                       headers: [TicketAudience.door.header: doorToken])
        return try decodeTickets(DoorCheckinResponse.self, data)
    }

    /// GET door/events/<id>/counts/
    func doorCounts(eventId: Int, doorToken: String) async throws -> DoorCounts {
        let (data, _) = try await send("door/events/\(eventId)/counts/", headers: [TicketAudience.door.header: doorToken])
        guard let counts = DoorCounts.decodeWire(data) else { throw APIError.decodingError("counts") }
        return counts
    }

    private func decodeTickets<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLog.caught(error, .tickets, "decode_\(T.self)", level: .error, ["bytes": .int(data.count)])
            throw APIError.decodingError(error.localizedDescription)
        }
    }
}

/// `door/events/` → `{"email", "events": [...]}`.
struct DoorEventList: Decodable, Sendable {
    var events: [DoorEvent] = []
    private enum CodingKeys: String, CodingKey { case events }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.lossyArray(DoorEvent.self, .events)
    }
}

/// What a ticket API error means for the person (no server text shown).
enum TicketErrorText {
    static func message(_ error: Error) -> String {
        guard let error = error as? APIError else { return "Something went wrong. Try again." }
        switch error {
        case .badRequest(let code) where code == "invalid_code":  return "That code isn’t right, or it expired. Check the email or ask for a new code."
        case .badRequest(let code) where code == "invalid_email": return "Enter a valid email address."
        case .serverError(429):     return "Too many tries. Wait a few minutes and try again."
        case .serverError(403):     return "This address can’t be used here."
        case .networkError:         return "You’re offline. Try again when you have a connection."
        case .ticketSignInExpired:  return "Your sign-in expired. Sign in again."
        case .notFound:             return "Not available any more."
        default:                    return error.localizedDescription
        }
    }

    static func isOffline(_ error: Error) -> Bool {
        if let error = error as? APIError, case .networkError = error { return true }
        return false
    }

    /// `error` field for `tickets.*.signin` / failures (no server text).
    static func kind(_ error: Error) -> String {
        guard let error = error as? APIError else { return "other" }
        switch error {
        case .badRequest(let code): return code == "invalid_code" || code == "invalid_email" ? code : "bad_request"
        case .serverError(429):     return "rate_limited"
        default:                    return error.logKind
        }
    }
}
