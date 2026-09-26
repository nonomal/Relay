//
//  BoxJsViewModel.swift
//  BoxJs
//
//  Created by Senku on 7/12/24.
//

import SwiftUI

class BoxJsViewModel: ObservableObject {
    @Published var boxData: BoxDataResp {
        didSet { rebuildDerivedData() }
    }
    @Published var isDataLoaded = false

    // Cached derived data — rebuilt once per boxData change instead of
    // recomputing on every access from multiple views.
    @Published private(set) var cachedAppSubSummaries: [AppSubSummary] = []
    @Published private(set) var cachedApps: [AppModel] = []
    @Published private(set) var favApps: [AppModel] = []

    /// Set by deep link handler to request a tab switch; ContentView consumes and resets to nil.
    @Published var pendingDeepLinkTab: Int?

    private func rebuildDerivedData() {
        cachedAppSubSummaries = boxData.displayAppSubSummaries
        // Building `apps` renames shared ids and resolves icons for every app; do it once.
        let apps = boxData.apps
        cachedApps = apps
        favApps = boxData.favApps(in: apps)
        logDecodeIssuesIfChanged()
    }

    var toastManager: ToastManager?
    /// Writes queued by `updateData`, sent by `flushPendingDataUpdates`. Main-actor
    /// state: views queue writes on the main thread while a flush is running.
    @MainActor private var pendingDataUpdates: [String: JSONValue] = [:]
    /// A queued subscription order. The list itself is built when it is sent, from the
    /// subscriptions as they are then, so one added or deleted in the meantime is not
    /// dropped or brought back.
    @MainActor private var pendingAppSubOrder: [String]?
    /// The flush in progress. Operations that rewrite the subscription list wait for
    /// it, so an older list can never land after them.
    @MainActor private var runningFlush: Task<Bool, Never>?
    /// Issues already written to the log, so an unchanged payload is not re-logged on
    /// every response that carries it.
    private var loggedDecodeIssues: [DecodeIssue] = []

    init(boxData: BoxDataResp = BoxDataResp(
        appSubCaches: [:],
        datas: [:],
        sessions: [],
        usercfgs: .empty,
        sysapps: [],
        globalbaks: nil,
        curSessions: nil,
        syscfgs: nil
    )) {
        self.boxData = boxData
    }

    @MainActor
    private func updateBoxData(_ boxdata: BoxDataResp) {
        self.boxData = boxdata
    }

    @MainActor
    func reset() {
        isDataLoaded = false
    }

    /// Everything that strayed from the BoxJS shape was worked around rather than
    /// failing; log what it was, so a user's exported log explains a subscription
    /// that shows fewer apps than expected.
    private func logDecodeIssuesIfChanged() {
        let issues = boxData.issues
        guard issues != loggedDecodeIssues else { return }
        loggedDecodeIssues = issues
        guard !issues.isEmpty else { return }
        let shown = issues.prefix(20).map { "  · \($0.description)" }.joined(separator: "\n")
        let more = issues.count > 20 ? "\n  … 另有 \(issues.count - 20) 条" : ""
        appLog(.warning, category: .network, "[boxdata] 数据中有 \(issues.count) 处不规范内容已兼容处理：\n\(shown)\(more)")
    }

    // MARK: - Generic Error Handling

    /// Runs `operation` and installs its result; on failure shows a toast. Returns
    /// whether it succeeded.
    @MainActor
    @discardableResult
    private func perform(_ hint: String,
                         showsErrorDetails: Bool = false,
                         _ operation: () async throws -> BoxDataResp) async -> Bool {
        do {
            let boxdata = try await operation()
            self.boxData = boxdata
            return true
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let toast = showsErrorDetails ? "\(hint)失败：\(msg)" : "\(hint)失败"
            toastManager?.showToast(message: toast)
            appLog(.error, category: .viewModel, "[\(hint)] \(msg)")
            return false
        }
    }

