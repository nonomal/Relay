//
//  ApiRequest.swift
//  NEBox
//
//  Created by Senku on 7/12/24.
//

import AnyCodable
import CryptoKit
import Foundation

/// High-level API helpers that contain business logic (parameter assembly, encoding).
/// For simple pass-through calls, use `NetworkProvider.request(.endpoint)` directly.
enum ApiRequest {

    // MARK: - Subscriptions

    static func addAppSub(url: String) async throws -> BoxDataResp {
        try await validateSubscriptionSource(url: url)
        return try await NetworkProvider.request(.addAppSub(url: url, id: UUID().uuidString))
    }

    /// Maximum accepted size for a pasted subscription payload (mirrors the backend cap).
    private static let maxRawSubBytes = 512 * 1024

    /// URL schemes allowed in subscription/app repos, icons, and executable scripts.
    /// A pasted subscription has no verifiable origin, so we reject anything but plain
    /// https to keep `javascript:`/`data:`/`file:` payloads out of the executable paths.
    private static let allowedEmbeddedSchemes: Set<String> = ["https"]

    /// Adds a subscription from raw JSON pasted by the user (no remote URL).
    /// Validation is intentionally stricter than the tolerant decode used when reading
    /// data back from the trusted backend, because this input is untrusted.
    static func addAppSubRaw(json: String, name: String? = nil) async throws -> BoxDataResp {
        let storageID = try validatePastedSubscription(json: json)
        return try await NetworkProvider.request(.addAppSubRaw(json: json, id: storageID, name: name))
    }

    /// Validates a pasted subscription and returns a namespaced cache key that cannot
    /// accidentally be treated as a refreshable remote URL by the backend.
    /// Throws `RequestError.statusFail` with a user-facing message on any problem.
    @discardableResult
    private static func validatePastedSubscription(json: String) throws -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RequestError.statusFail(code: -1, message: "订阅内容为空")
        }
        guard trimmed.utf8.count <= maxRawSubBytes else {
            throw RequestError.statusFail(code: -1, message: "订阅内容过大")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw RequestError.statusFail(code: -1, message: "订阅内容不是合法 JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw RequestError.statusFail(code: -1, message: "订阅内容不是合法 JSON 对象")
        }

        guard let id = (dict["id"] as? String), !id.isEmpty else {
            throw RequestError.statusFail(code: -1, message: "订阅缺少 id 字段")
        }
        guard dict["apps"] is [Any] else {
            throw RequestError.statusFail(code: -1, message: "订阅 apps 字段格式错误")
        }

        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedID == id else {
            throw RequestError.statusFail(code: -1, message: "订阅 id 不能包含首尾空格")
        }
        guard URLComponents(string: normalizedID)?.scheme == nil else {
            throw RequestError.statusFail(code: -1, message: "订阅 id 不能是链接")
        }

        let subscription: AppSubCache
        do {
            subscription = try JSONDecoder().decode(AppSubCache.self, from: Data(trimmed.utf8))
        } catch {
            throw RequestError.statusFail(
                code: -1,
                message: "订阅字段不完整或格式错误（应用至少需要 id、name 和 icons）"
            )
        }
        guard subscription.apps.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RequestError.statusFail(code: -1, message: "订阅包含缺少 id 的应用")
        }

        try validateEmbeddedURLs(in: subscription)
        return manualStorageID(for: normalizedID)
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

    private static func validateSubscriptionSource(url: String) async throws {
        guard let requestURL = URL(string: url) else {
            throw RequestError.statusFail(code: -1, message: "订阅地址无效")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RequestError.statusFail(code: -1, message: "订阅地址响应异常")
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw RequestError.statusFail(code: http.statusCode, message: "订阅地址请求失败")
            }

            let hasContent = !data.isEmpty &&
                !String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            guard hasContent else {
                throw RequestError.statusFail(code: -1, message: "订阅地址暂无可用数据")
            }
        } catch let error as RequestError {
            throw error
        } catch {
            throw RequestError.networkFail
        }
    }

    // MARK: - Sessions

    static func saveSessions(_ sessions: [Session]) async throws -> BoxDataResp {
        let key = "chavy_boxjs_sessions"
        let data = try JSONEncoder().encode(sessions)
        let val = String(data: data, encoding: .utf8) ?? "[]"
        let parameters = [SessionData(key: key, val: AnyCodable(val))]
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
        let bakJSON = try JSONSerialization.jsonObject(with: Data(bakData.utf8))
        let bak: [String: Any] = [
            "id": UUID().uuidString,
            "name": name,
            "createTime": ISO8601DateFormatter().string(from: Date()),
            "bak": bakJSON
        ]
        return try await NetworkProvider.request(.impGlobalBak(bak: bak))
    }
}
