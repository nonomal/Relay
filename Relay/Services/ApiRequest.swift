//
//  ApiRequest.swift
//  NEBox
//
//  Created by Senku on 7/12/24.
//

import CryptoKit
import Foundation

/// High-level API helpers that contain business logic (parameter assembly, encoding).
/// For simple pass-through calls, use `NetworkProvider.request(.endpoint)` directly.
enum ApiRequest {

    // MARK: - Subscriptions

    /// Adds a subscription by URL.
    ///
    /// The source is fetched here first, so a URL that cannot work fails with a reason
    /// instead of leaving a broken 匿名订阅 entry behind. If BoxJS then cannot cache a
    /// source this app did read — `JSON.parse` in BoxJS rejects a UTF-8 byte-order mark,
    /// BoxJS discards a subscription without `id`, and the proxy may not reach a host
    /// the phone can — the copy read here is stored under the same URL instead.
    /// Refreshing keeps fetching the URL, and BoxJS keeps this copy until one succeeds.
    static func addAppSub(url: String) async throws -> BoxDataResp {
        let source = try await fetchSubscriptionSource(url: url)
        let boxdata: BoxDataResp
        do {
            boxdata = try await NetworkProvider.request(.addAppSub(url: url, id: UUID().uuidString))
        } catch RequestError.boxjsFailed {
            // BoxJS saves the entry before fetching the source, then fails the whole
            // request when it cannot reach it. Continue from what it stored.
            boxdata = try await NetworkProvider.request(.getBoxData)
        }
        guard boxdata.appSubCaches[url] == nil else { return boxdata }
        guard boxdata.appsubs.contains(where: { $0.url == url }) else {
            throw RequestError.statusFail(code: -1, message: "BoxJS 未能保存该订阅")
        }
        return try await storeFetchedCopy(source, url: url, in: boxdata)
    }

    /// For subscriptions BoxJS holds no cache for (see `addAppSub`), stores this app's
    /// own copy of each source it can read. Returns the latest box data when anything
    /// was recovered, `nil` when nothing could be.
    static func recoverUncachedSubscriptions(in boxdata: BoxDataResp, urls: [String]? = nil) async -> BoxDataResp? {
        var seen = Set<String>()
        let candidates = (urls ?? boxdata.appsubs.map(\.url)).filter { url in
            boxdata.appSubCaches[url] == nil && isRemoteURL(url) && seen.insert(url).inserted
        }
        guard !candidates.isEmpty else { return nil }

        // Fetch in parallel (dead links cost a timeout each); store one at a time,
        // because every store rewrites the subscription list.
        let sources = await withTaskGroup(of: (String, SubscriptionSource?).self) { group in
            for url in candidates {
                group.addTask { (url, try? await fetchSubscriptionSource(url: url)) }
            }
            var fetched: [String: SubscriptionSource] = [:]
            for await (url, source) in group {
                fetched[url] = source
            }
            return fetched
        }

        var latest: BoxDataResp?
        for url in candidates {
            guard let source = sources[url] else { continue }
            do {
                latest = try await storeFetchedCopy(source, url: url, in: latest ?? boxdata)
            } catch {
                appLog(.warning, category: .network, "[recoverSubscription] \(url): \(error.localizedDescription)")
            }
        }
        return latest
    }

    /// Stores `source` as the cache for `url` through `/api/addAppSubRaw`. That endpoint
    /// also appends a subscription entry of its own, so the list is written back as it
    /// was: the user's entry keeps its place and its fields.
    private static func storeFetchedCopy(_ source: SubscriptionSource, url: String,
                                         in boxdata: BoxDataResp) async throws -> BoxDataResp {
        let copy = try importableCopy(of: source, url: url)
        // The list is written back whole, so it must be one actually read from BoxJS.
        guard let appsubs = boxdata.usercfgs?.raw["appsubs"], appsubs.arrayValue?.isEmpty == false else {
            throw RequestError.statusFail(code: -1, message: "BoxJS 返回的订阅列表为空，已停止写入")
        }
        appLog(.warning, category: .network,
               "[subscription] BoxJS could not cache \(url); storing the copy fetched by Relay (\(source.bomNote))")
        let _: BoxDataResp = try await NetworkProvider.request(.addAppSubRaw(json: copy, id: url, name: nil))
        return try await NetworkProvider.request(.updateData(path: "usercfgs.appsubs", val: appsubs))
    }

