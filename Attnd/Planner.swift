// Planner.swift
// Attnd (app target only — not in the App Clip; unit tested in PlannerTests)
//
// The planner's deterministic core (shared spec §6, "build me a plan"). A port of Android's
// `domain/Planner.kt`, `PlanSimilarity.kt` and `PlanCodec.kt` rule for rule, with the same
// fixture and the same expected scores and plans (`AttndTests/PlannerFixture.swift`), so both
// apps plan the same day from the same request:
//
//   - PlanPreferences: what the attendee wants (extracted by the on-device model and the plain
//     rules in PlanRequest.swift, validated against the bundle).
//   - TfIdfSimilarity: how alike two schedule items are (TF-IDF cosine over name, tags,
//     category, description and location; not NLEmbedding, so plans match Android's).
//   - Planner: scores, the best chain of items within the pace, hearted must-includes with
//     "or instead", walk legs, meal breaks, reasons, swap alternatives, change detection.
//   - PlanCodec: the stored form (JSON per event in UserDefaults), lenient like the API models.
//
// Dates and clock times are the event's: `PlanDate` (a calendar day) and `PlanClock` (a time
// of day) are read and placed in the event's time zone. Text is normalised with `PlanText`
// (Android's `SearchText`: NFD, marks dropped, lower case, letters/digits kept), not the
// search's own folding, so tags and terms split exactly as on Android.

import Foundation

// MARK: - Days and clock times

/// A calendar day ("2026-11-14"), like `java.time.LocalDate`.
struct PlanDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int

    static func < (a: PlanDate, b: PlanDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// "2026-11-14".
    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Strict "YYYY-MM-DD" with a real day of that month; nil otherwise.
    static func parse(_ text: String) -> PlanDate? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1 else { return nil }
        let candidate = PlanDate(year: year, month: month, day: day)
        guard let first = Self.utc.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = Self.utc.range(of: .day, in: .month, for: first)?.count,
              day <= days else { return nil }
        return candidate
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Pure date arithmetic (no time zone involved).
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private var utcNoon: Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    func adding(days: Int) -> PlanDate {
        guard let date = Self.utc.date(byAdding: .day, value: days, to: utcNoon) else { return self }
        return PlanDate(date, in: Self.utc)
    }

    /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
    var weekday: Int { Self.utc.component(.weekday, from: utcNoon) }

    /// "Saturday" (always English, like Android's `Locale.US`; used in prompts and examples).
    var weekdayName: String { Self.weekdayNames[(weekday - 1 + 7) % 7] }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// This day at `clock` in `calendar`'s time zone.
    func at(_ clock: PlanClock, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: clock.hour, minute: clock.minute))
            ?? .distantPast
    }
}

/// A time of day ("15:00"), like `java.time.LocalTime` without seconds.
struct PlanClock: Hashable, Comparable, Sendable, CustomStringConvertible {
    var hour: Int
    var minute: Int

    static let midnight = PlanClock(hour: 0, minute: 0)

    var minutesOfDay: Int { hour * 60 + minute }

    static func < (a: PlanClock, b: PlanClock) -> Bool { a.minutesOfDay < b.minutesOfDay }

    /// "15:00".
    var description: String { String(format: "%02d:%02d", hour, minute) }

    /// "HH:MM" or "HH:MM:SS" (the stored form); nil otherwise.
    static func parse(_ text: String) -> PlanClock? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return PlanClock(hour: hour, minute: minute)
    }
}

enum PlanCalendar {
    /// Longest event the day list covers (Android `TimeMatcher.MAX_EVENT_DAYS`).
    static let maxEventDays = 31

    /// A Gregorian calendar in `timeZone`.
    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The event's calendar days in its zone: its start date to its end date (when that is
    /// within 31 days), else the days schedule items start on, else today
    /// (Android `TimeMatcher.eventDays`).
    static func eventDays(_ bundle: EventBundle, now: Date) -> [PlanDate] {
        let calendar = calendar(bundle.event.timeZone)
        if let start = bundle.event.startTime {
            let first = PlanDate(start, in: calendar)
            var last = first
            if let end = bundle.event.endTime {
                let candidate = PlanDate(end, in: calendar)
                if candidate >= first, candidate <= first.adding(days: maxEventDays) { last = candidate }
            }
            var days: [PlanDate] = []
            var day = first
            while day <= last {
                days.append(day)
                day = day.adding(days: 1)
            }
            return days
        }
        let fromItems = Set(bundle.schedule.compactMap { $0.startTime.map { PlanDate($0, in: calendar) } }).sorted()
        return fromItems.isEmpty ? [PlanDate(now, in: calendar)] : fromItems
    }

    /// `date` truncated to the whole minute.
    static func truncatedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// Whole minutes from `start` to `end`, rounded toward zero (`Duration.toMinutes`).
    static func minutes(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) / 60)
    }
}

// MARK: - Text

/// Android's `SearchText` normalisation, used by the planner and its request reading so words
/// split exactly as on Android: each character decomposed (NFD), combining marks dropped,
/// lower case, letters and decimal digits kept, everything else a single space.
enum PlanText {
    static func normalize(_ value: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in value {
            for raw in String(character).decomposedStringWithCanonicalMapping.unicodeScalars {
                if raw.properties.generalCategory == .nonspacingMark { continue }
                for scalar in String(raw).lowercased().unicodeScalars {
                    if isLetterOrDigit(scalar) {
                        if pendingSpace, !out.isEmpty { out.append(" ") }
                        pendingSpace = false
                        out.unicodeScalars.append(scalar)
                    } else {
                        pendingSpace = true
                    }
                }
            }
        }
        return out
    }

