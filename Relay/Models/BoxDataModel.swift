//
//  BoxDataModel.swift
//  BoxJs
//
//  Created by Senku on 7/16/24.
//

import AnyCodable
import Foundation

struct AppSubCache: Codable, Identifiable {
    let id: String
    var name: String
    let icon: String
    var author: String
    var repo: String
    var updateTime: String
    var apps: [AppModel]
    
    // AppSub Struct
    var isErr: Bool?
    var enable: Bool?
    var url: String?
    var raw: AppSub?

    init(
        id: String,
        name: String,
        icon: String,
        author: String,
        repo: String,
        updateTime: String,
        apps: [AppModel],
        isErr: Bool? = nil,
        enable: Bool? = nil,
        url: String? = nil,
        raw: AppSub? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.author = author
        self.repo = repo
        self.updateTime = updateTime
        self.apps = apps
        self.isErr = isErr
        self.enable = enable
        self.url = url
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case author
        case repo
        case updateTime
        case apps
        case isErr
        case enable
        case url
        case raw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = c.decodeFlexibleString(forKey: .id) ?? ""
        name = c.decodeFlexibleString(forKey: .name) ?? "匿名订阅"
        icon = c.decodeFlexibleString(forKey: .icon) ?? ""
        author = c.decodeFlexibleString(forKey: .author) ?? "@anonymous"
        repo = c.decodeFlexibleString(forKey: .repo) ?? ""
        updateTime = c.decodeFlexibleString(forKey: .updateTime) ?? ""
        // Skip malformed apps rather than failing the whole subscription.
        let decodedApps = c.decodeLenientArray(AppModel.self, forKey: .apps)
        apps = decodedApps?.elements ?? []
        if let skipped = decodedApps?.skippedCount, skipped > 0 {
            appLog(.warning, category: .network,
                   "[AppSubCache] skipped \(skipped) malformed app(s) in subscription \(name)")
        }

        isErr = try c.decodeIfPresent(Bool.self, forKey: .isErr)
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable)
        url = c.decodeFlexibleString(forKey: .url)

        // BoxJS ecosystem has mixed formats here:
        // - object: { "enable": true, "url": "...", ... }
        // - string: "https://..."
        // Keep object when possible and gracefully ignore string format.
        if let rawSub = try? c.decodeIfPresent(AppSub.self, forKey: .raw) {
            raw = rawSub
        } else {
            raw = nil
        }
    }
    
    var formatTime: String {
        return formattedTimeDifference(from: self.updateTime)
    }
}

func formattedTimeDifference(from isoDateString: String) -> String {
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    guard let date = isoFormatter.date(from: isoDateString) else {
        return "Invalid date"
    }

    let calendar = Calendar.current
    let now = Date()

    if calendar.isDateInToday(date) {
        let components = calendar.dateComponents([.minute, .hour], from: date, to: now)

        if let hours = components.hour, hours > 0 {
            return "\(hours)小时前"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)分钟前"
        } else {
            return "刚刚"
        }
    } else {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd"
        return dateFormatter.string(from: date)
    }
}

extension AppSubCache {
    var isValid: Bool {
        return !apps.isEmpty && apps.allSatisfy { !$0.id.isEmpty }
    }
}

/// Lightweight projection of a subscription for the list page.
/// Contains only display fields + URL for navigation — no [AppModel] array.
struct AppSubSummary: Identifiable {
    let id: String
    let name: String
    let icon: String
    let updateTime: String
    let appCount: Int
    let repo: String
    let url: String?
}

struct RunScript: Codable {
    var name: String
    var script: String
}

struct RadioItem: Codable, Identifiable {
    let key: String
    let label: String
    
    var id: String { key }
}

struct Setting: Codable {
    let id: String
    let name: String?
    var val: AnyCodable?
    let desc: String?
    let placeholder: String?
    let type: String?
    let items: [RadioItem]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        val = try c.decodeIfPresent(AnyCodable.self, forKey: .val)
        desc = try c.decodeIfPresent(String.self, forKey: .desc)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        type = try c.decodeIfPresent(String.self, forKey: .type)

