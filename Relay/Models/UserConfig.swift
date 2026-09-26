//
//  UserConfig.swift
//  Relay
//

import Foundation

/// `usercfgs`: the user's BoxJS preferences and subscription list.
///
/// Every field is written by several parties — the web UI, this app, scripts calling
/// `$.setdata('true', '@chavy_boxjs_userCfgs.isMute')`, older BoxJS versions — so each
/// is read leniently. One odd field must never hide the rest: if this object failed
/// as a whole, every subscription and favorite would disappear with it.
struct UserConfig {
    /// The object as BoxJS stores it. Optimistic updates patch it and project again,
    /// so a locally applied change follows exactly the rules of a fetched one.
    let raw: [String: JSONValue]

    let appsubs: [AppSub]
    let favapps: [String]
    let bgimgs: String?
    let bgimg: String?
    let name: String?
    let icon: String?
    let viewkeys: [String]?
    let gist_cache_key: [String]?
    // Preferences
    /// 外观模式：`light` / `dark` / `auto`（缺省即 `auto`，跟随系统）。
    /// 它同时决定 `color_light_primary` 与 `color_dark_primary` 哪个生效。
    let theme: String?
    /// 浅色下的主题色，BoxJs 存十六进制串（默认 `#F7BB0E`）
    let color_light_primary: String?
    /// 深色下的主题色，BoxJs 存十六进制串（默认 `#2196F3`）
    let color_dark_primary: String?
    let isTransparentIcons: Bool?
    let isWallpaperMode: Bool?
    let isMute: Bool?
    let isMuteQueryAlert: Bool?
    let isHideHelp: Bool?
    let isHideBoxIcon: Bool?
    let isHideMyTitle: Bool?
    let isHideCoding: Bool?
    let isHideRefresh: Bool?
    let isDebugWeb: Bool?
    let lang: String?
    /// Surge HTTP-API 地址，如 `examplekey@127.0.0.1:6166`
    let httpapi: String?
    /// 逗号分隔的候选列表；有值时 UI 用选择器，否则为自由输入
    let httpapis: String?

    /// Entries of `appsubs` that could not be used, and why.
    let issues: [DecodeIssue]

    static let empty = UserConfig(raw: [:])

    init(raw: [String: JSONValue]) {
        self.raw = raw
        let fields = JSONFields(raw)
        var report = DecodeReport()

        appsubs = (fields.objects("appsubs", path: "usercfgs", report: &report) ?? [])
            .enumerated()
            .compactMap { AppSub($0.element, path: "usercfgs.appsubs[\($0.offset)]", report: &report) }
        favapps = fields.strings("favapps") ?? []
        bgimgs = fields.text("bgimgs")
        bgimg = fields.string("bgimg")
        name = fields.string("name")
        icon = fields.string("icon")
        viewkeys = fields.strings("viewkeys")
        gist_cache_key = fields.strings("gist_cache_key")
        theme = fields.trimmedString("theme")
        color_light_primary = fields.trimmedString("color_light_primary")
        color_dark_primary = fields.trimmedString("color_dark_primary")
        isTransparentIcons = fields.bool("isTransparentIcons")
        isWallpaperMode = fields.bool("isWallpaperMode")
        isMute = fields.bool("isMute")
        isMuteQueryAlert = fields.bool("isMuteQueryAlert")
        isHideHelp = fields.bool("isHideHelp")
        isHideBoxIcon = fields.bool("isHideBoxIcon")
        isHideMyTitle = fields.bool("isHideMyTitle")
        isHideCoding = fields.bool("isHideCoding")
        isHideRefresh = fields.bool("isHideRefresh")
        isDebugWeb = fields.bool("isDebugWeb")
        lang = fields.trimmedString("lang")
        httpapi = fields.trimmedString("httpapi")
        // A list stored as an array still means "comma-separated candidates".
        httpapis = fields.text("httpapis", joinedBy: ",")
        issues = report.issues
    }

    /// The stored `appsubs` list rearranged to follow `urls`, for `usercfgs.appsubs`.
    ///
    /// Built from the stored entries rather than from `appsubs`, so nothing the list
    /// view does not show is lost: duplicates stay together, and entries this client
    /// could not read (no `url`) keep their place at the end.
    func appsubsJSON(orderedBy urls: [String]) -> JSONValue {
        let stored = raw["appsubs"]?.arrayValue ?? []
        var rank: [String: Int] = [:]
        for (index, url) in urls.enumerated() where rank[url] == nil {
            rank[url] = index
        }
        let ordered = stored.enumerated().sorted { lhs, rhs in
            let lhsRank = lhs.element["url"]?.scalarText.flatMap { rank[$0] } ?? Int.max
            let rhsRank = rhs.element["url"]?.scalarText.flatMap { rank[$0] } ?? Int.max
            return (lhsRank, lhs.offset) < (rhsRank, rhs.offset)
        }
        return .array(ordered.map(\.element))
    }