    /// Normalised words (no empty strings).
    static func words(_ value: String) -> [String] {
        normalize(value).split(separator: " ").map(String.init)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// Android's `SearchQuery.STOP_WORDS`.
    static let stopWords: Set<String> = [
        "a", "an", "the", "at", "in", "on", "of", "for", "and", "or", "to", "is", "are", "be",
        "what", "whats", "when", "where", "who", "which", "how", "does", "do", "s",
        "can", "i", "me", "my", "we", "find", "get", "show", "tell", "about", "there", "any",
        "it", "this", "that", "with",
    ]
}

// MARK: - Preferences

/// How much of the planned window may be booked with items.
enum PlanPace: String, CaseIterable, Hashable, Sendable {
    case relaxed, balanced, packed

    var bookedPercent: Int {
        switch self {
        case .relaxed:  return 50
        case .balanced: return 70
        case .packed:   return 90
        }
    }

    /// "Packed" → .packed; anything else → .balanced.
    static func of(_ value: String?) -> PlanPace {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return .balanced }
        return PlanPace(rawValue: key) ?? .balanced
    }
}

/// What the attendee wants, validated against the bundle: tags lower case and only ones the
/// event uses, categories as the event spells them, ids only of existing schedule items, days
/// only event days.
struct PlanPreferences: Hashable, Sendable {
    var likedTags: Set<String> = []
    var dislikedTags: Set<String> = []
    var likedCategories: Set<String> = []
    var dislikedCategories: Set<String> = []
    /// Schedule items the attendee named as examples ("more like Prairie Lights").
    var similarTo: Set<Int> = []
    var days: [PlanDate] = []
    var earliest: PlanClock? = nil
    var latest: PlanClock? = nil
    /// "I've got 3 hours": the window ends this many minutes after it starts.
    var durationMinutes: Int? = nil
    var pace: PlanPace = .balanced
    var includeMeals = false
    var kidFriendly = false
}

// MARK: - Plans

enum MealKind: String, CaseIterable, Hashable, Sendable {
    case lunch, dinner

    var label: String {
        switch self {
        case .lunch:  return "Lunch break"
        case .dinner: return "Dinner break"
        }
    }

    var from: PlanClock {
        switch self {
        case .lunch:  return PlanClock(hour: 12, minute: 0)
        case .dinner: return PlanClock(hour: 18, minute: 0)
        }
    }

    var until: PlanClock {
        switch self {
        case .lunch:  return PlanClock(hour: 13, minute: 30)
        case .dinner: return PlanClock(hour: 19, minute: 30)
        }
    }
}

/// A schedule item in the plan. `walkMinutes` is the walk from the previous planned item of the
/// day (nil for the first one, or when a location has no coordinates; 0 at the same location).
/// `alternatives` are what Swap offers (best first); `orInstead` are hearted items that clash.
struct PlannedItem: Hashable, Sendable {
    var itemId: Int
    var start: Date
    var end: Date
    var reason: String
    var walkMinutes: Int?
    var alternatives: [Int]
    var orInstead: [Int]
}

/// A 45-minute meal break, with a food location to suggest when the event has one.
struct MealBreak: Hashable, Sendable {
    var kind: MealKind
    var start: Date
    var end: Date
    var locationId: Int?
}

enum PlanEntry: Hashable, Sendable {
    case item(PlannedItem)
    case meal(MealBreak)

    var start: Date {
        switch self {
        case .item(let item): return item.start
        case .meal(let meal): return meal.start
        }
    }

    var end: Date {
        switch self {
        case .item(let item): return item.end
        case .meal(let meal): return meal.end
        }
    }
}

struct PlanDay: Hashable, Sendable {
    var date: PlanDate
    var windowStart: Date
    var windowEnd: Date
    var entries: [PlanEntry]

    var items: [PlannedItem] {
        entries.compactMap { if case .item(let item) = $0 { return item } else { return nil } }
    }

    var meals: [MealBreak] {
        entries.compactMap { if case .meal(let meal) = $0 { return meal } else { return nil } }
    }
}

/// A plan for one event, stored on the device (`PlanCodec`).
struct Plan: Hashable, Sendable {
    var eventId: Int
    var createdAt: Date
    var request: String
    var preferences: PlanPreferences
    var days: [PlanDay]
    /// Planned item id → `Planner.fingerprint` when planned, to notice content changes.
    var fingerprints: [Int: String]

    var items: [PlannedItem] { days.flatMap(\.items) }
    var itemIds: [Int] { items.map(\.itemId) }
    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Similarity

/// How alike two schedule items are, 0 (nothing shared) … 1 (same words).
protocol ItemSimilarity {
    func similarity(_ a: ScheduleItem, _ b: ScheduleItem) -> Double
}

/// TF-IDF cosine similarity over the schedule (the same on Android, so plans match).
///
/// - Document of an item: its name, tags, its location's category, description and location
///   name (the bundle's location name, else the item's `location_name`), joined with spaces.
/// - Terms: `PlanText.words`, keeping words of 2+ characters that are not stop words.
/// - Corpus: every schedule item (N). `df(t)` = items containing t;
///   `idf(t) = ln((1 + N) / (1 + df(t))) + 1`; weight = raw count × idf.
/// - Similarity = cosine of the weight vectors (sums in sorted term order); 0 when either has
///   no terms; an item is 1 with itself.
struct TfIdfSimilarity: ItemSimilarity {
    private let vectors: [Int: [String: Double]]
    private let norms: [Int: Double]

    init(_ bundle: EventBundle) {
        var docs: [Int: [String]] = [:]
        for item in bundle.schedule {
            docs[item.id] = Self.terms(Self.document(bundle, item))
        }
        let n = Double(docs.count)
        var df: [String: Int] = [:]
        for words in docs.values {
            for term in Set(words) { df[term, default: 0] += 1 }
        }
        var vectors: [Int: [String: Double]] = [:]
        for (id, words) in docs {
            var counts: [String: Int] = [:]
            for word in words { counts[word, default: 0] += 1 }
            var vector: [String: Double] = [:]
            for (term, count) in counts {
                vector[term] = Double(count) * (log((1.0 + n) / (1.0 + Double(df[term] ?? 0))) + 1.0)
            }
            vectors[id] = vector
        }
        self.vectors = vectors
        norms = vectors.mapValues { vector in
            sqrt(vector.keys.sorted().reduce(0.0) { sum, term in
                let w = vector[term] ?? 0
                return sum + w * w
            })
        }
    }

