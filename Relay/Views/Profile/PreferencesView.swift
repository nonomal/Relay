//
//  PreferencesView.swift
//  NEBox
//
//  Created by Senku on 2024.
//

import SwiftUI

/// Controls which icon variant (light / dark / auto) is shown for app icons within the app.
enum IconAppearance: String, CaseIterable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// Resolves to a concrete `isDark` value given the current system color scheme.
    func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .auto: return systemIsDark
        case .light: return false
        case .dark: return true
        }
    }

    static let userDefaultsKey = "iconAppearance"
}

/// Controls the actual iOS home-screen app icon.
enum AppIconChoice: String, CaseIterable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// The image asset name used for preview in the picker.
    var previewImageName: String {
        switch self {
        case .auto: return "AppIcon-Light"
        case .light: return "AppIcon-Light"
        case .dark: return "AppIcon-Dark"
        }
    }

    /// The alternate icon name passed to `setAlternateIconName`. `nil` = default (auto light/dark).
    var alternateIconName: String? {
        switch self {
        case .auto: return nil
        case .light: return "AppIcon-LightOnly"
        case .dark: return "AppIcon-DarkOnly"
        }
    }

    static let userDefaultsKey = "appIconChoice"

    static var current: AppIconChoice {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let choice = AppIconChoice(rawValue: raw) else { return .auto }
        return choice
    }
}

struct PreferencesView: View {
    @EnvironmentObject var boxModel: BoxJsViewModel
    @EnvironmentObject var toastManager: ToastManager
    @AppStorage(IconAppearance.userDefaultsKey) private var iconAppearanceRaw: String = IconAppearance.auto.rawValue
    @AppStorage(AppIconChoice.userDefaultsKey) private var appIconChoiceRaw: String = AppIconChoice.auto.rawValue

    var usercfgs: UserConfig? { boxModel.boxData.usercfgs }

    private var isSurgeEnv: Bool {
        boxModel.boxData.syscfgs?.env == "Surge"
    }