        // items can be [RadioItem] or a "key@label\n..." string
        if let arr = try? c.decodeIfPresent([RadioItem].self, forKey: .items) {
            items = arr
        } else if let str = try? c.decodeIfPresent(String.self, forKey: .items) {
            items = str.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "@")
                guard parts.count >= 2 else { return nil }
                return RadioItem(key: parts[0], label: parts[1])
            }
        } else {
            items = nil
        }
    }
}

/// Decodes an array element-by-element, dropping entries that fail to decode.
///
/// Subscription JSON is hand-authored and frequently malformed in ways no field-level
/// tolerance can anticipate (a missing `id`, an object where a list belongs). Without
/// this, one bad app anywhere in `boxdata` fails the whole response and the app is left
/// with no data at all. Skipping the bad entry keeps every valid one usable.
struct LenientArray<Element: Decodable>: Decodable {
    let elements: [Element]
    /// Number of entries that failed to decode and were skipped.
    let skippedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        if let count = container.count {
            elements.reserveCapacity(count)
        }
        var skipped = 0
        while !container.isAtEnd {
            // A failed decode must still consume the element, or the loop never advances.
            // Decoding into an opaque placeholder is what moves the cursor forward.
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                skipped += 1
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        self.elements = elements
        self.skippedCount = skipped
    }
}

/// Consumes exactly one element of any shape without interpreting it.
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {
        // Succeeds for any JSON value, so a malformed element is always consumed.
        _ = try? decoder.singleValueContainer()
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array, skipping elements that fail. Returns nil when the key is absent
    /// or the value is not an array at all.
    func decodeLenientArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key
    ) -> (elements: [Element], skippedCount: Int)? {
        guard let wrapper = try? decodeIfPresent(LenientArray<Element>.self, forKey: key) else {
            return nil
        }
        return (wrapper.elements, wrapper.skippedCount)
    }
}

/// Subscription JSON is hand-authored, so fields documented as strings are
/// sometimes published as arrays of strings (and vice versa). Decoding either
/// shape keeps one malformed app from failing the entire boxdata payload.
extension KeyedDecodingContainer {
    /// Decodes a string that may arrive as `"a"`, `["a", "b"]`, or be absent.
    /// Arrays are joined so no authored content is silently dropped.
    func decodeFlexibleString(forKey key: Key, joinedBy separator: String = "\n") -> String? {
        if let single = try? decodeIfPresent(String.self, forKey: key) {
            return single
        }
        if let many = try? decodeIfPresent([String].self, forKey: key) {
            return many.isEmpty ? nil : many.joined(separator: separator)
        }
        return nil
    }

    /// Decodes a string array that may arrive as a bare `"a"`, or be absent.
    func decodeFlexibleStringArray(forKey key: Key) -> [String]? {
        if let many = try? decodeIfPresent([String].self, forKey: key) {
            return many
        }
        if let single = try? decodeIfPresent(String.self, forKey: key) {
            return [single]
        }
        return nil
    }
}

struct AppModel: Codable, Identifiable {
    var id: String
    let name: String
    let author: String
    let repo: String?
    let descs: [String]?
    let keys: [String]?
    var icons: [String]
    let desc: String?
    let script: String?
    let scripts: [RunScript]?

    let desc_html: String?
    let descs_html: [String]?
    var settings: [Setting]?
    
