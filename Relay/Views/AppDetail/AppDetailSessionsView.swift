//
//  AppDetailSessionsView.swift
//  Relay
//
//  Session sections of the app detail page: the current session's data rows, and the
//  list of stored sessions.
//
//  Extracted from `AppDetailView` as dedicated view types rather than more computed
//  `some View` helpers — these sections have their own inputs, their own row identity,
//  and are the part of the page most likely to change independently.
//

import SwiftUI
import AnyCodable

// MARK: - Current session data

/// Data rows for the session currently in use, plus the "clone" action.
struct AppCurrentSessionSection: View {
    let app: AppModel
    let datas: [SessionData]
    let currentSessionName: String?
    /// Raised when a row's clear button is tapped; the parent owns the confirmation.
    let onRequestClear: (String) -> Void
    let onClone: () -> Void

    @EnvironmentObject private var toastManager: ToastManager

    private var title: String {
        currentSessionName.map { "当前会话 · \($0)" } ?? "当前会话"
    }

    var body: some View {
        DetailGroup(title: title, actionTitle: "克隆", action: onClone) {
            ForEach(Array(datas.enumerated()), id: \.element.key) { index, data in
                if index > 0 { DetailRowDivider() }
                AppSessionDataRow(data: data, onRequestClear: onRequestClear)
            }
        }
    }
}

/// One key/value row.
///
/// Two lines: the key reads as a label, the value gets the full row width beneath it.
/// Long values (tokens, JSON) are unreadable squeezed into a trailing column.
private struct AppSessionDataRow: View {
    let data: SessionData
    let onRequestClear: (String) -> Void

    @EnvironmentObject private var toastManager: ToastManager

    private var valueText: String { SessionValueFormatter.string(data.val) }
    private var isEmpty: Bool { valueText.isEmpty }
    /// Only surface the type when it is *not* plain text — "TEXT" on every row is noise.
    private var typeLabel: String? {
        SettingValue.typeLabel(data.val).flatMap { $0 == "TEXT" ? nil : $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(data.key)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let typeLabel {
                        Text(typeLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundColor(.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }

                Text(isEmpty ? "无数据" : valueText)
                    .font(isEmpty
                          ? .system(size: 13).italic()
                          : .system(size: 13, design: .monospaced))
                    .foregroundColor(isEmpty ? .textTertiary : .textPrimary)
                    // Head truncation keeps the tail visible — the end of a token or
                    // path is what distinguishes one value from another.
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // One menu instead of two always-on icon buttons; clearing is destructive
            // and no longer sits a few points away from copy.
            Menu {
                Button(action: copyValue) {
                    Label("复制值", systemImage: "doc.on.doc")
                }
                .disabled(isEmpty)

                Button(action: copyKey) {
                    Label("复制键名", systemImage: "textformat.abc")
                }

                Divider()

                Button(role: .destructive) {
                    onRequestClear(data.key)
                } label: {
                    Label("清除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textTertiary)
                    .frame(width: 28, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(data.key) 操作")
        }
        .padding(.leading, DetailMetrics.rowHPadding)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: copyValue)
    }

    private func copyValue() {
        guard !isEmpty else { return }
        copyToClipboard(text: valueText)
        toastManager.showToast(message: "已复制")
    }

    private func copyKey() {
        copyToClipboard(text: data.key)
        toastManager.showToast(message: "已复制键名")
    }
}

// MARK: - Stored sessions

/// The list of stored sessions, current one first.
struct AppSessionsSection: View {
    let app: AppModel
    let sessions: [Session]
    let currentSessionId: String?
    let onImport: () -> Void

    /// Current session floats to the top — it is the one users check most.
    private var ordered: [Session] {
        sessions.sorted { lhs, _ in currentSessionId == lhs.id }
    }

    var body: some View {
        DetailGroup(
            title: "历史会话 · \(sessions.count)",
            actionTitle: "导入",
            action: onImport
        ) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, session in
                if index > 0 { DetailRowDivider() }
                AppSessionRow(
                    session: session,
                    app: app,
                    isCurrent: currentSessionId == session.id
                )
            }
        }
    }
}

private struct AppSessionRow: View {
    let session: Session
    let app: AppModel
    let isCurrent: Bool

    @EnvironmentObject private var boxModel: BoxJsViewModel
    @EnvironmentObject private var toastManager: ToastManager

    /// Preview caps at 3 rows so one fat session cannot fill the screen.
    private var preview: [SessionData] { Array(session.datas.prefix(3)) }
    private var overflow: Int { session.datas.count - preview.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !preview.isEmpty { previewBlock }
            footer
        }
        .padding(.horizontal, DetailMetrics.rowHPadding)
        .padding(.vertical, DetailMetrics.rowVPadding)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(session.name)
                .font(.system(size: 14, weight: isCurrent ? .semibold : .medium))
                .foregroundColor(isCurrent ? .accent : .textPrimary)
                .lineLimit(1)

            if isCurrent {
                Text("使用中")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.accent, in: Capsule())
            }

            Spacer(minLength: 0)

            Menu {
                Button(action: link) {
                    Label("关联到此会话", systemImage: "link")
                }
                Button(action: copy) {
                    Label("复制会话", systemImage: "doc.on.doc")
                }
                Divider()
                Button(role: .destructive, action: delete) {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.textTertiary)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("会话操作")
        }
    }

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(preview, id: \.key) { data in
                let valStr = SessionValueFormatter.string(data.val)
                HStack(spacing: 8) {
                    Text(data.key)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(valStr.isEmpty ? "无数据" : valStr)
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if overflow > 0 {
                Text("还有 \(overflow) 项")
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(RelativeTime.string(from: session.createTime))
                .font(.system(size: 11))
                .foregroundColor(.textTertiary)
                // Full timestamp stays reachable without spending a row on it.
                .accessibilityLabel(RelativeTime.absolute(from: session.createTime))
            Spacer(minLength: 0)

            // Only one primary action per row; "关联" lives in the menu.
            if !isCurrent {
                Button(action: use) {
                    Text("切换")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.accent)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background(Color.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func use() {
        boxModel.useAppSession(sessionId: session.id, appId: app.id)
        toastManager.showToast(message: "已切换")
    }

    private func link() {
        boxModel.linkAppSession(sessionId: session.id, appId: app.id)
        toastManager.showToast(message: "已关联")
    }

    private func copy() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session),
              let str = String(data: data, encoding: .utf8) else { return }
        copyToClipboard(text: str)
        toastManager.showToast(message: "已复制会话")
    }

    private func delete() {
        boxModel.delAppSession(sessionId: session.id)
        toastManager.showToast(message: "已删除")
    }
}

// MARK: - Value formatting

/// Renders a stored value for display. Shared so the detail page and the session rows
/// cannot drift apart on how a value is stringified.
enum SessionValueFormatter {
    private static let encoder = JSONEncoder()

    static func string(_ val: AnyCodable?) -> String {
        guard let val else { return "" }
        if let str = val.value as? String { return str }
        if let data = try? encoder.encode(val), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: val.value)
    }
}
