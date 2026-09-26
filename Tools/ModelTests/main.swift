//
//  main.swift
//  Relay model-layer tests.
//
//  The model layer is Foundation-only, so it is compiled and run directly with
//  `swiftc` — no simulator, no Xcode test target. Run `Tools/ModelTests/run.sh`.
//

import Foundation

// MARK: - Minimal test runner

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ✗ \(message)  (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
    check(actual == expected, "\(message): expected \(expected), got \(actual)", file: file, line: line)
}

func suite(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { failures += 1; print("  ✗ threw \(error)") }
}

func json(_ text: String) -> JSONValue { try! JSONValue.parse(text) }
func fields(_ text: String) -> JSONFields { JSONFields(json(text))! }

// MARK: - JSONValue

suite("JSONValue parsing and encoding") {
    expectEqual(try JSONValue.parse(Data([0xEF, 0xBB, 0xBF] + Array("{\"a\":1}".utf8))), ["a": 1], "UTF-8 BOM is skipped")
    expectEqual(json("null"), .null, "bare null body parses")
    expectEqual(json("[true, 1, \"1\"]"), [true, 1, "1"], "booleans stay distinct from numbers")
    let encoded = String(data: try JSONEncoder().encode(JSONValue.number(20)), encoding: .utf8)
    expectEqual(encoded, "20", "integral numbers encode without a fraction")
    expectEqual(String(data: try JSONEncoder().encode(JSONValue.number(1.5)), encoding: .utf8), "1.5", "fractions survive")
    let object = json("{\"a\":[1,null,\"x\"],\"b\":{\"c\":false}}")
    let roundTrip = JSONValue(foundation: try JSONSerialization.jsonObject(
        with: JSONSerialization.data(withJSONObject: object.foundationObject)))
    expectEqual(roundTrip, object, "foundationObject round-trips through JSONSerialization")
    let jsNumbers: [(Double, String)] = [
        (20, "20"), (-0.0, "0"), (0.1, "0.1"), (-1.5, "-1.5"), (123.45, "123.45"),
        (1e16, "10000000000000000"), (5e20, "500000000000000000000"), (1e21, "1e+21"),
        (1e-5, "0.00001"), (1e-6, "0.000001"), (1e-7, "1e-7"), (1.5e-7, "1.5e-7"),
        (9007199254740993, "9007199254740992"), (1.7976931348623157e308, "1.7976931348623157e+308"),
    ]
    for (number, text) in jsNumbers { expectEqual(JSONValue.format(number), text, "String(\(number)) as in JavaScript") }
    expectEqual(json("[\"a\", null, 1, [2, 3]]").jsString, "a,,1,2,3", "String(array) as in JavaScript")
    expectEqual(json("{}").jsString, "[object Object]", "String(object) as in JavaScript")
}

suite("JSONValue coercions follow the web UI") {
    expectEqual(JSONValue.null.wireText, "", "null saves as empty text (lodash _.toString)")
    expectEqual(JSONValue.bool(true).wireText, "true", "Booleans save as text")
    expectEqual(JSONValue.number(2000).wireText, "2000", "numbers save as text")
    expectEqual(json("[\"a\",\"b\"]").wireText, "a,b", "lists save comma-joined")
    expectEqual(json("{\"a\":1}").wireText, "{\"a\":1}", "objects save as JSON, not [object Object]")
    for on in ["true", "\"true\"", "1", "\"1\"", "\" TRUE \""] { expectEqual(json(on).boolValue, true, "\(on) is on") }
    for off in ["false", "\"false\"", "0", "\"0\""] { expectEqual(json(off).boolValue, false, "\(off) is off") }
    for unknown in ["\"\"", "null", "\"yes\"", "[]"] { expectEqual(json(unknown).boolValue, nil, "\(unknown) states nothing") }
    expectEqual(json("\" 3 \"").numberValue, 3, "numeric text is a number")
    expectEqual(json("\"abc\"").numberValue, nil, "non-numeric text is not")
    expectEqual(json("\"a,b,,c\"").listItems, ["a", "b", "c"], "checkboxes text splits on commas")
    expectEqual(json("[\"a\", 1, null]").listItems, ["a", "1"], "list items are stringified, nulls dropped")
    expectEqual(json("2000").displayText, "2000", "numbers display as text")
    expectEqual(json("\"[1,2]\"").decodedJSONText, [1, 2], "JSON stored as text is decodable")
}

