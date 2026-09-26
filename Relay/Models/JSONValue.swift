//
//  JSONValue.swift
//  Relay
//

import Foundation

/// A JSON value exactly as BoxJS stored it.
///
/// BoxJS is a JavaScript project. Subscriptions are written by hand by third parties,
/// and user data is written by the web UI, by scripts and by older BoxJS versions, so
/// the same field arrives as a string in one payload and as a number, array or `null`
/// in the next. Parsing into `JSONValue` never fails for well-formed JSON; the typed
/// models are then projected from it (see `LenientDecoding.swift`), the way the web UI
/// reads a plain JavaScript object.
///
/// Numbers are `Double` on purpose: that is what JavaScript stores, so precision and
/// formatting match what BoxJS itself sees.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Parsing

extension JSONValue {
    enum ParseError: LocalizedError {
        case notUTF8
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notUTF8: return "内容不是 UTF-8 文本"
            case .malformed(let reason): return "JSON 格式错误：\(reason)"
            }
        }
    }

    /// Parses a complete JSON document.
    ///
    /// A leading UTF-8 byte-order mark is skipped: Windows editors write one routinely,
    /// and it is invisible to the author even though `JSON.parse` in BoxJS rejects it.
    static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data.droppingUTF8BOM(), options: [.fragmentsAllowed])
        } catch {
            throw ParseError.malformed((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                                       ?? error.localizedDescription)
        }
        return JSONValue(foundation: object)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Converts a `JSONSerialization` result. Anything outside the JSON model becomes `null`.
    init(foundation object: Any) {
        switch object {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // JSONSerialization boxes booleans as NSNumber too; only the CFBoolean
            // singletons are real booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(foundation:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(foundation:)))
        default:
            self = .null
        }
    }

    /// The `JSONSerialization`-compatible form, for request bodies built as dictionaries.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .number(let number): return JSONValue.integerIfExact(number).map { $0 as Any } ?? number
        case .string(let string): return string
        case .array(let items): return items.map(\.foundationObject)
        case .object(let fields): return fields.mapValues(\.foundationObject)
        }
    }

    /// Integral doubles within the exactly-representable range, so they serialize as
    /// `20` rather than `20.0`.
    fileprivate static func integerIfExact(_ number: Double) -> Int64? {
        guard number.isFinite, number == number.rounded(.towardZero),
              abs(number) <= 9_007_199_254_740_992 else { return nil }
        return Int64(number)
    }
}

extension Data {
    /// The same bytes without a leading UTF-8 byte-order mark.
    func droppingUTF8BOM() -> Data {
        starts(with: [0xEF, 0xBB, 0xBF]) ? dropFirst(3) : self
    }

