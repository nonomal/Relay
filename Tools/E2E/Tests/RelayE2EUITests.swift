//
//  RelayE2EUITests.swift
//  Relay end-to-end UI tests. Run with Tools/E2E/run.sh.
//
//  Drives the installed Relay app against the real BoxJS backend script, served by
//  Server/e2e-server.mjs with data as the web UI, scripts and older clients leave it,
//  and checks both what the app shows and what it writes back.
//

import XCTest

final class RelayE2EUITests: XCTestCase {
    static let server = URL(string: ProcessInfo.processInfo.environment["RELAY_E2E_SERVER"] ?? "http://127.0.0.1:8124")!
    static let testSubscription = "Relay E2E 订阅"
    static let plainSubscription = "E2E 常规订阅"
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // test61 needs every subscription source reachable by BoxJS.
        try post(name.contains("test61") ? "/__e2e/reset?reachable=1" : "/__e2e/reset")
        app = XCUIApplication(bundleIdentifier: "net.sodion.relay-app")
        app.launchArguments = ["-apiUrl", Self.server.absoluteString]
        app.launch()
    }

    // MARK: - Loading

    func test10_livedInDataLoads() throws {
        XCTAssertTrue(app.staticTexts["偏好设置"].waitForExistence(timeout: 10),
                      "favorites load although a script wrote isMute: \"true\" and favapps holds a null")
        XCTAssertTrue(app.staticTexts["E2E 设置"].exists)
        app.tabBars.buttons["Subs"].tap()
        XCTAssertTrue(app.staticTexts[Self.testSubscription].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[Self.plainSubscription].exists)
        app.staticTexts[Self.testSubscription].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["数字ID应用"].waitForExistence(timeout: 5), "an app with a numeric id is listed")
        screenshot("subscription")
    }

    // MARK: - Settings

    func test20_settingsShowStoredValues() throws {
        openTestApp()
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "2000", "a number stored in a text setting is shown")
        XCTAssertEqual(app.switches.firstMatch.value as? String, "1", "\"true\" stored as text turns the switch on")
        XCTAssertTrue(app.buttons["选项一"].exists && app.buttons["选项二"].exists, "numeric radio keys still give options")
        XCTAssertTrue(app.buttons["选项Y"].exists, "options named by a data key are resolved, and the stored choice shown")
        XCTAssertTrue(app.staticTexts["7"].exists, "a setting whose name is a number is rendered")
        XCTAssertTrue(app.staticTexts["run.js"].exists, "a script without a name is named after its file")
        // The option rows do not expose their selection to accessibility; see the screenshot.
        screenshot("settings")
    }

    func test30_saveWritesWhatTheWebUIWrites() throws {
        openTestApp()
        app.switches.firstMatch.tap()                  // "true" → off
        app.buttons["选项一"].tap()                     // numeric option key 1
        app.buttons["plus"].firstMatch.tap()           // number stored as "3" → 4
        let saveButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "保存")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertEqual(saveButton.label, "保存，有未保存的改动", "the edits are detected as changes")
        saveButton.tap()

        let save = try waitForWrite { $0.path == "/api/save" }
        XCTAssertEqual(save.pairs.count, 3, "only the edited settings are sent: \(save.pairs)")
        XCTAssertEqual(save.pairs["e2e_bool"] as? String, "false", "Booleans are saved as text, like the web UI")
        XCTAssertEqual(save.pairs["e2e_radio"] as? String, "1", "a numeric option key is saved as text")
        XCTAssertEqual(save.pairs["e2e_number"] as? String, "4", "numbers are saved as text, without a fraction")
        XCTAssertEqual(try storedValue("e2e_bool") as? String, "false")
        XCTAssertEqual(try storedValue("e2e_number") as? String, "4")
        XCTAssertEqual(saveButton.label, "保存", "saved values become the new baseline")
    }

    func test31_revertRestoresTheValuesThemselves() throws {
        openTestApp()
        let toggle = app.switches.firstMatch
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["撤销"].tap()
        XCTAssertEqual(toggle.value as? String, "1", "a switch reverted from \"true\" text is on again")
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "2000")
    }

    // MARK: - Sessions

    func test40_snapshotKeepsOtherSessionsAsStored() throws {
        openTestApp()
        app.buttons["克隆"].firstMatch.tap()
        let save = try waitForWrite { $0.path == "/api/save" && $0.pairs["chavy_boxjs_sessions"] != nil }
        let text = try XCTUnwrap(save.pairs["chavy_boxjs_sessions"] as? String)
        let sessions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)

        let legacy = try XCTUnwrap(sessions.first { $0["id"] as? String == "legacy-session" })
        XCTAssertEqual(legacy["custom"] as? String, "keep-me", "fields Relay does not model survive")
        XCTAssertEqual((legacy["createTime"] as? NSNumber)?.int64Value, 1767225600000, "a numeric createTime stays a number")
        let legacyDatas = try XCTUnwrap(legacy["datas"] as? [[String: Any]])
        XCTAssertNil(legacyDatas.first { $0["key"] as? String == "e2e_unset" }?["val"], "an entry stored without val stays so")

        let snapshot = try XCTUnwrap(sessions.first { $0["id"] as? String != "legacy-session" })
        let snapshotDatas = try XCTUnwrap(snapshot["datas"] as? [[String: Any]])
        XCTAssertEqual(snapshotDatas.first { $0["key"] as? String == "e2e_unset" }?["val"] as? String, "",
                       "an unset key is recorded as \"\" (a null would not clear it when applied)")
    }

    func test41_switchingSessionClearsKeysItHadUnset() throws {
        openTestApp()
        app.buttons["切换"].firstMatch.tap()
        let use = try waitForWrite { $0.path.hasPrefix("/api/save?appid=") }
        XCTAssertEqual(use.pairs["e2e_cookie"] as? String, "cookie-B")
        XCTAssertEqual(use.pairs["e2e_unset"] as? String, "", "a value the session has unset is sent as \"\", never null")
        XCTAssertEqual(try storedValue("e2e_cookie") as? String, "cookie-B")
        XCTAssertEqual(try storedValue("e2e_unset") as? String, "", "the key is actually cleared in BoxJS")
    }

    // MARK: - Subscriptions

    func test50_addingASourceBoxJSCannotParse() throws {
        let before = try storedSubscriptions()
        let bomURL = Self.server.appendingPathComponent("__e2e/subs/bom.boxjs.json").absoluteString
        app.tabBars.buttons["Subs"].tap()
        app.buttons["Add"].tap()
        app.buttons["输入订阅地址"].tap()
        let alert = app.alerts["添加订阅"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText(bomURL)
        alert.buttons["确定"].tap()

        let update = try waitForWrite(timeout: 45) { $0.path == "/api/update" }
        let raw = try XCTUnwrap(writes().first { $0.path == "/api/addAppSubRaw" }, "Relay stored its own copy")
        XCTAssertEqual((raw.body as? [String: Any])?["id"] as? String, bomURL, "stored under the subscription's URL")
        let list = try XCTUnwrap((update.body as? [String: Any])?["val"] as? [[String: Any]])
        XCTAssertEqual(list.count, before.count + 1, "every entry is kept, plus the new one")
        XCTAssertEqual(list.filter { $0["url"] as? String == bomURL }.count, 1, "the new subscription is listed once")
        XCTAssertEqual(list.first?["url"] as? String, before.first?["url"] as? String, "order is unchanged")

        XCTAssertTrue(scrollTo(app.staticTexts["E2E BOM 订阅"]), "the subscription loads with its apps")
        screenshot("added-bom-subscription")
    }

    func test60_refreshAllWhenBoxJSCannotReachOneSource() throws {
        app.tabBars.buttons["Subs"].tap()
        XCTAssertTrue(app.staticTexts[Self.testSubscription].waitForExistence(timeout: 10))
        app.buttons["arrow.triangle.2.circlepath"].tap()
        XCTAssertTrue(toast(containing: "部分订阅刷新失败").waitForExistence(timeout: 45), "the partial failure is reported")
        screenshot("refresh-partial")
        XCTAssertTrue(app.staticTexts[Self.testSubscription].exists, "subscriptions stay listed")
        XCTAssertTrue(app.staticTexts[Self.plainSubscription].exists)
        sleep(3)
        XCTAssertFalse(toast(containing: "已刷新全部订阅").exists, "no success message follows a partial failure")
    }

    func test61_refreshAllWhenEverySourceIsReachable() throws {
        app.tabBars.buttons["Subs"].tap()
        XCTAssertTrue(app.staticTexts[Self.testSubscription].waitForExistence(timeout: 10))
        app.buttons["arrow.triangle.2.circlepath"].tap()
        XCTAssertTrue(toast(containing: "已刷新全部订阅").waitForExistence(timeout: 45), "a full refresh is announced")
        XCTAssertTrue(try writes().contains { $0.path == "/api/reloadAppSub" })
    }

    // MARK: - Helpers

    private func openTestApp() {
        app.tabBars.buttons["Subs"].tap()
        let subscription = app.staticTexts[Self.testSubscription].firstMatch
        XCTAssertTrue(subscription.waitForExistence(timeout: 10))
        subscription.tap()
        let entry = app.staticTexts["E2E 设置"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.staticTexts["文本数字值"].waitForExistence(timeout: 5))
    }

    private func toast(containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, attempts: Int = 12) -> Bool {
        for _ in 0..<attempts {
            if element.waitForExistence(timeout: 1) { return true }
            app.swipeUp()
        }
        return element.exists
    }

    /// Kept in the result bundle, for what accessibility cannot tell (e.g. selected options).
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Server

    struct Write {
        let path: String
        let body: Any?

        /// `/api/save` bodies, `[{key, val}]`, as a dictionary (a missing val is NSNull).
        var pairs: [String: Any] {
            var result: [String: Any] = [:]
            for entry in body as? [[String: Any]] ?? [] {
                if let key = entry["key"] as? String { result[key] = entry["val"] ?? NSNull() }
            }
            return result
        }
    }

    struct E2EFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func writes() throws -> [Write] {
        let data = try fetch(URLRequest(url: Self.server.appendingPathComponent("__e2e/log")))
        let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return list.map { Write(path: $0["path"] as? String ?? "", body: $0["body"]) }
    }

    private func waitForWrite(timeout: TimeInterval = 15, _ match: (Write) -> Bool) throws -> Write {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = try writes().last(where: match) { return hit }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        let seen = (try? writes().map(\.path)) ?? []
        throw E2EFailure(message: "expected write never arrived; writes: \(seen)")
    }

    private func storedValue(_ key: String) throws -> Any? {
        let data = try fetch(URLRequest(url: Self.server.appendingPathComponent("query/data/\(key)")))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["val"]
    }

    private func storedSubscriptions() throws -> [[String: Any]] {
        let data = try fetch(URLRequest(url: Self.server.appendingPathComponent("query/boxdata")))
        let boxdata = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (boxdata?["usercfgs"] as? [String: Any])?["appsubs"] as? [[String: Any]] ?? []
    }

    @discardableResult
    private func post(_ path: String) throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.server)!)
        request.httpMethod = "POST"
        return try fetch(request)
    }

    private func fetch(_ request: URLRequest) throws -> Data {
        let done = expectation(description: request.url!.path)
        var result: Result<Data, Error> = .failure(URLError(.unknown))
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return try result.get()
    }
}
