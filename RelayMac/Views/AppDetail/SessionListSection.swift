//
//  SessionListSection.swift
//  RelayMac
//

import AppKit
import SwiftUI

struct SessionListSection: View {
    let app: AppModel
    let sessions: [Session]
    let currentSessionId: String?
    var onRenameRequested: (Session) -> Void

    @EnvironmentObject var boxModel: BoxJsViewModel
    @EnvironmentObject var toastManager: ToastManager

    var body: some View {
        WorkbenchSectionBlock(title: "会话") {
            if sessions.isEmpty {
                Text("暂无会话。点击右上角「新建」保存当前数据为会话。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { pair in
                        let idx = pair.offset
                        let session = pair.element
                        SessionRow(
                            session: session,
                            index: idx,
                            isActive: session.id == currentSessionId
                        )
                        .contextMenu { menu(for: session) }
                        .swipeActions(edge: .trailing) { swipe(for: session) }

                        if idx < sessions.count - 1 {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }
        } accessory: {
            Button {
                createEmpty()
            } label: {
                Label("新建", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("从当前应用数据新建会话")
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private func menu(for session: Session) -> some View {
        Button("使用") { use(session) }
        Button("克隆") { clone(session) }
        Button("重命名…") { onRenameRequested(session) }
        Button("复制 JSON") { copyJSON(session) }
        Divider()
        Button("删除", role: .destructive) { askDelete(session) }
    }

    @ViewBuilder
    private func swipe(for session: Session) -> some View {
        Button {
            askDelete(session)
        } label: {
            Label("删除", systemImage: "trash")
        }
        .tint(.red)

        Button {
            use(session)
        } label: {
            Label("使用", systemImage: "play.circle")
        }
        .tint(.blue)

        Button {
            clone(session)
        } label: {
            Label("克隆", systemImage: "plus.square.on.square")
        }
        .tint(.teal)
    }

    // MARK: - Actions

    private func use(_ session: Session) {
        boxModel.useAppSession(sessionId: session.id, appId: session.appId)
        boxModel.linkAppSession(sessionId: session.id, appId: session.appId)
        toastManager.showToast(message: "已应用会话")
    }

    private func clone(_ session: Session) {
        boxModel.cloneAppSession(session)
        toastManager.showToast(message: "已克隆")
    }

    private func copyJSON(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(session),
           let string = String(data: data, encoding: .utf8) {
            PlatformBridge.copyToPasteboard(string)
            toastManager.showToast(message: "已复制 JSON")
        } else {
            toastManager.showToast(message: "编码失败")
        }
    }

    private func askDelete(_ session: Session) {
        let alert = NSAlert()
        alert.messageText = "删除会话 \"\(session.name)\"？"
        alert.informativeText = "该操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            boxModel.delAppSession(sessionId: session.id)
            toastManager.showToast(message: "已删除")
        }
    }

    private func createEmpty() {
        // Save the app's own data as a new session, as the web UI and iOS do. An app
        // without `keys` gets an empty session: snapshotting every stored key would
        // make applying the session overwrite other apps' data.
        let datas = boxModel.boxData.loadAppDataInfo(for: app).datas
        boxModel.saveAppSession(app: app, datas: datas)
        toastManager.showToast(message: "已保存当前数据为新会话")
    }
}
