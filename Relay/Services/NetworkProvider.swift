//
//  NetworkProvider.swift
//  NEBox
//

import Alamofire
import Foundation
import Moya

// MARK: - Request Error

enum RequestError: Error {
    case networkFail
    case statusFail(code: Int, message: String)
    case decodeFail(message: String)
    /// A BoxJS handler threw; BoxJS then answers with the bare text `"BoxJs"` instead
    /// of data. Whatever the handler stored before failing is kept, so callers that
    /// change data should reload rather than assume nothing happened.
    case boxjsFailed

    /// The request may have been applied even though its response could not be used.
    var mayHaveBeenApplied: Bool {
        switch self {
        case .decodeFail, .boxjsFailed: return true
        case .networkFail, .statusFail: return false
        }
    }
}

extension RequestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .networkFail: return "网络连接失败"
        case .statusFail(_, let message): return message
        case .decodeFail(let message): return "数据解析失败: \(message)"
        case .boxjsFailed: return "BoxJS 处理请求时出错，详见 BoxJS 脚本日志"
        }
    }
}

// MARK: - Response Mapping

extension Response {
    /// Checks the HTTP status and, for `/api/*` calls, BoxJS's `{ code, message }`
    /// error envelope, then projects the body into `T`.
    ///
    /// Only a body that is not JSON at all can fail here. Every well-formed body is
    /// projected leniently (see `JSONProjectable`): BoxJS data is written by many
    /// parties, and one unexpected field must not cost the user the whole response.
    func mapBoxJS<T: JSONProjectable>(_ type: T.Type, checksEnvelope: Bool) throws -> T {
        let filtered = try filterSuccessfulStatusCodes()

        let json: JSONValue
        do {
            json = try JSONValue.parse(filtered.data)
        } catch {
            let raw = String(decoding: filtered.data.prefix(500), as: UTF8.self)
            appLog(.error, category: .network, "Response for \(String(describing: T.self)) is not JSON. Raw: \(raw)")
            throw RequestError.decodeFail(message: Self.describeNonJSONBody(filtered.data, error: error))
        }

        // The envelope is only an API error shape. Query results are user data, and a
        // stored key that happens to be called `code` must not read as a failure.
        if checksEnvelope, let code = json["code"]?.numberValue, code != 0, json["message"] != nil {
            let message = json["message"]?.scalarText ?? "Unknown error"
            appLog(.error, category: .network, "BoxJS business code failed: code=\(JSONValue.format(code)), message=\(message)")
            throw RequestError.statusFail(code: Int(exactly: code.rounded(.towardZero)) ?? -1, message: message)
        }

        // Never project a body that is not a response: an empty model would replace
        // the app's state, and anything written back from it would erase user data.
        guard T.accepts(json) else {
            if case .string(let text) = json {
                appLog(.error, category: .network, "BoxJS handler failed for \(String(describing: T.self)): \(text.prefix(100))")
                throw RequestError.boxjsFailed
            }
            throw RequestError.decodeFail(message: "BoxJS 返回了意外的数据（\(json.typeName)）")
        }
        return T(json: json)
    }

    /// Explains the usual reasons BoxJS answers with something other than JSON.
    private static func describeNonJSONBody(_ data: Data, error: Error) -> String {
        let text = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "BoxJS 返回了空内容"
        }
        if text.hasPrefix("<") {
            return "BoxJS 返回的是网页而不是数据，请检查地址是否为 BoxJS 的访问地址"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Provider

enum NetworkProvider {
    private static let session: Alamofire.Session = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30
        return Alamofire.Session(configuration: configuration)
    }()

    static let shared = MoyaProvider<BoxJSAPI>(session: session)

    /// Generic async request with BoxJS envelope validation.
    static func request<T: JSONProjectable>(_ target: BoxJSAPI) async throws -> T {
        let fullURL = "\(ApiManager.shared.baseURL)\(target.path)"
        appLog(.info, category: .network, "→ \(target.method.rawValue) \(fullURL)")
        let response: Response
        do {
            response = try await shared.request(target)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appLog(.error, category: .network, "✗ \(fullURL) network fail: \(msg)")
            throw RequestError.networkFail
        }
        appLog(.info, category: .network, "← \(fullURL) \(response.statusCode)")
        do {
            return try response.mapBoxJS(T.self, checksEnvelope: target.path.hasPrefix("/api/"))
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appLog(.error, category: .network, "✗ \(fullURL) map/decode fail: \(msg)")
            throw error
        }
    }
}

// MARK: - MoyaProvider async extension

extension MoyaProvider {
    func request(_ target: Target) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            self.request(target) { result in
                switch result {
                case .success(let response):
                    continuation.resume(returning: response)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
