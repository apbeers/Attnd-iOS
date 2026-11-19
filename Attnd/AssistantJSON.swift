// AssistantJSON.swift
// Attnd (app + App Clip; unit tested in AssistantBlocksTests)
//
// The JSON the event assistant speaks (assistant spec §2–3): blocks, actions and plan ops as the
// on-device model writes them and as Android's kotlinx JSON elements read them. Foundation's
// JSONSerialization neither keeps key order nor tells numbers from booleans reliably, and the
// fixtures compare exact JSON text, so the assistant uses this small value type:
//
//   - JSONValue: null, bool, number (kept as its literal text, like kotlinx `JsonPrimitive`),
//     string, array, object.
//   - JSONObject: an object that keeps insertion order (encoding writes keys in that order);
//     equality ignores order, like kotlinx `JsonObject`.
//   - JSONValue.parse: a strict JSON reader; `encoded` writes compact JSON exactly like
//     kotlinx `JsonElement.toString()` (no spaces, `"` `\` and control characters escaped).

import Foundation

/// One JSON value. Numbers keep their literal text ("10", "1.5"), so encoding gives back what
/// was read and `intValue` is nil for "1.0", as in kotlinx.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    // MARK: Primitive access (kotlinx `JsonPrimitive` semantics)

    /// A primitive's text: a string's characters, a number's literal, "true"/"false", "null";
    /// nil for arrays and objects.
    var content: String? {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        case .array, .object: return nil
        }
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var isPrimitive: Bool { content != nil }

    /// A string value's text (nil for every other kind).
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }

    /// kotlinx `intOrNull`: the primitive's content read as a whole number ("12" as a string too).
    var intValue: Int? {
        guard let text = content, !isNull else { return nil }
        return Int(text)
    }

    /// kotlinx `booleanOrNull`: content exactly "true" or "false".
    var boolValue: Bool? {
        switch content {
        case "true"?: return true
        case "false"?: return false
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var objectValue: JSONObject? { if case .object(let o) = self { return o } else { return nil } }

    // MARK: Encoding

    /// Compact JSON text (kotlinx `toString()`).
    var encoded: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.quote(s, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 { out += "," }
                Self.quote(entry.key, into: &out)
                out += ":"
                entry.value.write(into: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: Parsing

    /// Strict JSON (one value, surrounding whitespace allowed); nil when malformed.
    static func parse(_ text: String) -> JSONValue? {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skipSpace()
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        return parser.atEnd ? value : nil
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var depth = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }

        mutating func skipSpace() {
            while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\r" || s[i] == "\t" { i += 1 }
        }

        mutating func value() -> JSONValue? {
            guard i < s.count else { return nil }
            switch s[i] {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map(JSONValue.string)
            case "t": return literal("true", .bool(true))
            case "f": return literal("false", .bool(false))
            case "n": return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ result: JSONValue) -> JSONValue? {
            let scalars = Array(word.unicodeScalars)
            guard i + scalars.count <= s.count, Array(s[i..<(i + scalars.count)]) == scalars else { return nil }
            i += scalars.count
            return result
        }

        mutating func number() -> JSONValue? {
            let start = i
            if i < s.count, s[i] == "-" { i += 1 }
            var digits = 0
            while i < s.count, ("0"..."9").contains(s[i]) { i += 1; digits += 1 }
            guard digits > 0 else { return nil }
            if i < s.count, s[i] == "." {
                i += 1
                var fraction = 0
                while i < s.count, ("0"..."9").contains(s[i]) { i += 1; fraction += 1 }
                guard fraction > 0 else { return nil }
            }
            if i < s.count, s[i] == "e" || s[i] == "E" {
                i += 1
                if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
                var exponent = 0
                while i < s.count, ("0"..."9").contains(s[i]) { i += 1; exponent += 1 }
                guard exponent > 0 else { return nil }
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: s[start..<i])
            return .number(text)
        }

        mutating func string() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                i += 1
                switch c {
                case "\"":
                    return String(out)
                case "\\":
                    guard i < s.count else { return nil }
                    let e = s[i]
                    i += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard var code = hex4() else { return nil }
                        if (0xD800..<0xDC00).contains(code), i + 1 < s.count, s[i] == "\\", s[i + 1] == "u" {
                            i += 2
                            guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { return nil }
                        out.append(scalar)
                    default:
                        return nil
                    }
                default:
                    if c.value < 0x20 { return nil }
                    out.append(c)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= s.count else { return nil }
            var text = ""
            text.unicodeScalars.append(contentsOf: s[i..<(i + 4)])
            i += 4
            return UInt32(text, radix: 16)
        }

        mutating func array() -> JSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { return nil }
            i += 1
            var values: [JSONValue] = []
            skipSpace()
            if i < s.count, s[i] == "]" { i += 1; return .array(values) }
            while true {
                skipSpace()
                guard let v = value() else { return nil }
                values.append(v)
                skipSpace()
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "]" { i += 1; return .array(values) }
                return nil
            }
        }

        mutating func object() -> JSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 200 else { return nil }
            i += 1
            var object = JSONObject()
            skipSpace()
            if i < s.count, s[i] == "}" { i += 1; return .object(object) }
            while true {
                skipSpace()
                guard let key = string() else { return nil }
                skipSpace()
                guard i < s.count, s[i] == ":" else { return nil }
                i += 1
                skipSpace()
                guard let v = value() else { return nil }
                object[key] = v
                skipSpace()
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "}" { i += 1; return .object(object) }
                return nil
            }
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(String(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

/// A JSON object that keeps key order for encoding; equality and hashing ignore the order.
struct JSONObject: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    struct Entry: Hashable, Sendable {
        var key: String
        var value: JSONValue
    }

    private(set) var entries: [Entry] = []

    init() {}

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    var keys: [String] { entries.map(\.key) }
    var isEmpty: Bool { entries.isEmpty }

    func contains(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// Setting an existing key replaces its value in place; nil removes it.
    subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }

    var encoded: String { JSONValue.object(self).encoded }

    static func == (a: JSONObject, b: JSONObject) -> Bool {
        guard a.entries.count == b.entries.count else { return false }
        return a.entries.allSatisfy { entry in b[entry.key] == entry.value }
    }

    func hash(into hasher: inout Hasher) {
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            hasher.combine(entry.key)
            hasher.combine(entry.value)
        }
    }
}
