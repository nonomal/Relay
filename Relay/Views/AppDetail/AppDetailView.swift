//
//  AppDetailView.swift
//  NEBox
//
//  Created by Senku on 8/27/24.
//

import SwiftUI
import UIKit
import WebKit
import AnyCodable
import SDWebImageSwiftUI
import UniformTypeIdentifiers

struct HTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "sizeNotify")
        config.userContentController = userController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrapped = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
                font-family: -apple-system, sans-serif;
                font-size: 14px;
                line-height: 1.5;
                color: #666;
                background: transparent;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            img { max-width: 100%; height: auto; }
            a { color: #007AFF; }
        </style>
        </head>
        <body>
        \(html)
        <script>
            function notifySize() {
                var h = document.body.scrollHeight;
                window.webkit.messageHandlers.sizeNotify.postMessage(h);
            }
            window.onload = notifySize;
            new MutationObserver(notifySize).observe(document.body, { childList: true, subtree: true });
            // fallback
            setTimeout(notifySize, 200);
            setTimeout(notifySize, 500);
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat

        init(height: Binding<CGFloat>) {
            _height = height
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "sizeNotify", let h = message.body as? CGFloat {
                DispatchQueue.main.async {
                    if h > 0 && h != self.height {
                        self.height = h
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

// MARK: - iOS 15 Compatibility

struct HideScrollContentBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content.onAppear {
                UITextView.appearance().backgroundColor = .clear
            }
        }
    }
}

struct HTMLTextView: View {
    let html: String
    @State private var webViewHeight: CGFloat = 1

    var body: some View {
        HTMLWebView(html: html, height: $webViewHeight)
            .frame(height: webViewHeight)
    }
}


struct AppHeaderView: View {
    let app: AppModel
    /// Favourite lives in the header card now, so the nav bar is free for "more".
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    /// Status strip content, derived from data already in `cachedAppDataInfo`.
    var dataCount: Int = 0
    var sessionName: String? = nil
    var lastRunText: String? = nil

    @Environment(\.openURL) private var openURL

    private var repoURL: URL? {
        guard let repo = app.repo, !repo.isEmpty else { return nil }
        return URL(string: repo)
    }

    private var showsStrip: Bool {
        dataCount > 0 || sessionName != nil || lastRunText != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconView(app: app, size: 54)
                    .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundColor(.textPrimary)
                    Text(app.author)
                        .font(.system(size: 12.5))
                        .foregroundColor(.textSecondary)
                    if let repo = app.repo, !repo.isEmpty {
                        HStack(spacing: 3) {
                            if repoURL != nil {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            Text(repo)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11.5))
                        .foregroundColor(repoURL != nil ? .accent : .textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let url = repoURL { openURL(url) }
                }

                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 19))
                            .foregroundColor(isFavorite ? .accentRed : .textTertiary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
                }
            }
            .padding(DetailMetrics.rowHPadding)

            if showsStrip {
                DetailRowDivider()
                statusStrip
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 7) {
            DetailStatusDot(state: dataCount > 0 ? .ok : .idle)
            Text(dataCount > 0 ? "\(dataCount) 项数据" : "无数据")

            if let sessionName {
                Text("·").foregroundColor(.textTertiary)
                Text("会话 \(sessionName)").lineLimit(1)
            }
            if let lastRunText {
                Text("·").foregroundColor(.textTertiary)
                Text(lastRunText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundColor(.textSecondary)
        .padding(.horizontal, DetailMetrics.rowHPadding)
        .padding(.vertical, 9)
    }
}

struct AppDescCardView: View {
    let app: AppModel?

    var body: some View {
        if app?.hasDescription == true {
            VStack(alignment: .leading, spacing: 2) {
                if let desc = app?.desc {
                    Text(desc)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let descs = app?.descs {
                    ForEach(descs, id: \.self) { desc in
                        Text(desc)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let html = app?.desc_html {
                    HTMLTextView(html: html)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let descs_html = app?.descs_html {
                    let html = descs_html.joined(separator: "<br>")
                    HTMLTextView(html: html)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct AppScriptsView: View {
    let scripts: [RunScript]
    var onScriptResult: ((ScriptResp) -> Void)? = nil
    @State private var loadingScript: String? = nil
    /// Per-script outcome of the last run in this session. `RunScript` carries no
    /// history, so this is the only place the result can live.
    @State private var lastRun: [String: ScriptRunState] = [:]
    @EnvironmentObject var boxModel: BoxJsViewModel

    struct ScriptRunState {
        let succeeded: Bool
        let at: Date
    }

    var body: some View {
        ForEach(Array(scripts.enumerated()), id: \.element.script) { index, script in
            if index > 0 { DetailRowDivider() }
            scriptRow(script)
        }
    }

    private func scriptRow(_ script: RunScript) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(script.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.textPrimary)
                HStack(spacing: 5) {
                    DetailStatusDot(state: dotState(for: script))
                    Text(subtitle(for: script))
                }
                .font(.system(size: 11))
                .foregroundColor(.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if loadingScript == script.script {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 30, height: 30)
            } else {
                Button {
                    Task { await run(script) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(hasRun(script) ? .white : .accent)
                        .frame(width: 30, height: 30)
                        .background(
                            hasRun(script) ? Color.accent : Color.bgMuted,
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("运行 \(script.name)")
            }
        }
        .padding(.horizontal, DetailMetrics.rowHPadding)
        .padding(.vertical, 11)
    }

    private func hasRun(_ script: RunScript) -> Bool {
        lastRun[script.script] != nil
    }

    private func dotState(for script: RunScript) -> DetailStatusDot.State {
        guard let state = lastRun[script.script] else { return .idle }
        return state.succeeded ? .ok : .danger
    }

    private func subtitle(for script: RunScript) -> String {
        guard let state = lastRun[script.script] else { return "尚未运行" }
        let when = RelativeTime.string(from: ISO8601DateFormatter().string(from: state.at))
        return "\(when) · \(state.succeeded ? "成功" : "失败")"
    }

    private func run(_ script: RunScript) async {
        loadingScript = script.script
        do {
            let resp: ScriptResp = try await NetworkProvider.request(.runScript(url: script.script))
            lastRun[script.script] = ScriptRunState(
                succeeded: resp.exception?.isEmpty ?? true,
                at: Date()
            )
            onScriptResult?(resp)
            boxModel.fetchData()
        } catch {
            lastRun[script.script] = ScriptRunState(succeeded: false, at: Date())
            onScriptResult?(ScriptResp(exception: "请求失败: \(error.localizedDescription)", output: nil))
        }
        loadingScript = nil
    }
}


// MARK: - Form Setting Row

struct FormSettingRow: View {
    let setting: Setting
    let index: Int
    @Binding var settings: [Setting]

    private func binding(for index: Int) -> Binding<String> {
        Binding<String>(
            get: { (settings[index].val?.value as? String) ?? "" },
            set: { settings[index].val = AnyCodable($0) }
        )
    }

    private func boolBinding(for index: Int) -> Binding<Bool> {
        Binding<Bool>(
            get: { (settings[index].val?.value as? Bool) ?? false },
            set: { settings[index].val = AnyCodable($0) }
        )
    }

    private func doubleBinding(for index: Int) -> Binding<Double> {
        Binding<Double>(
            get: {
                if let val = settings[index].val?.value {
                    if let d = val as? Double { return d }
                    if let n = val as? Int { return Double(n) }
                    if let s = val as? String, let d = Double(s) { return d }
                }
                return 0
            },
            set: { settings[index].val = AnyCodable($0) }
        )
    }

    private func colorBinding(for index: Int) -> Binding<Color> {
        Binding<Color>(
            get: {
                if let hex = settings[index].val?.value as? String, !hex.isEmpty {
                    return Color(hex: hex)
                }
                return .blue
            },
            set: { settings[index].val = AnyCodable($0.toHex()) }
        )
    }

    private func arrayBinding(for index: Int) -> Binding<[String]> {
        Binding<[String]>(
            get: { (settings[index].val?.value as? [String]) ?? [] },
            set: { settings[index].val = AnyCodable($0) }
        )
    }

    private func pickerBinding(for index: Int, items: [RadioItem]) -> Binding<String> {
        Binding<String>(
            get: {
                let current = (settings[index].val?.value as? String) ?? ""
                if items.contains(where: { $0.key == current }) { return current }
                return items.first?.key ?? ""
            },
            set: { settings[index].val = AnyCodable($0) }
        )
    }

    private var title: String { setting.name ?? setting.id }

    var body: some View {
        switch setting.type {
        // Option lists own their whole row — the label sits above the card-style options.
        case "radios", "checkboxes":
            optionGroup(isMultiSelect: setting.type == "checkboxes")

        default:
            DetailSettingRow(title: title, desc: setting.desc) {
                settingControl
            }
        }
    }

    // MARK: Option groups

    @ViewBuilder
    private func optionGroup(isMultiSelect: Bool) -> some View {
        let items = setting.items ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let desc = setting.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11.5))
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DetailMetrics.rowHPadding)
            .padding(.top, DetailMetrics.rowVPadding)
            .padding(.bottom, 8)

            if items.isEmpty {
                Text("无可选项")
                    .font(.system(size: 12.5))
                    .foregroundColor(.textTertiary)
                    .padding(.horizontal, DetailMetrics.rowHPadding)
                    .padding(.bottom, DetailMetrics.rowVPadding)
            } else if isMultiSelect {
                let selected = arrayBinding(for: index)
                ForEach(Array(items.enumerated()), id: \.element.key) { i, item in
                    if i > 0 { DetailRowDivider() }
                    DetailOptionRow(
                        label: item.label,
                        isSelected: selected.wrappedValue.contains(item.key),
                        isMultiSelect: true
                    ) {
                        var keys = selected.wrappedValue
                        if let idx = keys.firstIndex(of: item.key) {
                            keys.remove(at: idx)
                        } else {
                            keys.append(item.key)
                        }
                        selected.wrappedValue = keys
                    }
                }
            } else {
                let selected = pickerBinding(for: index, items: items)
                ForEach(Array(items.enumerated()), id: \.element.key) { i, item in
                    if i > 0 { DetailRowDivider() }
                    DetailOptionRow(
                        label: item.label,
                        isSelected: selected.wrappedValue == item.key,
                        isMultiSelect: false
                    ) {
                        selected.wrappedValue = item.key
                    }
                }
            }
        }
    }

    // MARK: Single-row controls

    @ViewBuilder
    private var settingControl: some View {
        switch setting.type {
        case "boolean":
            DetailInlineLabel(title: title) {
                Toggle("", isOn: boolBinding(for: index))
                    .labelsHidden()
                    .tint(.green)
            }

        case "textarea":
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DetailTextEditor(
                    placeholder: setting.placeholder ?? "请输入内容",
                    text: binding(for: index)
                )
            }

        case "selects", "modalSelects":
            let items = setting.items ?? []
            DetailInlineLabel(title: title) {
                if items.isEmpty {
                    Text("—").foregroundColor(.textTertiary)
                } else {
                    let selection = pickerBinding(for: index, items: items)
                    Menu {
                        Picker("", selection: selection) {
                            ForEach(items) { item in
                                Text(item.label).tag(item.key)
                            }
                        }
                    } label: {
                        DetailPillLabel(
                            text: items.first { $0.key == selection.wrappedValue }?.label
                                ?? selection.wrappedValue
                        )
                    }
                }
            }

        case "slider":
            VStack(alignment: .leading, spacing: 4) {
                DetailInlineLabel(title: title) {
                    Text(String(format: "%.0f", doubleBinding(for: index).wrappedValue))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(.accent)
                }
                Slider(value: doubleBinding(for: index), in: 0...100, step: 1)
                    .tint(.accent)
            }

        case "colorpicker":
            let color = colorBinding(for: index)
            DetailInlineLabel(title: title) {
                HStack(spacing: 7) {
                    ColorPicker("", selection: color)
                        .labelsHidden()
                        .frame(width: 28)
                    // The hex is the value users actually copy between scripts.
                    Text(color.wrappedValue.toHex())
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.textSecondary)
                }
            }

        case "number":
            DetailInlineLabel(title: title) {
                DetailStepper(value: doubleBinding(for: index))
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DetailTextField(
                    placeholder: setting.placeholder ?? "请输入内容",
                    text: binding(for: index),
                    isMonospaced: isMonospacedField
                )
            }
        }
    }

    /// Tokens, cookies and keys are strings users read character-by-character.
    private var isMonospacedField: Bool {
        let haystack = "\(setting.id) \(setting.name ?? "")".lowercased()
        return ["cookie", "token", "key", "secret", "auth", "session"]
            .contains { haystack.contains($0) }
    }
}

struct AppDetailView: View {
    @State var app: AppModel?

    @EnvironmentObject var boxModel: BoxJsViewModel
    @EnvironmentObject var toastManager: ToastManager

    @State private var showImportSession = false
    @State private var importSessionText = ""
    @State private var showImportFilePickerSession = false
    @State private var showScriptResult = false
    @State private var scriptResult: ScriptResp? = nil
    @State private var cachedAppDataInfo = AppDataInfo(datas: [], sessions: [], curSession: nil)
    @State private var isSavingSettings = false
    @State private var isRunningScript = false
    @State private var keyboardHeight: CGFloat = 0
    /// Key awaiting clear confirmation. Clearing writes empty values to the server
    /// and cannot be undone, so it is never applied straight from a tap.
    @State private var pendingClearKey: String? = nil

    /// Snapshot of setting values taken on appear. Diffing against it drives both the
    /// save button's state and the "已修改" filter, and lets saves skip untouched keys.
    @State private var originalValues: [String: String] = [:]
    @State private var settingsQuery = ""
    @State private var settingsFilter: SettingsFilter = .all
    /// Row membership captured when a filter is selected, so editing a visible row
    /// never makes it jump out of the list mid-edit.
    @State private var filterSnapshot: Set<String> = []

    enum SettingsFilter: String, CaseIterable {
        case all = "全部"
        case modified = "已修改"
        case empty = "未填写"
    }

    /// `Setting` has no grouping field, so a large list is navigated by search, not sections.
    private var showsSettingsSearch: Bool { (app?.settings?.count ?? 0) > 12 }
    private var showsSettingsFilter: Bool { (app?.settings?.count ?? 0) > 20 }

    private var modifiedSettingIds: Set<String> {
        guard !originalValues.isEmpty else { return [] }
        return Set((app?.settings ?? [])
            .filter { originalValues[$0.id] != Self.comparableValue($0.val) }
            .map(\.id))
    }

    /// Short-circuits on the first difference instead of building the whole Set —
    /// this is read several times per body pass (save button fill, its accessibility
    /// label, the group's revert action), and only the yes/no answer is needed.
    private var hasUnsavedChanges: Bool {
        guard !originalValues.isEmpty else { return false }
        return (app?.settings ?? []).contains { originalValues[$0.id] != Self.comparableValue($0.val) }
    }

    var body: some View {
        if let app = app {
            withAppBottomActions(
                ScrollView {
                    LazyVStack(spacing: DetailMetrics.groupSpacing) {
                        // MARK: App Info
                        DetailCard {
                            AppHeaderView(
                                app: app,
                                isFavorite: isFavorite(app),
                                onToggleFavorite: { toggleFav(app) },
                                dataCount: cachedAppDataInfo.datas.count,
                                sessionName: cachedAppDataInfo.curSession?.name,
                                lastRunText: nil
                            )
                        }

                        if app.hasDescription {
                            DetailCard {
                                AppDescCardView(app: app)
                                    .padding(DetailMetrics.rowHPadding)
                            }
                        }

                        // MARK: Scripts
                        if let scripts = app.scripts, !scripts.isEmpty {
                            DetailGroup(title: "脚本") {
                                AppScriptsView(scripts: scripts) { resp in
                                    scriptResult = resp
                                    showScriptResult = true
                                }
                            }
                        }

                        // MARK: Settings
                        let settings = app.settings ?? []
                        if !settings.isEmpty {
                            settingsGroup(settings: settings)
                        }

                        // MARK: Session Data
                        if app.keys != nil && !cachedAppDataInfo.datas.isEmpty {
                            appSessionDataSection(app: app)
                        }

                        // MARK: Sessions
                        if !cachedAppDataInfo.sessions.isEmpty {
                            sessionsGroup(app: app)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
                .neboxDismissKeyboardOnScroll()
                .background(RelayPageBackground())
                // 沉浸式导航栏：push 进来的详情页，标题常显（页内没有替代性大标题
                // ——头部卡片是图标 + 元信息，不是大字应用名）。
                .navigationBar(.init(
                    chrome: .plain(background: .gradientTop),
                    title: .fixed(app.name)
                )),
                app: app
            )
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    keyboardHeight = frame.height
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardHeight = 0
            }
            .neboxHideTabBar()
            .sheet(isPresented: $showImportSession) {
                importSessionSheet(app: app)
            }
            .sheet(isPresented: $showScriptResult) {
                scriptResultSheet
            }
            .onDisappear {
                Task {
                    await boxModel.flushPendingDataUpdates()
                }
            }
            .onAppear {
                refreshCachedAppDataInfo()
                captureSettingsSnapshot()
            }
            .onReceive(boxModel.$boxData) { _ in
                refreshCachedAppDataInfo()
            }
        }
    }

    @ViewBuilder
    private func withAppBottomActions<Content: View>(_ content: Content, app: AppModel) -> some View {
        // `ToolbarSpacer` is an iOS 26 SDK symbol, so the native toolbar branch needs
        // the compile-time guard on top of the runtime `#available` check.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        appSaveToolbarButton(app: app)
                        if let script = app.script, !script.isEmpty {
                            appRunToolbarButton(script: script)
                        }
                    }
                }
                .modifier(AppOverflowToolbar(menu: appOverflowMenu(app: app)))
        } else {
            appLegacyBottomActions(content, app: app)
        }
        #else
        appLegacyBottomActions(content, app: app)
        #endif
    }

    @ViewBuilder
    private func appLegacyBottomActions<Content: View>(_ content: Content, app: AppModel) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                appLegacyBottomActionBar(app: app)
                    .offset(y: keyboardHeight)
            }
            .modifier(AppOverflowToolbar(menu: appOverflowMenu(app: app)))
    }

    // MARK: - Current Session Data Section

    private func appSessionDataSection(app: AppModel) -> some View {
        AppCurrentSessionSection(
            app: app,
            datas: cachedAppDataInfo.datas,
            currentSessionName: cachedAppDataInfo.curSession?.name,
            onRequestClear: { pendingClearKey = $0 },
            onClone: {
                boxModel.saveAppSession(app: app, datas: cachedAppDataInfo.datas)
                toastManager.showToast(message: "已克隆会话")
            }
        )
        .confirmationDialog(
            "清除「\(pendingClearKey ?? "")」的数据？",
            isPresented: Binding(
                get: { pendingClearKey != nil },
                set: { if !$0 { pendingClearKey = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                if let key = pendingClearKey {
                    boxModel.clearAppDatas(app: app, key: key)
                    toastManager.showToast(message: "已清除")
                }
                pendingClearKey = nil
            }
            Button("取消", role: .cancel) { pendingClearKey = nil }
        } message: {
            Text("该操作会清空此项数据且无法撤销。")
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private func settingsGroup(settings: [Setting]) -> some View {
        let visible = visibleSettingIndices(in: settings)

        // Header, search and chips all live inside the card so nothing but the card
        // itself ever sits on the wallpaper.
        DetailCard {
            DetailGroupHeader(
                title: "设置 · \(settings.count) 项",
                actionTitle: hasUnsavedChanges ? "撤销" : nil,
                action: hasUnsavedChanges ? revertSettings : nil
            )

            if showsSettingsSearch || showsSettingsFilter {
                DetailRowDivider()
                VStack(spacing: 8) {
                    if showsSettingsSearch {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundColor(.textTertiary)
                            TextField("搜索设置项", text: $settingsQuery)
                                .font(.system(size: 13.5))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if !settingsQuery.isEmpty {
                                Button {
                                    settingsQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }

                    if showsSettingsFilter {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                // Computed once per render, not once per chip: the
                                // diff walks every setting and each chip would repeat it.
                                let modified = modifiedSettingIds
                                ForEach(SettingsFilter.allCases, id: \.self) { filter in
                                    filterChip(filter, settings: settings, modified: modified)
                                }
                            }
                            .padding(.horizontal, 1)
                        }
                    }
                }
                .padding(.horizontal, DetailMetrics.rowHPadding)
                .padding(.vertical, 10)
            }

            DetailRowDivider()

            if visible.isEmpty {
                Text("没有匹配的设置项")
                    .font(.system(size: 13))
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element) { position, index in
                    if position > 0 { DetailRowDivider() }
                    FormSettingRow(
                        setting: settings[index],
                        index: index,
                        settings: bindingForSettings()
                    )
                }
            }
        }
    }

    private func filterChip(_ filter: SettingsFilter, settings: [Setting], modified: Set<String>) -> some View {
        let isOn = settingsFilter == filter
        let count: Int? = {
            switch filter {
            case .all: return nil
            case .modified: return modified.count
            case .empty: return settings.filter { Self.isEmptyValue($0.val) }.count
            }
        }()

        return Button {
            settingsFilter = filter
            filterSnapshot = Self.membership(for: filter, in: settings, modified: modified)
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                if let count, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.75)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isOn ? .bgCard : .textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isOn ? Color.textPrimary : Color.bgCard)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? Color.clear : Color.borderSubtle, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Indices into the unfiltered array — `FormSettingRow` writes back by index.
    private func visibleSettingIndices(in settings: [Setting]) -> [Int] {
        let query = settingsQuery.trimmingCharacters(in: .whitespaces).lowercased()

        return settings.indices.filter { index in
            let setting = settings[index]

            if showsSettingsFilter {
                switch settingsFilter {
                case .all: break
                case .modified:
                    // Membership is frozen when the filter is picked. Recomputing live
                    // would make a row vanish the moment you edited it back to its
                    // original value — or appear under your finger as you typed.
                    guard filterSnapshot.contains(setting.id) else { return false }
                case .empty:
                    guard filterSnapshot.contains(setting.id) else { return false }
                }
            }

            guard showsSettingsSearch, !query.isEmpty else { return true }
            return setting.id.lowercased().contains(query)
                || (setting.name ?? "").lowercased().contains(query)
        }
    }

    private func revertSettings() {
        guard var settings = app?.settings else { return }
        for index in settings.indices {
            if let original = originalValues[settings[index].id] {
                settings[index].val = original.isEmpty ? AnyCodable(nil) : AnyCodable(original)
            }
        }
        app?.settings = settings
        toastManager.showToast(message: "已撤销改动")
    }

    private func captureSettingsSnapshot() {
        // Only snapshot once per visit; re-capturing would erase pending edits.
        guard originalValues.isEmpty, let settings = app?.settings, !settings.isEmpty else { return }
        originalValues = Dictionary(
            settings.map { ($0.id, Self.comparableValue($0.val)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Stable string form used for diffing — AnyCodable is not Equatable.
    /// `JSONEncoder` is comparatively expensive to build; `comparableValue` runs once
    /// per setting per diff, so it must not allocate one each time.
    private static let comparisonEncoder = JSONEncoder()

    private static func comparableValue(_ val: AnyCodable?) -> String {
        guard let value = val?.value else { return "" }
        if value is NSNull { return "" }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let arr = value as? [String] { return arr.joined(separator: ",") }
        if let encoded = try? Self.comparisonEncoder.encode(AnyCodable(value)),
           let str = String(data: encoded, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }

    private static func isEmptyValue(_ val: AnyCodable?) -> Bool {
        comparableValue(val).isEmpty
    }

    private static func membership(
        for filter: SettingsFilter,
        in settings: [Setting],
        modified: Set<String>
    ) -> Set<String> {
        switch filter {
        case .all:      return Set(settings.map(\.id))
        case .modified: return modified
        case .empty:    return Set(settings.filter { isEmptyValue($0.val) }.map(\.id))
        }
    }

    // MARK: - Current Session Data Row

    // MARK: - Sessions

    private func sessionsGroup(app: AppModel) -> some View {
        AppSessionsSection(
            app: app,
            sessions: cachedAppDataInfo.sessions,
            currentSessionId: cachedAppDataInfo.curSession?.id,
            onImport: { showImportSession = true }
        )
    }

    // MARK: - Import Session Sheet

    private func importSessionSheet(app: AppModel) -> some View {
        neboxNavigationContainer {
            Form {
                Section(footer: Text("支持 JSON 格式的会话数据")) {
                    Button {
                        guard let str = UIPasteboard.general.string, !str.isEmpty else {
                            toastManager.showToast(message: "剪贴板为空")
                            return
                        }
                        importSessionText = str
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        showImportFilePickerSession = true
                    } label: {
                        Label("从文件导入", systemImage: "doc")
                    }
                }

                if !importSessionText.isEmpty {
                    Section(header: Text("数据预览")) {
                        ScrollView {
                            Text(importSessionText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }
            .navigationTitle("导入会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showImportSession = false
                        importSessionText = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认导入") {
                        performImportSession()
                    }
                    .disabled(importSessionText.isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showImportFilePickerSession,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url),
                       let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        importSessionText = str
                        performImportSession()
                    } else {
                        toastManager.showToast(message: "文件读取失败")
                    }
                }
            }
        }
    }

    private func performImportSession() {
        guard !importSessionText.isEmpty else { return }
        if boxModel.importSession(jsonString: importSessionText) {
            toastManager.showToast(message: "导入会话成功!")
        } else {
            toastManager.showToast(message: "会话数据格式错误")
        }
        showImportSession = false
        importSessionText = ""
    }

    // MARK: - Script Result Sheet

    private var scriptResultSheet: some View {
        ScriptResultSheetView(
            scriptResult: scriptResult,
            onClose: { showScriptResult = false }
        )
    }

    /// Secondary operations (import / copy / clear). These are page-level actions on
    /// the app itself, not the bar's save-and-run pair, so they belong in the nav bar.
    private func appOverflowMenu(app: AppModel) -> some View {
        Menu {
            Button {
                showImportSession = true
            } label: {
                Label("导入会话", systemImage: "square.and.arrow.down")
            }

            Button(action: copyAppDatas) {
                Label("复制数据", systemImage: "doc.on.clipboard")
            }

            Button {
                if let session = cachedAppDataInfo.curSession {
                    copySession(session)
                }
            } label: {
                Label("复制会话", systemImage: "doc.on.doc")
            }
            .disabled(cachedAppDataInfo.curSession == nil)

            Divider()

            Button(role: .destructive) {
                Task {
                    boxModel.clearAppDatas(app: app)
                    toastManager.showToast(message: "已清除")
                }
            } label: {
                Label("清除数据", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
        }
        .accessibilityLabel("更多操作")
    }

    @available(iOS 26.0, *)
    private func appSaveToolbarButton(app: AppModel) -> some View {
        Button {
            Task { @MainActor in
                guard !isSavingSettings else { return }
                isSavingSettings = true
                saveCurrentAppSettings(app: app)
                isSavingSettings = false
            }
        } label: {
            if isSavingSettings {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 22, height: 22, alignment: .center)
            } else {
                // The toolbar has no room for a count, so dirty state is colour only.
                Label("保存", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(hasUnsavedChanges ? .accent : .textSecondary)
                    .frame(width: 22, height: 22, alignment: .center)
            }
        }
        .frame(minWidth: 32, minHeight: 32, alignment: .center)
        .disabled(isSavingSettings)
        .accessibilityLabel(hasUnsavedChanges ? "保存，有未保存的改动" : "保存")
    }

    @available(iOS 26.0, *)
    private func appRunToolbarButton(script: String) -> some View {
        Button {
            Task {
                guard !isRunningScript else { return }
                isRunningScript = true
                await runAppScript(script)
                isRunningScript = false
            }
        } label: {
            if isRunningScript {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 22, height: 22, alignment: .center)
            } else {
                Label("运行", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 22, height: 22, alignment: .center)
            }
        }
        .frame(minWidth: 32, minHeight: 32, alignment: .center)
        .disabled(isRunningScript)
        .accessibilityLabel("运行")
    }

    /// Floating capsule rather than a full-width bar: a bar cuts the page in two and
    /// hides a strip of wallpaper, and it shares no shape language with the app's own
    /// floating tab bar. This uses the same glass pane that tab bar does.
    private func appLegacyBottomActionBar(app: AppModel) -> some View {
        let hasRun = app.script?.isEmpty == false

        // The overflow menu now lives in the nav bar, so this capsule holds only the
        // two actions that belong to the page's edit cycle.
        return HStack(spacing: 8) {
                // Save carries its own state: grey when clean, accent-tinted when there
                // are edits, and solid only when it is the bar's single action.
                DetailActionButton(
                    title: "保存",
                    systemImage: "square.and.arrow.down",
                    emphasis: saveEmphasis(hasRun: hasRun),
                    isBusy: isSavingSettings
                ) {
                    Task { @MainActor in
                        guard !isSavingSettings else { return }
                        isSavingSettings = true
                        saveCurrentAppSettings(app: app)
                        isSavingSettings = false
                    }
                }
                .accessibilityLabel(hasUnsavedChanges ? "保存，有未保存的改动" : "保存")

                if let script = app.script, !script.isEmpty {
                    DetailActionButton(
                        title: "运行",
                        systemImage: "play.fill",
                        emphasis: .primary,
                        isBusy: isRunningScript
                    ) {
                        Task {
                            guard !isRunningScript else { return }
                            isRunningScript = true
                            await runAppScript(script)
                            isRunningScript = false
                        }
                    }
                    .shadow(color: Color.accent.opacity(0.13), radius: 10, x: 0, y: 4)
                    .accessibilityLabel("运行")
                }

            }
            // Geometry mirrors `RelayTabBar` exactly — 64pt tall, 21pt side inset,
            // 4pt off the bottom — so the capsule sits precisely where the tab bar
            // does. The detail page replaces the tab bar; it should occupy its slot.
            .padding(.horizontal, 6)
            .frame(height: RelayTabBar.barHeight)
            .background(RelayGlassBackground(cornerRadius: RelayTabBar.barHeight / 2))
            .padding(.horizontal, 21)
            .padding(.bottom, 4)
    }

    // MARK: - Helpers

    /// Grey when clean; accent-tinted when dirty; solid only when it is the sole action.
    private func saveEmphasis(hasRun: Bool) -> DetailActionButton.Emphasis {
        guard hasUnsavedChanges else { return hasRun ? .neutral : .primary }
        return hasRun ? .soft : .primary
    }

    @MainActor
    private func saveCurrentAppSettings(app: AppModel) {
        let allSettings = app.settings ?? []
        let changedIds = modifiedSettingIds
        // Only push what actually changed. On first save of an untouched page the
        // snapshot may be empty, so fall back to a full submit.
        let payload = changedIds.isEmpty
            ? allSettings
            : allSettings.filter { changedIds.contains($0.id) }

        guard !payload.isEmpty else {
            toastManager.showToast(message: "没有需要保存的改动")
            return
        }

        boxModel.saveData(params: payload.map { setting in
            let transformedVal: AnyCodable = {
                if setting.type == "checkboxes", let arrayVal = setting.val?.value as? [String] {
                    return AnyCodable(arrayVal.joined(separator: ","))
                } else if let val = setting.val {
                    return val
                } else {
                    return AnyCodable(nil)
                }
            }()
            return SessionData(key: setting.id, val: transformedVal)
        })

        // Saved values become the new baseline, returning the button to its clean state.
        for setting in payload {
            originalValues[setting.id] = Self.comparableValue(setting.val)
        }
        toastManager.showToast(message: "保存成功!")
    }

    private func runAppScript(_ script: String) async {
        do {
            let resp: ScriptResp = try await NetworkProvider.request(.runScript(url: script))
            scriptResult = resp
            showScriptResult = true
            boxModel.fetchData()
        } catch {
            scriptResult = ScriptResp(exception: "请求失败: \(error.localizedDescription)", output: nil)
            showScriptResult = true
        }
    }

    private func refreshCachedAppDataInfo() {
        guard let app = app else {
            cachedAppDataInfo = AppDataInfo(datas: [], sessions: [], curSession: nil)
            return
        }
        cachedAppDataInfo = boxModel.boxData.loadAppDataInfo(for: app)
    }

    private func bindingForSettings() -> Binding<[Setting]> {
        return Binding<[Setting]>(
            get: { app?.settings ?? [] },
            set: { newValue in
                app?.settings = newValue
            }
        )
    }

    private func isFavorite(_ app: AppModel) -> Bool {
        let favIds = boxModel.boxData.usercfgs?.favapps ?? []
        return favIds.contains(app.id)
    }

    private func toggleFav(_ app: AppModel) {
        var favIds = boxModel.boxData.usercfgs?.favapps ?? []
        if let idx = favIds.firstIndex(of: app.id) {
            favIds.remove(at: idx)
        } else {
            favIds.append(app.id)
        }
        boxModel.updateData(path: "usercfgs.favapps", data: favIds)
    }

    private func copySession(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(session),
           let str = String(data: data, encoding: .utf8) {
            copyToClipboard(text: str)
            toastManager.showToast(message: "已复制会话")
        }
    }

    private func copyAppDatas() {
        var result: [String: String] = [:]
        for data in cachedAppDataInfo.datas {
            result[data.key] = SessionValueFormatter.string(data.val)
        }
        if let jsonData = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: jsonData, encoding: .utf8) {
            copyToClipboard(text: str)
            toastManager.showToast(message: "已复制数据")
        }
    }

}