    /// 与网页版一致：`httpapis` 为逗号分隔列表时使用选择器
    private var httpapiPickerItems: [String] {
        guard let raw = usercfgs?.httpapis, !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 当前值若不在列表中，前置一项以免 Picker 无匹配
    private var httpapiPickerResolvedItems: [String] {
        let items = httpapiPickerItems
        guard let cur = usercfgs?.httpapi, !cur.isEmpty, !items.contains(cur) else { return items }
        return [cur] + items
    }

    private var currentAppearance: IconAppearance {
        IconAppearance(rawValue: iconAppearanceRaw) ?? .auto
    }

    private var themeModeSummary: String {
        (usercfgs?.themeMode ?? .auto).displayName
    }

    /// 优先显示壁纸在 BoxJs 清单里的名字，自定义地址则显示「自定义」
    private var wallpaperSummary: String {
        guard let bgimg = usercfgs?.bgimg, !bgimg.isEmpty else { return "无" }
        if let match = usercfgs?.wallpaperOptions.first(where: { $0.value == bgimg }) {
            return match.name
        }
        return "自定义"
    }

    var body: some View {
        Form {
            Section(header: Text("通知")) {
                Toggle("勿扰模式", isOn: prefBoolBinding(\.isMute))
                Toggle("不显示查询警告", isOn: prefBoolBinding(\.isMuteQueryAlert))
            }

            Section(header: Text("外观")) {
                NavigationLink {
                    ThemeColorPickerView()
                } label: {
                    HStack {
                        Text("主题色")
                        Spacer()
                        Text(themeModeSummary)
                            .foregroundColor(.secondary)
                        // 两个模式各自的色点，一眼看出配了什么色
                        ForEach(ThemeColorSlot.allCases, id: \.self) { slot in
                            ThemeSwatch(
                                hex: usercfgs?.resolvedPrimaryHex(isDark: slot.isDark) ?? slot.fallback,
                                size: 16
                            )
                        }
                    }
                }
                NavigationLink {
                    AppIconPickerView()
                } label: {
                    HStack {
                        Text("应用图标")
                        Spacer()
                        Text((AppIconChoice(rawValue: appIconChoiceRaw) ?? .auto).displayName)
                            .foregroundColor(.secondary)
                    }
                }
                NavigationLink {
                    IconAppearancePickerView()
                } label: {
                    HStack {
                        Text("图标风格")
                        Spacer()
                        Text(currentAppearance.displayName)
                            .foregroundColor(.secondary)
                    }
                }
                NavigationLink {
                    WallpaperPickerView()
                } label: {
                    HStack {
                        Text("壁纸")
                        Spacer()
                        Text(wallpaperSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if isSurgeEnv {
                Section {
                    if !httpapiPickerItems.isEmpty {
                        Picker("HTTP-API (Surge)", selection: prefStringBinding(\.httpapi, default: "")) {
                            Text("未设置").tag("")
                            ForEach(httpapiPickerResolvedItems, id: \.self) { item in
                                Text(item).tag(item)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HTTP-API (Surge)")
                                .font(.subheadline)
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("examplekey@127.0.0.1:6166", text: prefStringBinding(\.httpapi, default: ""))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                if let v = usercfgs?.httpapi, !v.isEmpty, !isValidSurgeHttpApiFormat(v) {
                                    Text("格式错误，示例: examplekey@127.0.0.1:6166")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } footer: {
                    if httpapiPickerItems.isEmpty {
                        Text("Surge http-api 地址，用于脚本与 Surge 交互。")
                    }
                }
                .modifier(ScrollDismissKeyboardModifier())
            }
        }
        .navigationTitle("偏好设置")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            Task {
                await boxModel.flushPendingDataUpdates()
            }
        }
    }

    /// 与网页版校验一致：`.*?@.*?:[0-9]+`
    private func isValidSurgeHttpApiFormat(_ value: String) -> Bool {
        value.range(of: ".*?@.*?:[0-9]+", options: .regularExpression) != nil
    }

    // MARK: - Binding Helpers

    private func prefStringBinding(_ keyPath: KeyPath<UserConfig, String?>, default defaultVal: String) -> Binding<String> {
        let path = prefPath(for: keyPath)
        return Binding<String>(
            get: { usercfgs?[keyPath: keyPath] ?? defaultVal },
            set: { newValue in
                boxModel.updateData(path: path, data: newValue)
            }
        )
    }

    private func prefBoolBinding(_ keyPath: KeyPath<UserConfig, Bool?>) -> Binding<Bool> {
        let path = prefPath(for: keyPath)
        return Binding<Bool>(
            get: { usercfgs?[keyPath: keyPath] ?? false },
            set: { newValue in
                boxModel.updateData(path: path, data: newValue)
            }
        )
    }

    private func prefPath<T>(for keyPath: KeyPath<UserConfig, T>) -> String {
        let map: [PartialKeyPath<UserConfig>: String] = [
            \UserConfig.isMute: "usercfgs.isMute",
            \UserConfig.isMuteQueryAlert: "usercfgs.isMuteQueryAlert",
            \UserConfig.httpapi: "usercfgs.httpapi",
        ]
        return map[keyPath] ?? "usercfgs.unknown"
    }
}

// MARK: - App Icon Picker

struct AppIconPickerView: View {
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage(AppIconChoice.userDefaultsKey) private var selectedRaw: String = AppIconChoice.auto.rawValue

    private var selected: AppIconChoice {
        AppIconChoice(rawValue: selectedRaw) ?? .auto
    }

    private let iconSize: CGFloat = 62
    private var cornerRadius: CGFloat { iconSize * 0.2237 }

    var body: some View {
        Form {
            Section {
                ForEach(AppIconChoice.allCases, id: \.self) { choice in
                    Button {
                        selectedRaw = choice.rawValue
                        UIApplication.shared.setAlternateIconName(choice.alternateIconName)
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(choice.previewImageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                            Text(choice.displayName)
                                .foregroundColor(.primary)

                            Spacer()

                            if selected == choice {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("应用图标")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Theme Colour Picker

/// Identifies which of the two BoxJs theme colours a row edits.
///
/// BoxJs keys the colours by appearance, so each slot owns its own config path
/// and factory default rather than the caller passing a matching set of four
/// correlated arguments (which nothing stopped from being mismatched).
enum ThemeColorSlot: CaseIterable {
    case light
    case dark

    var title: String {
        switch self {
        case .light: return "明亮色调"
        case .dark: return "暗黑色调"
        }
    }

    var footer: String {
        switch self {
        case .light: return "浅色模式下使用的主色调。"
        case .dark: return "深色模式下使用的主色调。"
        }
    }

    var path: String {
        switch self {
        case .light: return "usercfgs.color_light_primary"
        case .dark: return "usercfgs.color_dark_primary"
        }
    }

    /// BoxJs 偏好设置里的出厂色
    var fallback: String {
        switch self {
        case .light: return UserConfig.defaultLightPrimary
        case .dark: return UserConfig.defaultDarkPrimary
        }
    }

    var isDark: Bool { self == .dark }
}

/// Mirrors BoxJs 偏好设置: an appearance mode plus one accent colour per mode.
///
/// BoxJs stores two colours (`color_light_primary` / `color_dark_primary`) and
/// picks between them with `theme`, so both are editable here regardless of
/// which one is currently active.
struct ThemeColorPickerView: View {
    @EnvironmentObject var boxModel: BoxJsViewModel

    var body: some View {
        Form {
            ThemeModeSection(
                mode: boxModel.boxData.usercfgs?.themeMode ?? .auto,
                onSelect: selectMode
            )

            ForEach(ThemeColorSlot.allCases, id: \.self) { slot in
                ThemeColorSection(
                    slot: slot,
                    hex: hex(for: slot),
                    onPick: { updateColor(slot, to: $0) }
                )
            }
        }
        .navigationTitle("主题色")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: flush)
    }

    private func hex(for slot: ThemeColorSlot) -> String {
        boxModel.boxData.usercfgs?.resolvedPrimaryHex(isDark: slot.isDark) ?? slot.fallback
    }

    private func selectMode(_ mode: BoxThemeMode) {
        boxModel.updateData(path: "usercfgs.theme", data: mode.rawValue)
    }

    private func updateColor(_ slot: ThemeColorSlot, to hex: String) {
        boxModel.updateData(path: slot.path, data: hex)
    }

    private func flush() {
        Task { await boxModel.flushPendingDataUpdates() }
    }
}

// MARK: -

/// Appearance mode picker — `light` / `dark` / `auto`.
private struct ThemeModeSection: View {
    let mode: BoxThemeMode
    let onSelect: (BoxThemeMode) -> Void

    var body: some View {
        Section {
            ForEach(BoxThemeMode.allCases, id: \.self) { option in
                Button { onSelect(option) } label: {
                    HStack {
                        Text(option.displayName)
                            .foregroundColor(.primary)
                        Spacer()
                        if mode == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundColor(.accent)
                        }
                    }
                }
            }
        } header: {
            Text("外观")
        } footer: {
            Text("「自动」跟随系统深浅色，并据此选用下面对应的主题色。")
        }
    }
}

/// One appearance's accent colour, with a reset row once it differs from the
/// BoxJs factory value.
private struct ThemeColorSection: View {
    let slot: ThemeColorSlot
    let hex: String
    let onPick: (String) -> Void

    /// 拖动中的颜色由本地 state 持有，`ColorPicker` 直接绑它。
    ///
    /// 不能让 picker 绑「hex ↔ Color」的转换绑定：每个采样点都写回
    /// `updateData` → 重置整个 `boxData` → 本页重建，picker 会被灌回量化后的
    /// 十六进制值，和用户正在进行的手势打架（表现为颜色乱跳）。本地 state 让
    /// 拖动全程连续，只在取值真的变化时才向上提交。
    @State private var draft: Color?

    private var isDefault: Bool {
        hex.caseInsensitiveCompare(slot.fallback) == .orderedSame
    }

    private var selection: Binding<Color> {
        Binding(
            get: { draft ?? Color(hex: hex) },
            set: { newValue in
                draft = newValue
                // 只在量化后的十六进制真的变了才写；同一格内的连续采样不该
                // 反复触发全局状态更新。
                let newHex = newValue.toHex()
                guard newHex.caseInsensitiveCompare(hex) != .orderedSame else { return }
                onPick(newHex)
            }
        )
    }

    var body: some View {
        Section {
            ColorPicker(selection: selection, supportsOpacity: false) {
                ThemeColorLabel(title: slot.title, hex: hex)
            }

            // 与网页版一致：给一个恢复出厂色的入口，避免只能靠手调回去
            if !isDefault {
                Button("恢复默认") {
                    // 连带清掉草稿，否则 picker 还显示恢复前的颜色
                    draft = nil
                    onPick(slot.fallback)
                }
            }
        } footer: {
            Text(slot.footer)
        }
        // 外部改了值（另一端写入 / 恢复默认 / 重新拉取配置）时丢弃草稿，
        // 让 picker 回到真实存储值。
        .onChange(of: hex) { newHex in
            if let draft, draft.toHex().caseInsensitiveCompare(newHex) == .orderedSame { return }
            self.draft = nil
        }
    }
}

/// Swatch + name + hex, used as the `ColorPicker` label.
private struct ThemeColorLabel: View {
    let title: String
    let hex: String

    var body: some View {
        HStack(spacing: 10) {
            ThemeSwatch(hex: hex)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hex.uppercased())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Icon Appearance Picker

struct IconAppearancePickerView: View {
    @Environment(\.presentationMode) private var presentationMode
    @AppStorage(IconAppearance.userDefaultsKey) private var iconAppearanceRaw: String = IconAppearance.auto.rawValue

    private var selected: IconAppearance {
        IconAppearance(rawValue: iconAppearanceRaw) ?? .auto
    }

    var body: some View {
        Form {
            Section {
                ForEach(IconAppearance.allCases, id: \.self) { style in
                    Button {
                        iconAppearanceRaw = style.rawValue
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Text(style.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if selected == style {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("图标")
        .navigationBarTitleDisplayMode(.inline)
    }
}
