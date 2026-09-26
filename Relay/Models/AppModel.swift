//
//  AppModel.swift
//  Relay
//

import Foundation

// MARK: - App

/// One app from a subscription (or a BoxJS built-in), projected leniently from its JSON.
struct AppModel: Identifiable {
    var id: String
    let name: String
    let author: String
    /// `author` exactly as JavaScript stringifies it (a missing author is
    /// `"undefined"`): the web UI names shared ids `${app.author}_${app.id}`, and
    /// favorites and sessions saved there use that name.
    let webAuthor: String
    let repo: String?
    let descs: [String]?
    let keys: [String]?
    var icons: [String]
    let desc: String?
    let script: String?
    /// Seconds; passed through when running `script` (web UI parity).
    let scriptTimeout: Double?
    let scripts: [RunScript]?

    let desc_html: String?
    let descs_html: [String]?
    var settings: [Setting]?

    var favIcon: String?
    var icon: String?
    var favIconColor: String?
    var isFav: Bool?

    var hasDescription: Bool {
        !(desc ?? "").isEmpty || !(descs ?? []).isEmpty
            || !(desc_html ?? "").isEmpty || !(descs_html ?? []).isEmpty
    }
}

extension AppModel {
    /// `nil` when the entry has no usable `id`: without one an app cannot be favorited,
    /// linked to sessions, or told apart from its neighbours. The web UI rejects the
    /// entire subscription in that case; here only the one entry is skipped.
    ///
    /// Identifiers are kept byte for byte (never trimmed): BoxJS and the web UI compare
    /// them exactly, and a setting's id is the key its value is stored under.
    init?(_ fields: JSONFields, path: String, report: inout DecodeReport) {
        guard let id = fields.string("id") else {
            report.note(path, "缺少 id，已跳过\(fields.string("name").map { "（\($0)）" } ?? "")")
            return nil
        }
        self.id = id
        name = fields.string("name") ?? id
        author = fields.text("author", joinedBy: ", ") ?? "@anonymous"
        webAuthor = fields["author"]?.jsString ?? "undefined"
        repo = fields.string("repo")
        descs = fields.strings("descs")
        keys = fields.strings("keys")
        icons = fields.strings("icons") ?? []
        icon = fields.string("icon")
        desc = fields.text("desc")
        script = fields.string("script")
        scriptTimeout = fields.number("script_timeout")

        // Some publishers write `desc_html` as a list of paragraphs; they are joined.
        // It is not mirrored into `descs_html`: views render both fields.
        desc_html = fields.text("desc_html", joinedBy: "<br>")
        descs_html = fields.strings("descs_html")

        scripts = fields.objects("scripts", path: path, report: &report)?
            .enumerated()
            .compactMap { RunScript($0.element, path: "\(path).scripts[\($0.offset)]", report: &report) }

        var seenSettingIDs = Set<String>()
        settings = fields.objects("settings", path: path, report: &report)?
            .enumerated()
            .compactMap { entry -> Setting? in
                let settingPath = "\(path).settings[\(entry.offset)]"
                guard let setting = Setting(entry.element, path: settingPath, report: &report) else { return nil }
                // Two rows writing one key would silently overwrite each other on save.
                guard seenSettingIDs.insert(setting.id).inserted else {
                    report.note(settingPath, "设置 id 重复（\(setting.id)），已跳过")
                    return nil
                }
                return setting
            }

        favIcon = nil
        favIconColor = nil
        isFav = nil
    }

    /// Projection without diagnostics, for single-object imports.
    init?(json: JSONValue) {
        guard let fields = JSONFields(json) else { return nil }
        var report = DecodeReport()
        self.init(fields, path: "app", report: &report)
    }

    func withIcon(_ icons: [String], _ icon: String, isFav: Bool) -> AppModel {
        var newApp = self
        newApp.icons = icons
        newApp.icon = icon
        newApp.isFav = isFav
        return newApp
    }

    /// Returns the icon URL appropriate for the current appearance.
    /// `icons[0]` = dark (Alpha), `icons[1]` = light (Color). Falls back to the other when missing.
    func adaptiveIconURL(isDark: Bool) -> URL? {
        let urlString: String? = if isDark {
            icons.first ?? icon
        } else {
            (icons.count > 1 ? icons[1] : icons.first) ?? icon
        }
        return urlString.flatMap { URL(string: $0) }
    }
}

// MARK: - Script

struct RunScript {
    var name: String
    var script: String
    /// Seconds; passed through when running the script (web UI parity).
    var timeout: Double?
}

extension RunScript {
    /// `nil` without a script address, since there is nothing to run. A missing name
    /// falls back to the script's file name rather than dropping the entry.
    init?(_ fields: JSONFields, path: String, report: inout DecodeReport) {
        guard let script = fields.trimmedString("script") else {
            report.note(path, "脚本缺少 script 地址，已跳过")
            return nil
        }
        self.script = script
        name = fields.string("name")
            ?? URL(string: script)?.lastPathComponent.nilIfEmpty
            ?? script
        timeout = fields.number("script_timeout") ?? fields.number("timeout")
    }
}

// MARK: - Setting

/// How a setting is edited. BoxJS keys this on free-form `type` text, and publishers
/// use aliases and typos (`texearea`, `" string"`, `int`), so the text is normalized
/// here once instead of being string-matched in every view.
enum SettingKind: Equatable {
    case boolean
    case text
    case textarea
    case number
    case slider
    case colorpicker
    case radios
    case checkboxes
    /// `selects` and `modalSelects`: one choice from a menu.
    case selects