    var favIcon: String?
    var icon: String?
    var favIconColor: String?
    var isFav: Bool?
    var hasDescription: Bool {
        return (desc != nil && !desc!.isEmpty) ||
               (descs != nil && !descs!.isEmpty) ||
               (desc_html != nil && !desc_html!.isEmpty) ||
               (descs_html != nil && !descs_html!.isEmpty)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = c.decodeFlexibleString(forKey: .author) ?? "@anonymous"
        // Published as an array by some subscriptions (e.g. cenbomin.box.json).
        repo = c.decodeFlexibleString(forKey: .repo)
        descs = c.decodeFlexibleStringArray(forKey: .descs)
        keys = c.decodeFlexibleStringArray(forKey: .keys)
        // Some subscriptions omit `icons` entirely; a single missing key must not
        // fail the whole boxdata decode. `icon` is used as the fallback source.
        icons = c.decodeFlexibleStringArray(forKey: .icons) ?? []
        desc = c.decodeFlexibleString(forKey: .desc)
        script = c.decodeFlexibleString(forKey: .script)
        scripts = try c.decodeIfPresent([RunScript].self, forKey: .scripts)

        // Some subscriptions return `desc_html` as [String] instead of String.
        // Keep backward compatibility by accepting both shapes.
        desc_html = c.decodeFlexibleString(forKey: .desc_html, joinedBy: "<br>")
        descs_html = c.decodeFlexibleStringArray(forKey: .descs_html)
            ?? c.decodeFlexibleStringArray(forKey: .desc_html)

        settings = try c.decodeIfPresent([Setting].self, forKey: .settings)
        favIcon = c.decodeFlexibleString(forKey: .favIcon)
        icon = c.decodeFlexibleString(forKey: .icon)
        favIconColor = c.decodeFlexibleString(forKey: .favIconColor)
        isFav = try c.decodeIfPresent(Bool.self, forKey: .isFav)
    }
}

extension AppModel {
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
            icons.first ?? (icons.count > 1 ? icons[1] : nil) ?? icon
        } else {
            (icons.count > 1 ? icons[1] : icons.first) ?? icon
        }
        return urlString.flatMap { URL(string: $0) }
    }
}

struct UserConfig: Codable {
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
}

extension UserConfig {
    /// 合并覆盖（`nil` 表示保留原值），供乐观更新使用
    func with(
        appsubs: [AppSub]? = nil,
        favapps: [String]? = nil,
        bgimgs: String? = nil,
        bgimg: String? = nil,
        name: String? = nil,
        icon: String? = nil,
        viewkeys: [String]? = nil,
        gist_cache_key: [String]? = nil,
        theme: String? = nil,
        color_light_primary: String? = nil,
        color_dark_primary: String? = nil,
        isTransparentIcons: Bool? = nil,
        isWallpaperMode: Bool? = nil,
        isMute: Bool? = nil,
        isMuteQueryAlert: Bool? = nil,
        isHideHelp: Bool? = nil,
        isHideBoxIcon: Bool? = nil,
        isHideMyTitle: Bool? = nil,
        isHideCoding: Bool? = nil,
        isHideRefresh: Bool? = nil,
        isDebugWeb: Bool? = nil,
        lang: String? = nil,
        httpapi: String? = nil,
        httpapis: String? = nil
    ) -> UserConfig {
        UserConfig(
            appsubs: appsubs ?? self.appsubs,
            favapps: favapps ?? self.favapps,
            bgimgs: bgimgs ?? self.bgimgs,
            bgimg: bgimg ?? self.bgimg,
            name: name ?? self.name,
            icon: icon ?? self.icon,
            viewkeys: viewkeys ?? self.viewkeys,
            gist_cache_key: gist_cache_key ?? self.gist_cache_key,
            theme: theme ?? self.theme,
            color_light_primary: color_light_primary ?? self.color_light_primary,
            color_dark_primary: color_dark_primary ?? self.color_dark_primary,
            isTransparentIcons: isTransparentIcons ?? self.isTransparentIcons,
            isWallpaperMode: isWallpaperMode ?? self.isWallpaperMode,
            isMute: isMute ?? self.isMute,
            isMuteQueryAlert: isMuteQueryAlert ?? self.isMuteQueryAlert,
            isHideHelp: isHideHelp ?? self.isHideHelp,
            isHideBoxIcon: isHideBoxIcon ?? self.isHideBoxIcon,
            isHideMyTitle: isHideMyTitle ?? self.isHideMyTitle,
            isHideCoding: isHideCoding ?? self.isHideCoding,
            isHideRefresh: isHideRefresh ?? self.isHideRefresh,
            isDebugWeb: isDebugWeb ?? self.isDebugWeb,
            lang: lang ?? self.lang,
            httpapi: httpapi ?? self.httpapi,
            httpapis: httpapis ?? self.httpapis
        )
    }

