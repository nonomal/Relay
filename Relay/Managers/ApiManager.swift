//
//  ApiManager.swift
//  NEBox
//
//  Created by Senku on 10/16/24.
//
import SwiftUI

class ApiManager: ObservableObject {
    static let shared = ApiManager()
    static let defaultAPIURL = "https://boxjs.com"

    @Published var apiUrl: String? {
        didSet {
            if let url = apiUrl {
                UserDefaults.standard.set(url, forKey: "apiUrl")
                appLog(.info, category: .app, "[ApiManager] apiUrl updated: \(url)")
            } else {
                UserDefaults.standard.removeObject(forKey: "apiUrl")
                appLog(.warning, category: .app, "[ApiManager] apiUrl cleared")
            }
        }
    }

    init() {
        self.apiUrl = UserDefaults.standard.string(forKey: "apiUrl")
        appLog(.info, category: .app, "[ApiManager] restored apiUrl: \(self.apiUrl ?? "nil")")
    }

    func isApiUrlSet() -> Bool {
        return apiUrl != nil && !apiUrl!.isEmpty
    }

    /// Returns the base URL with no trailing slash, e.g. `ApiManager.defaultAPIURL`
    var baseURL: String {
        guard let url = apiUrl, !url.isEmpty else { return Self.defaultAPIURL }
        let normalized = Self.normalizeHost(url)
        return normalized.isEmpty ? Self.defaultAPIURL : normalized
    }

    /// Normalizes a user-entered host into an API base URL.
    ///
    /// The BoxJS web UI is a fragment-routed SPA, so its address bar reads
    /// `http://host/#/`. Pasting that verbatim makes every request a fragment
    /// (`/#/query/boxdata`), which the server never receives — it just returns the
    /// SPA's HTML and JSON decoding fails on `<`. Drop the fragment, and any
    /// trailing slashes left behind.
    static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIndex = host.firstIndex(of: "#") {
            host = String(host[host.startIndex..<hashIndex])
        }
        while host.hasSuffix("/") {
            host = String(host.dropLast())
        }
        return host
    }
}
