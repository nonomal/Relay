//
//  RelayThemedAccent.swift
//  Relay
//
//  Applies the BoxJs theme preferences at the root: the appearance mode
//  (`usercfgs.theme`) and the accent colour for that mode
//  (`usercfgs.color_light_primary` / `color_dark_primary`).
//

import SwiftUI
import UIKit

/// Root-level theme application.
///
/// Drives three things off the BoxJs config:
/// 1. `preferredColorScheme` from `theme` (`light` / `dark`; `auto` = follow system)
/// 2. `tint`, which is what every implicit `.accentColor` call site resolves to
/// 3. `ThemePalette.shared`, which the explicit token aliases read
///
/// Kept as a modifier on `ContentView` rather than inside it so the tint also
/// covers the toast/loading overlays layered alongside it.
private struct RelayThemedAccentModifier: ViewModifier {
    @EnvironmentObject private var boxModel: BoxJsViewModel
    @ObservedObject private var palette = ThemePalette.shared
    @Environment(\.colorScheme) private var systemScheme

    private var mode: BoxThemeMode {
        boxModel.boxData.usercfgs?.themeMode ?? .auto
    }

    /// `auto` 下用系统外观；显式 light/dark 时按它自己算，
    /// 不能用 `systemScheme`——`preferredColorScheme` 生效前后它不一致。
    private var isDark: Bool {
        mode.isDark(systemIsDark: systemScheme == .dark)
    }

    private var accent: Color {
        palette.colors?.primary ?? .accentBlue
    }

    func body(content: Content) -> some View {
        content
            .tint(accent)
            .preferredColorScheme(mode.preferredColorScheme)
            .onAppear { sync() }
            .onChange(of: boxModel.boxData.usercfgs?.color_light_primary) { _ in sync() }
            .onChange(of: boxModel.boxData.usercfgs?.color_dark_primary) { _ in sync() }
            .onChange(of: boxModel.boxData.usercfgs?.theme) { _ in sync() }
            .onChange(of: systemScheme) { _ in sync() }
    }

    private func sync() {
        let before = ThemePalette.shared.colors?.primary
        ThemePalette.shared.update(usercfgs: boxModel.boxData.usercfgs, isDark: isDark)
        let after = ThemePalette.shared.colors?.primary

        // 刷 UIKit 外观会重写整个 window 的 tint 链并触发重绘，只在颜色真的
        // 变了（或首次）时才做——深浅切换时 pinned 模式下颜色其实没变。
        guard before != after || !Self.didApplyUIKitAppearance else { return }
        Self.didApplyUIKitAppearance = true
        Self.applyUIKitAppearance(accent: after ?? .accentBlue)
    }

    /// 是否已经写过一次 UIKit 外观——首次同步必须执行，即使颜色算下来没变。
    nonisolated(unsafe) private static var didApplyUIKitAppearance = false

    /// Mirrors the one-time setup in `RelayApp.init()` so newly created bars
    /// pick up the current accent.
    ///
    /// 只改 `appearance()` 代理，不去遍历 window / view controller 树：
    /// 已经显示出来的 bar 由 SwiftUI 的 `.tint(accent)`（见 `body`）负责，
    /// 那条路径有订阅、会重绘。写 `window.tintColor` 会连带染上本 App 没打算
    /// 主题化的系统 UI（分享面板、文件选择器等），是越界。
    private static func applyUIKitAppearance(accent: Color) {
        guard #available(iOS 26.0, *) else { return }
        UITabBar.appearance().tintColor = UIColor(accent)
    }
}

extension BoxThemeMode {
    /// `auto` 返回 `nil`，交给系统。
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Re-applies just the theme tint, for content hosted outside the root's
/// environment (Transmission presentations, UIKit-hosted screens).
///
/// 只管 tint：`preferredColorScheme` 是整窗口口径，只能挂在根上，
/// 在子页面重复设会把系统外观切换搞乱。
private struct RelayThemedAccentTintModifier: ViewModifier {
    @ObservedObject private var palette = ThemePalette.shared

    func body(content: Content) -> some View {
        content.tint(palette.colors?.primary ?? .accentBlue)
    }
}

extension View {
    /// Applies the BoxJs appearance mode + theme colour. Use once, at the root.
    func relayThemedAccent() -> some View {
        modifier(RelayThemedAccentModifier())
    }

    /// Applies only the theme tint — for pages presented outside the root
    /// environment, where `.tint` does not propagate.
    func relayThemedAccentTint() -> some View {
        modifier(RelayThemedAccentTintModifier())
    }
}