// MARK: - Fields

suite("JSONFields reads odd shapes instead of failing") {
    let f = fields("{\"n\":12,\"b\":\"true\",\"arr\":[\"\",\"https://a\"],\"blank\":\"  \",\"desc\":[\"l1\",\"l2\"],\"list\":\"one\"}")
    expectEqual(f.string("n"), "12", "numbers read as text")
    expectEqual(f.bool("b"), true, "Boolean text reads as a Boolean")
    expectEqual(f.string("arr"), "https://a", "arrays yield their first non-blank item")
    expectEqual(f.string("blank"), nil, "blank text is absent")
    expectEqual(f.text("desc"), "l1\nl2", "text arrays are joined")
    expectEqual(f.strings("list"), ["one"], "a single scalar is a one-item list")
    var report = DecodeReport()
    let entries = fields("{\"apps\":{\"b\":{\"id\":\"B\"},\"a\":{\"id\":\"A\"},\"x\":3}}").objects("apps", path: "$", report: &report)
    expectEqual(entries?.compactMap { $0.string("id") }, ["A", "B"], "an object used as a list yields its values")
    expectEqual(report.issues.count, 2, "the shape and the non-object entry are both reported")
}

// MARK: - Apps and settings

suite("AppModel projection") {
    var report = DecodeReport()
    let app = AppModel(fields("""
    {"id": 20240101, "icons": "https://i/a.png", "repo": ["https://r1", "https://r2"],
     "desc_html": ["<p>a</p>", "<p>b</p>"], "script_timeout": 30,
     "scripts": [{"script": "https://s/checkin.js"}, {"name": "no url"}],
     "settings": [{"id": "k", "name": 1, "desc": ["x", "y"], "placeholder": 5, "type": " string", "val": 2000},
                  {"name": "no id"}, {"id": "k", "type": "radios"}]}
    """), path: "app", report: &report)
    expectEqual(app?.id, "20240101", "numeric id becomes text")
    expectEqual(app?.name, "20240101", "missing name falls back to the id")
    expectEqual(app?.icons, ["https://i/a.png"], "a single icon string becomes a list")
    expectEqual(app?.repo, "https://r1", "the first repo of a list is used")
    expectEqual(app?.desc_html, "<p>a</p><br><p>b</p>", "desc_html paragraphs are joined")
    expectEqual(app?.descs_html == nil, true, "desc_html is not duplicated into descs_html")
    expectEqual(app?.scriptTimeout, 30, "script_timeout is kept")
    expectEqual(app?.scripts?.map(\.name), ["checkin.js"], "unnamed scripts are named by file; url-less ones skipped")
    expectEqual(app?.settings?.count, 1, "settings without id, and repeated ids, are skipped")
    let setting = app?.settings?.first
    expectEqual(setting?.name, "1", "numeric setting name becomes text")
    expectEqual(setting?.desc, "x\ny", "array desc is joined")
    expectEqual(setting?.placeholder, "5", "numeric placeholder becomes text")
    expectEqual(setting?.kind, .text, "\" string\" is a text field")
    expectEqual(setting?.val.wireText, "2000", "numeric value of a text field is shown as text")
    expectEqual(report.issues.count, 4, "skipped script, id-less setting, option-less radios and duplicate setting are reported")
    check(AppModel(json: json("{\"name\": \"no id\"}")) == nil, "an app without any id is skipped")
}

suite("SettingKind normalizes publisher spellings") {
    let cases: [(String?, SettingKind)] = [
        ("boolean", .boolean), ("checkbox", .boolean), ("texearea", .textarea), ("textarea", .textarea),
        ("int", .number), ("number", .number), ("slider", .slider), ("colorpicker", .colorpicker),
        ("radios", .radios), ("checkboxes", .checkboxes), ("selects", .selects), ("modalSelects", .selects),
        (" string", .text), ("input", .text), ("date", .text), (nil, .text),
    ]
    for (raw, kind) in cases { expectEqual(SettingKind(rawType: raw), kind, "type \(raw ?? "nil")") }
}

