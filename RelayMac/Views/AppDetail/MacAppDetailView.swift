//
//  MacAppDetailView.swift
//  RelayMac
//

import SwiftUI

struct MacAppDetailView: View {
    let app: AppModel
    @EnvironmentObject var boxModel: BoxJsViewModel
    @EnvironmentObject var toastManager: ToastManager
    @EnvironmentObject var chrome: WindowChromeModel
    @Environment(\.dismiss) private var dismiss

    /// Setting values as edited, keyed by setting id; seeded once on appear.
    @State private var drafts: [String: JSONValue] = [:]
    /// The seeded values, so saving writes back only what was edited.
    @State private var originals: [String: JSONValue] = [:]
    @State private var saving: Bool = false
    @State private var renameTarget: Session?
    @State private var showImportSession: Bool = false
    @State private var showClearConfirm: Bool = false

    var body: some View {
        WorkbenchPageScroll {
            headerSection
            basicsSection
            settingsSection
            sessionSection
            scriptsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.hidden)
        .background {
            Button("", action: save)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasChanges || saving)
                .hidden()
        }
        .onAppear {
            primeDrafts()
            updateChrome()
        }
        .onChange(of: hasChanges) { _, _ in updateChrome() }
        .onChange(of: saving) { _, _ in updateChrome() }
        .onReceive(boxModel.$boxData) { _ in updateChrome() }
        .popover(item: $renameTarget, arrowEdge: .trailing) { session in
            RenameSessionPopover(session: session)
                .environmentObject(boxModel)
                .environmentObject(toastManager)
        }
        .sheet(isPresented: $showImportSession) {
            NavigationStack {
                MacImportSessionView()
                    .environmentObject(boxModel)
                    .environmentObject(toastManager)
            }
            .frame(minWidth: 640, minHeight: 420)
        }
        .confirmationDialog(
            "确定要清除这个应用的所有数据吗？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                boxModel.clearAppDatas(app: app)
                toastManager.showToast(message: "已清除")
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.name)
                .font(.largeTitle).bold()
                .foregroundStyle(.primary)
            Text(app.author.asHandle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var basicsSection: some View {
        WorkbenchSectionBlock(title: "基础") {
            LabeledContent("名称") { Text(app.name) }
            LabeledContent("作者") { Text(app.author) }
            if let repo = app.repo, !repo.isEmpty, let url = URL(string: repo) {
                LabeledContent("Repo") {
                    Link(repo, destination: url)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        if app.hasDescription {
            WorkbenchSectionBlock(title: "说明") {
                descriptionContent
            }
        }
    }

    @ViewBuilder
    private var descriptionContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let desc = app.desc, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let descs = app.descs, !descs.isEmpty {
                ForEach(descs, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let html = app.desc_html, !html.isEmpty {
                htmlText(html)
            }
            if let descs_html = app.descs_html, !descs_html.isEmpty {
                htmlText(descs_html.joined(separator: "<br>"))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func htmlText(_ html: String) -> some View {
        if let attributed = Self.attributedString(fromHTML: html) {
            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(html)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Parses HTML into an `AttributedString` for SwiftUI `Text`. Drops the
    /// HTML-defaulted black foreground color so the text inherits from the
    /// surrounding environment (important for dark mode).
    private static func attributedString(fromHTML html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let ns = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        let mutable = NSMutableAttributedString(attributedString: ns)
        let range = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.foregroundColor, range: range)
        return try? AttributedString(mutable, including: \.swiftUI)
    }

    @ViewBuilder
    private var settingsSection: some View {
        if let settings = app.settings, !settings.isEmpty {
            WorkbenchSectionBlock(title: "设置") {
                ForEach(settings, id: \.id) { setting in
                    SettingRowMac(
                        setting: setting,
                        value: binding(for: setting)
                    )
                }
            }
        } else {
            WorkbenchSectionBlock(title: "设置") {
                Text("此应用没有可编辑项")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sessionSection: some View {
        SessionListSection(
            app: app,
            sessions: sessionsForThisApp,
            currentSessionId: currentSessionId,
            onRenameRequested: { renameTarget = $0 }
        )
    }

    @ViewBuilder
    private var scriptsSection: some View {
        if let scripts = app.scripts, !scripts.isEmpty {
            ScriptsSection(scripts: scripts)
        }
    }

    // MARK: - Derived data

    private var sessionsForThisApp: [Session] {
        boxModel.boxData.sessions.filter { $0.appId == app.id }
    }

    private var currentSessionId: String? {
        boxModel.boxData.curSessions?[app.id]
    }

    // MARK: - Drafts

    private func primeDrafts() {
        guard drafts.isEmpty, let settings = app.settings else { return }
        for setting in settings {
            // A value saved since the app list was fetched is only in `datas` so far.
            let stored = boxModel.boxData.datas[setting.id].flatMap { $0.isNull ? nil : $0 }
            drafts[setting.id] = stored ?? setting.val
        }
        originals = drafts
    }

    private func binding(for setting: Setting) -> Binding<JSONValue> {
        Binding(
            get: { drafts[setting.id] ?? setting.val },
            set: { drafts[setting.id] = $0 }
        )
    }

    /// Settings whose value differs from the seeded one as BoxJS would store it.
    private var changedSettings: [Setting] {
        (app.settings ?? []).compactMap { setting in
            guard let draft = drafts[setting.id],
                  draft.wireText != originals[setting.id]?.wireText else { return nil }
            var edited = setting
            edited.val = draft
            return edited
        }
    }

    private var hasChanges: Bool {
        !changedSettings.isEmpty
    }

    private func updateChrome() {
        chrome.setBackAction { dismiss() }
        var items: [WindowChromeMenuItem] = [
            WindowChromeMenuItem(
                title: "导入会话",
                systemImage: "square.and.arrow.down",
                action: { showImportSession = true }
            ),
            WindowChromeMenuItem(
                title: "复制数据",
                systemImage: "doc.on.doc",
                isDisabled: appKeys.isEmpty,
                action: copyAppDatas
            ),
            WindowChromeMenuItem(
                title: "复制会话",
                systemImage: "person.crop.square",
                isDisabled: currentSession == nil,
                action: {
                    if let session = currentSession {
                        copySession(session)
                    }
                }
            ),
            WindowChromeMenuItem(
                title: "清除数据",
                systemImage: "trash",
                role: .destructive,
                isDisabled: appKeys.isEmpty,
                action: { showClearConfirm = true }
            )
        ]
        chrome.setActions([
            WindowChromeAction(
                title: "保存",
                systemImage: "tray.and.arrow.down",
                isPrimary: true,
                isDisabled: !hasChanges || saving,
                kind: .button(action: save)
            ),
            WindowChromeAction(
                title: "更多",
                systemImage: "ellipsis",
                kind: .menu(items: items)
            )
        ])
    }

    private func save() {
        let changed = changedSettings
        guard !changed.isEmpty else { return }
        saving = true
        boxModel.saveSettings(changed)
        for setting in changed {
            originals[setting.id] = setting.val
        }
        toastManager.showToast(message: "已提交")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            saving = false
        }
    }

    // MARK: - Session ops

    private var appKeys: [String] {
        app.keys ?? []
    }

    private var currentSession: Session? {
        guard let id = currentSessionId else { return nil }
        return boxModel.boxData.sessions.first { $0.id == id }
    }

    /// Same shape as the web UI's copy: `{ key: value }` with values in their stored types.
    private func copyAppDatas() {
        var result: [String: JSONValue] = [:]
        for key in appKeys {
            result[key] = boxModel.boxData.datas[key] ?? .null
        }
        PlatformBridge.copyToPasteboard(JSONValue.object(result).compactJSONText)
        toastManager.showToast(message: "已复制数据")
    }

    private func copySession(_ session: Session) {
        PlatformBridge.copyToPasteboard(session.jsonValue.prettyJSONText)
        toastManager.showToast(message: "已复制会话")
    }
}
