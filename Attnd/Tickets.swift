// Tickets.swift
// Attnd
//
// Pure, unit-tested ticket logic (API-017, attnd-web API_V2.md → Tickets; `TicketsTests`, also
// run in the Linux harness): "Get tickets" (`TicketSalesAction`), My tickets (`MyTicket`,
// `SavedMyTickets`, `MyTicketsText`, `MyTicketsGrouping`), QR tokens (`TicketToken`:
// `ATK1.<payload>.<signature>`, Ed25519 via `TicketCrypto`) and door mode: the manifest
// (`DoorManifest`), the offline scanning rules (`DoorRules`, API_V2.md "Scanning offline"),
// manual search (`DoorSearch`), the local scan log + upload queue and merging the server's
// results (`DoorLocalState`, `DoorSync`), texts (`DoorText`).
//
// Nothing here logs; callers never log emails, names, codes, tokens or QR strings.

import Foundation

// MARK: - Get tickets

/// What the event's ticket row shows. Tickets are only ever bought on the website.
enum TicketSalesAction: Hashable, Sendable {
    /// "Get Tickets" → `url` in Safari; `detail` = the all-in `price_text` ("From $26.06").
    case buy(URL, detail: String?)
    /// Not on sale: the state ("Sold out"); `url` when the page still helps (waitlist, opening).
    case status(String, url: URL?)
    case none

    /// `sales` = `bundle.tickets`, `eventURL` = `event.tickets_url`. An unknown `state` never
    /// shows a buy button (a newer server's state this build can't explain).
    static func of(_ sales: TicketSales?, eventURL: URL?) -> TicketSalesAction {
        guard let sales else {
            // Event objects outside the bundle carry only the link.
            return eventURL.map { .buy($0, detail: nil) } ?? .none
        }
        let url = sales.url ?? eventURL
        guard let raw = sales.stateRaw else {
            if sales.onSale, let url { return .buy(url, detail: sales.priceText) }
            return .none
        }
        guard let state = TicketSales.State(rawValue: raw) else { return .none }
        switch state {
        case .open:
            if sales.onSale, let url { return .buy(url, detail: sales.priceText) }
            return sales.soldOut ? .status("Sold out", url: url) : .none
        case .soldOut:   return .status("Sold out", url: url)
        case .paused:    return .status("Tickets aren’t on sale yet", url: url)
        case .cancelled: return .status("Event cancelled", url: nil)
        case .ended:     return .status("Ticket sales have ended", url: nil)
        case .closed:    return .status("Ticket sales have closed", url: nil)
        case .off:       return .none
        }
    }
}

// MARK: - base64url

enum Base64URL {
    static func decode(_ text: Substring) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty, !s.contains("=") || s.hasSuffix("=") else { return nil }
        s = s.replacingOccurrences(of: "=", with: "")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - QR token

/// `ATK1.<payload>.<signature>`: payload = base64url of `{"e","k","n","t","y"}` (event, key id,
/// ticket version, ticket id, type id), signature = base64url of the 64-byte Ed25519 signature
/// of the ASCII bytes `ATK1.<payload>` (attnd-web `tickets/signing.py`).
struct TicketToken: Hashable, Sendable {
    static let prefix = "ATK1"

    var eventId: Int
    var keyId: Int
    var version: Int
    var ticketId: Int
    var typeId: Int?
    /// The signed bytes (`ATK1.<payload>`) and the signature.
    var message: Data
    var signature: Data

    private struct Payload: Decodable {
        var e: Int, k: Int, n: Int, t: Int
        var y: Int?
    }

    /// nil unless `raw` is a well-formed ATK1 token (the signature is not checked here).
    static func parse(_ raw: String) -> TicketToken? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(prefix),
              let json = Base64URL.decode(parts[1]), let signature = Base64URL.decode(parts[2]),
              let payload = try? JSONDecoder().decode(Payload.self, from: json) else { return nil }
        return TicketToken(eventId: payload.e, keyId: payload.k, version: payload.n, ticketId: payload.t,
                           typeId: payload.y, message: Data("\(parts[0]).\(parts[1])".utf8), signature: signature)
    }

    /// True when the signature verifies with key `keyId` of `keys` (kid → raw 32-byte key).
    func isSigned(by keys: [Int: Data]) -> Bool {
        guard let key = keys[keyId] else { return false }
        return TicketCrypto.isValidSignature(signature, of: message, publicKey: key)
    }
}

// MARK: - My tickets

/// The event a ticket is for (`tickets/mine/` → `event`).
struct TicketEventInfo: Hashable, Sendable {
    var id: Int
    var name: String = ""
    var eventCode: String = ""
    var timeZoneIdentifier: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    var address: String = ""
    var latitude: Double? = nil
    var longitude: Double? = nil
    var cancelled: Bool = false

    var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
}