    /// `pathSuffix` 为 `usercfgs.` 之后的片段，如 `isMute`
    func updating(pathSuffix: String, value: Any) -> UserConfig? {
        switch pathSuffix {
        case "isMute":
            guard let v = value as? Bool else { return nil }
            return with(isMute: v)
        case "isMuteQueryAlert":
            guard let v = value as? Bool else { return nil }
            return with(isMuteQueryAlert: v)
        case "httpapi":
            guard let v = value as? String else { return nil }
            return with(httpapi: v)
        case "favapps":
            guard let v = value as? [String] else { return nil }
            return with(favapps: v)
        case "appsubs":
            guard let v = value as? [AppSub] else { return nil }
            return with(appsubs: v)
        case "name":
            guard let v = value as? String else { return nil }
            return with(name: v)
        case "icon":
            guard let v = value as? String else { return nil }
            return with(icon: v)
        case "viewkeys":
            guard let v = value as? [String] else { return nil }
            return with(viewkeys: v)
        case "gist_cache_key":
            guard let v = value as? [String] else { return nil }
            return with(gist_cache_key: v)
        case "bgimg":
            guard let v = value as? String else { return nil }
            return with(bgimg: v)
        case "bgimgs":
            guard let v = value as? String else { return nil }
            return with(bgimgs: v)
        case "isWallpaperMode":
            guard let v = value as? Bool else { return nil }
            return with(isWallpaperMode: v)
        case "theme":
            guard let v = value as? String else { return nil }
            return with(theme: v)
        case "color_light_primary":
            guard let v = value as? String else { return nil }
            return with(color_light_primary: v)
        case "color_dark_primary":
            guard let v = value as? String else { return nil }
            return with(color_dark_primary: v)
        default:
            return nil
        }
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

struct AppSub: Codable {
    let enable: Bool
    let id: String?
    let url: String
    
    // MARK: 非接口返回
    
    var isErr: Bool?
}

struct SessionData: Codable {
    let key: String
    let val: AnyCodable?
}

struct Session: Codable, Identifiable {
    let id: String
    var name: String
    let enable: Bool
    let appId: String
    let appName: String
    let createTime: String
    var datas: [SessionData]
}

struct GlobalBackup: Codable, Identifiable {
    let id: String
    var name: String
    let createTime: String?
    let tags: [String]?
    var bak: AnyCodable?
}

struct DataQueryResp: Codable {
    let val: AnyCodable?
}

/// Declared in an extension so the memberwise initializer stays synthesized —
/// `replacingUsercfgs`/`replacingSessions` and the view model both rely on it.
extension BoxDataResp {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // A single malformed subscription or app must not cost the user every
        // other one, so both collections drop only the entries that fail.
        var caches: [String: AppSubCache] = [:]
        if let rawCaches = try? c.decodeIfPresent([String: AppSubCache].self, forKey: .appSubCaches) {
            caches = rawCaches
        } else if let keyed = try? c.nestedContainer(keyedBy: AnyStringKey.self, forKey: .appSubCaches) {
            for key in keyed.allKeys {
                if let cache = try? keyed.decode(AppSubCache.self, forKey: key) {
                    caches[key.stringValue] = cache
                } else {
                    appLog(.warning, category: .network,
                           "[BoxDataResp] skipped malformed subscription: \(key.stringValue)")
                }
            }
        }
        appSubCaches = caches

        datas = (try? c.decodeIfPresent([String: AnyCodable?].self, forKey: .datas)) ?? [:]
        sessions = c.decodeLenientArray(Session.self, forKey: .sessions)?.elements ?? []
        usercfgs = try? c.decodeIfPresent(UserConfig.self, forKey: .usercfgs)

        let decodedSysApps = c.decodeLenientArray(AppModel.self, forKey: .sysapps)
        sysapps = decodedSysApps?.elements ?? []
        if let skipped = decodedSysApps?.skippedCount, skipped > 0 {
            appLog(.warning, category: .network, "[BoxDataResp] skipped \(skipped) malformed sysapp(s)")
        }

        globalbaks = c.decodeLenientArray(GlobalBackup.self, forKey: .globalbaks)?.elements
        curSessions = try? c.decodeIfPresent([String: String].self, forKey: .curSessions)
        syscfgs = try? c.decodeIfPresent(SysCfgs.self, forKey: .syscfgs)
    }
}

/// Dynamic key for containers whose keys are arbitrary strings (subscription URLs).
private struct AnyStringKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct BoxDataResp: Codable {
    let appSubCaches: [String: AppSubCache]
    let datas: [String: AnyCodable?]
    var sessions: [Session]
    let usercfgs: UserConfig?
    let sysapps: [AppModel]
    let globalbaks: [GlobalBackup]?
    let curSessions: [String: String]?
    let syscfgs: SysCfgs?
    
