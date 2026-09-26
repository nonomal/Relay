//
//  SubscriptionModels.swift
//  Relay
//

import Foundation

// MARK: - Subscription entry (usercfgs.appsubs)

/// One entry of `usercfgs.appsubs`: a subscription the user added.
struct AppSub {
    let url: String
    let enable: Bool
    let id: String?

    // MARK: 非接口返回

    var isErr: Bool?

    /// The entry as BoxJS stores it. Rewriting the list (reordering) sends this back,
    /// so fields written by the web UI or other clients survive.
    let raw: [String: JSONValue]

    init(url: String, enable: Bool = true, id: String? = nil, raw: [String: JSONValue] = [:]) {
        self.url = url
        self.enable = enable
        self.id = id
        self.raw = raw
    }

    /// `nil` without a `url`: BoxJS keys the subscription's cache by it, so an entry
    /// without one can never load (the web UI lists it as a broken subscription).
    init?(_ fields: JSONFields, path: String, report: inout DecodeReport) {
        // Kept exactly as stored: BoxJS keys the cache and deletes entries by exact match.
        guard let url = fields.string("url") else {
            report.note(path, "订阅缺少 url，已忽略")
            return nil
        }
        self.url = url
        enable = fields.bool("enable") ?? true
        id = fields.string("id")
        isErr = fields.bool("isErr")
        raw = fields.raw
    }

    /// The entry to store, keeping every field BoxJS had for it.
    var jsonValue: JSONValue {
        var object = raw
        object["url"] = .string(url)
        object["enable"] = .bool(enable)
        if let id { object["id"] = .string(id) }
        return .object(object)
    }
}

// MARK: - Subscription cache (appSubCaches)

/// A downloaded subscription as cached by BoxJS under its URL.
struct AppSubCache: Identifiable {
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

    /// What was wrong with the published JSON, so the list can explain a subscription
    /// that shows fewer apps than its author intended.
    var issues: [DecodeIssue]

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
        raw: AppSub? = nil,
        issues: [DecodeIssue] = []
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
        self.issues = issues
    }

    /// Defaults follow the web UI: `匿名订阅`, `@anonymous`, and the URL standing in
    /// for a missing repository link.
    init(_ fields: JSONFields, cacheKey: String, path: String) {
        var report = DecodeReport()
        id = fields.string("id") ?? ""
        name = fields.string("name") ?? "匿名订阅"
        icon = fields.string("icon") ?? ""
        author = fields.text("author", joinedBy: ", ") ?? "@anonymous"
        repo = fields.string("repo") ?? ""
        updateTime = BoxTimestamp.normalize(fields["updateTime"]) ?? ""

        // Aggregating subscriptions reuse ids for different apps. All are kept; the
        // display layer renames them apart (see `BoxDataResp.displayAppSubCaches`).
        var seenAppIDs = Set<String>()
        apps = (fields.objects("apps", path: path, report: &report) ?? [])
            .enumerated()
            .compactMap { entry -> AppModel? in
                let appPath = "\(path).apps[\(entry.offset)]"
                guard let app = AppModel(entry.element, path: appPath, report: &report) else { return nil }
                if !seenAppIDs.insert(app.id).inserted {
                    report.note(appPath, "应用 id 重复（\(app.id)），已重命名以便区分")
                }
                return app
            }
        if !fields.has("apps") {
            report.note(path, "缺少 apps 列表")
        }

        isErr = fields.bool("isErr")
        enable = fields.bool("enable")
        url = fields.string("url") ?? cacheKey
        // Some caches carry the subscription entry under `raw`; a bare URL string there is ignored.
        raw = fields.object("raw").flatMap { AppSub($0, path: "\(path).raw", report: &report) }
        issues = report.issues
    }

    var formatTime: String {
        formattedTimeDifference(from: updateTime)
    }

    /// Usable when it produced at least one app.
    var isValid: Bool {
        !apps.isEmpty
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
    /// Problems found in the published JSON (entries skipped, fields ignored).
    var issueCount: Int = 0
}