extension TicketEventInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, timezone, address, latitude, longitude, cancelled
        case eventCode = "event_code"
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        eventCode = c.lenient(String.self, .eventCode) ?? ""
        timeZoneIdentifier = c.nonEmptyString(.timezone)
        startTime = c.date(.startTime)
        endTime = c.date(.endTime)
        address = c.lenient(String.self, .address) ?? ""
        latitude = c.lenient(Double.self, .latitude)
        longitude = c.lenient(Double.self, .longitude)
        cancelled = c.lenient(Bool.self, .cancelled) ?? false
    }
}

/// One ticket held by the signed-in email.
struct MyTicket: Identifiable, Hashable, Sendable {
    var id: Int
    var code: String = ""
    /// `valid`, `refunded`, `void` (others shown as sent).
    var status: String = "valid"
    var version: Int = 1
    /// The exact QR string (`ATK1…`); nil unless valid.
    var qr: String? = nil
    var typeId: Int? = nil
    var typeName: String = ""
    var holderName: String = ""
    var orderRef: String = ""
    var checkedInAt: Date? = nil
    var transferable: Bool = false
    var ticketURL: URL? = nil
    var appleWalletURL: URL? = nil
    var googleWalletURL: URL? = nil
    var event: TicketEventInfo

    var isValid: Bool { status == "valid" }
}

extension MyTicket: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, code, status, version, qr, type, event, transferable
        case holderName = "holder_name"
        case orderRef = "order_ref"
        case checkedInAt = "checked_in_at"
        case ticketURL = "ticket_url"
        case appleWalletURL = "apple_wallet_url"
        case googleWalletURL = "google_wallet_url"
    }

    private struct TypeRef: Decodable {
        var id: Int?
        var name: String?
        private enum CodingKeys: String, CodingKey { case id, name }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.lenient(Int.self, .id)
            name = c.lenient(String.self, .name)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        event = try c.decode(TicketEventInfo.self, forKey: .event)
        code = c.lenient(String.self, .code) ?? ""
        status = c.nonEmptyString(.status)?.lowercased() ?? "valid"
        version = c.lenient(Int.self, .version) ?? 1
        qr = c.nonEmptyString(.qr)
        let type = c.lenient(TypeRef.self, .type)
        typeId = type?.id
        typeName = type?.name ?? ""
        holderName = c.lenient(String.self, .holderName) ?? ""
        orderRef = c.lenient(String.self, .orderRef) ?? ""
        checkedInAt = c.date(.checkedInAt)
        transferable = c.lenient(Bool.self, .transferable) ?? false
        ticketURL = c.httpsURL(.ticketURL)
        appleWalletURL = c.httpsURL(.appleWalletURL)
        googleWalletURL = c.httpsURL(.googleWalletURL)
    }
}

/// `GET tickets/mine/`.
struct MyTicketsPayload: Hashable, Sendable {
    var email: String = ""
    var tickets: [MyTicket] = []
}

extension MyTicketsPayload: Decodable {
    private enum CodingKeys: String, CodingKey { case email, tickets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = c.lenient(String.self, .email) ?? ""
        tickets = c.lossyArray(MyTicket.self, .tickets)
    }
}

/// My tickets on disk (Application Support, excluded from backup): the raw response, so a
/// newer build reads fields an older one didn't know, plus the ETag and when it was fetched.
struct SavedMyTickets: Codable, Hashable, Sendable {
    static let currentFormat = 1
    var format: Int = SavedMyTickets.currentFormat
    var email: String
    var etag: String?
    var fetchedAt: Date?
    var json: Data

    func decoded() -> MyTicketsPayload? {
        guard format == Self.currentFormat else { return nil }
        return try? JSONDecoder().decode(MyTicketsPayload.self, from: json)
    }

    static func encode(_ saved: SavedMyTickets) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(saved)
    }

    static func decode(_ data: Data) throws -> SavedMyTickets {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SavedMyTickets.self, from: data)
    }
}

enum MyTicketsText {
    /// "Checked in 7:42 PM" / "Valid" / "Refunded" / "Void" / "Event cancelled".
    static func status(_ ticket: MyTicket, locale: Locale = .current) -> String {
        if ticket.event.cancelled { return "Event cancelled" }
        switch ticket.status {
        case "valid":
            guard let at = ticket.checkedInAt else { return "Valid" }
            return "Checked in \(DoorText.clock(at, timeZone: ticket.event.timeZone, locale: locale))"
        case "refunded": return "Refunded"
        case "void":     return "Void"
        default:         return ticket.status.prefix(1).uppercased() + ticket.status.dropFirst()
        }
    }

    /// "Sat, Nov 21 · 7:00 PM" in the event's zone.
    static func eventDate(_ event: TicketEventInfo, locale: Locale = .current) -> String? {
        guard let start = event.startTime else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = event.timeZone
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        return formatter.string(from: start)
    }
}

/// My tickets grouped by event: upcoming events first (soonest first), then past ones (newest first).
enum MyTicketsGrouping {
    struct Section: Hashable, Sendable, Identifiable {
        var event: TicketEventInfo
        var tickets: [MyTicket]
        var isPast: Bool
        var id: Int { event.id }
    }

