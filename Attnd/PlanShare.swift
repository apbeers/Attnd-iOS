// PlanShare.swift
// Attnd (app + App Clip; unit tested in AssistantExtrasTests)
//
// Shared plan / item links (assistant spec §7, attnd-web API-015), a port of Android's
// `domain/PlanShare.kt`: `https://attnd.app/p/<EVENT_CODE>/<payload>`, payload = base64url
// without padding of compact JSON with keys v, ids, d (`{"v":1,"ids":[101,114],"d":"2026-11-14"}`
// → `eyJ2IjoxLCJpZHMiOlsxMDEsMTE0XSwiZCI6IjIwMjYtMTEtMTQifQ`), ≤ 1,500 characters (ids are
// dropped from the end until it fits). No personal data. Decoding is lenient like the server's:
// padding and the standard alphabet accepted, ids may be "s12", a malformed `d` ignored.
// `GroupPlan` merges shared plans with the attendee's likes (+1 per person). Link building and
// the app's URL routing stay in `Components/ShareCard.swift` (`SharedPlanLink`); `parseLink` is
// Android's stricter `JoinLinks.parseShareLink` (attnd.app only) for text the assistant reads.

import Foundation

/// A decoded share payload. `version` > 1 can't be read: join the event only.
struct SharedPayload: Hashable, Sendable {
    var version: Int
    var ids: [Int]
    var day: PlanDate?

    var isReadable: Bool { version == 1 }
}

enum PlanShare {
    static let maxPayload = 1500
    /// Production links; the dev server's are `https://dev.attnd.app/p/…` (callers pass `host`).
    static let productionHost = "attnd.app"
    /// Hosts whose `/p/` links the app reads (dev events link to the dev server, Nov 20, 2026).
    static let linkHosts: Set<String> = ["attnd.app", "dev.attnd.app", "www.attnd.app"]

    /// The exact JSON text (no spaces; v, ids, d).
    static func json(_ ids: [Int], day: PlanDate?) -> String {
        "{\"v\":1,\"ids\":[\(ids.map(String.init).joined(separator: ","))]" + (day.map { ",\"d\":\"\($0)\"" } ?? "") + "}"
    }

    static func payload(_ ids: [Int], day: PlanDate? = nil) -> String {
        var seen = Set<Int>()
        var kept = ids.filter { seen.insert($0).inserted }
        while true {
            let encoded = base64url(Data(json(kept, day: day).utf8))
            if encoded.count <= maxPayload || kept.isEmpty { return encoded }
            kept.removeLast()
        }
    }

    static func link(_ eventCode: String, _ ids: [Int], day: PlanDate? = nil, host: String = productionHost) -> String {
        "https://\(host)/p/" + eventCode.trimmingCharacters(in: .whitespacesAndNewlines) + "/" + payload(ids, day: day)
    }

    /// `share_plan`: the plan's items in plan order; `d` = its day when exactly one day has items.
    static func planLink(_ plan: Plan, _ bundle: EventBundle, host: String = productionHost) -> String {
        let days = plan.days.filter { !$0.items.isEmpty }
        return link(bundle.event.eventCode, plan.itemIds, day: days.count == 1 ? days[0].date : nil, host: host)
    }

    static func itemLink(_ itemId: Int, _ bundle: EventBundle, host: String = productionHost) -> String {
        link(bundle.event.eventCode, [itemId], host: host)
    }

    static func decode(_ payload: String?) -> SharedPayload? {
        guard var text = payload?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty || text.count > maxPayload + 2 { return nil }
        guard let data = fromBase64url(text), let string = String(data: data, encoding: .utf8),
              let obj = JSONValue.parse(string)?.objectValue,
              let version = obj["v"]?.intValue, version >= 1 else { return nil }
        if version > 1 { return SharedPayload(version: version, ids: [], day: nil) }
        guard let array = obj["ids"]?.arrayValue else { return nil }
        var seen = Set<Int>()
        let ids = array.compactMap { EntityRef.id($0, prefix: "s") }.filter { seen.insert($0).inserted }
        let day = obj["d"]?.content.flatMap { PlanDate.parse($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return SharedPayload(version: version, ids: ids, day: day)
    }

    /// The shared ids still in `bundle` (others are gone).
    static func resolve(_ shared: SharedPayload, _ bundle: EventBundle) -> [Int] {
        shared.ids.filter { bundle.scheduleItem($0) != nil }
    }

    /// `https://attnd.app/p/<code>/<payload>` (with or without `www.` or a scheme, a trailing
    /// slash, query or fragment) → its code (percent-decoded) and still-encoded payload; nil for
    /// anything else (other hosts, `/join/`, `/p/<code>/<payload>/qr.svg`).
    static func parseLink(_ raw: String?) -> (eventCode: String, payload: String)? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              let components = URLComponents(string: value.contains("://") ? value : "https://\(value)"),
              var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard linkHosts.contains(host) else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard segments.count == 3, segments[0] == "p" else { return nil }
        let code = (segments[1].removingPercentEncoding ?? segments[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = segments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty || payload.isEmpty { return nil }
        return (code, payload)
    }

    // MARK: base64url

    static func base64url(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// Java's URL decoder: the URL-safe alphabet (standard `+` `/` accepted too), padding optional.
    static func fromBase64url(_ text: String) -> Data? {
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let unpadded = standard.replacingOccurrences(of: "=", with: "")
        guard unpadded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }),
              unpadded.count % 4 != 1 else { return nil }
        standard = unpadded + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}

/// Group plans (spec §7): several shared plans plus the attendee's likes → the union of liked
/// items, each weighted +1 per person who liked or planned it (`PlanConstraints.groupLikes`), then
/// the normal planner. The attendee is one person (their liked schedule items); each shared plan
/// is one person. Ids not in the bundle are dropped.
enum GroupPlan {
    static func merge(_ shared: [[Int]], _ own: LikeSet, _ bundle: EventBundle) -> (likes: LikeSet, counts: [Int: Int]) {
        var counts: [Int: Int] = [:]
        for person in [Array(own.scheduleItems)] + shared {
            for id in Set(person) where bundle.scheduleItem(id) != nil { counts[id, default: 0] += 1 }
        }
        var likes = own
        likes.scheduleItems = Set(counts.keys)
        return (likes, counts)
    }

    static func plan(_ shared: [[Int]], _ own: LikeSet, _ bundle: EventBundle, _ preferences: PlanPreferences, now: Date, request: String = "") -> Plan {
        let (likes, counts) = merge(shared, own, bundle)
        return Planner(bundle: bundle, preferences: preferences, heartedItems: likes.scheduleItems, heartedLocations: likes.locations,
                       constraints: PlanConstraints(groupLikes: counts)).plan(from: now, request: request)
    }
}
