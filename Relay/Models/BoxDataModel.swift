//
//  BoxDataModel.swift
//  BoxJs
//
//  Created by Senku on 7/16/24.
//

import Foundation

// MARK: - Projection

/// A model read from a BoxJS response by projecting its JSON (see `JSONValue`)
/// instead of strict `Decodable` decoding, so an unexpected field can never fail
/// the whole response.
protocol JSONProjectable {
    init(json: JSONValue)

    /// Whether a body of this shape is a response at all. When a BoxJS handler throws,
    /// BoxJS answers with the bare text `"BoxJs"`; projecting that would produce an
    /// empty model, which would wipe the app's state — or, written back, the user's
    /// data. Defaults to requiring an object.
    static func accepts(_ json: JSONValue) -> Bool
}

extension JSONProjectable {
    static func accepts(_ json: JSONValue) -> Bool {
        json.objectValue != nil
    }
}

extension JSONValue: JSONProjectable {
    init(json: JSONValue) {
        self = json
    }

    /// Requested for backup contents, which are always structured.
    static func accepts(_ json: JSONValue) -> Bool {
        json.objectValue != nil || json.arrayValue != nil
    }
}

// MARK: - Box data

/// `/query/boxdata`, which most `/api/*` calls also return: everything BoxJS knows.
struct BoxDataResp {
    let appSubCaches: [String: AppSubCache]
    let datas: [String: JSONValue]
    var sessions: [Session]
    let usercfgs: UserConfig?
    let sysapps: [AppModel]
    let globalbaks: [GlobalBackup]?
    let curSessions: [String: String]?
    let syscfgs: SysCfgs?
    /// Everything in the payload that strayed from the BoxJS shape and was worked around.
    var issues: [DecodeIssue] = []

    var appsubs: [AppSub] {
        return usercfgs?.appsubs ?? []
    }
}

/// Declared in an extension so the memberwise initializer stays synthesized —
/// the `replacing…` helpers and the view model both rely on it.
extension BoxDataResp: JSONProjectable {
    init(json: JSONValue) {
        let fields = JSONFields(json.objectValue ?? [:])
        var report = DecodeReport()
        if json.objectValue == nil {
            report.note("boxdata", "响应不是对象（\(json.typeName)）")
        }

        var caches: [String: AppSubCache] = [:]
        for (key, value) in fields["appSubCaches"]?.objectValue ?? [:] {
            let path = "appSubCaches[\(key)]"
            guard let cacheFields = JSONFields(value) else {
                report.note(path, "订阅缓存不是对象（\(value.typeName)），已忽略")
                continue
            }
            let cache = AppSubCache(cacheFields, cacheKey: key, path: path)
            report.append(contentsOf: DecodeReport(cache.issues))
            caches[key] = cache
        }
        appSubCaches = caches

        datas = fields["datas"]?.objectValue ?? [:]

        sessions = (fields["sessions"]?.arrayValue ?? []).enumerated().compactMap { entry in
            let path = "sessions[\(entry.offset)]"
            guard let sessionFields = JSONFields(entry.element) else {
                report.note(path, "会话不是对象（\(entry.element.typeName)），已忽略")
                return nil
            }
            return Session(sessionFields, index: entry.offset, path: path, report: &report)
        }

        let config = UserConfig(raw: fields["usercfgs"]?.objectValue ?? [:])
        report.append(contentsOf: DecodeReport(config.issues))
        usercfgs = config

        sysapps = (fields.objects("sysapps", path: "boxdata", report: &report) ?? [])
            .enumerated()
            .compactMap { AppModel($0.element, path: "sysapps[\($0.offset)]", report: &report) }

        globalbaks = (fields.objects("globalbaks", path: "boxdata", report: &report) ?? [])
            .enumerated()
            .compactMap { GlobalBackup($0.element, path: "globalbaks[\($0.offset)]", report: &report) }

        // `{ appId: sessionId }`; a cleared entry may linger as null.
        curSessions = (fields["curSessions"]?.objectValue ?? [:]).compactMapValues(\.scalarText)
        syscfgs = fields.object("syscfgs").map(SysCfgs.init)
        issues = report.issues
    }
}

private extension DecodeReport {
    init(_ issues: [DecodeIssue]) {
        self.init()
        for issue in issues { note(issue.path, issue.message) }
    }
}

// MARK: - Derived data