    static func sections(_ tickets: [MyTicket], now: Date) -> [Section] {
        var byEvent: [Int: [MyTicket]] = [:]
        var events: [Int: TicketEventInfo] = [:]
        for ticket in tickets {
            byEvent[ticket.event.id, default: []].append(ticket)
            events[ticket.event.id] = ticket.event
        }
        let all = events.values.map { event -> Section in
            let end = event.endTime ?? event.startTime?.addingTimeInterval(24 * 3600) ?? .distantFuture
            let sorted = (byEvent[event.id] ?? []).sorted {
                ($0.isValid ? 0 : 1, $0.typeName, $0.id) < ($1.isValid ? 0 : 1, $1.typeName, $1.id)
            }
            return Section(event: event, tickets: sorted, isPast: end < now)
        }
        let start: (Section) -> Date = { $0.event.startTime ?? .distantFuture }
        let upcoming = all.filter { !$0.isPast }.sorted { (start($0), $0.id) < (start($1), $1.id) }
        let past = all.filter(\.isPast).sorted { (start($0), $0.id) > (start($1), $1.id) }
        return upcoming + past
    }
}

// MARK: - Door mode: server objects

/// An event this email may scan (`door/verify/`, `door/events/`, the manifest's `event`).
struct DoorEvent: Identifiable, Hashable, Sendable, Codable {
    var id: Int
    var name: String = ""
    var eventCode: String = ""
    var timeZoneIdentifier: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil

    var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }

    private enum CodingKeys: String, CodingKey {
        case id, name, timezone
        case eventCode = "event_code"
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(id: Int, name: String = "", eventCode: String = "", timeZoneIdentifier: String? = nil,
         startTime: Date? = nil, endTime: Date? = nil) {
        self.id = id
        self.name = name
        self.eventCode = eventCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.startTime = startTime
        self.endTime = endTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        eventCode = c.lenient(String.self, .eventCode) ?? ""
        timeZoneIdentifier = c.nonEmptyString(.timezone)
        startTime = c.date(.startTime)
        endTime = c.date(.endTime)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(eventCode, forKey: .eventCode)
        try c.encodeIfPresent(timeZoneIdentifier, forKey: .timezone)
        try c.encodeIfPresent(startTime.map(ISODate.string(from:)), forKey: .startTime)
        try c.encodeIfPresent(endTime.map(ISODate.string(from:)), forKey: .endTime)
    }
}

/// `door/verify/` → the token and the events this email works.
struct DoorSignIn: Hashable, Sendable {
    var doorToken: String
    var email: String = ""
    var events: [DoorEvent] = []
}

extension DoorSignIn: Decodable {
    private enum CodingKeys: String, CodingKey { case email, events; case doorToken = "door_token" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doorToken = try c.decode(String.self, forKey: .doorToken)
        email = c.lenient(String.self, .email) ?? ""
        events = c.lossyArray(DoorEvent.self, .events)
    }
}

struct DoorTicketType: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String = ""
    var reentry: Bool = false
    var addOn: Bool = false
    /// "YYYY-MM-DD" in the event's zone, or nil (any day).
    var validOn: String? = nil
}

extension DoorTicketType: Decodable {
    private enum CodingKeys: String, CodingKey { case id, name, reentry; case addOn = "add_on"; case validOn = "valid_on" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? ""
        reentry = c.lenient(Bool.self, .reentry) ?? false
        addOn = c.lenient(Bool.self, .addOn) ?? false
        validOn = c.nonEmptyString(.validOn)
    }
}

/// One ticket in the manifest: name and `email_hash` only (no email, prices or answers).
struct DoorTicket: Identifiable, Hashable, Sendable {
    var id: Int
    var code: String = ""
    var typeId: Int? = nil
    var status: String = "valid"
    var version: Int = 1
    var name: String = ""
    var emailHash: String = ""
    var orderRef: String = ""
    var checkedInAt: Date? = nil
    var checkedInGate: String? = nil
    var inside: Bool = false
}

extension DoorTicket: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, code, status, version, name, inside
        case typeId = "type_id"
        case emailHash = "email_hash"
        case orderRef = "order_ref"
        case checkedInAt = "checked_in_at"
        case checkedInGate = "checked_in_gate"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        code = c.lenient(String.self, .code) ?? ""
        typeId = c.lenient(Int.self, .typeId)
        status = c.nonEmptyString(.status)?.lowercased() ?? "valid"
        version = c.lenient(Int.self, .version) ?? 1
        name = c.lenient(String.self, .name) ?? ""
        emailHash = c.lenient(String.self, .emailHash)?.lowercased() ?? ""
        orderRef = c.lenient(String.self, .orderRef) ?? ""
        checkedInAt = c.date(.checkedInAt)
        checkedInGate = c.nonEmptyString(.checkedInGate)
        inside = c.lenient(Bool.self, .inside) ?? false
    }
}

/// `GET door/events/<id>/manifest/`: everything a door device needs to scan offline.
struct DoorManifest: Hashable, Sendable {
    var schema: Int = 1
    var generatedAt: Date? = nil
    var event: DoorEvent
    /// kid → raw 32-byte Ed25519 public key.
    var keys: [Int: Data] = [:]
    var ticketTypes: [DoorTicketType] = []
    var tickets: [DoorTicket] = []
    var revocationsCursor: Int = 0
    var gates: [String] = []