    /// Apply local state immediately, then sync to backend in background.
    /// On failure, refetch from server to restore consistent state.
    @MainActor
    private func optimistic(_ hint: String, apply: (BoxDataResp) -> BoxDataResp, sync: @escaping () async throws -> BoxDataResp) {
        boxData = apply(boxData)
        Task {
            do {
                let boxdata = try await sync()
                await updateBoxData(boxdata)
            } catch {
                appLog(.error, category: .viewModel, "[optimistic/\(hint)] sync failed: \(error), refetching...")
                toastManager?.showToast(message: "\(hint)同步失败，正在刷新…")
                await fetchDataAsync()
            }
        }
    }

    // MARK: - Data Fetching

    func fetchData() {
        Task { await fetchDataAsync() }
    }

    func fetchDataAsync() async {
        appLog(.info, category: .viewModel, "[fetchData] start, baseURL: \(ApiManager.shared.baseURL)")
        do {
            let boxdata: BoxDataResp = try await NetworkProvider.request(.getBoxData)
            await updateBoxData(boxdata)
            await MainActor.run { self.isDataLoaded = true }
            appLog(.info, category: .viewModel, "[fetchData] success")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                self.isDataLoaded = true
                toastManager?.showToast(message: "加载数据失败：\(msg)")
            }
            appLog(.error, category: .viewModel, "[fetchData] failed, baseURL: \(ApiManager.shared.baseURL), error: \(msg)")
        }
    }

    /// Converts a value handed in by a view into JSON for `/api/update`. `nil` when it
    /// is not representable, so a programming error can never write `null` into the
    /// user's preferences.
    private func jsonValue(for data: Any, path: String) -> JSONValue? {
        let value = JSONValue(foundation: data)
        guard !value.isNull || data is NSNull else {
            appLog(.error, category: .viewModel, "[updateData] \(path): \(type(of: data)) is not JSON, write skipped")
            return nil
        }
        return value
    }

    /// Fire-and-forget version (existing callers)
    @MainActor
    func updateData(path: String, data: Any) {
        guard let value = jsonValue(for: data, path: path) else { return }
        if path.hasPrefix("usercfgs.") {
            applyOptimisticUsercfgsUpdate(path: path, value: value)
        }
        pendingDataUpdates[path] = value
    }

    /// Shows a new subscription order at once and queues it (see `pendingAppSubOrder`).
    /// The stored entries themselves are sent back (`UserConfig.appsubsJSON`), so
    /// nothing the list does not show is lost.
    @MainActor
    func reorderAppSubs(urls: [String]) {
        guard let usercfgs = boxData.usercfgs else { return }
        applyOptimisticUsercfgsUpdate(path: "usercfgs.appsubs", value: usercfgs.appsubsJSON(orderedBy: urls))
        pendingDataUpdates["usercfgs.appsubs"] = nil
        pendingAppSubOrder = urls
    }

    /// Sends queued writes. A caller arriving while a flush runs waits for it first.
    @MainActor
    @discardableResult
    func flushPendingDataUpdates() async -> Bool {
        while let running = runningFlush {
            _ = await running.value
        }
        guard !pendingDataUpdates.isEmpty || pendingAppSubOrder != nil else { return true }

        // The task clears `runningFlush` itself, before any waiter resumes.
        let flush = Task { @MainActor () -> Bool in
            let succeeded = await self.sendPendingDataUpdates()
            self.runningFlush = nil
            return succeeded
        }
        runningFlush = flush
        return await flush.value
    }

    @MainActor
    private func sendPendingDataUpdates() async -> Bool {
        var updates = pendingDataUpdates
        pendingDataUpdates.removeAll()
        let order = pendingAppSubOrder
        pendingAppSubOrder = nil
        if let order, let usercfgs = boxData.usercfgs {
            updates["usercfgs.appsubs"] = usercfgs.appsubsJSON(orderedBy: order)
        }

        var failedPaths: [String] = []
        for (path, value) in updates {
            do {
                let _: BoxDataResp = try await NetworkProvider.request(.updateData(path: path, val: value))
            } catch let error as RequestError where error.mayHaveBeenApplied {
                continue
            } catch {
                failedPaths.append(path)
                appLog(.error, category: .viewModel, "[flushPendingDataUpdates] write failed for \(path): \(error)")
            }
        }

        if !failedPaths.isEmpty {
            // Keep them for the next flush, unless something newer was queued meanwhile.
            for path in failedPaths {
                if path == "usercfgs.appsubs", let order {
                    if pendingAppSubOrder == nil { pendingAppSubOrder = order }
                } else if pendingDataUpdates[path] == nil {
                    pendingDataUpdates[path] = updates[path]
                }
            }
            toastManager?.showToast(message: "部分更新失败，已保留待重试")
            return false
        }

        do {
            let boxdata: BoxDataResp = try await NetworkProvider.request(.getBoxData)
            updateBoxData(boxdata)
            return true
        } catch {
            appLog(.error, category: .viewModel, "[flushPendingDataUpdates] refetch failed: \(error)")
            return true
        }
    }

    /// 先改本地 `usercfgs`，避免 Toggle 等控件等网络往返才刷新
    @MainActor
    private func applyOptimisticUsercfgsUpdate(path: String, value: JSONValue) {
        guard path.hasPrefix("usercfgs."), let cfg = boxData.usercfgs else { return }
        let suffix = String(path.dropFirst("usercfgs.".count))
        boxData = boxData.replacingUsercfgs(cfg.updating(path: suffix, value: value))
    }

    enum UpdateError: Error {
        case writeFailed(underlying: Error)
        case refetchFailed(underlying: Error)
    }

    /// Async version with explicit error propagation
    @discardableResult
    func updateDataAsync(path: String, data: Any) async -> Result<Void, UpdateError> {
        guard let value = jsonValue(for: data, path: path) else {
            return .failure(.writeFailed(underlying: RequestError.decodeFail(message: "\(path) 的值无法写入")))
        }
        var writeSucceeded = false
        do {
            let boxdata: BoxDataResp = try await NetworkProvider.request(.updateData(path: path, val: value))
            await updateBoxData(boxdata)
            writeSucceeded = true
        } catch let error as RequestError where error.mayHaveBeenApplied {
            writeSucceeded = true
        } catch {
            return .failure(.writeFailed(underlying: error))
        }

        do {
            let boxdata: BoxDataResp = try await NetworkProvider.request(.getBoxData)
            await updateBoxData(boxdata)
            return .success(())
        } catch {
            return writeSucceeded ? .success(()) : .failure(.refetchFailed(underlying: error))
        }
    }

    // MARK: - 订阅管理

    /// How a subscription refresh ended. Failures and partial results have already
    /// been reported with a toast; callers only announce `.refreshed`.
    enum SubscriptionRefresh {
        case refreshed
        /// BoxJS could not reach some sources; everything it did refresh is shown.
        case partial
        case failed
    }

    @discardableResult
    func reloadAppSub(url: String) async -> SubscriptionRefresh {
        await refreshSubscriptions("刷新订阅", target: .reloadAppSub(url: url), urls: [url])
    }

    @discardableResult
    func reloadAllAppSub() async -> SubscriptionRefresh {
        await refreshSubscriptions("刷新全部订阅", target: .reloadAllAppSub, urls: nil)
    }

    /// BoxJS aborts a whole refresh when it cannot reach one source, yet keeps every
    /// subscription it did refresh; that state is loaded and the failure reported.
    /// Sources BoxJS could never cache are then recovered from the copy this app can
    /// read (see `ApiRequest.addAppSub`).
    private func refreshSubscriptions(_ hint: String, target: BoxJSAPI, urls: [String]?) async -> SubscriptionRefresh {
        // Queued list writes land first, so they cannot overwrite the result.
        await flushPendingDataUpdates()
        var unreachable = false
        var recovered = false
        let succeeded = await perform(hint) {
            var boxdata: BoxDataResp
            do {
                boxdata = try await NetworkProvider.request(target)
            } catch RequestError.boxjsFailed {
                unreachable = true
                boxdata = try await NetworkProvider.request(.getBoxData)
            }
            guard let repaired = await ApiRequest.recoverUncachedSubscriptions(in: boxdata, urls: urls) else {
                return boxdata
            }
            recovered = true
            return repaired
        }
        guard succeeded else { return .failed }
        // A single source BoxJS could not reach, but this app could: it is up to date.
        guard unreachable, !(urls?.count == 1 && recovered) else { return .refreshed }
        let message = urls == nil
            ? "部分订阅刷新失败：BoxJS 无法访问其中一些订阅地址"
            : "刷新订阅失败：BoxJS 无法访问该订阅地址"
        await MainActor.run { toastManager?.showToast(message: message) }
        return .partial
    }

    func addAppSub(url: String) async {
        await flushPendingDataUpdates()
        await perform("添加订阅", showsErrorDetails: true) { try await ApiRequest.addAppSub(url: url) }
    }

    /// Adds a subscription from raw JSON pasted by the user (no remote URL).
    /// Local validation lives in `ApiRequest.addAppSubRaw`; the backend stores it under
    /// a stable `manual://` cache id, so refresh never treats it as a remote URL.
    func addAppSubRaw(json: String, name: String? = nil) async {
        await flushPendingDataUpdates()
        await perform("添加订阅", showsErrorDetails: true) {
            try await ApiRequest.addAppSubRaw(json: json, name: name)
        }
    }

    func deleteAppSub(url: String) async {
        // A queued or in-flight reorder lands first; built after it, the delete sticks.
        await flushPendingDataUpdates()
        await perform("删除订阅") { try await NetworkProvider.request(.deleteAppSub(url: url)) }
    }

    // MARK: - 数据保存

    @MainActor
    func saveData(params: [SessionData]) {
        let syncParams = params
        optimistic("保存数据", apply: { boxData in
            var newDatas = boxData.datas
            for p in params {
                newDatas[p.key] = p.val
            }
            return boxData.replacingDatas(newDatas)
        }) {
            try await NetworkProvider.request(.saveData(params: syncParams))
        }
    }

    /// Saves settings the way the web UI does: every value as text (`_.toString`),
    /// which is what BoxJS and the scripts reading these keys expect. (The web UI also
    /// posts `?appid=`, which makes BoxJS overwrite the linked session with these
    /// values; that side effect is deliberately not reproduced.)
    @MainActor
    func saveSettings(_ settings: [Setting]) {
        saveData(params: settings.map { SessionData(key: $0.id, val: .string($0.val.wireText)) })
    }

    // MARK: - 全局备份

    func saveGlobalBak(name: String? = nil) async {
        let bakName = name ?? "全局备份 \((boxData.globalbaks?.count ?? 0) + 1)"
        let env = boxData.syscfgs?.env ?? ""
        let version = boxData.syscfgs?.version ?? ""
        let versionType = boxData.syscfgs?.versionType ?? ""
        await perform("保存备份") {
            try await ApiRequest.saveGlobalBak(name: bakName, env: env, version: version, versionType: versionType)
        }
    }

    func delGlobalBak(id: String) async {
        await perform("删除备份") { try await NetworkProvider.request(.delGlobalBak(id: id)) }
    }

    func revertGlobalBak(id: String) async {
        await perform("恢复备份") { try await NetworkProvider.request(.revertGlobalBak(id: id)) }
    }

    func updateGlobalBak(id: String, name: String) async {
        await perform("更新备份") { try await NetworkProvider.request(.updateGlobalBak(id: id, name: name)) }
    }

    func impGlobalBak(bakData: String) async {
        let name = "全局备份 \((boxData.globalbaks?.count ?? 0) + 1)"
        await perform("导入备份", showsErrorDetails: true) { try await ApiRequest.impGlobalBak(bakData: bakData, name: name) }
    }

    // MARK: - 会话管理

    @MainActor
    func saveAppSession(app: AppModel, datas: [SessionData]) {
        let session = Session(
            id: UUID().uuidString,
            name: "会话 \(boxData.sessions.filter { $0.appId == app.id }.count + 1)",
            enable: true,
            appId: app.id,
            appName: app.name,
            createTime: BoxTimestamp.isoString(from: Date()),
            datas: datas
        )
        var allSessions = boxData.sessions
        allSessions.append(session)
        let sessions = allSessions
        optimistic("保存会话", apply: { $0.replacingSessions(sessions) }) {
            try await ApiRequest.saveSessions(sessions)
        }
    }

    @MainActor
    func delAppSession(sessionId: String) {
        var allSessions = boxData.sessions
        allSessions.removeAll { $0.id == sessionId }
        let sessions = allSessions
        optimistic("删除会话", apply: { $0.replacingSessions(sessions) }) {
            try await ApiRequest.saveSessions(sessions)
        }
    }

    @MainActor
    func updateAppSession(_ session: Session) {
        var allSessions = boxData.sessions
        if let idx = allSessions.firstIndex(where: { $0.id == session.id }) {
            allSessions[idx] = session
        }
        let sessions = allSessions
        optimistic("更新会话", apply: { $0.replacingSessions(sessions) }) {
            try await ApiRequest.saveSessions(sessions)
        }
    }

    @MainActor
    func cloneAppSession(_ session: Session) {
        let clone = Session(
            id: UUID().uuidString,
            name: "\(session.name) 副本",
            enable: session.enable,
            appId: session.appId,
            appName: session.appName,
            createTime: BoxTimestamp.isoString(from: Date()),
            datas: session.datas
        )
        var allSessions = boxData.sessions
        allSessions.append(clone)
        let sessions = allSessions
        optimistic("克隆会话", apply: { $0.replacingSessions(sessions) }) {
            try await ApiRequest.saveSessions(sessions)
        }
    }

    @MainActor
    func useAppSession(sessionId: String, appId: String) {
        guard let session = boxData.sessions.first(where: { $0.id == sessionId }) else { return }
        var datas = session.datas
        datas.append(SessionData(key: "chavy_boxjs_cur_sessions", val: "{}"))

        // Optimistically apply session datas to local state
        var newDatasDict = boxData.datas
        for d in session.datas {
            newDatasDict[d.key] = d.val
        }
        let syncDatas = datas
        let appIdCopy = appId
        optimistic("应用会话", apply: { $0.replacingDatas(newDatasDict) }) {
            try await NetworkProvider.request(.useAppSession(datas: syncDatas, appId: appIdCopy))
        }
    }

    @MainActor
    func linkAppSession(sessionId: String, appId: String) {
        guard let session = boxData.sessions.first(where: { $0.id == sessionId }) else { return }
        var curSessions = boxData.curSessions ?? [:]
        curSessions[appId] = sessionId
        let curSessionsJSON = JSONValue.object(curSessions.mapValues(JSONValue.string)).compactJSONText
        var datas = session.datas
        datas.append(SessionData(key: "chavy_boxjs_cur_sessions", val: .string(curSessionsJSON)))
        let syncDatas = datas
        optimistic("关联会话", apply: { $0.replacingCurSessions(curSessions) }) {
            try await NetworkProvider.request(.linkAppSession(datas: syncDatas))
        }
    }

    @MainActor
    func clearAppDatas(app: AppModel, key: String? = nil) {
        let dataInfo = boxData.loadAppDataInfo(for: app)
        let datas = dataInfo.datas.map { d in
            key == nil || d.key == key ? SessionData(key: d.key, val: "") : d
        }

        // Optimistically clear local datas
        var newDatasDict = boxData.datas
        for d in datas {
            newDatasDict[d.key] = d.val
        }
        let syncDatas = datas
        optimistic("清除数据", apply: { $0.replacingDatas(newDatasDict) }) {
            try await NetworkProvider.request(.saveData(params: syncDatas))
        }
    }

    /// Imports a copied session: any JSON object with a `datas` list of `{key, val}`.
    @MainActor
    func importSession(jsonString: String) -> Bool {
        guard let value = try? JSONValue.parse(jsonString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let fields = JSONFields(value) else { return false }
        let datas = (fields["datas"]?.arrayValue ?? []).compactMap(SessionData.init)
        guard !datas.isEmpty else { return false }
        saveData(params: datas)
        return true
    }
}