suite("Setting options in every published shape") {
    func items(_ text: String) -> [RadioItem]? { SettingItemsParser.items(from: json(text)) }
    expectEqual(items("[{\"key\":\"a\",\"label\":\"A\"}]")?.map(\.key), ["a"], "canonical objects")
    expectEqual(items("[{\"key\":null,\"label\":\"关闭\"},{\"key\":1,\"label\":\"一\"}]")?.map(\.key), ["", "1"],
                "null and numeric keys become the text the web UI saves")
    expectEqual(items("[{\"key\":\"a\"}]")?.first?.label, "a", "missing label falls back to the key")
    expectEqual(items("[\"x\", \"y\", 3]")?.map(\.label), ["x", "y", "3"], "plain value lists")
    expectEqual(items("{\"b\":\"B\",\"a\":\"A\"}")?.map(\.key), ["a", "b"], "key-to-label maps")
    expectEqual(items("\"[{\\\"key\\\":\\\"j\\\",\\\"label\\\":\\\"J\\\"}]\"")?.map(\.key), ["j"], "JSON text")
    expectEqual(items("\"d@每天\\nw@每周\"")?.map(\.label), ["每天", "每周"], "legacy key@label lines")
    expectEqual(items("[\"a\",\"a\"]")?.count, 1, "duplicate keys are merged")
    var report = DecodeReport()
    let reference = Setting(fields("{\"id\":\"r\",\"type\":\"modalSelects\",\"items\":\"@gist.revision_options\"}"),
                            path: "s", report: &report)
    expectEqual(reference?.items == nil, true, "a data key is not parsed as options")
    expectEqual(reference?.itemsKey, "@gist.revision_options", "the data key is kept for resolution")
}

suite("Slider range never clamps the stored value") {
    var report = DecodeReport()
    let slider = Setting(fields("{\"id\":\"s\",\"type\":\"slider\",\"min\":1,\"max\":10,\"step\":0.5,\"val\":\"25\"}"),
                         path: "s", report: &report)
    expectEqual(slider?.sliderRange, 1...25, "range widens to include the stored value")
    expectEqual(slider?.sliderStep, 0.5, "step is honored")
    let defaults = Setting(fields("{\"id\":\"s\",\"type\":\"slider\",\"min\":5,\"max\":5}"), path: "s", report: &report)
    expectEqual(defaults?.sliderRange, 0...100, "an empty range falls back to 0...100")
}

// MARK: - User config

suite("UserConfig survives every odd field") {
    let config = UserConfig(raw: json("""
    {"appsubs": [{"url": "https://a", "enable": "true"}, {"url": null, "enable": true}, {"url": "https://b"}, "junk"],
     "favapps": ["x", null, 7], "isMute": "true", "name": 12345, "viewkeys": ["a", 1], "httpapis": ["k@1.1.1.1:6166", "k@2.2.2.2:6166"]}
    """).objectValue!)
    expectEqual(config.appsubs.map(\.url), ["https://a", "https://b"], "unusable subscription entries are skipped")
    expectEqual(config.appsubs.map(\.enable), [true, true], "missing or textual enable reads as on")
    expectEqual(config.favapps, ["x", "7"], "favorites keep every usable id")
    expectEqual(config.isMute, true, "\"true\" is on")
    expectEqual(config.name, "12345", "numeric name becomes text")
    expectEqual(config.httpapis, "k@1.1.1.1:6166,k@2.2.2.2:6166", "a candidate list stored as an array is comma-joined")
    expectEqual(config.issues.count, 2, "the null url and the non-object entry are reported")

    let updated = config.updating(path: "favapps", value: ["y"]).updating(path: "a.b", value: true)
    expectEqual(updated.favapps, ["y"], "optimistic update re-projects the patched field")
    expectEqual(updated.raw["a"]?["b"], true, "nested paths create intermediate objects")
    expectEqual(updated.isMute, true, "other fields are untouched")

    let reordered = config.appsubsJSON(orderedBy: ["https://b", "https://a"]).arrayValue ?? []
    expectEqual(reordered.count, 4, "reordering keeps every stored entry, even unusable ones")
    expectEqual(reordered.first?["url"], "https://b", "entries follow the new order")
    expectEqual(reordered[1]["enable"], "true", "stored fields are written back untouched")
}

// MARK: - Sessions