    private static func isRemoteURL(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Maximum accepted size for a pasted subscription payload (mirrors the backend cap).
    private static let maxRawSubBytes = 512 * 1024

    /// URL schemes allowed in pasted subscriptions' repos, icons, and executable scripts.
    /// A pasted subscription has no verifiable origin, so anything that is not a web
    /// address (`javascript:`, `data:`, `file:`, other apps' schemes) is rejected. Plain
    /// `http` stays allowed: a subscription added by URL may point at it just the same.
    private static let allowedEmbeddedSchemes: Set<String> = ["https", "http"]

    /// Adds a subscription from raw JSON pasted by the user (no remote URL).
    /// Validation is intentionally stricter than the tolerant decode used when reading
    /// data back from the trusted backend, because this input is untrusted.
    static func addAppSubRaw(json: String, name: String? = nil) async throws -> BoxDataResp {
        let pasted = try validatePastedSubscription(json: json)
        return try await NetworkProvider.request(.addAppSubRaw(json: pasted.json, id: pasted.storageID, name: name))
    }

    /// Validates a pasted subscription. Returns it as JSON BoxJS can parse (a leading
    /// byte-order mark removed, an `apps` map turned into a list) and a namespaced
    /// cache key that cannot be mistaken for a refreshable remote URL by the backend.
    /// Throws `RequestError.statusFail` with a user-facing message on any problem.
    private static func validatePastedSubscription(json: String) throws -> (json: String, storageID: String) {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RequestError.statusFail(code: -1, message: "订阅内容为空")
        }
        guard trimmed.utf8.count <= maxRawSubBytes else {
            throw RequestError.statusFail(code: -1, message: "订阅内容过大")
        }

        let value: JSONValue
        do {
            // A leading byte-order mark is dropped by the parser; BoxJS would reject it.
            value = try JSONValue.parse(trimmed)
        } catch {
            throw RequestError.statusFail(code: -1, message: "订阅内容不是合法 JSON")
        }
        guard var object = value.objectValue else {
            throw RequestError.statusFail(code: -1, message: "订阅内容不是合法 JSON 对象")
        }

        guard let id = JSONFields(object).trimmedString("id") else {
            throw RequestError.statusFail(code: -1, message: "订阅缺少 id 字段")
        }
        guard URLComponents(string: id)?.scheme == nil else {
            throw RequestError.statusFail(code: -1, message: "订阅 id 不能是链接")
        }
        object["id"] = .string(id)

        let subscription = AppSubCache(JSONFields(object), cacheKey: id, path: "pasted")
        guard !subscription.apps.isEmpty else {
            throw RequestError.statusFail(
                code: -1,
                message: object["apps"] == nil ? "订阅缺少 apps 字段" : "订阅中没有可用的应用（应用至少需要 id）"
            )
        }
        try validateEmbeddedURLs(in: subscription)
        object["apps"] = normalizedApps(object["apps"])

        return (JSONValue.object(object).compactJSONText, manualStorageID(for: id))
    }

    /// Rejects any embedded URL whose scheme is not whitelisted (defends the
    /// `runScript`/open-repo paths against `javascript:`/`data:`/`file:` injection).
    private static func validateEmbeddedURLs(in subscription: AppSubCache) throws {
        try assertAllowedSchemeIfPresent(subscription.repo)
        try assertAllowedSchemeIfPresent(subscription.icon)

        for app in subscription.apps {
            try assertAllowedSchemeIfPresent(app.repo)
            try assertAllowedSchemeIfPresent(app.icon)
            try assertAllowedSchemeIfPresent(app.script)
            for icon in app.icons {
                try assertAllowedSchemeIfPresent(icon)
            }
            for script in app.scripts ?? [] {
                try assertAllowedSchemeIfPresent(script.script)
            }
        }
    }

    private static func assertAllowedSchemeIfPresent(_ urlString: String?) throws {
        guard let urlString,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try assertAllowedScheme(urlString)
    }

    private static func assertAllowedScheme(_ urlString: String) throws {
        let scheme = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?
            .scheme?.lowercased()
        guard let scheme, allowedEmbeddedSchemes.contains(scheme) else {
            let preview = urlString.count > 160 ? "\(urlString.prefix(160))…" : urlString
            throw RequestError.statusFail(code: -1, message: "订阅包含不受支持的链接: \(preview)")
        }
    }