    func similarity(_ a: ScheduleItem, _ b: ScheduleItem) -> Double {
        if a.id == b.id { return 1 }
        guard let va = vectors[a.id], let vb = vectors[b.id] else { return 0 }
        let na = norms[a.id] ?? 0
        let nb = norms[b.id] ?? 0
        if na == 0 || nb == 0 { return 0 }
        let dot = va.keys.filter { vb[$0] != nil }.sorted().reduce(0.0) { sum, term in
            sum + (va[term] ?? 0) * (vb[term] ?? 0)
        }
        return min(max(dot / (na * nb), 0), 1)
    }

    static func document(_ bundle: EventBundle, _ item: ScheduleItem) -> String {
        let location = item.locationId.flatMap { id in bundle.locations.first { $0.id == id } }
        return [
            item.name,
            item.tags.joined(separator: " "),
            location?.category ?? "",
            item.description,
            location?.name ?? item.locationName ?? "",
        ].joined(separator: " ")
    }

    static func terms(_ text: String) -> [String] {
        PlanText.words(text).filter { $0.count >= 2 && !PlanText.stopWords.contains($0) }
    }
}

// MARK: - Planner

/// The planner's deterministic core (shared spec §6; Android implements exactly these rules in
/// `Planner.kt`, whose KDoc is the source of truth). The model only extracts `PlanPreferences`.
///
/// 1. **Times**: an item's end is its end, or start + 1 h when missing / not after the start; its
///    booked length is the whole minutes between (rounded down). `from` is truncated to the
///    minute. Dates and clock times are in the event's zone.
/// 2. **Days**: the preference days that are event days on or after `from`'s date, ascending.
///    With none, the first event day on or after `from`'s date that has a candidate.
/// 3. **Window per day**: start = max(`from`, day at `earliest` or 00:00). End = day at `latest`,
///    on the next day when `latest` < 06:00 or (`earliest` is set and `latest` ≤ `earliest`);
///    without `latest` the next midnight. With `durationMinutes`, end = min(end, start + it).
/// 4. **Candidates**: items starting that day, start ≥ window start and end ≤ window end; with
///    `kidFriendly`, items tagged `adultTags` are dropped unless hearted; items scoring ≤ 0 are
///    dropped unless hearted. Ordered by (start, end, id).
/// 5. **Score** (integer milli-points, `floor(x × 1000 + 0.5)`): x = 0.5 + 3·hearted + 2·S + M +
///    K − 2·D (S = highest similarity to a liked item: the hearted items and `similarTo`, never
///    itself; M = liked tag / liked category / hearted location; K = kid-friendly and a family
///    tag; D = disliked tag or category).
/// 6. **Gap**: b may follow a when a.end + walk(a, b) + 5 min ≤ b.start (walk 0 at the same
///    location or without coordinates, else the straight-line estimate in whole minutes, ≥ 1).
/// 7. **Hearted items are must-include**: by (score desc, start, end, id), each kept when it fits
///    with every kept one; otherwise an "or instead" of the earliest-starting kept item it
///    clashes with (ties: lower id), left out of the plan.
/// 8. **Pace**: span = max(window start, first candidate start) … min(window end, last candidate
///    end) in whole minutes; cap = max(floor(span × percent / 100), kept hearted minutes).
/// 9. **Choice**: the chain (candidate order, gap rule) with every kept hearted item, ≤ cap
///    minutes and the highest total score; ties: fewer minutes, fewer items, lexicographically
///    smallest candidate positions.
/// 10. **Meals**: lunch 12:00–13:30 / dinner 18:00–19:30 clipped to the window, on a day with
///    planned items: 45 minutes at the earliest of {clipped start, planned ends inside it}, each
///    rounded up to 5 minutes, that ends in time and overlaps nothing; a food location nearest the
///    item before it (ties: sort order, id), else the first food location.
/// 11. **Reasons**, first that applies: "You hearted this"; "Because you hearted <name>" (S ≥ 0.2
///    from a hearted item); "Because you like <tag>"; "Because you like <category>"; "At
///    <location>, which you hearted"; "Kid-friendly"; "Like <name>" (S ≥ 0.2 from `similarTo`);
///    "Fits your day".
/// 12. **Swap alternatives** (≤ 3): the item's "or instead" items, then candidates (not planned,
///    not left out) that fit between its neighbours, by (score desc, start, id). No pace cap.
final class Planner {
    /// Every candidate's base score, so a request with no stated likes still gets a plan.
    static let base = 0.5
    static let bufferMinutes = 5
    static let maxAlternatives = 3
    static let similarReason = 0.2
    static let mealLength: TimeInterval = 45 * 60
    private static let nightOwlUntil = PlanClock(hour: 6, minute: 0)

    /// Tags that count as kid-friendly (K) with `kidFriendly`.
    static let familyTags: Set<String> = ["kid-friendly", "kids", "family", "all ages", "family-friendly"]
    /// Tags dropped with `kidFriendly` (unless hearted).
    static let adultTags: Set<String> = ["21+", "18+", "adults", "adults only", "adult"]

    private let bundle: EventBundle
    private let preferences: PlanPreferences
    private let heartedItems: Set<Int>
    private let heartedLocations: Set<Int>
    private let similarity: ItemSimilarity
    private let calendar: Calendar
    private let itemsById: [Int: ScheduleItem]
    private let likedTags: Set<String>
    private let dislikedTags: Set<String>
    private let likedCategories: Set<String>
    private let dislikedCategories: Set<String>
    private let heartedLiked: [ScheduleItem]
    private let namedLiked: [ScheduleItem]
    private var scores: [Int: Int] = [:]