    var appsubs: [AppSub] {
        return usercfgs?.appsubs ?? []
    }
    
    var displayAppSubCaches: [String: AppSubCache] {
        // Collect all app IDs and find duplicates using a Set (O(n) instead of O(n²))
        var seen = Set<String>()
        var duplicateIds = Set<String>()
        for appSub in appsubs {
            if let sub = appSubCaches[appSub.url], !(appSub.isErr ?? false) {
                for app in sub.apps {
                    if !seen.insert(app.id).inserted {
                        duplicateIds.insert(app.id)
                    }
                }
            }
        }

        // Only clone caches that contain duplicate IDs
        guard !duplicateIds.isEmpty else { return appSubCaches }

        var updatedAppSubCaches = appSubCaches
        for appSub in appsubs {
            if var sub = updatedAppSubCaches[appSub.url], !(appSub.isErr ?? false) {
                let hasDup = sub.apps.contains { duplicateIds.contains($0.id) }
                if hasDup {
                    sub.apps = sub.apps.map { app in
                        guard duplicateIds.contains(app.id) else { return app }
                        var cloneApp = app
                        cloneApp.id = "\(app.author)_\(app.id)"
                        return cloneApp
                    }
                    updatedAppSubCaches[appSub.url] = sub
                }
            }
        }
        return updatedAppSubCaches
    }
    
    /// Lightweight summaries for the subscription list — no [AppModel] cloning.
    var displayAppSubSummaries: [AppSubSummary] {
        return appsubs.map { sub in
            let cacheSub = appSubCaches[sub.url]
            let isValid = cacheSub?.isValid == true
            let appCount = isValid ? (cacheSub?.apps.count ?? 0) : 0
            return AppSubSummary(
                id: (cacheSub?.id ?? sub.id) ?? "",
                name: cacheSub?.name ?? "匿名订阅",
                icon: cacheSub?.icon ?? "",
                updateTime: cacheSub?.updateTime ?? "",
                appCount: appCount,
                repo: cacheSub?.repo ?? sub.url,
                url: sub.url
            )
        }
    }

    /// Full subscription data — only called when navigating into a detail page.
    func displayAppSubDetail(for url: String) -> AppSubCache? {
        guard let appSub = appsubs.first(where: { $0.url == url }),
              let cacheSub = appSubCaches[url],
              cacheSub.isValid,
              !(appSub.isErr ?? false) else { return nil }
        return AppSubCache(
            id: cacheSub.id,
            name: cacheSub.name,
            icon: cacheSub.icon,
            author: cacheSub.author,
            repo: cacheSub.repo,
            updateTime: cacheSub.updateTime,
            apps: cacheSub.apps.map { loadAppBaseInfo($0) },
            isErr: appSub.isErr,
            enable: cacheSub.enable ?? appSub.enable,
            url: url,
            raw: appSub
        )
    }
    
    var displaySysApps: [AppModel] {
        return sysapps.map { app in
            loadAppBaseInfo(app)
        }
    }
    