    /// The config with `value` written at `path` (`usercfgs.` already removed, e.g.
    /// `favapps` or `a.b`), mirroring the backend's `update()` for `/api/update`.
    func updating(path: String, value: JSONValue) -> UserConfig {
        let keys = path.split(separator: ".").map(String.init)
        guard !keys.isEmpty else { return self }
        return UserConfig(raw: Self.setting(value, at: keys[...], in: raw))
    }

    private static func setting(_ value: JSONValue, at keys: ArraySlice<String>,
                                in object: [String: JSONValue]) -> [String: JSONValue] {
        guard let key = keys.first else { return object }
        var object = object
        if keys.count == 1 {
            object[key] = value
        } else {
            let child = object[key]?.objectValue ?? [:]
            object[key] = .object(setting(value, at: keys.dropFirst(), in: child))
        }
        return object
    }
}

/// BoxJs 的外观模式，决定两个主题色哪个生效。
enum BoxThemeMode: String, CaseIterable {
    case auto
    case light
    case dark

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// `auto` 跟随系统，其余强制。
    func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .auto: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }
}

extension UserConfig {
    /// BoxJs 偏好设置里的出厂值，`nil` / 空串时回落到它。
    static let defaultLightPrimary = "#F7BB0E"
    static let defaultDarkPrimary = "#2196F3"

    /// `theme` 缺省或非法值时按 `auto`（跟随系统）处理。
    ///
    /// 刻意与网页版不同：网页版 `isDarkMode` 把 `isDark` 初始化为 `true`，
    /// 于是未设置时落到「深色」。原生端跟随 iOS 外观才是对的行为——
    /// 未配置过就强制深色会盖掉系统设置。只有显式的 `light` / `dark` 才强制。
    var themeMode: BoxThemeMode {
        guard let theme, let mode = BoxThemeMode(rawValue: theme) else { return .auto }
        return mode
    }

    /// 解析出当前该用的主题色十六进制串。空串视为未设置。
    func resolvedPrimaryHex(isDark: Bool) -> String {
        let raw = isDark ? color_dark_primary : color_light_primary
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return isDark ? Self.defaultDarkPrimary : Self.defaultLightPrimary
        }
        return raw
    }
}

/// 壁纸清单里的一项。BoxJS 用 `usercfgs.bgimgs` 存储，格式为
/// `名字,链接` 每行一条，其中 `无,`（空链接）表示关闭壁纸。
struct WallpaperOption: Identifiable, Equatable {
    let name: String
    /// 存进 `bgimg` 的值：图片地址，或 `跟随系统` 这类哨兵值
    let value: String

    var id: String { "\(name)\u{1}\(value)" }

    /// BoxJS 用 `跟随系统` 作为哨兵，表示按深浅色分别取清单里的
    /// `light` / `dark` 两项，而不是把它本身当图片地址请求。
    static let systemSentinel = "跟随系统"

    var isSystemFollow: Bool { value == Self.systemSentinel }

    /// 仅当它是真实图片地址时才可用于预览/加载
    var imageURL: URL? {
        guard !isSystemFollow, let url = URL(string: value) else { return nil }
        return url
    }
}

extension UserConfig {
    /// 解析 `bgimgs` 清单；跳过「无」这类空值项，由 UI 单独提供关闭入口
    var wallpaperOptions: [WallpaperOption] {
        guard let raw = bgimgs, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        return raw.components(separatedBy: .newlines).compactMap { line -> WallpaperOption? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // 只按第一个逗号切分，链接本身可能含逗号
            let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return WallpaperOption(name: name.isEmpty ? value : name, value: value)
        }
    }

    /// 按名字取清单项的地址，供「跟随系统」解析 `light` / `dark` 使用
    private func wallpaperValue(named name: String) -> String? {
        wallpaperOptions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.isSystemFollow }?.value
    }

    /// 解析出当前实际要显示的壁纸地址。
    /// `bgimg` 为 `跟随系统` 时按深浅色取清单里的 `dark` / `light` 项。
    func resolvedWallpaperURL(isDark: Bool) -> URL? {
        guard let bgimg, !bgimg.isEmpty else { return nil }
        guard bgimg != WallpaperOption.systemSentinel else {
            let preferred = isDark ? "dark" : "light"
            let fallback = isDark ? "light" : "dark"
            guard let value = wallpaperValue(named: preferred) ?? wallpaperValue(named: fallback) else { return nil }
            return URL(string: value)
        }
        return URL(string: bgimg)
    }
}