    init(rawType: String?) {
        switch rawType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "boolean", "bool", "checkbox":
            self = .boolean
        case "textarea", "texearea":
            self = .textarea
        case "number", "int", "integer":
            self = .number
        case "slider":
            self = .slider
        case "colorpicker", "color":
            self = .colorpicker
        case "radios", "radio":
            self = .radios
        case "checkboxes":
            self = .checkboxes
        case "selects", "select", "modalselects":
            self = .selects
        default:
            // The web UI renders every other type as a text field.
            self = .text
        }
    }

    var hasOptions: Bool {
        switch self {
        case .radios, .checkboxes, .selects: return true
        default: return false
        }
    }
}

struct RadioItem: Identifiable, Hashable {
    let key: String
    let label: String

    var id: String { key }
}

struct Setting: Identifiable {
    let id: String
    let name: String?
    /// The current value, in whatever JSON shape BoxJS returned it. Views read it
    /// through `JSONValue`'s coercions; saving converts it with `wireText`.
    var val: JSONValue
    let desc: String?
    let placeholder: String?
    /// The publisher's `type` text, trimmed. Use `kind` to decide how to edit it.
    let type: String?
    let kind: SettingKind
    /// Resolved options for `radios`/`checkboxes`/`selects`.
    var items: [RadioItem]?
    /// When `items` was given as text, the text itself. The web UI treats it as the
    /// key of a stored value holding the options, which is resolved against `datas`
    /// once they are available (see `BoxDataResp.loadAppBaseInfo`).
    let itemsKey: String?
    let sliderRange: ClosedRange<Double>
    let sliderStep: Double
}

extension Setting {
    /// `nil` without an `id`: the id is the key the value is saved under.
    init?(_ fields: JSONFields, path: String, report: inout DecodeReport) {
        guard let id = fields.string("id") else {
            report.note(path, "设置缺少 id，已跳过")
            return nil
        }
        self.id = id
        name = fields.string("name")
        val = fields["val"] ?? .null
        desc = fields.text("desc")
        placeholder = fields.string("placeholder")
        type = fields.trimmedString("type")
        kind = SettingKind(rawType: type)

        switch fields["items"] {
        case .string(let text)?:
            itemsKey = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            items = SettingItemsParser.items(fromText: text)
        case let value?:
            itemsKey = nil
            items = SettingItemsParser.items(from: value)
        case nil:
            itemsKey = nil
            items = nil
        }
        if kind.hasOptions, items == nil, itemsKey == nil {
            report.note(path, "\(id) 缺少可选项 items")
        }

        var lower = fields.number("min") ?? 0
        var upper = fields.number("max") ?? 100
        if lower >= upper { (lower, upper) = (0, 100) }
        // Never let the slider clamp (and so silently rewrite) an existing value.
        if let current = val.numberValue {
            lower = min(lower, current)
            upper = max(upper, current)
        }
        sliderRange = lower...upper
        let step = fields.number("step") ?? 1
        sliderStep = step > 0 ? step : 1
    }
}

/// Reads setting options in every shape found in published subscriptions.
enum SettingItemsParser {
    /// - `[{"key": "a", "label": "A"}]`, the documented form. Keys are stringified
    ///   (`1` → `"1"`, `null` → `""`), matching what the web UI saves for them; a
    ///   missing label falls back to the key.
    /// - `["a", "b"]`, which the web UI's menus accept.
    /// - `{"a": "A"}`, a key-to-label map.
    /// - JSON text of any of the above, which is how scripts often store options.
    /// - Legacy `"a@A\nb@B"` lines.
    static func items(from value: JSONValue) -> [RadioItem]? {
        switch value {
        case .array(let entries):
            return deduplicated(entries.compactMap(item(from:)))
        case .object(let map):
            return deduplicated(map.keys.sorted().map { key in
                RadioItem(key: key, label: map[key]?.scalarText?.nilIfEmpty ?? key)
            })
        case .string(let text):
            return items(fromText: text)
        case .null, .bool, .number:
            return nil
        }
    }

    static func items(fromText text: String) -> [RadioItem]? {
        if let decoded = JSONValue.string(text).decodedJSONText {
            return items(from: decoded)
        }
        return legacyLines(text)
    }

    private static func item(from entry: JSONValue) -> RadioItem? {
        switch entry {
        case .object(let fields):
            let keyValue = fields["key"] ?? fields["value"] ?? fields["id"]
            let key = keyValue?.scalarText ?? ""
            let label = (fields["label"] ?? fields["text"] ?? fields["name"] ?? fields["title"])?
                .scalarText?.nilIfEmpty
            guard keyValue != nil || label != nil else { return nil }
            return RadioItem(key: key, label: label ?? (key.isEmpty ? "（空）" : key))
        case .string, .number, .bool:
            guard let text = entry.scalarText else { return nil }
            return RadioItem(key: text, label: text)
        case .null, .array:
            return nil
        }
    }

    /// `key@label` per line. A leading `@` means the text is a data key such as
    /// `@gist.revision_options`, not a list.
    private static func legacyLines(_ text: String) -> [RadioItem]? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let parsed = lines.compactMap { line -> RadioItem? in
            guard let separator = line.firstIndex(of: "@"), separator != line.startIndex else { return nil }
            let key = String(line[..<separator])
            let label = String(line[line.index(after: separator)...])
            return RadioItem(key: key, label: label.isEmpty ? key : label)
        }
        guard !parsed.isEmpty, parsed.count == lines.count else { return nil }
        return deduplicated(parsed)
    }

    /// Two options with one key cannot be told apart once saved; keep the first.
    private static func deduplicated(_ items: [RadioItem]) -> [RadioItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.key).inserted }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
