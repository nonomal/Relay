//
//  SubcribeView.swift
//  NEBox
//

import SwiftUI
import UniformTypeIdentifiers

struct SubcribeView: View {
    @EnvironmentObject var boxModel: BoxJsViewModel
    @EnvironmentObject var toastManager: ToastManager
    @State private var items: [AppSubSummary] = []
    @State private var isEditMode: Bool = false
    @State private var showAddAlert: Bool = false
    @State private var addUrlInput: String = ""
    @State private var showAddOptions: Bool = false
    @State private var showPasteSheet: Bool = false
    @State private var pasteJSONInput: String = ""
    @State private var showPasteFilePicker: Bool = false
    @StateObject private var router = RelayRouter()

    var body: some View {
        neboxNavigationContainer {
            ZStack(alignment: .top) {
                RelayPageBackground()

                Group {
                    if items.isEmpty {
                        emptyState
                    } else {
                        SubGridView(
                            items: $items,
                            boxModel: boxModel,
                            router: router,
                            isEditMode: $isEditMode,
                            // Attached per-card inside the grid so the zoom morphs out
                            // of the tapped card rather than the whole page.
                            destination: { summary in
                                AnyView(SubDetailView(subURL: summary.url))
                            }
                        )
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            // Destination is attached per-card inside `SubGridView` so the zoom
            // originates from the tapped card.
            //
            // 沉浸式导航栏，同 HomeView：真正的 ScrollView 在 SubGridView 内部，
            // 所以这层传 ownsScrollEdge: false。
            .navigationBar(.init(
                chrome: .plain(background: .gradientTop, ownsScrollEdge: false),
                title: .fixed("应用订阅")
            ))
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await boxModel.reloadAllAppSub()
                            toastManager.showToast(message: "已刷新全部订阅")
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .medium))
                    }
                    Menu {
                        Button(action: beginURLSubscription) {
                            Label("输入订阅地址", systemImage: "link")
                        }
                        Button(action: beginPastedSubscription) {
                            Label("粘贴 JSON 内容", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
            }
        }
        .neboxLiquidGlassTabBarChrome()
        .alert("添加订阅", isPresented: $showAddAlert) {
            TextField("输入订阅地址", text: $addUrlInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("确定") {
                let url = addUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    Task { await boxModel.addAppSub(url: url) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请输入订阅链接地址")
        }
        .confirmationDialog("添加订阅", isPresented: $showAddOptions, titleVisibility: .visible) {
            Button("输入订阅地址", action: beginURLSubscription)
            Button("粘贴 JSON 内容", action: beginPastedSubscription)
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteSubscriptionSheet(
                jsonText: $pasteJSONInput,
                showFilePicker: $showPasteFilePicker,
                onConfirm: {
                    let json = pasteJSONInput
                    showPasteSheet = false
                    Task { await boxModel.addAppSubRaw(json: json) }
                },
                onCancel: { showPasteSheet = false }
            )
        }
        .onReceive(boxModel.$cachedAppSubSummaries) { summaries in
            // Skip while a reorder drag is in flight, otherwise a server refresh would
            // snap the cards back to their old order mid-gesture.
            if SubDragState.currentID == nil {
                items = summaries
            }
        }
    }


    private func beginURLSubscription() {
        addUrlInput = ""
        showAddAlert = true
    }

    private func beginPastedSubscription() {
        pasteJSONInput = ""
        showPasteSheet = true
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.bgMuted)
                    .frame(width: 80, height: 80)
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundColor(.textTertiary)
            }
            VStack(spacing: 8) {
                Text("暂无订阅")
                    .font(.system(size: 20, weight: .semibold))
                    .relayWallpaperAwareForeground(.textPrimary)
                Text("添加订阅源后，这里会展示所有应用")
                    .font(.system(size: 14))
                    .relayWallpaperAwareForeground(.textSecondary, secondary: true)
                    .multilineTextAlignment(.center)
            }
            Button {
                showAddOptions = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("添加订阅")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.onAccent)
                .padding(.horizontal, 24)
                .frame(height: 48)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Paste JSON Subscription Sheet

/// Lets the user add a subscription by pasting raw JSON (or importing a JSON file)
/// instead of a remote URL. Because the content has no verifiable origin, the sheet
/// shows a prominent trust warning; the backend keys such subs under `manual://`.
private struct PasteSubscriptionSheet: View {
    @EnvironmentObject var toastManager: ToastManager

    @Binding var jsonText: String
    @Binding var showFilePicker: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        neboxNavigationContainer {
            Form {
                Section {
                    Label {
                        Text("粘贴的内容来源无法验证。请仅添加你信任的订阅，恶意脚本可能读取或篡改你的代理配置。")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                }

                Section(footer: Text("支持 JSON 格式的订阅数据")) {
                    Button(action: pasteFromClipboard) {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    Button { showFilePicker = true } label: {
                        Label("从文件导入", systemImage: "doc")
                    }
                }

                if !jsonText.isEmpty {
                    Section(header: Text("内容预览")) {
                        Text(jsonText.prefix(500) + (jsonText.count > 500 ? "..." : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(10)
                    }
                }
            }
            .navigationTitle("粘贴订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: onConfirm)
                        .disabled(jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.json, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    private func pasteFromClipboard() {
        guard let str = PlatformBridge.pasteboardString(), !str.isEmpty else {
            toastManager.showToast(message: "剪贴板为空")
            return
        }
        jsonText = str
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            guard url.startAccessingSecurityScopedResource() else {
                toastManager.showToast(message: "无法访问文件")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8), !str.isEmpty {
                jsonText = str
            } else {
                toastManager.showToast(message: "文件读取失败")
            }
        }
    }
}

#Preview {
    SubcribeView()
}
