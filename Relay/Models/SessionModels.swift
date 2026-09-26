//
//  SessionModels.swift
//  Relay
//

import Foundation

// MARK: - Session data

/// One stored key and its value, as BoxJS exchanges them in `/api/save` bodies and
/// inside sessions.
struct SessionData: Codable, Equatable {
    let key: String
    let val: JSONValue

    init(key: String, val: JSONValue) {
        self.key = key
        self.val = val
    }

    /// `nil` without a key: there is nothing to write the value to.
    init?(_ value: JSONValue) {
        guard let fields = JSONFields(value), let key = fields.string("key") else { return nil }
        self.key = key
        val = fields["val"] ?? .null
    }

    var jsonValue: JSONValue {
        .object(["key": .string(key), "val": val])
    }
}

// MARK: - Session

/// A saved snapshot of an app's data (`chavy_boxjs_sessions`).
///
/// The whole list is rewritten whenever one session changes, so each session keeps
/// the object it was read from. Sessions this client did not touch are written back
/// exactly as stored — including fields and value types it does not model — instead
/// of being dropped or re-encoded.
struct Session: Identifiable {
    static let defaultName = "会话"

    let id: String
    var name: String
    let enable: Bool
    let appId: String
    let appName: String
    let createTime: String
    var datas: [SessionData]
    /// The stored object; empty for a session created in this app.
    let raw: [String: JSONValue]

    init(id: String, name: String, enable: Bool, appId: String, appName: String,
         createTime: String, datas: [SessionData], raw: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.enable = enable
        self.appId = appId
        self.appName = appName
        self.createTime = createTime
        self.datas = datas
        self.raw = raw
    }

    /// Every stored session is kept, however incomplete, so that saving the list can
    /// never delete one. A missing id is replaced by a positional one for this client
    /// only; it is not written back unless the session itself is edited.
    init(_ fields: JSONFields, index: Int, path: String, report: inout DecodeReport) {
        if let id = fields.string("id") {
            self.id = id
        } else {
            id = "session-\(index)"
            report.note(path, "会话缺少 id")
        }
        name = fields.string("name") ?? Self.defaultName
        enable = fields.bool("enable") ?? true
        appId = fields.string("appId") ?? ""
        appName = fields.string("appName") ?? ""
        createTime = BoxTimestamp.normalize(fields["createTime"]) ?? ""
        datas = Self.datas(from: fields)
        raw = fields.raw
    }

    private static func datas(from fields: JSONFields) -> [SessionData] {
        (fields["datas"]?.arrayValue ?? []).compactMap(SessionData.init)
    }

    /// The object to store: the original with only what was edited replaced.
    var jsonValue: JSONValue {
        guard !raw.isEmpty else {
            return .object([
                "id": .string(id),
                "name": .string(name),
                "enable": .bool(enable),
                "appId": .string(appId),
                "appName": .string(appName),
                "createTime": .string(createTime),
                "datas": .array(datas.map(\.jsonValue)),
            ])
        }
        var object = raw
        let stored = JSONFields(raw)
        if name != (stored.string("name") ?? Self.defaultName) {
            object["name"] = .string(name)
            if stored.string("id") == nil { object["id"] = .string(id) }
        }
        if datas != Self.datas(from: stored) {
            object["datas"] = .array(datas.map(\.jsonValue))
            if stored.string("id") == nil { object["id"] = .string(id) }
        }
        return .object(object)
    }
}

extension Session: Codable {
    /// For pasted/imported sessions: any object with at least an `appId` or `datas`.
    init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let fields = JSONFields(json), fields.has("datas") || fields.has("appId") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "不是有效的会话数据"))
        }
        var report = DecodeReport()
        self.init(fields, index: 0, path: "session", report: &report)
    }

    func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }
}

/// An app's current data, its sessions, and the session last applied to it.
struct AppDataInfo {
    var datas: [SessionData]
    var sessions: [Session]
    var curSession: Session?
}

// MARK: - Global backup

/// An entry of the backup index (`globalbaks`). The backup's content is loaded
/// separately (`/query/baks/<id>`) into `bak`.
struct GlobalBackup: Identifiable {
    let id: String
    var name: String
    let createTime: String?
    let tags: [String]?
    var bak: JSONValue?

    /// `nil` without an id, since the content is addressed by it.
    init?(_ fields: JSONFields, path: String, report: inout DecodeReport) {
        guard let id = fields.string("id") else {
            report.note(path, "备份缺少 id，已忽略")
            return nil
        }
        self.id = id
        name = fields.string("name") ?? "备份"
        createTime = BoxTimestamp.normalize(fields["createTime"])
        tags = fields.strings("tags")
        bak = fields["bak"].flatMap { $0.isNull ? nil : $0 }
    }
}

extension GlobalBackup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, createTime, tags, bak
    }

    init(from decoder: Decoder) throws {
        var report = DecodeReport()
        guard let fields = JSONFields(try JSONValue(from: decoder)),
              let backup = GlobalBackup(fields, path: "backup", report: &report) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "不是有效的备份"))
        }
        self = backup
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(bak, forKey: .bak)
    }
}