    init(
        bundle: EventBundle,
        preferences: PlanPreferences,
        heartedItems: Set<Int> = [],
        heartedLocations: Set<Int> = [],
        similarity: ItemSimilarity? = nil
    ) {
        self.bundle = bundle
        self.preferences = preferences
        self.heartedItems = heartedItems
        self.heartedLocations = heartedLocations
        self.similarity = similarity ?? TfIdfSimilarity(bundle)
        calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let itemsById = Dictionary(bundle.schedule.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.itemsById = itemsById
        likedTags = Set(preferences.likedTags.map { $0.lowercased() })
        dislikedTags = Set(preferences.dislikedTags.map { $0.lowercased() })
        likedCategories = Set(preferences.likedCategories.map { $0.lowercased() })
        dislikedCategories = Set(preferences.dislikedCategories.map { $0.lowercased() })
        heartedLiked = heartedItems.sorted().compactMap { itemsById[$0] }
        namedLiked = preferences.similarTo.sorted().compactMap { itemsById[$0] }
    }

    // MARK: Public API

    func plan(from: Date, request: String, createdAt: Date? = nil) -> Plan {
        let start = PlanCalendar.truncatedToMinute(from)
        let today = PlanDate(start, in: calendar)
        let eventDays = PlanCalendar.eventDays(bundle, now: start)
        let wanted = Set(preferences.days).sorted().filter { eventDays.contains($0) && $0 >= today }
        var days: [PlanDay] = []
        if !wanted.isEmpty {
            days = wanted.compactMap { planDay($0, from: start) }
        } else {
            for day in eventDays where day >= today {
                if let planned = planDay(day, from: start), !planned.items.isEmpty {
                    days = [planned]
                    break
                }
            }
        }
        return Plan(
            eventId: bundle.event.id,
            createdAt: createdAt ?? from,
            request: request,
            preferences: preferences,
            days: days,
            fingerprints: fingerprints(of: days)
        )
    }

    /// Replaces `oldId` by `newId` in `plan` (one of its alternatives); nil when either is gone.
    func swap(_ plan: Plan, oldId: Int, newId: Int) -> Plan? {
        guard let dayIndex = plan.days.firstIndex(where: { day in day.items.contains { $0.itemId == oldId } }),
              itemsById[newId] != nil, !plan.itemIds.contains(newId) else { return nil }
        let day = plan.days[dayIndex]
        let chosen = day.items.map { $0.itemId == oldId ? newId : $0.itemId }
            .compactMap { itemsById[$0] }
            .sorted(by: Self.itemOrder)
        var orInstead: [Int: [Int]] = [:]
        for item in day.items { orInstead[item.itemId] = item.orInstead }
        // The swapped-out item's clashing hearted items stay with the slot.
        let moved = (orInstead.removeValue(forKey: oldId) ?? []) + [oldId]
        orInstead[newId] = moved.filter { $0 != newId && heartedItems.contains($0) }
        let rebuilt = buildDay(
            day.date,
            windowStart: day.windowStart,
            windowEnd: day.windowEnd,
            chosen: chosen,
            orInstead: orInstead,
            candidates: candidates(day.date, windowStart: day.windowStart, windowEnd: day.windowEnd)
        )
        var updated = plan
        updated.days[dayIndex] = rebuilt
        updated.fingerprints = fingerprints(of: updated.days)
        return updated
    }

    /// The integer milli-point score of `item` (rule 5).
    func score(_ item: ScheduleItem) -> Int {
        if let cached = scores[item.id] { return cached }
        let hearted = heartedItems.contains(item.id) ? 1.0 : 0.0
        let similar = bestSimilar(item, heartedLiked + namedLiked)?.similarity ?? 0
        let raw = Self.base + 3.0 * hearted + 2.0 * similar + Double(matches(item)) + Double(kid(item)) - 2.0 * Double(disliked(item))
        let value = Int((raw * 1000 + 0.5).rounded(.down))
        scores[item.id] = value
        return value
    }

    func reason(_ item: ScheduleItem) -> String {
        if heartedItems.contains(item.id) { return "You hearted this" }
        if let best = bestSimilar(item, heartedLiked), best.similarity >= Self.similarReason {
            return "Because you hearted \(best.item.name)"
        }
        if let tag = item.tags.first(where: { likedTags.contains($0.lowercased()) }) {
            return "Because you like \(tag.lowercased())"
        }
        if let category = category(item), likedCategories.contains(category.lowercased()) {
            return "Because you like \(category.lowercased())"
        }
        if let location = location(item.locationId), heartedLocations.contains(location.id) {
            return "At \(location.name), which you hearted"
        }
        if kid(item) == 1 { return "Kid-friendly" }
        if let best = bestSimilar(item, namedLiked), best.similarity >= Self.similarReason {
            return "Like \(best.item.name)"
        }
        return "Fits your day"
    }

    // MARK: Days

    private func window(_ day: PlanDate, from: Date) -> (start: Date, end: Date)? {
        let earliest = preferences.earliest
        let latest = preferences.latest
        let start = max(from, day.at(earliest ?? .midnight, in: calendar))
        var end: Date
        if let latest {
            let nextDay = latest < Self.nightOwlUntil || (earliest.map { latest <= $0 } ?? false)
            end = (nextDay ? day.adding(days: 1) : day).at(latest, in: calendar)
        } else {
            end = day.adding(days: 1).at(.midnight, in: calendar)
        }
        if let duration = preferences.durationMinutes, duration > 0 {
            end = min(end, start.addingTimeInterval(TimeInterval(duration * 60)))
        }
        return end > start ? (start, end) : nil
    }

    private func candidates(_ day: PlanDate, windowStart: Date, windowEnd: Date) -> [ScheduleItem] {
        bundle.schedule.filter { item in
            guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return false }
            let hearted = heartedItems.contains(item.id)
            return PlanDate(start, in: calendar) == day
                && start >= windowStart && end <= windowEnd
                && (hearted || !(preferences.kidFriendly && item.tags.contains { Self.adultTags.contains($0.lowercased()) }))
                && (hearted || score(item) > 0)
        }
        .sorted(by: Self.itemOrder)
    }

