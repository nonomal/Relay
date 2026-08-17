//
//  WallpaperPickerView.swift
//  Relay
//
//  Picks the page wallpaper from the BoxJS `usercfgs.bgimgs` list, or a
//  custom URL. The choice is written back to `usercfgs.bgimg`, so it stays
//  in sync with the BoxJS web UI.
//

import SwiftUI
import SDWebImageSwiftUI

struct WallpaperPickerView: View {
    @EnvironmentObject var boxModel: BoxJsViewModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var customURL: String = ""
    @State private var didLoadCustomURL = false

    private var usercfgs: UserConfig? { boxModel.boxData.usercfgs }
    private var options: [WallpaperOption] { usercfgs?.wallpaperOptions ?? [] }
    private var current: String { usercfgs?.bgimg ?? "" }

    /// 当前壁纸不在清单里时，说明用的是自定义地址
    private var isCustomSelected: Bool {
        !current.isEmpty && !options.contains { $0.value == current }
    }

    var body: some View {
        Form {
            Section {
                Button {
                    select("")
                } label: {
                    HStack {
                        Label("无壁纸", systemImage: "square.slash")
                            .foregroundColor(.primary)
                        Spacer()
                        if current.isEmpty {
                            checkmark
                        }
                    }
                }
            } footer: {
                Text("关闭后恢复默认渐变背景。")
            }

            if !options.isEmpty {
                Section(header: Text("BoxJs 清单")) {
                    ForEach(options) { option in
                        Button {
                            select(option.value)
                        } label: {
                            wallpaperRow(option)
                        }
                    }
                }
            }

            Section {
                TextField("https://example.com/wallpaper.jpg", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                Button("使用该地址") {
                    select(customURL.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(!isCustomURLApplicable)
            } header: {
                Text("自定义地址")
            } footer: {
                Text("支持随机图片接口，每次加载可能返回不同图片。")
            }
        }
        .modifier(ScrollDismissKeyboardModifier())
        .navigationTitle("壁纸")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 只在首次进入时回填，避免编辑过程中被刷新覆盖
            guard !didLoadCustomURL else { return }
            didLoadCustomURL = true
            if isCustomSelected { customURL = current }
        }
        .onDisappear {
            Task { await boxModel.flushPendingDataUpdates() }
        }
    }

    private var isCustomURLApplicable: Bool {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current else { return false }
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme?.hasPrefix("http") == true && url.host != nil
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundColor(.accentColor)
    }

    private func wallpaperRow(_ option: WallpaperOption) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: option)

            VStack(alignment: .leading, spacing: 2) {
                Text(option.name)
                    .foregroundColor(.primary)
                Text(option.isSystemFollow ? "按深浅色自动切换 light / dark 壁纸" : option.value)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if current == option.value {
                checkmark
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnail(for option: WallpaperOption) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let url = option.imageURL {
                WebImage(url: url)
                    .resizable()
                    .scaledToFill()
            } else {
                // 「跟随系统」没有固定图，用图标占位
                ZStack {
                    Color.bgMuted
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 56, height: 40)
        .clipShape(shape)
        .overlay(shape.stroke(Color.borderSubtle, lineWidth: 1))
    }

    private func select(_ url: String) {
        guard url != current else { return }
        boxModel.updateData(path: "usercfgs.bgimg", data: url)
    }
}