    func ticket(_ id: Int) -> DoorTicket? { tickets.first { $0.id == id } }
    func type(_ id: Int?) -> DoorTicketType? { id.flatMap { id in ticketTypes.first { $0.id == id } } }
}

extension DoorManifest: Decodable {
    private enum CodingKeys: String, CodingKey {
        case schema, event, keys, tickets, gates
        case generatedAt = "generated_at"
        case ticketTypes = "ticket_types"
        case revocationsCursor = "revocations_cursor"
    }

    private struct Key: Decodable {
        var kid: Int?
        var publicKey: String?
        private enum CodingKeys: String, CodingKey { case kid; case publicKey = "public_key" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kid = c.lenient(Int.self, .kid)
            publicKey = c.lenient(String.self, .publicKey)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(DoorEvent.self, forKey: .event)
        schema = c.lenient(Int.self, .schema) ?? 1
        generatedAt = c.date(.generatedAt)
        for key in c.lossyArray(Key.self, .keys) {
            if let kid = key.kid, let raw = key.publicKey.flatMap({ Base64URL.decode(Substring($0)) }) { keys[kid] = raw }
        }
        ticketTypes = c.lossyArray(DoorTicketType.self, .ticketTypes)
        tickets = c.lossyArray(DoorTicket.self, .tickets)
        revocationsCursor = c.lenient(Int.self, .revocationsCursor) ?? 0
        gates = c.lenient([String].self, .gates) ?? []
    }
}

struct DoorRevocation: Hashable, Sendable, Codable {
    var cursor: Int
    var ticketId: Int
    var version: Int
    var reason: String

    private enum CodingKeys: String, CodingKey { case cursor, version, reason; case ticketId = "ticket_id" }

    init(cursor: Int, ticketId: Int, version: Int, reason: String) {
        self.cursor = cursor
        self.ticketId = ticketId
        self.version = version
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = c.lenient(Int.self, .cursor) ?? 0
        ticketId = try c.decode(Int.self, forKey: .ticketId)
        version = c.lenient(Int.self, .version) ?? 0
        reason = c.lenient(String.self, .reason) ?? ""
    }

    /// Refund / void / cancelled / dispute read "Refunded / void" (the server's `void`); a
    /// transfer or reissue is an "Old QR code" (`revoked`).
    var result: DoorResult { reason == "transfer" || reason.isEmpty ? .revoked : .void }
}

/// `GET door/events/<id>/revocations/?since=`.
struct DoorRevocationsPage: Hashable, Sendable {
    var revocations: [DoorRevocation] = []
    var cursor: Int = 0
    var more: Bool = false
}

extension DoorRevocationsPage: Decodable {
    private enum CodingKeys: String, CodingKey { case revocations, cursor, more }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revocations = c.lossyArray(DoorRevocation.self, .revocations)
        cursor = c.lenient(Int.self, .cursor) ?? 0
        more = c.lenient(Bool.self, .more) ?? false
    }
}

struct DoorCounts: Hashable, Sendable, Codable {
    struct TypeCount: Hashable, Sendable, Codable {
        var typeId: Int?
        var name: String
        var total: Int
        var checkedIn: Int
    }

    struct GateCount: Hashable, Sendable, Codable {
        var gate: String
        var checkedIn: Int
    }

    var total: Int = 0
    var checkedIn: Int = 0
    var inside: Int = 0
    var flagged: Int = 0
    var byType: [TypeCount] = []
    var byGate: [GateCount] = []
    var updatedAt: Date? = nil
}

extension DoorCounts {
    fileprivate struct Wire: Decodable {
        var total, checkedIn, inside, flagged: Int?
        var byType: [TypeWire]
        var byGate: [GateWire]
        var updatedAt: Date?
        private enum CodingKeys: String, CodingKey {
            case total, inside, flagged
            case checkedIn = "checked_in", byType = "by_type", byGate = "by_gate", updatedAt = "updated_at"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = c.lenient(Int.self, .total)
            checkedIn = c.lenient(Int.self, .checkedIn)
            inside = c.lenient(Int.self, .inside)
            flagged = c.lenient(Int.self, .flagged)
            byType = c.lossyArray(TypeWire.self, .byType)
            byGate = c.lossyArray(GateWire.self, .byGate)
            updatedAt = c.date(.updatedAt)
        }
    }

    fileprivate struct TypeWire: Decodable {
        var typeId: Int?, name: String?, total: Int?, checkedIn: Int?
        private enum CodingKeys: String, CodingKey { case name, total; case typeId = "type_id", checkedIn = "checked_in" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            typeId = c.lenient(Int.self, .typeId)
            name = c.lenient(String.self, .name)
            total = c.lenient(Int.self, .total)
            checkedIn = c.lenient(Int.self, .checkedIn)
        }
    }

    fileprivate struct GateWire: Decodable {
        var gate: String?, checkedIn: Int?
        private enum CodingKeys: String, CodingKey { case gate; case checkedIn = "checked_in" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gate = c.lenient(String.self, .gate)
            checkedIn = c.lenient(Int.self, .checkedIn)
        }
    }