    var apps: [AppModel] {
        // Use displayAppSubCaches directly — apps inside already have corrected IDs.
        // Only call loadAppBaseInfo once per app (not twice via displayAppSubs).
        let subApps = appsubs.flatMap { appSub -> [AppModel] in
            guard let sub = displayAppSubCaches[appSub.url], !(appSub.isErr ?? false) else { return [] }
            return sub.apps.map { loadAppBaseInfo($0) }
        }
        return subApps + displaySysApps
    }
    var favApps: [AppModel] {
        var favapps: [AppModel] = []
        if let favAppIds = usercfgs?.favapps, !favAppIds.isEmpty {
            for favId in favAppIds {
                if let app = apps.first(where: { $0.id == favId }) {
                    favapps.append(app)
                }
            }
        }
        return favapps
    }
    
    func loadAppDataInfo(for app: AppModel) -> AppDataInfo {
        var appDatas: [SessionData] = []
        if let keys = app.keys {
            for key in keys {
                let val = datas[key] ?? nil
                appDatas.append(SessionData(key: key, val: val))
            }
        }
        let appSessions = sessions.filter { $0.appId == app.id }
        var curSession: Session? = nil
        if let curSessionId = curSessions?[app.id] {
            curSession = sessions.first { $0.id == curSessionId }
        }
        return AppDataInfo(datas: appDatas, sessions: appSessions, curSession: curSession)
    }

    func loadAppBaseInfo(_ app: AppModel) -> AppModel {
        var icons = app.icons

        if icons.contains(where: { $0.contains("/Orz-3/task/master/") }) {
            if icons.indices.contains(0) {
                icons[0] = icons[0].replacingOccurrences(of: "/Orz-3/mini/master/", with: "/Orz-3/mini/master/Alpha/")
            }
            if icons.indices.contains(1) {
                icons[1] = icons[1].replacingOccurrences(of: "/Orz-3/task/master/", with: "/Orz-3/mini/master/Color/")
            }
        }
        let isFav = usercfgs?.favapps.contains(app.id) ?? false

        let newApp = app.withIcon(icons, icons.last ?? icons.first ?? "", isFav: isFav)
        return newApp
    }

    func replacingUsercfgs(_ usercfgs: UserConfig?) -> BoxDataResp {
        BoxDataResp(
            appSubCaches: appSubCaches,
            datas: datas,
            sessions: sessions,
            usercfgs: usercfgs,
            sysapps: sysapps,
            globalbaks: globalbaks,
            curSessions: curSessions,
            syscfgs: syscfgs
        )
    }

    func replacingSessions(_ sessions: [Session]) -> BoxDataResp {
        BoxDataResp(
            appSubCaches: appSubCaches,
            datas: datas,
            sessions: sessions,
            usercfgs: usercfgs,
            sysapps: sysapps,
            globalbaks: globalbaks,
            curSessions: curSessions,
            syscfgs: syscfgs
        )
    }

    func replacingCurSessions(_ curSessions: [String: String]?) -> BoxDataResp {
        BoxDataResp(
            appSubCaches: appSubCaches,
            datas: datas,
            sessions: sessions,
            usercfgs: usercfgs,
            sysapps: sysapps,
            globalbaks: globalbaks,
            curSessions: curSessions,
            syscfgs: syscfgs
        )
    }

    func replacingDatas(_ datas: [String: AnyCodable?]) -> BoxDataResp {
        BoxDataResp(
            appSubCaches: appSubCaches,
            datas: datas,
            sessions: sessions,
            usercfgs: usercfgs,
            sysapps: sysapps,
            globalbaks: globalbaks,
            curSessions: curSessions,
            syscfgs: syscfgs
        )
    }
}


struct AppDataInfo {
    var datas: [SessionData]
    var sessions: [Session]
    var curSession: Session?
}

struct ScriptResp: Codable {
    var exception: String?
    var output: String?
}

struct VersionNote: Codable {
    let name: String
    let descs: [String]
}

struct VersionInfo: Codable, Identifiable {
    let version: String
    let notes: [VersionNote]
    var id: String { version }
}

struct VersionsResp: Codable {
    let releases: [VersionInfo]?
}

// Add syscfgs to BoxDataResp
struct SysEnv: Codable, Identifiable {
    let id: String
    let icons: [String]?
}

struct SysCfgs: Codable {
    let version: String?
    let env: String?
    let envs: [SysEnv]?
    let versionType: String?
}
