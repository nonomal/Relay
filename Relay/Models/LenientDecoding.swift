//
//  LenientDecoding.swift
//  Relay
//

import Foundation

// MARK: - Decode report

/// A place where a payload strayed from the BoxJS shape, and what the projection did
/// about it. Recorded instead of thrown, so one malformed third-party entry is
/// explained in the log rather than costing the user the rest of their data.
struct DecodeIssue: Hashable, Sendable {
    /// Where in the payload, e.g. `appSubCaches[https://…/x.json].apps[3]`.
    let path: String
    let message: String

    var description: String { "\(path): \(message)" }
}

/// Collects `DecodeIssue`s while a payload is projected into models.
struct DecodeReport: Sendable {
    private(set) var issues: [DecodeIssue] = []

    mutating func note(_ path: String, _ message: String) {
        issues.append(DecodeIssue(path: path, message: message))
    }

    mutating func append(contentsOf other: DecodeReport) {
        issues.append(contentsOf: other.issues)
    }
}

// MARK: - Field reader

/// Never-failing typed reads over one JSON object, following the web UI's conventions:
/// a field that is absent, `null` or of an unexpected type yields `nil` (so the caller
/// applies the same default the web UI would) instead of failing the whole object.
struct JSONFields {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue]) {
        self.raw = raw
    }

    /// `nil` unless the value is an object.
    init?(_ value: JSONValue) {
        guard let raw = value.objectValue else { return nil }
        self.raw = raw
    }

    subscript(key: String) -> JSONValue? {
        raw[key]
    }

    func has(_ key: String) -> Bool {
        raw[key].map { !$0.isNull } ?? false
    }

    /// Non-blank text. Numbers and Booleans are stringified the way JavaScript would
    /// render them; for an array, its first non-blank item is used.
    func string(_ key: String) -> String? {
        guard let value = raw[key] else { return nil }
        switch value {
        case .array(let items):
            return items.lazy.compactMap(\.scalarText).first(where: Self.isNotBlank)
        default:
            return value.scalarText.flatMap { Self.isNotBlank($0) ? $0 : nil }
        }
    }

    /// Like `string(_:)`, with surrounding whitespace removed. For identifiers and
    /// enumerations, where `" text"` and `"text"` must mean the same thing.
    func trimmedString(_ key: String) -> String? {
        string(key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Text that may be split across an array (descriptions): items are joined.
    func text(_ key: String, joinedBy separator: String = "\n") -> String? {
        guard let value = raw[key] else { return nil }
        switch value {
        case .array(let items):
            let parts = items.compactMap(\.scalarText).filter(Self.isNotBlank)
            return parts.isEmpty ? nil : parts.joined(separator: separator)
        default:
            return value.scalarText.flatMap { Self.isNotBlank($0) ? $0 : nil }
        }
    }

    /// A list of strings: an array's non-blank scalar items, or a single scalar.
    func strings(_ key: String) -> [String]? {
        guard let value = raw[key] else { return nil }
        switch value {
        case .array(let items):
            return items.compactMap(\.scalarText).filter(Self.isNotBlank)
        case .null, .object:
            return nil
        default:
            return value.scalarText.flatMap { Self.isNotBlank($0) ? [$0] : nil }
        }
    }

    func bool(_ key: String) -> Bool? {
        raw[key]?.boolValue
    }

    func number(_ key: String) -> Double? {
        raw[key]?.numberValue
    }

    func object(_ key: String) -> JSONFields? {
        raw[key].flatMap(JSONFields.init)
    }

    /// The object entries of a list. Some publishers write the list as an object keyed
    /// by id instead of an array; its values are used in that case. Entries that are
    /// not objects are skipped and reported.
    func objects(_ key: String, path: String, report: inout DecodeReport) -> [JSONFields]? {
        guard let value = raw[key] else { return nil }
        let entries: [(label: String, value: JSONValue)]
        switch value {
        case .array(let items):
            entries = items.enumerated().map { ("\($0.offset)", $0.element) }
        case .object(let fields):
            report.note("\(path).\(key)", "应为数组，实际是对象，已按其中的值读取")
            entries = fields.keys.sorted().map { ($0, fields[$0]!) }
        case .null:
            return nil
        default:
            report.note("\(path).\(key)", "应为数组，实际是 \(value.typeName)，已忽略")
            return nil
        }
        return entries.compactMap { entry in
            guard let fields = JSONFields(entry.value) else {
                report.note("\(path).\(key)[\(entry.label)]", "应为对象，实际是 \(entry.value.typeName)，已跳过")
                return nil
            }
            return fields
        }
    }

    private static func isNotBlank(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Timestamps

enum BoxTimestamp {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// BoxJS writes `new Date()` through `JSON.stringify`, which yields ISO-8601 text.
    /// Scripts sometimes write epoch numbers instead (milliseconds, occasionally
    /// seconds); those are normalized to the same ISO form so every consumer parses
    /// one format.
    static func normalize(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let epoch = Double(trimmed), trimmed.count >= 9 {
                return isoString(epoch: epoch)
            }
            return trimmed.isEmpty ? nil : trimmed
        case .number(let epoch):
            return isoString(epoch: epoch)
        default:
            return nil
        }
    }

    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func isoString(epoch: Double) -> String? {
        guard epoch.isFinite, epoch > 0 else { return nil }
        // Anything past 10^11 cannot be seconds (that is the year 5138): treat as ms.
        let seconds = epoch > 100_000_000_000 ? epoch / 1000 : epoch
        return isoFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