    /// The server's `Counts` object (lenient).
    static func decodeWire(_ data: Data) -> DoorCounts? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return DoorCounts(wire)
    }

    fileprivate init(_ wire: Wire) {
        total = wire.total ?? 0
        checkedIn = wire.checkedIn ?? 0
        inside = wire.inside ?? 0
        flagged = wire.flagged ?? 0
        byType = wire.byType.map { TypeCount(typeId: $0.typeId, name: $0.name ?? "", total: $0.total ?? 0, checkedIn: $0.checkedIn ?? 0) }
        byGate = wire.byGate.map { GateCount(gate: $0.gate ?? "", checkedIn: $0.checkedIn ?? 0) }
        updatedAt = wire.updatedAt
    }

    fileprivate static func lenient(_ c: KeyedDecodingContainer<DoorCheckinResponse.CodingKeys>) -> DoorCounts? {
        (try? c.decodeIfPresent(Wire.self, forKey: .counts))?.map(DoorCounts.init)
    }
}

// MARK: - Door mode: scans

enum DoorResult: String, Hashable, Sendable, Codable {
    case ok, duplicate, revoked, void, invalid
    case wrongDay = "wrong_day"
    /// Not an ATK1 token at all (never uploaded).
    case unreadable
    /// The server refused the scan (or answered with a result this build doesn't know).
    case rejected

    init(server raw: String?) { self = raw.flatMap(DoorResult.init(rawValue:)) ?? .rejected }
}

enum DoorScanKind: String, Hashable, Sendable, Codable { case `in`, out }

/// What the server said about one uploaded scan.
struct DoorServerResult: Hashable, Sendable, Codable {
    var result: DoorResult
    var flagged: Bool = false
    var firstAt: Date? = nil
    var firstGate: String? = nil
}

/// One scan this device made (kept for duplicate checks; queued until the server answered).
struct DoorScan: Identifiable, Hashable, Sendable, Codable {
    var clientId: String
    /// The QR string (uploaded so the server re-verifies it); nil for a manual check-in.
    var token: String?
    var ticketId: Int?
    var at: Date
    var kind: DoorScanKind
    var gate: String
    var deviceResult: DoorResult
    var manual: Bool = false
    var server: DoorServerResult? = nil

    var id: String { clientId }
    /// The server's answer once there is one, else what the device decided.
    var effectiveResult: DoorResult { server?.result ?? deviceResult }
    var isPending: Bool { server == nil }
    /// Admitted offline but the server disagrees (or flagged it as a later duplicate).
    var isFlagged: Bool {
        guard let server else { return false }
        return server.flagged || (deviceResult == .ok && server.result != .ok)
    }
}

/// Door mode's local state for one event, on disk next to the manifest: the gate, the
/// revocations polled since the download, every scan this device made, and the last counts.
struct DoorLocalState: Hashable, Sendable, Codable {
    var eventId: Int
    var gate: String = ""
    var revocationsCursor: Int = 0
    /// ticket id → the highest revoked version and its reason.
    var revocations: [Int: DoorRevocation] = [:]
    var scans: [DoorScan] = []
    var counts: DoorCounts? = nil
    var lastSyncAt: Date? = nil

    init(eventId: Int) { self.eventId = eventId }

    private enum CodingKeys: String, CodingKey {
        case eventId, gate, revocationsCursor, revocations, scans, counts, lastSyncAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(Int.self, forKey: .eventId)
        gate = c.lenient(String.self, .gate) ?? ""
        revocationsCursor = c.lenient(Int.self, .revocationsCursor) ?? 0
        revocations = c.lenient([Int: DoorRevocation].self, .revocations) ?? [:]
        scans = c.lossyArray(DoorScan.self, .scans)
        counts = c.lenient(DoorCounts.self, .counts)
        lastSyncAt = c.lenient(Date.self, .lastSyncAt)
    }

    var pending: [DoorScan] { scans.filter(\.isPending) }
    var flagged: [DoorScan] { scans.filter(\.isFlagged) }

    /// Revocations from `door/…/revocations/` (or the upload's cursor): the highest version per ticket.
    mutating func apply(_ page: DoorRevocationsPage) {
        for revocation in page.revocations {
            if let existing = revocations[revocation.ticketId], existing.version >= revocation.version { continue }
            revocations[revocation.ticketId] = revocation
        }
        revocationsCursor = max(revocationsCursor, page.cursor, page.revocations.map(\.cursor).max() ?? 0)
    }

    /// A newly downloaded manifest already contains everything up to its cursor.
    mutating func adopt(_ manifest: DoorManifest) {
        revocationsCursor = max(revocationsCursor, manifest.revocationsCursor)
    }

    mutating func record(_ scan: DoorScan) { scans.append(scan) }

    /// This device's admissions per gate ("Gate B: 41"), from the local log.
    func localAdmissionsByGate() -> [(gate: String, count: Int)] {
        var counts: [String: Int] = [:]
        for scan in scans where scan.kind == .in && scan.effectiveResult == .ok {
            counts[scan.gate, default: 0] += 1
        }
        return counts.map { (gate: $0.key, count: $0.value) }.sorted { ($0.gate, $0.count) < ($1.gate, $1.count) }
    }
}