suite("Saving sessions never rewrites untouched ones") {
    let stored = json("""
    [{"id": "s1", "name": "会话 1", "appId": "a", "createTime": 1767225600000, "datas": [{"key": "k", "val": 1}], "custom": "keep"},
     {"name": "no id", "appId": "a", "datas": [{"val": "orphan"}]}]
    """).arrayValue!
    var report = DecodeReport()
    let sessions = stored.enumerated().map { Session(JSONFields($0.element)!, index: $0.offset, path: "s", report: &report) }
    expectEqual(sessions.count, 2, "incomplete sessions are kept")
    expectEqual(sessions[0].enable, true, "missing enable reads as on")
    expectEqual(sessions[0].createTime, "2026-01-01T00:00:00.000Z", "epoch milliseconds read as ISO time")
    expectEqual(sessions[1].id, "session-1", "a missing id gets a local positional id")
    expectEqual(sessions[0].jsonValue, stored[0], "an untouched session is written back exactly as stored")
    expectEqual(sessions[1].jsonValue, stored[1], "including one without an id")
    var renamed = sessions[0]
    renamed.name = "新名字"
    expectEqual(renamed.jsonValue["name"], "新名字", "an edited field is replaced")
    expectEqual(renamed.jsonValue["createTime"], 1767225600000, "unedited fields keep their stored type")
    expectEqual(renamed.jsonValue["custom"], "keep", "unmodeled fields survive an edit")
    let created = Session(id: "n", name: "新", enable: true, appId: "a", appName: "A", createTime: "t", datas: [])
    expectEqual(created.jsonValue["appName"], "A", "a new session is written in full")
    let pasted = try JSONDecoder().decode(Session.self, from: Data("{\"appId\":\"a\",\"datas\":[{\"key\":\"k\",\"val\":\"v\"}]}".utf8))
    expectEqual(pasted.datas, [SessionData(key: "k", val: "v")], "a pasted session with only appId and datas imports")
}

// MARK: - Responses

suite("Only real responses are projected") {
    check(!BoxDataResp.accepts("BoxJs"), "BoxJS's failure reply is not box data (projecting it would wipe the app)")
    check(!BoxDataResp.accepts(.null) && BoxDataResp.accepts(json("{}")), "box data must be an object")
    check(ScriptResp.accepts(.null), "a script that reports nothing answers null")
    check(!DataQueryResp.accepts("BoxJs") && !VersionsResp.accepts("BoxJs"), "other responses reject it too")
    check(JSONValue.accepts(json("{\"a\":1}")) && !JSONValue.accepts("BoxJs"), "backup contents must be structured")
}

// MARK: - Box data

suite("BoxDataResp derived views") {
    let box = BoxDataResp(json: json("""
    {"usercfgs": {"appsubs": [{"url": "u1"}, {"url": "u2"}], "favapps": ["@x_dup", "@x_dup#2", "solo"]},
     "appSubCaches": {
       "u1": {"id": "sub", "name": "S1", "apps": [{"id": "dup", "author": "@x", "name": "A"}, {"id": "dup", "author": "@x", "name": "B"},
                                                  {"id": "solo", "name": "Solo", "settings": [{"id": "pick", "type": "selects", "items": "opts"}]}]},
       "u2": {"id": "sub", "name": "S2", "apps": [{"id": "other", "name": "O"}]},
       "bad": "not an object"},
     "datas": {"opts": "[\\"p\\", \\"q\\"]"},
     "sessions": [{"id": "s", "appId": "solo"}, null],
     "curSessions": {"solo": "s", "gone": null},
     "globalbaks": [{"id": "b", "createTime": 1767225600000, "tags": [null, "0.19.30"]}]}
    """))
    let names = box.apps.map(\.name)
    expectEqual(names, ["A", "B", "Solo", "O"], "every app is listed once, duplicates included")
    expectEqual(box.apps.prefix(2).map(\.id), ["@x_dup", "@x_dup#2"], "shared ids follow the web rule, then disambiguate")
    expectEqual(box.favApps.map(\.name), ["A", "B", "Solo"], "favorites resolve through the renamed ids")
    expectEqual(box.displayAppSubDetail(for: "u1")?.apps.map(\.id), ["@x_dup", "@x_dup#2", "solo"],
                "the subscription page uses the same ids as Home")
    expectEqual(box.displayAppSubSummaries.map(\.id), ["u1", "u2"], "summaries are keyed by URL")
    expectEqual(box.apps.first { $0.id == "solo" }?.settings?.first?.items?.map(\.key), ["p", "q"],
                "options named by a data key resolve from datas")
    expectEqual(box.sessions.count, 1, "non-object sessions are dropped")
    expectEqual(box.curSessions, ["solo": "s"], "null current-session entries are dropped")
    expectEqual(box.globalbaks?.first?.tags, ["0.19.30"], "null backup tags are dropped")
    check(box.issues.contains { $0.path == "appSubCaches[bad]" }, "a non-object cache is reported")
    expectEqual(box.loadAppDataInfo(for: AppModel(json: json("{\"id\":\"k\",\"keys\":[\"opts\",\"unset\"]}"))!).datas.map(\.val),
                [box.datas["opts"]!, ""], "a snapshot records an unset key as \"\", so applying it clears the key")
}