extension BoxDataResp {
    /// Active subscriptions in list order, each URL once.
    private var activeAppSubs: [AppSub] {
        var seenURLs = Set<String>()
        return appsubs.filter { !($0.isErr ?? false) && seenURLs.insert($0.url).inserted }
    }

    var displayAppSubCaches: [String: AppSubCache] {
        // Collect all app IDs and find duplicates using a Set (O(n) instead of O(n²)).
        // Every stored entry counts, as in the web UI: a subscription added twice shares
        // all of its ids with itself, and they are renamed like any other shared id.
        var seen = Set<String>()
        var duplicateIds = Set<String>()
        for appSub in appsubs where !(appSub.isErr ?? false) {
            for app in appSubCaches[appSub.url]?.apps ?? [] where !seen.insert(app.id).inserted {
                duplicateIds.insert(app.id)
            }
        }

        // Only clone caches that contain duplicate IDs
        guard !duplicateIds.isEmpty else { return appSubCaches }

        // Same rule as the web UI: every app sharing an id is renamed `author_id`, so
        // favorites and sessions stored by the web UI still match. When that is still
        // ambiguous (one author publishing an id twice), later copies get a `#n`
        // suffix; the web UI cannot open those copies at all. Each URL is listed once.
        var assigned = Set<String>()
        var updatedAppSubCaches = appSubCaches
        for appSub in activeAppSubs {
            guard var sub = updatedAppSubCaches[appSub.url] else { continue }
            let hasDup = sub.apps.contains { duplicateIds.contains($0.id) }
            sub.apps = sub.apps.map { app in
                guard duplicateIds.contains(app.id) else {
                    assigned.insert(app.id)
                    return app
                }
                var cloneApp = app
                var newID = "\(app.webAuthor)_\(app.id)"
                if assigned.contains(newID) {
                    var n = 2
                    while assigned.contains("\(newID)#\(n)") { n += 1 }
                    newID = "\(newID)#\(n)"
                }
                assigned.insert(newID)
                cloneApp.id = newID
                return cloneApp
            }
            if hasDup {
                updatedAppSubCaches[appSub.url] = sub
            }
        }
        return updatedAppSubCaches
    }

    /// Lightweight summaries for the subscription list — no [AppModel] cloning.
    /// A URL listed twice is shown once; reordering keeps both stored entries together.
    var displayAppSubSummaries: [AppSubSummary] {
        var seenURLs = Set<String>()
        return appsubs.compactMap { sub in
            guard seenURLs.insert(sub.url).inserted else { return nil }
            let cacheSub = appSubCaches[sub.url]
            let isValid = cacheSub?.isValid == true
            let appCount = isValid ? (cacheSub?.apps.count ?? 0) : 0
            return AppSubSummary(
                // The URL is the only identity guaranteed unique: publishers reuse
                // subscription ids across mirrors, and a broken cache has none.
                id: sub.url,
                name: cacheSub?.name ?? "匿名订阅",
                icon: cacheSub?.icon ?? "",
                updateTime: cacheSub?.updateTime ?? "",
                appCount: appCount,
                repo: cacheSub.map { $0.repo.isEmpty ? sub.url : $0.repo } ?? sub.url,
                url: sub.url,
                issueCount: cacheSub?.issues.count ?? 0
            )
        }
    }

    /// Full subscription data — only called when navigating into a detail page.
    /// Built from `displayAppSubCaches`, so an app shared across subscriptions has the
    /// same id here as on Home and in Search (favorites and sessions attach to it).
    func displayAppSubDetail(for url: String) -> AppSubCache? {
        guard let appSub = appsubs.first(where: { $0.url == url }),
              let cacheSub = displayAppSubCaches[url],
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
            raw: appSub,
            issues: cacheSub.issues
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
        let caches = displayAppSubCaches
        let subApps = activeAppSubs.flatMap { appSub -> [AppModel] in
            (caches[appSub.url]?.apps ?? []).map { loadAppBaseInfo($0) }
        }
        return subApps + displaySysApps
    }

    var favApps: [AppModel] {
        favApps(in: apps)
    }

    /// Favorites in the user's order, looked up in an already built `apps` list.
    func favApps(in apps: [AppModel]) -> [AppModel] {
        guard let favAppIds = usercfgs?.favapps, !favAppIds.isEmpty else { return [] }
        var byID: [String: AppModel] = [:]
        for app in apps where byID[app.id] == nil {
            byID[app.id] = app
        }
        return favAppIds.compactMap { byID[$0] }
    }