    private func planDay(_ day: PlanDate, from: Date) -> PlanDay? {
        guard let bounds = window(day, from: from) else { return nil }
        let windowStart = bounds.start, windowEnd = bounds.end
        let candidates = candidates(day, windowStart: windowStart, windowEnd: windowEnd)
        if candidates.isEmpty { return PlanDay(date: day, windowStart: windowStart, windowEnd: windowEnd, entries: []) }

        // Rule 7: hearted items are must-include unless they clash with a better hearted item.
        var kept: [ScheduleItem] = []
        var orInstead: [Int: [Int]] = [:]
        let hearted = candidates.filter { heartedItems.contains($0.id) }
            .sorted { a, b in
                let sa = score(a), sb = score(b)
                return sa != sb ? sa > sb : Self.itemOrder(a, b)
            }
        for item in hearted {
            let clashes = kept.filter { !compatible($0, item) }
            if let owner = clashes.min(by: { a, b in
                let sa = startOf(a), sb = startOf(b)
                return sa != sb ? sa < sb : a.id < b.id
            }) {
                orInstead[owner.id, default: []].append(item.id)
            } else {
                kept.append(item)
            }
        }
        let leftOut = Set(orInstead.values.flatMap { $0 })
        let pool = candidates.filter { !leftOut.contains($0.id) }
        let must = Set(kept.map(\.id))

        // Rule 8: pace cap.
        let spanStart = max(windowStart, candidates.map(startOf).min() ?? windowStart)
        let spanEnd = min(windowEnd, candidates.map(endOf).max() ?? windowEnd)
        let span = max(PlanCalendar.minutes(from: spanStart, to: spanEnd), 0)
        let mustMinutes = kept.reduce(0) { $0 + minutes($1) }
        let cap = max(span * preferences.pace.bookedPercent / 100, mustMinutes)

        let chosen = choose(pool, must: must, cap: cap)
        return buildDay(day, windowStart: windowStart, windowEnd: windowEnd, chosen: chosen, orInstead: orInstead, candidates: candidates)
    }

    private struct Chain {
        var score: Int
        var minutes: Int
        var positions: [Int]

        func betterInState(than other: Chain) -> Bool {
            if score != other.score { return score > other.score }
            if positions.count != other.positions.count { return positions.count < other.positions.count }
            return Self.lexLess(positions, other.positions)
        }

        func betterFinal(than other: Chain) -> Bool {
            if score != other.score { return score > other.score }
            if minutes != other.minutes { return minutes < other.minutes }
            if positions.count != other.positions.count { return positions.count < other.positions.count }
            return Self.lexLess(positions, other.positions)
        }

        private static func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
            for k in 0..<min(a.count, b.count) where a[k] != b[k] {
                return a[k] < b[k]
            }
            return a.count < b.count
        }
    }

    /// Rule 9: the best chain by dynamic programming over (last item, booked minutes).
    private func choose(_ pool: [ScheduleItem], must: Set<Int>, cap: Int) -> [ScheduleItem] {
        let n = pool.count
        var mustBefore = [Int](repeating: 0, count: n + 1) // must items at positions < i
        for i in 0..<n {
            mustBefore[i + 1] = mustBefore[i] + (must.contains(pool[i].id) ? 1 : 0)
        }
        let totalMust = mustBefore[n]
        let itemScore = pool.map { score($0) }
        let itemMinutes = pool.map { minutes($0) }
        var states = [[Int: Chain]](repeating: [:], count: n)

        func offer(_ j: Int, _ chain: Chain) {
            if let current = states[j][chain.minutes], !chain.betterInState(than: current) { return }
            states[j][chain.minutes] = chain
        }

        for j in 0..<n {
            if itemMinutes[j] > cap { continue }
            // Start a chain at j: no must item may come before it.
            if mustBefore[j] == 0 { offer(j, Chain(score: itemScore[j], minutes: itemMinutes[j], positions: [j])) }
            for i in 0..<j {
                if states[i].isEmpty { continue }
                // Skipping a must item between i and j is not allowed.
                if mustBefore[j] - mustBefore[i + 1] > 0 { continue }
                if !compatible(pool[i], pool[j]) { continue }
                for chain in states[i].values {
                    let total = chain.minutes + itemMinutes[j]
                    if total > cap { continue }
                    offer(j, Chain(score: chain.score + itemScore[j], minutes: total, positions: chain.positions + [j]))
                }
            }
        }

        var best: Chain? = totalMust == 0 ? Chain(score: 0, minutes: 0, positions: []) : nil
        for j in 0..<n {
            // A chain may end at j only when no must item comes after it.
            if totalMust - mustBefore[j + 1] > 0 { continue }
            for chain in states[j].values {
                if let current = best, !chain.betterFinal(than: current) { continue }
                best = chain
            }
        }
        return best?.positions.map { pool[$0] } ?? []
    }

    /// Items, walks, alternatives and meals for one day (also after a swap).
    private func buildDay(
        _ day: PlanDate,
        windowStart: Date,
        windowEnd: Date,
        chosen: [ScheduleItem],
        orInstead: [Int: [Int]],
        candidates: [ScheduleItem]
    ) -> PlanDay {
        let chosenIds = Set(chosen.map(\.id))
        let leftOut = Set(orInstead.values.flatMap { $0 })
        var entries: [PlanEntry] = []
        for (index, item) in chosen.enumerated() {
            let previous = index > 0 ? chosen[index - 1] : nil
            let next = index + 1 < chosen.count ? chosen[index + 1] : nil
            let clashing = orInstead[item.id] ?? []
            let others = candidates
                .filter { !chosenIds.contains($0.id) && !leftOut.contains($0.id) }
                .filter { candidate in
                    (previous.map { follows($0, candidate) } ?? true) && (next.map { follows(candidate, $0) } ?? true)
                }
                .sorted { a, b in
                    let sa = score(a), sb = score(b)
                    if sa != sb { return sa > sb }
                    let ta = startOf(a), tb = startOf(b)
                    return ta != tb ? ta < tb : a.id < b.id
                }
                .map(\.id)
            var alternatives: [Int] = []
            for id in clashing + others where !alternatives.contains(id) {
                alternatives.append(id)
            }
            entries.append(.item(PlannedItem(
                itemId: item.id,
                start: startOf(item),
                end: endOf(item),
                reason: reason(item),
                walkMinutes: previous.flatMap { walkShown($0, item) },
                alternatives: Array(alternatives.prefix(Self.maxAlternatives)),
                orInstead: clashing
            )))
        }
        if preferences.includeMeals, !chosen.isEmpty {
            for kind in MealKind.allCases {
                if let meal = meal(kind, day: day, windowStart: windowStart, windowEnd: windowEnd, chosen: chosen) {
                    entries.append(.meal(meal))
                }
            }
        }
        // Stable, like Kotlin's sortedWith.
        let ordered = entries.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map(\.element)
        return PlanDay(date: day, windowStart: windowStart, windowEnd: windowEnd, entries: ordered)
    }