/// How a scan was judged, with what the full-screen result shows.
struct DoorVerdict: Hashable, Sendable {
    enum Tone: String, Sendable { case green, amber, red }

    var result: DoorResult
    var kind: DoorScanKind
    var ticketId: Int? = nil
    var holderName: String? = nil
    var typeName: String? = nil
    var firstAt: Date? = nil
    var firstGate: String? = nil
    /// For `wrong_day`: the day the ticket is for ("YYYY-MM-DD").
    var validOn: String? = nil
    /// The token, when the scan is worth uploading (parsed and for a ticket).
    var token: String? = nil

    var tone: Tone {
        switch result {
        case .ok: return .green
        case .duplicate: return .amber
        default: return .red
        }
    }

    /// Scans with a ticket (or at least a well-formed token) go into the upload queue.
    var isQueued: Bool { result != .unreadable && (ticketId != nil || token != nil) }
}

// MARK: - Door mode: the offline rules

/// API_V2.md → "Scanning offline", in order. The same rules as the server's `_evaluate`
/// (status before version, so the device's result matches what the server will say).
enum DoorRules {
    /// A scanned QR string.
    static func evaluate(scanned raw: String, manifest: DoorManifest, state: DoorLocalState,
                         kind: DoorScanKind = .in, now: Date) -> DoorVerdict {
        guard let token = TicketToken.parse(raw) else { return DoorVerdict(result: .unreadable, kind: kind) }
        // 1. The signature with key k, and the event.
        guard token.eventId == manifest.event.id, token.isSigned(by: manifest.keys) else {
            return DoorVerdict(result: .invalid, kind: kind, token: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var verdict = judge(ticketId: token.ticketId, tokenVersion: token.version, tokenTypeId: token.typeId,
                            manifest: manifest, state: state, kind: kind, now: now)
        verdict.token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return verdict
    }

    /// A manual check-in of a manifest ticket (search by name, code, order ref or email).
    static func evaluate(ticketId: Int, manifest: DoorManifest, state: DoorLocalState,
                         kind: DoorScanKind = .in, now: Date) -> DoorVerdict {
        judge(ticketId: ticketId, tokenVersion: nil, tokenTypeId: nil, manifest: manifest, state: state, kind: kind, now: now)
    }

    private static func judge(ticketId: Int, tokenVersion: Int?, tokenTypeId: Int?, manifest: DoorManifest,
                              state: DoorLocalState, kind: DoorScanKind, now: Date) -> DoorVerdict {
        // A ticket missing from the manifest but with a valid signature was bought after the download.
        let ticket = manifest.ticket(ticketId)
        let type = manifest.type(ticket?.typeId ?? tokenTypeId)
        var verdict = DoorVerdict(result: .ok, kind: kind, ticketId: ticketId,
                                  holderName: ticket.map(\.name).flatMap { $0.isEmpty ? nil : $0 },
                                  typeName: type.map(\.name).flatMap { $0.isEmpty ? nil : $0 })
        // 2. Refunded / void, then old versions (revocations polled since the download, or an
        //    older `n` than the manifest's version).
        if let ticket, ticket.status != "valid" {
            verdict.result = .void
            return verdict
        }
        if let n = tokenVersion {
            if let revocation = state.revocations[ticketId], n <= revocation.version {
                verdict.result = revocation.result
                return verdict
            }
            if let ticket, n < ticket.version {
                verdict.result = .revoked
                return verdict
            }
        }
        // 3. Day tickets.
        if let validOn = type?.validOn, validOn != day(now, in: manifest.event.timeZone) {
            verdict.result = .wrongDay
            verdict.validOn = validOn
            return verdict
        }
        // 4. Already admitted (any gate this device knows of), unless re-entry and outside.
        guard kind == .in else { return verdict }
        let history = admissions(ticketId: ticketId, ticket: ticket, manifest: manifest, state: state)
        guard let first = history.first else { return verdict }
        if type?.reentry == true, !history.inside { return verdict }
        verdict.result = .duplicate
        verdict.firstAt = first.at
        verdict.firstGate = first.gate
        return verdict
    }

    struct Admissions {
        var first: (at: Date, gate: String?)?
        var inside: Bool
    }

    /// The earliest admission (manifest or this device's admitted scans) and whether the holder
    /// is inside now: this device's admitted scans since the manifest was made decide, else the
    /// manifest's `inside`.
    static func admissions(ticketId: Int, ticket: DoorTicket?, manifest: DoorManifest, state: DoorLocalState) -> Admissions {
        let local = state.scans.filter { $0.ticketId == ticketId && $0.effectiveResult == .ok }.sorted { $0.at < $1.at }
        var candidates: [(at: Date, gate: String?)] = []
        if let at = ticket?.checkedInAt { candidates.append((at, ticket?.checkedInGate)) }
        for scan in local where scan.kind == .in { candidates.append((scan.at, scan.gate.isEmpty ? nil : scan.gate)) }
        let first = candidates.min { $0.at < $1.at }
        let since = manifest.generatedAt ?? .distantPast
        let inside: Bool
        if let last = local.last(where: { $0.at >= since }) {
            inside = last.kind == .in
        } else {
            inside = ticket?.inside ?? false
        }
        return Admissions(first: first, inside: inside)
    }

    /// "YYYY-MM-DD" of `date` in `timeZone`.
    static func day(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The scan to record for a verdict (nil when it isn't worth keeping: unreadable codes).
    static func scan(for verdict: DoorVerdict, gate: String, at: Date, clientId: String = UUID().uuidString.lowercased(),
                     manual: Bool = false) -> DoorScan? {
        guard verdict.isQueued else { return nil }
        return DoorScan(clientId: clientId, token: manual ? nil : verdict.token, ticketId: verdict.ticketId, at: at,
                        kind: verdict.kind, gate: gate, deviceResult: verdict.result, manual: manual)
    }
}

/// The scanner sees the same QR many times a second: one decision per code per few seconds.
struct DoorScanDebounce: Sendable {
    var interval: TimeInterval = 3
    private var last: (raw: String, at: Date)?

    init(interval: TimeInterval = 3) { self.interval = interval }

    mutating func accept(_ raw: String, at now: Date) -> Bool {
        if let last, last.raw == raw, now.timeIntervalSince(last.at) < interval { return false }
        last = (raw, now)
        return true
    }
}

// MARK: - Door mode: manual search

enum DoorSearch {
    /// Tickets matching `query`: an email (hashed like the server: `sha256("<event id>:<email>")`),
    /// a ticket code (dashes and case ignored), an order ref, or every word of the name. ≤ 50, by name.
    static func find(_ query: String, in manifest: DoorManifest, limit: Int = 50) -> [DoorTicket] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let matches: [DoorTicket]
        if trimmed.contains("@") {
            let hash = emailHash(eventId: manifest.event.id, email: trimmed)
            matches = manifest.tickets.filter { $0.emailHash == hash }
        } else {
            let code = compact(trimmed)
            let words = fold(trimmed).split(separator: " ").map(String.init)
            matches = manifest.tickets.filter { ticket in
                if code.count >= 3, compact(ticket.code).hasPrefix(code) || compact(ticket.orderRef).hasPrefix(code) {
                    return true
                }
                let name = fold(ticket.name)
                return !words.isEmpty && words.allSatisfy { name.contains($0) }
            }
        }
        return Array(matches.sorted { (fold($0.name), $0.id) < (fold($1.name), $1.id) }.prefix(limit))
    }

    static func emailHash(eventId: Int, email: String) -> String {
        TicketCrypto.sha256Hex("\(eventId):\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())")
    }

    /// Upper-case letters and digits only ("K7Q2-9XPM" → "K7Q29XPM").
    static func compact(_ text: String) -> String {
        String(text.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}

// MARK: - Door mode: upload and merge

/// `POST door/events/<id>/checkins/` and its answer.
struct DoorCheckinResponse: Sendable {
    struct Row: Sendable, Hashable {
        var clientId: String?
        var result: DoorServerResult
    }

    var results: [Row] = []
    var counts: DoorCounts? = nil
    var revocationsCursor: Int? = nil

    fileprivate enum CodingKeys: String, CodingKey { case results, counts; case revocationsCursor = "revocations_cursor" }
}

extension DoorCheckinResponse: Decodable {
    private struct RowWire: Decodable {
        var clientId: String?, result: String?, flagged: Bool?, firstAt: Date?, firstGate: String?
        private enum CodingKeys: String, CodingKey {
            case result, flagged
            case clientId = "client_id", firstAt = "first_at", firstGate = "first_gate"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clientId = c.nonEmptyString(.clientId)
            result = c.lenient(String.self, .result)
            flagged = c.lenient(Bool.self, .flagged)
            firstAt = c.date(.firstAt)
            firstGate = c.nonEmptyString(.firstGate)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(RowWire.self, .results).map {
            Row(clientId: $0.clientId, result: DoorServerResult(result: DoorResult(server: $0.result), flagged: $0.flagged ?? false,
                                                               firstAt: $0.firstAt, firstGate: $0.firstGate))
        }
        counts = DoorCounts.lenient(c)
        revocationsCursor = c.lenient(Int.self, .revocationsCursor)
    }
}

enum DoorSync {
    static let maxBatch = 500

    /// The oldest scans without a server result, ≤ 500.
    static func nextBatch(_ state: DoorLocalState, limit: Int = maxBatch) -> [DoorScan] {
        Array(state.pending.sorted { ($0.at, $0.clientId) < ($1.at, $1.clientId) }.prefix(limit))
    }

    private struct Body: Encodable {
        var deviceId: String
        var gate: String
        var checkins: [Checkin]
        enum CodingKeys: String, CodingKey { case gate, checkins; case deviceId = "device_id" }
    }

    private struct Checkin: Encodable {
        var clientId: String
        var token: String?
        var ticketId: Int?
        var at: String
        var kind: String
        var gate: String
        var deviceResult: String
        enum CodingKeys: String, CodingKey {
            case token, at, kind, gate
            case clientId = "client_id", ticketId = "ticket_id", deviceResult = "device_result"
        }
    }

    /// The request body. Each scan carries its own gate (the server keeps it per scan).
    static func body(_ batch: [DoorScan], deviceId: String, gate: String) throws -> Data {
        let body = Body(deviceId: deviceId, gate: gate, checkins: batch.map {
            Checkin(clientId: $0.clientId, token: $0.token, ticketId: $0.token == nil ? $0.ticketId : nil,
                    at: ISODate.string(from: $0.at), kind: $0.kind.rawValue, gate: $0.gate,
                    deviceResult: $0.deviceResult.rawValue)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// Stores each result on its scan (by `client_id`; unknown ids are ignored), the counts and
    /// the sync time. Returns how many scans got a result and how many of them are flagged.
    @discardableResult
    static func merge(_ response: DoorCheckinResponse, into state: inout DoorLocalState, now: Date) -> (merged: Int, flagged: Int) {
        var byId: [String: DoorServerResult] = [:]
        for row in response.results { if let id = row.clientId { byId[id] = row.result } }
        var merged = 0, flagged = 0
        for index in state.scans.indices {
            guard let result = byId[state.scans[index].clientId] else { continue }
            state.scans[index].server = result
            merged += 1
            if state.scans[index].isFlagged { flagged += 1 }
        }
        if let counts = response.counts { state.counts = counts }
        state.lastSyncAt = now
        return (merged, flagged)
    }
}

// MARK: - Door mode: texts

enum DoorText {
    /// "7:42 PM" in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// The big line on the result screen.
    static func title(_ verdict: DoorVerdict, timeZone: TimeZone, now: Date, locale: Locale = .current) -> String {
        switch verdict.result {
        case .ok:         return verdict.kind == .out ? "Checked out" : "Admitted"
        case .duplicate:  return alreadyIn(verdict.firstAt, gate: verdict.firstGate, timeZone: timeZone, now: now, locale: locale)
        case .revoked:    return "Old QR code"
        case .void:       return "Refunded / void"
        case .invalid:    return "Not a ticket for this event"
        case .wrongDay:   return "Not valid today"
        case .unreadable: return "Not an Attnd ticket"
        case .rejected:   return "Rejected"
        }
    }

    /// "Already checked in 7:42 PM at Gate B" (the day too when it wasn't today).
    static func alreadyIn(_ at: Date?, gate: String?, timeZone: TimeZone, now: Date, locale: Locale = .current) -> String {
        var text = "Already checked in"
        if let at {
            let sameDay = DoorRules.day(at, in: timeZone) == DoorRules.day(now, in: timeZone)
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = sameDay ? "h:mm a" : "MMM d, h:mm a"
            text += " \(formatter.string(from: at))"
        }
        if let gate, !gate.isEmpty { text += " at \(gate)" }
        return text
    }

    /// The line under it: who and what, or what to do.
    static func detail(_ verdict: DoorVerdict) -> String {
        switch verdict.result {
        case .ok, .duplicate:
            return [verdict.holderName, verdict.typeName].compactMap { $0 }.joined(separator: " · ")
        case .revoked:    return "This ticket was transferred or reissued. Ask for the current QR code."
        case .void:       return "This ticket was refunded or cancelled."
        case .invalid:    return "The code isn’t a valid ticket for this event."
        case .wrongDay:   return verdict.validOn.map { "This ticket is for \($0)." } ?? "This ticket is for another day."
        case .unreadable: return "Scan the ticket’s QR code from the Attnd email, app or Wallet."
        case .rejected:   return ""
        }
    }

    /// "Offline · 3 waiting to sync", "3 waiting to sync", "All synced · 7:42 PM".
    static func syncLine(pending: Int, online: Bool, lastSync: Date?, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let waiting = "\(pending) waiting to sync"
        if !online { return pending > 0 ? "Offline · \(waiting)" : "Offline · all scans synced" }
        if pending > 0 { return waiting }
        return lastSync.map { "All synced · \(clock($0, timeZone: timeZone, locale: locale))" } ?? "All synced"
    }

    /// A flagged scan in the sync summary: "Duplicate · first 7:42 PM at Gate A".
    static func flagged(_ scan: DoorScan, timeZone: TimeZone, locale: Locale = .current) -> String {
        guard let server = scan.server else { return "" }
        let name: String
        switch server.result {
        case .duplicate: name = "Duplicate"
        case .revoked:   name = "Old QR code"
        case .void:      name = "Refunded / void"
        case .invalid:   name = "Not valid"
        case .wrongDay:  name = "Wrong day"
        case .ok:        name = "Admitted"
        default:         name = "Rejected"
        }
        guard server.result == .duplicate, let first = server.firstAt else { return name }
        var text = "\(name) · first \(clock(first, timeZone: timeZone, locale: locale))"
        if let gate = server.firstGate { text += " at \(gate)" }
        return text
    }
}