    func loadAppDataInfo(for app: AppModel) -> AppDataInfo {
        // An unset key is recorded as "", as the web UI does: applying the snapshot must
        // clear it, and BoxJS ignores a `null` value instead of writing it.
        let appDatas = (app.keys ?? []).map { key in
            SessionData(key: key, val: datas[key].flatMap { $0.isNull ? nil : $0 } ?? "")
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

        var newApp = app.withIcon(icons, icons.last ?? icons.first ?? app.icon ?? "", isFav: isFav)
        newApp.settings = app.settings.map(resolvingItems)
        return newApp
    }

    /// Options given as text name a stored value that holds them (the web UI's
    /// `getItems`); a value found there wins over reading the text itself.
    private func resolvingItems(in settings: [Setting]) -> [Setting] {
        guard settings.contains(where: { $0.itemsKey != nil }) else { return settings }
        return settings.map { setting in
            guard let key = setting.itemsKey, let stored = datas[key], !stored.isEmptyValue,
                  let items = SettingItemsParser.items(from: stored) else { return setting }
            var resolved = setting
            resolved.items = items
            return resolved
        }
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
            syscfgs: syscfgs,
            issues: issues
        )
    }

    func replacingSessions(_ sessions: [Session]) -> BoxDataResp {
        var copy = self
        copy.sessions = sessions
        return copy
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
            syscfgs: syscfgs,
            issues: issues
        )
    }

    func replacingDatas(_ datas: [String: JSONValue]) -> BoxDataResp {
        BoxDataResp(
            appSubCaches: appSubCaches,
            datas: datas,
            sessions: sessions,
            usercfgs: usercfgs,
            sysapps: sysapps,
            globalbaks: globalbaks,
            curSessions: curSessions,
            syscfgs: syscfgs,
            issues: issues
        )
    }
}

// MARK: - Other responses

/// `/query/data/<key>` and `/api/saveData`: `{ key, val }`.
struct DataQueryResp: JSONProjectable {
    let val: JSONValue?

    init(json: JSONValue) {
        val = json["val"].flatMap { $0.isNull ? nil : $0 }
    }
}

/// `/api/runScript`. BoxJS answers `{ result, output }`; Surge's HTTP-API adds `exception`.
struct ScriptResp: JSONProjectable {
    var exception: String?
    var output: String?

    init(exception: String?, output: String?) {
        self.exception = exception
        self.output = output
    }

    init(json: JSONValue) {
        let fields = JSONFields(json.objectValue ?? [:])
        exception = fields["exception"].flatMap { $0.isNull ? nil : $0.displayText }?.nilIfEmpty
        output = fields["output"].flatMap { $0.isNull ? nil : $0.displayText }
    }

    /// A script that finishes without reporting anything yields a bare `null` body.
    static func accepts(_ json: JSONValue) -> Bool {
        json.objectValue != nil || json.isNull
    }
}

struct VersionNote {
    let name: String
    let descs: [String]
}

struct VersionInfo: Identifiable {
    let version: String
    let notes: [VersionNote]
    var id: String { version }
}

/// `/query/versions`: BoxJS's release notes.
struct VersionsResp: JSONProjectable {
    let releases: [VersionInfo]?

    init(json: JSONValue) {
        var report = DecodeReport()
        let fields = JSONFields(json.objectValue ?? [:])
        releases = fields.objects("releases", path: "versions", report: &report)?.compactMap { release in
            guard let version = release.trimmedString("version") else { return nil }
            let notes = (release.objects("notes", path: "versions", report: &report) ?? []).map { note in
                VersionNote(name: note.string("name") ?? "", descs: note.strings("descs") ?? [])
            }
            return VersionInfo(version: version, notes: notes)
        }
    }
}

struct SysEnv: Identifiable {
    let id: String
    let icons: [String]?
}

/// `syscfgs`: which proxy tool BoxJS runs in, and its version.
struct SysCfgs {
    let version: String?
    let env: String?
    let envs: [SysEnv]?
    let versionType: String?

    init(_ fields: JSONFields) {
        var report = DecodeReport()
        version = fields.string("version")
        env = fields.trimmedString("env")
        envs = fields.objects("envs", path: "syscfgs", report: &report)?.compactMap { env in
            env.trimmedString("id").map { SysEnv(id: $0, icons: env.strings("icons")) }
        }
        versionType = fields.string("versionType")
    }
}