    private func meal(_ kind: MealKind, day: PlanDate, windowStart: Date, windowEnd: Date, chosen: [ScheduleItem]) -> MealBreak? {
        let from = max(windowStart, day.at(kind.from, in: calendar))
        let until = min(windowEnd, day.at(kind.until, in: calendar))
        if until.timeIntervalSince(from) < Self.mealLength { return nil }
        let raw = [from] + chosen.map(endOf).filter { $0 >= from && $0 < until }
        let starts = Set(raw.map(roundUpToFiveMinutes)).sorted()
        guard let start = starts.first(where: { s in
            let e = s.addingTimeInterval(Self.mealLength)
            return e <= until && !chosen.contains { startOf($0) < e && endOf($0) > s }
        }) else { return nil }
        let before = chosen.filter { endOf($0) <= start }.max { a, b in
            let ea = endOf(a), eb = endOf(b)
            return ea != eb ? ea < eb : Self.itemOrder(a, b)
        }
        let near = before.flatMap { location($0.locationId)?.coordinate }
        return MealBreak(kind: kind, start: start, end: start.addingTimeInterval(Self.mealLength), locationId: foodLocation(near: near))
    }

    private func foodLocation(near: Coordinate?) -> Int? {
        let foods = bundle.locations.filter { location in
            PlanText.normalize(location.category ?? "").contains("food")
                || location.tags.contains { PlanText.normalize($0).contains("food") }
        }
        .sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id < $1.id }
        guard let first = foods.first else { return nil }
        if let near {
            let nearest = foods.compactMap { location in location.coordinate.map { (location, Self.distance(near, $0)) } }
                .min { a, b in
                    if a.1 != b.1 { return a.1 < b.1 }
                    if a.0.sortOrder != b.0.sortOrder { return a.0.sortOrder < b.0.sortOrder }
                    return a.0.id < b.0.id
                }
            if let nearest { return nearest.0.id }
        }
        return first.id
    }

    private func roundUpToFiveMinutes(_ date: Date) -> Date {
        let truncated = PlanCalendar.truncatedToMinute(date)
        let base = truncated == date ? truncated : truncated.addingTimeInterval(60)
        let minute = calendar.component(.minute, from: base)
        let extra = (5 - minute % 5) % 5
        return base.addingTimeInterval(TimeInterval(extra * 60))
    }

    // MARK: Scoring helpers

    private func location(_ id: Int?) -> Location? {
        guard let id else { return nil }
        return bundle.locations.first { $0.id == id }
    }

    private func category(_ item: ScheduleItem) -> String? {
        guard let category = location(item.locationId)?.category,
              !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return category
    }

    private func matches(_ item: ScheduleItem) -> Int {
        let category = category(item)?.lowercased()
        let liked = item.tags.contains { likedTags.contains($0.lowercased()) }
            || (category.map { likedCategories.contains($0) } ?? false)
            || (item.locationId.map { heartedLocations.contains($0) } ?? false)
        return liked ? 1 : 0
    }

    private func kid(_ item: ScheduleItem) -> Int {
        preferences.kidFriendly && item.tags.contains { Self.familyTags.contains($0.lowercased()) } ? 1 : 0
    }

    private func disliked(_ item: ScheduleItem) -> Int {
        let category = category(item)?.lowercased()
        let disliked = item.tags.contains { dislikedTags.contains($0.lowercased()) }
            || (category.map { dislikedCategories.contains($0) } ?? false)
        return disliked ? 1 : 0
    }

    private func bestSimilar(_ item: ScheduleItem, _ liked: [ScheduleItem]) -> (item: ScheduleItem, similarity: Double)? {
        liked.filter { $0.id != item.id }
            .map { (item: $0, similarity: similarity.similarity(item, $0)) }
            .min { a, b in a.similarity != b.similarity ? a.similarity > b.similarity : a.item.id < b.item.id }
    }

    // MARK: Time and walking

    private func startOf(_ item: ScheduleItem) -> Date { item.startTime ?? .distantPast }
    private func endOf(_ item: ScheduleItem) -> Date { ScheduleTiming.effectiveEnd(of: item) ?? startOf(item) }
    private func minutes(_ item: ScheduleItem) -> Int { PlanCalendar.minutes(from: startOf(item), to: endOf(item)) }

    /// Rule 6 in either order: the pair can both be planned (the earlier in candidate order first).
    private func compatible(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        Self.itemOrder(b, a) ? follows(b, a) : follows(a, b)
    }

    /// Rule 6: `b` can come right after `a`.
    private func follows(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        let gap = TimeInterval(((walkShown(a, b) ?? 0) + Self.bufferMinutes) * 60)
        return endOf(a).addingTimeInterval(gap) <= startOf(b)
    }

    /// The walk shown before `b`: 0 at the same location, nil without coordinates.
    private func walkShown(_ a: ScheduleItem, _ b: ScheduleItem) -> Int? {
        if let id = a.locationId, id == b.locationId { return 0 }
        guard let from = location(a.locationId)?.coordinate, let to = location(b.locationId)?.coordinate else { return nil }
        return Self.walkMinutes(meters: Self.distance(from, to))
    }

    /// Android's `Walking.minutes(Walking.estimateSeconds(m))`: the straight line × 1.2 at
    /// 1.3 m/s rounded to whole seconds, then whole minutes rounded up, at least 1.
    static func walkMinutes(meters: Double) -> Int {
        let seconds = Int((max(meters, 0) * WalkTime.detourFactor / WalkTime.speed).rounded(.toNearestOrAwayFromZero))
        return max(1, (seconds + 59) / 60)
    }

    /// Android's `Geo.distanceMeters` (haversine with atan2), so walk minutes round the same.
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * (Double.pi / 180)
        let lat2 = b.latitude * (Double.pi / 180)
        let dLat = lat2 - lat1
        let dLng = (b.longitude - a.longitude) * (Double.pi / 180)
        let s1 = sin(dLat / 2), s2 = sin(dLng / 2)
        let h = s1 * s1 + cos(lat1) * cos(lat2) * s2 * s2
        return 2 * Compass.earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    // MARK: Ordering, fingerprints, summary

    /// (start, effective end, id); a missing start or end sorts first (Kotlin `compareBy`).
    static func itemOrder(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        if a.startTime != b.startTime {
            guard let sa = a.startTime else { return true }
            guard let sb = b.startTime else { return false }
            return sa < sb
        }
        let ea = ScheduleTiming.effectiveEnd(of: a), eb = ScheduleTiming.effectiveEnd(of: b)
        if ea != eb {
            guard let ea else { return true }
            guard let eb else { return false }
            return ea < eb
        }
        return a.id < b.id
    }

    private func fingerprints(of days: [PlanDay]) -> [Int: String] {
        var result: [Int: String] = [:]
        for item in days.flatMap(\.items) {
            if let scheduleItem = itemsById[item.itemId] { result[item.itemId] = Self.fingerprint(scheduleItem) }
        }
        return result
    }

    /// What a planned item looked like when planned; a different value means the plan changed.
    static func fingerprint(_ item: ScheduleItem) -> String {
        [
            item.name,
            item.startTime.map(ISODate.string(from:)) ?? "",
            ScheduleTiming.effectiveEnd(of: item).map(ISODate.string(from:)) ?? "",
            item.locationId.map(String.init) ?? "",
        ].joined(separator: "|")
    }

    /// One line about `plan`: "8 items, 10:00 AM – 11:00 PM, with a lunch break" (one day) or
    /// "5 items over 2 days"; "Nothing fits" when empty.
    static func summary(_ plan: Plan, timeZone: TimeZone, locale: Locale = .current) -> String {
        let items = plan.items
        if items.isEmpty { return "Nothing fits" }
        let count = "\(items.count) \(items.count == 1 ? "item" : "items")"
        let planned = plan.days.filter { !$0.items.isEmpty }
        guard planned.count == 1, let day = planned.first, let first = day.items.first,
              let last = day.items.map(\.end).max() else {
            return "\(count) over \(planned.count) days"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        let span = "\(formatter.string(from: first.start)) – \(formatter.string(from: last))"
        let meals = day.meals.map { $0.kind.label.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        let mealText: String
        switch meals.count {
        case 0: mealText = ""
        case 1: mealText = ", with a \(meals[0]) break"
        default: mealText = ", with \(meals.joined(separator: " and ")) breaks"
        }
        return "\(count), \(span)\(mealText)"
    }

    /// True when a planned item is gone or changed (name, times, location) since it was planned.
    static func changed(_ plan: Plan, schedule: [ScheduleItem]) -> Bool {
        plan.fingerprints.contains { id, print in
            guard let item = schedule.first(where: { $0.id == id }) else { return true }
            return fingerprint(item) != print
        }
    }
}

// MARK: - Stored form

/// The stored form of a `Plan` (one JSON text per event in UserDefaults; Android `PlanCodec`
/// has the same shape). Lenient: unknown keys are ignored, missing ones defaulted, and a
/// broken text decodes to nil.
enum PlanCodec {
    static func encode(_ plan: Plan) -> Data? {
        try? JSONEncoder().encode(StoredPlan(plan))
    }

    static func decode(_ data: Data?) -> Plan? {
        guard let data, !data.isEmpty,
              let stored = try? JSONDecoder().decode(StoredPlan.self, from: data) else { return nil }
        return stored.plan
    }

    static func decode(_ text: String?) -> Plan? {
        decode(text.flatMap { $0.data(using: .utf8) })
    }

    private struct StoredPlan: Codable {
        var eventId = 0
        var createdAt = ""
        var request = ""
        var preferences = StoredPreferences()
        var days: [StoredDay] = []
        var fingerprints: [String: String] = [:]

        init(_ plan: Plan) {
            eventId = plan.eventId
            createdAt = ISODate.string(from: plan.createdAt)
            request = plan.request
            preferences = StoredPreferences(plan.preferences)
            days = plan.days.map(StoredDay.init)
            fingerprints = Dictionary(plan.fingerprints.map { (String($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        }

        private enum CodingKeys: String, CodingKey {
            case eventId, createdAt, request, preferences, days, fingerprints
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventId = c.lenient(Int.self, .eventId) ?? 0
            createdAt = c.lenient(String.self, .createdAt) ?? ""
            request = c.lenient(String.self, .request) ?? ""
            preferences = c.lenient(StoredPreferences.self, .preferences) ?? StoredPreferences()
            days = c.lossyArray(StoredDay.self, .days)
            fingerprints = c.lenient([String: String].self, .fingerprints) ?? [:]
        }

        var plan: Plan? {
            guard eventId != 0, let created = ISODate.parse(createdAt) else { return nil }
            var prints: [Int: String] = [:]
            for (key, value) in fingerprints {
                if let id = Int(key) { prints[id] = value }
            }
            return Plan(
                eventId: eventId,
                createdAt: created,
                request: request,
                preferences: preferences.preferences,
                days: days.compactMap(\.day),
                fingerprints: prints
            )
        }
    }

    private struct StoredPreferences: Codable {
        var likedTags: [String] = []
        var dislikedTags: [String] = []
        var likedCategories: [String] = []
        var dislikedCategories: [String] = []
        var similarTo: [Int] = []
        var days: [String] = []
        var earliest: String? = nil
        var latest: String? = nil
        var durationMinutes: Int? = nil
        var pace = PlanPace.balanced.rawValue
        var includeMeals = false
        var kidFriendly = false

        init() {}

        init(_ p: PlanPreferences) {
            likedTags = p.likedTags.sorted()
            dislikedTags = p.dislikedTags.sorted()
            likedCategories = p.likedCategories.sorted()
            dislikedCategories = p.dislikedCategories.sorted()
            similarTo = p.similarTo.sorted()
            days = p.days.map(\.description)
            earliest = p.earliest?.description
            latest = p.latest?.description
            durationMinutes = p.durationMinutes
            pace = p.pace.rawValue
            includeMeals = p.includeMeals
            kidFriendly = p.kidFriendly
        }

        private enum CodingKeys: String, CodingKey {
            case likedTags, dislikedTags, likedCategories, dislikedCategories, similarTo, days
            case earliest, latest, durationMinutes, pace, includeMeals, kidFriendly
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            likedTags = c.lenient([String].self, .likedTags) ?? []
            dislikedTags = c.lenient([String].self, .dislikedTags) ?? []
            likedCategories = c.lenient([String].self, .likedCategories) ?? []
            dislikedCategories = c.lenient([String].self, .dislikedCategories) ?? []
            similarTo = c.lenient([Int].self, .similarTo) ?? []
            days = c.lenient([String].self, .days) ?? []
            earliest = c.lenient(String.self, .earliest)
            latest = c.lenient(String.self, .latest)
            durationMinutes = c.lenient(Int.self, .durationMinutes)
            pace = c.lenient(String.self, .pace) ?? PlanPace.balanced.rawValue
            includeMeals = c.lenient(Bool.self, .includeMeals) ?? false
            kidFriendly = c.lenient(Bool.self, .kidFriendly) ?? false
        }

        var preferences: PlanPreferences {
            PlanPreferences(
                likedTags: Set(likedTags),
                dislikedTags: Set(dislikedTags),
                likedCategories: Set(likedCategories),
                dislikedCategories: Set(dislikedCategories),
                similarTo: Set(similarTo),
                days: days.compactMap(PlanDate.parse),
                earliest: earliest.flatMap(PlanClock.parse),
                latest: latest.flatMap(PlanClock.parse),
                durationMinutes: durationMinutes,
                pace: PlanPace.of(pace),
                includeMeals: includeMeals,
                kidFriendly: kidFriendly
            )
        }
    }

    private struct StoredDay: Codable {
        var date = ""
        var windowStart = ""
        var windowEnd = ""
        var entries: [StoredEntry] = []

        init(_ day: PlanDay) {
            date = day.date.description
            windowStart = ISODate.string(from: day.windowStart)
            windowEnd = ISODate.string(from: day.windowEnd)
            entries = day.entries.map(StoredEntry.init)
        }

        private enum CodingKeys: String, CodingKey {
            case date, windowStart, windowEnd, entries
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = c.lenient(String.self, .date) ?? ""
            windowStart = c.lenient(String.self, .windowStart) ?? ""
            windowEnd = c.lenient(String.self, .windowEnd) ?? ""
            entries = c.lossyArray(StoredEntry.self, .entries)
        }

        var day: PlanDay? {
            guard let date = PlanDate.parse(date),
                  let start = ISODate.parse(windowStart),
                  let end = ISODate.parse(windowEnd) else { return nil }
            return PlanDay(date: date, windowStart: start, windowEnd: end, entries: entries.compactMap(\.entry))
        }
    }

    private struct StoredEntry: Codable {
        /// "item" or "meal".
        var type = "item"
        var start = ""
        var end = ""
        var itemId: Int? = nil
        var reason = ""
        var walkMinutes: Int? = nil
        var alternatives: [Int] = []
        var orInstead: [Int] = []
        var meal: String? = nil
        var locationId: Int? = nil

        init(_ entry: PlanEntry) {
            start = ISODate.string(from: entry.start)
            end = ISODate.string(from: entry.end)
            switch entry {
            case .item(let item):
                type = "item"
                itemId = item.itemId
                reason = item.reason
                walkMinutes = item.walkMinutes
                alternatives = item.alternatives
                orInstead = item.orInstead
            case .meal(let mealBreak):
                type = "meal"
                meal = mealBreak.kind.rawValue
                locationId = mealBreak.locationId
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, start, end, itemId, reason, walkMinutes, alternatives, orInstead, meal, locationId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.lenient(String.self, .type) ?? "item"
            start = c.lenient(String.self, .start) ?? ""
            end = c.lenient(String.self, .end) ?? ""
            itemId = c.lenient(Int.self, .itemId)
            reason = c.lenient(String.self, .reason) ?? ""
            walkMinutes = c.lenient(Int.self, .walkMinutes)
            alternatives = c.lenient([Int].self, .alternatives) ?? []
            orInstead = c.lenient([Int].self, .orInstead) ?? []
            meal = c.lenient(String.self, .meal)
            locationId = c.lenient(Int.self, .locationId)
        }

        var entry: PlanEntry? {
            guard let s = ISODate.parse(start), let e = ISODate.parse(end) else { return nil }
            if type == "meal" {
                guard let kind = meal.flatMap({ MealKind(rawValue: $0.lowercased()) }) else { return nil }
                return .meal(MealBreak(kind: kind, start: s, end: e, locationId: locationId))
            }
            guard let itemId else { return nil }
            return .item(PlannedItem(
                itemId: itemId, start: s, end: e, reason: reason, walkMinutes: walkMinutes,
                alternatives: alternatives, orInstead: orInstead
            ))
        }
    }
}