suite("A subscription listed twice follows the web UI's rename") {
    // The web UI counts every stored entry, so a repeated URL shares all its ids with
    // itself and they are renamed `${author}_${id}` (a missing author reads "undefined").
    let box = BoxDataResp(json: json("""
    {"usercfgs": {"appsubs": [{"url": "u1"}, {"url": "u2"}, {"url": "u1"}],
                  "favapps": ["@x_a", "undefined_solo", "other"]},
     "appSubCaches": {"u1": {"apps": [{"id": "a", "author": "@x", "name": "A"}, {"id": "solo", "name": "Solo"}]},
                      "u2": {"apps": [{"id": "other", "name": "O"}]}}}
    """))
    expectEqual(box.apps.map(\.id), ["@x_a", "undefined_solo", "other"], "ids match what the web UI stored")
    expectEqual(box.favApps.map(\.name), ["A", "Solo", "O"], "favorites saved by the web UI resolve")
    expectEqual(box.displayAppSubSummaries.map(\.id), ["u1", "u2"], "the repeated URL is listed once")
}

suite("Identifiers are kept byte for byte") {
    let config = UserConfig(raw: json("{\"appsubs\": [{\"url\": \" https://a.json \"}, {\"url\": \"https://b.json\"}]}").objectValue!)
    expectEqual(config.appsubs.first?.url, " https://a.json ", "a padded URL matches the cache key and deletes BoxJS stored")
    expectEqual(config.appsubsJSON(orderedBy: ["https://b.json", " https://a.json "]).arrayValue?.compactMap { $0["url"]?.scalarText },
                ["https://b.json", " https://a.json "], "reordering finds the padded entry")
    var report = DecodeReport()
    let setting = Setting(fields("{\"id\": \"key \", \"type\": \"text\"}"), path: "s", report: &report)
    expectEqual(setting?.id, "key ", "a setting id is the storage key, so it is not trimmed")
}

suite("Backups export in their stored shape") {
    let backup = try JSONDecoder().decode(GlobalBackup.self, from: Data("""
    {"id": "b1", "name": "全局备份 1", "createTime": "2026-01-01T00:00:00.000Z", "tags": ["Surge", null], "env": "Surge"}
    """.utf8))
    let exported = try JSONValue.parse(try JSONEncoder().encode(backup))
    expectEqual(exported, ["id": "b1", "name": "全局备份 1", "createTime": "2026-01-01T00:00:00.000Z", "tags": ["Surge"]],
                "export keeps id, name, createTime and tags")
}

// MARK: - Real payloads

let fixtureRoot = CommandLine.arguments.dropFirst().first
if let fixtureRoot {
    suite("Recorded payloads (\(fixtureRoot))") {
        let files = try FileManager.default.contentsOfDirectory(atPath: fixtureRoot).filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent(file))
            let start = Date()
            let box = BoxDataResp(json: try JSONValue.parse(data))
            let ms = Date().timeIntervalSince(start) * 1000
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let rawSubs = (raw["usercfgs"] as? [String: Any])?["appsubs"] as? [Any] ?? []
            let rawCaches = raw["appSubCaches"] as? [String: Any] ?? [:]
            let rawApps = rawCaches.values.reduce(0) { $0 + ((($1 as? [String: Any])?["apps"] as? [Any])?.count ?? 0) }
            let usable = box.displayAppSubSummaries.filter { $0.appCount > 0 }
            let cachedApps = usable.reduce(0) { $0 + $1.appCount }
            check(box.usercfgs?.appsubs.isEmpty == false || rawSubs.isEmpty, "\(file): subscriptions survive")
            check(cachedApps >= rawApps - box.issues.filter { $0.message.contains("缺少 id") }.count,
                  "\(file): only id-less apps may be skipped (\(cachedApps)/\(rawApps))")
            print("  \(file): \(usable.count) subs, \(box.apps.count) apps, \(box.issues.count) issues, \(Int(ms)) ms")
        }
    }
}

print(failures == 0 ? "\nPASS: \(checks) checks" : "\nFAIL: \(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