    var hasUTF8BOM: Bool { starts(with: [0xEF, 0xBB, 0xBF]) }
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .number(let number):
            if let integer = JSONValue.integerIfExact(number) {
                try container.encode(integer)
            } else if number.isFinite {
                try container.encode(number)
            } else {
                // JSON has no NaN/Infinity; JavaScript's JSON.stringify writes null too.
                try container.encodeNil()
            }
        case .string(let string):
            try container.encode(string)
        case .array(let items):
            try container.encode(items)
        case .object(let fields):
            try container.encode(fields)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Structure

extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Short name of the JSON type, for diagnostics and data-type chips.
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - JavaScript-faithful coercions

extension JSONValue {
    /// `String(value)` for scalars: how the web UI renders a value it treats as text.
    /// `nil` for `null`, arrays and objects.
    var scalarText: String? {
        switch self {
        case .string(let string): return string
        case .number(let number): return JSONValue.format(number)
        case .bool(let bool): return bool ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// Lodash's `_.toString`: the exact text the web UI writes when it saves a setting,
    /// and therefore the text scripts expect to read back through `$.getdata`.
    ///
    /// `null` becomes `""` and arrays become comma-joined, as in lodash. Objects become
    /// JSON rather than lodash's useless `"[object Object]"`.
    var wireText: String {
        switch self {
        case .null: return ""
        case .array(let items): return items.map(\.wireText).joined(separator: ",")
        case .object: return compactJSONText
        case .string, .number, .bool: return scalarText ?? ""
        }
    }

    /// Text for showing a stored value: strings verbatim, `null` as empty, everything
    /// else as compact JSON.
    var displayText: String {
        switch self {
        case .string(let string): return string
        case .null: return ""
        default: return compactJSONText
        }
    }

    /// The BoxJS Boolean convention: `true`/`false`, their string forms (how BoxJS
    /// persists form values), and `1`/`0`. `nil` when the value states neither.
    var boolValue: Bool? {
        switch self {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number != 0
        case .string(let string):
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        case .null, .array, .object:
            return nil
        }
    }

    /// A number, or text holding one: BoxJS stores numbers typed into forms as strings.
    var numberValue: Double? {
        switch self {
        case .number(let number):
            return number
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return nil }
            return number
        case .bool, .null, .array, .object:
            return nil
        }
    }

    /// Items of a list value: an array's scalar items, or comma-separated text, which
    /// is how BoxJS persists `checkboxes` settings.
    var listItems: [String] {
        switch self {
        case .array(let items):
            return items.compactMap(\.scalarText)
        case .string(let string):
            return string.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        case .number, .bool:
            return scalarText.map { [$0] } ?? []
        case .null, .object:
            return []
        }
    }

    /// True for `null`, empty text and empty collections: a value that says nothing.
    var isEmptyValue: Bool {
        switch self {
        case .null: return true
        case .string(let string): return string.isEmpty
        case .array(let items): return items.isEmpty
        case .object(let fields): return fields.isEmpty
        case .bool, .number: return false
        }
    }

    /// JavaScript's `String(value)`, used where the web UI builds text from a raw value
    /// (it names shared app ids `${app.author}_${app.id}`). Unlike `wireText`, `null`
    /// is `"null"` and an object is `"[object Object]"`, exactly as in JavaScript.
    var jsString: String {
        switch self {
        case .null: return "null"
        case .array(let items):
            // Array.prototype.join writes null and undefined items as empty text.
            return items.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        case .string, .number, .bool: return scalarText ?? ""
        }
    }

    /// JavaScript's `Number.prototype.toString()`: the shortest digits that round-trip
    /// (which Swift's `description` also produces), laid out by ECMAScript's rules —
    /// plain decimals from 1e-6 up to 1e21, exponent notation outside that range.
    static func format(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number == 0 { return "0" }
        if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }

        let (digits, n) = shortestDigits(abs(number))
        let k = digits.count
        let body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            let point = digits.index(digits.startIndex, offsetBy: n)
            body = digits[..<point] + "." + digits[point...]
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let exponent = n - 1
            let suffix = "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
            body = k == 1 ? digits + suffix : digits.prefix(1) + "." + digits.dropFirst() + suffix
        }
        return (number < 0 ? "-" : "") + body
    }

    /// The significant digits of a positive finite `value` and the exponent `n` with
    /// value = 0.digits × 10^n, read from Swift's shortest round-trip representation
    /// (`"123.45"`, `"0.001"`, `"1e-07"`, `"1.5e+20"`).
    private static func shortestDigits(_ value: Double) -> (digits: String, n: Int) {
        let parts = "\(value)".lowercased().split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pointOffset = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        var n = pointOffset + exponent
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            n -= 1
        }
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        return (digits, n)
    }
}

// MARK: - Serialization

extension JSONValue {
    private static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }()

    /// Single-line JSON with sorted keys, so equal values always print identically.
    var compactJSONText: String {
        (try? JSONValue.compactEncoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Indented JSON with sorted keys, for viewing and exporting.
    var prettyJSONText: String {
        (try? JSONValue.prettyEncoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Text that is itself JSON (a common way scripts store structured data) parsed
    /// into a value; `nil` when the value is not a string or the text is not JSON.
    var decodedJSONText: JSONValue? {
        guard case .string(let text) = self else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        return try? JSONValue.parse(trimmed)
    }
}