    /// Stable per subscription id, so importing the same manual subscription updates it
    /// instead of creating duplicates. The non-http scheme also makes refresh a no-op.
    private static func manualStorageID(for subscriptionID: String) -> String {
        let digest = SHA256.hash(data: Data(subscriptionID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "manual://\(hex)"
    }

    // MARK: Subscription source

    /// A subscription source as fetched by this app.
    private struct SubscriptionSource {
        let object: [String: JSONValue]
        let hadBOM: Bool

        var bomNote: String { hadBOM ? "source starts with a UTF-8 BOM" : "no BOM" }
    }

    /// Fetches a subscription URL and checks it is a JSON object, explaining the usual
    /// mistakes (an HTML page instead of the raw file, an error page, an empty body).
    private static func fetchSubscriptionSource(url: String) async throws -> SubscriptionSource {
        guard isRemoteURL(url), let requestURL = URL(string: url) else {
            throw RequestError.statusFail(code: -1, message: "订阅地址无效（需以 http:// 或 https:// 开头）")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RequestError.statusFail(code: -1, message: "订阅地址响应异常")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw RequestError.statusFail(code: http.statusCode, message: "订阅地址请求失败（HTTP \(http.statusCode)）")
            }
            data = body
        } catch let error as RequestError {
            throw error
        } catch {
            throw RequestError.networkFail
        }

        let head = String(decoding: data.droppingUTF8BOM().prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else {
            throw RequestError.statusFail(code: -1, message: "订阅地址暂无可用数据")
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            let message = head.hasPrefix("<")
                ? "订阅地址返回的是网页而不是订阅 JSON，请使用原始文件（raw）地址"
                : "订阅内容不是合法 JSON"
            throw RequestError.statusFail(code: -1, message: message)
        }
        guard let object = value.objectValue else {
            throw RequestError.statusFail(code: -1, message: "订阅内容应为 JSON 对象，实际是 \(value.typeName)")
        }
        return SubscriptionSource(object: object, hadBOM: data.hasUTF8BOM)
    }

    /// The fetched source in the shape `/api/addAppSubRaw` accepts: an `id` (derived
    /// from the URL when the publisher left it out) and `apps` as a list.
    private static func importableCopy(of source: SubscriptionSource, url: String) throws -> String {
        var object = source.object
        if JSONFields(object).trimmedString("id") == nil {
            let digest = SHA256.hash(data: Data(url.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            object["id"] = .string("relay.auto.\(digest)")
        }
        object["apps"] = normalizedApps(object["apps"])
        guard object["apps"]?.arrayValue?.isEmpty == false else {
            throw RequestError.statusFail(code: -1, message: "BoxJS 无法读取该订阅，且订阅中没有应用")
        }
        let json = JSONValue.object(object).compactJSONText
        guard json.utf8.count <= maxRawSubBytes else {
            throw RequestError.statusFail(code: -1, message: "BoxJS 无法读取该订阅（\(source.hadBOM ? "文件带有 BOM 头" : "格式不受支持")），且订阅过大无法代为导入")
        }
        return json
    }

    /// `apps` as BoxJS's raw import requires it: a list. A map of apps becomes its values.
    private static func normalizedApps(_ apps: JSONValue?) -> JSONValue {
        switch apps {
        case .array(let list)?:
            return .array(list)
        case .object(let map)?:
            return .array(map.keys.sorted().compactMap { map[$0] })
        default:
            return .array([])
        }
    }

    // MARK: - Sessions

    static func saveSessions(_ sessions: [Session]) async throws -> BoxDataResp {
        let key = "chavy_boxjs_sessions"
        let val = JSONValue.array(sessions.map(\.jsonValue)).compactJSONText
        let parameters = [SessionData(key: key, val: .string(val))]
        return try await NetworkProvider.request(.saveData(params: parameters))
    }

    // MARK: - Global Backups

    static func saveGlobalBak(name: String, env: String, version: String, versionType: String) async throws -> BoxDataResp {
        let bak: [String: Any] = [
            "id": UUID().uuidString,
            "name": name,
            "env": env,
            "version": version,
            "versionType": versionType,
            "createTime": ISO8601DateFormatter().string(from: Date()),
            "tags": [env, version, versionType]
        ]
        return try await NetworkProvider.request(.saveGlobalBak(bak: bak))
    }

    static func impGlobalBak(bakData: String, name: String) async throws -> BoxDataResp {
        let bakJSON = try JSONValue.parse(bakData)
        let bak: [String: Any] = [
            "id": UUID().uuidString,
            "name": name,
            "createTime": ISO8601DateFormatter().string(from: Date()),
            "bak": bakJSON.foundationObject
        ]
        return try await NetworkProvider.request(.impGlobalBak(bak: bak))
    }
}
