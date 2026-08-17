//
//  RelayPageBackground.swift
//  Relay
//
//  Shared page background: BoxJS wallpaper (`usercfgs.bgimg`) when set,
//  otherwise the default adaptive gradient.
//

import SwiftUI
import SDWebImageSwiftUI

/// Full-bleed page background used by every top-level and detail screen.
///
/// When `usercfgs.bgimg` holds a wallpaper the image is drawn edge-to-edge,
/// unmodified. Without a wallpaper it falls back to the existing
/// `Color.pageGradientColors` gradient, so screens look unchanged.
///
/// The view model is injected through `Environment` rather than
/// `@EnvironmentObject` because this view is also used inside sheets (e.g. the
/// disclaimer reachable from the welcome screen), which do not always inherit
/// environment objects on iOS 15 — `@EnvironmentObject` would trap there.
/// `WallpaperBackdrop` observes the model so wallpaper changes still animate in.
struct RelayPageBackground: View {
    @Environment(\.relayBoxModel) private var boxModel: BoxJsViewModel?
    @ObservedObject private var palette = WallpaperPalette.shared

    /// 有壁纸色板时渐变跟着壁纸走（壁纸加载前/失败时的打底也就同色系了），
    /// 没有则保持原来的三色渐变，无壁纸观感完全不变。
    private var gradientColors: [Color] {
        guard let c = palette.colors else { return Color.pageGradientColors }
        return [c.top, c.mid, c.bottom]
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: gradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeInOut(duration: 0.3), value: palette.colors)

            if let boxModel {
                WallpaperBackdrop(boxModel: boxModel)
            }
        }
        .ignoresSafeArea()
    }
}

/// Draws the wallpaper itself. Split out so it can `@ObservedObject` the view
/// model and refresh when `boxData` changes.
private struct WallpaperBackdrop: View {
    @ObservedObject var boxModel: BoxJsViewModel
    @Environment(\.colorScheme) private var colorScheme

    private var wallpaperURL: URL? {
        boxModel.boxData.usercfgs?.resolvedWallpaperURL(isDark: colorScheme == .dark)
    }

    var body: some View {
        // `GeometryReader` + an explicit `.frame` is what keeps the wallpaper from
        // affecting layout. `scaledToFill` sizes the image to its own aspect ratio,
        // and `clipped()` only clips *drawing* — the oversized intrinsic size still
        // propagates up and stretches the parent, which pushed page content
        // sideways and cut off the nav bar's trailing controls.
        GeometryReader { proxy in
            if let url = wallpaperURL {
                WebImage(url: url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: wallpaperURL)
        // 单一驱动点：解析后的壁纸地址变了就重算色板（含变为 nil = 关闭壁纸）。
        .onAppear { WallpaperPalette.shared.update(for: wallpaperURL) }
        .onChange(of: wallpaperURL) { WallpaperPalette.shared.update(for: $0) }
    }
}

// MARK: - Environment injection

private struct RelayBoxModelKey: EnvironmentKey {
    static let defaultValue: BoxJsViewModel? = nil
}

extension EnvironmentValues {
    var relayBoxModel: BoxJsViewModel? {
        get { self[RelayBoxModelKey.self] }
        set { self[RelayBoxModelKey.self] = newValue }
    }
}

// MARK: - Wallpaper-aware chrome

/// Reads whether a wallpaper is currently showing, so opaque chrome (nav bars,
/// bottom fills) can step aside and let it through.
///
/// A `View` cannot read this from a plain computed property without observing
/// the model, so screens use `relayWallpaperAwareBackground(_:)` below.
struct WallpaperAwareBackground<Fallback: View>: View {
    @ObservedObject private var palette = WallpaperPalette.shared
    let fallback: Fallback

    var body: some View {
        // 只读色板，不再各自去 boxData 里重解析一遍 `bgimgs`：
        // `colors != nil` 的充要条件就是「壁纸已解析且生效」（见 WallpaperPalette）。
        if palette.colors != nil {
            Color.clear
        } else {
            fallback
        }
    }
}

extension View {
    /// Applies `fill` as the background only while no wallpaper is set. With a
    /// wallpaper active the surface becomes transparent so the image shows
    /// through instead of being covered by an opaque slab.
    func relayWallpaperAwareBackground<Fallback: View>(
        @ViewBuilder _ fill: () -> Fallback
    ) -> some View {
        background(WallpaperAwareBackground(fallback: fill()))
    }

    /// Foreground colour for text drawn directly on the page background.
    ///
    /// The `text*` tokens are mid-grey blues tuned against the light gradient;
    /// on a wallpaper they wash out. With a wallpaper active this swaps them for
    /// the contrast colour derived from the image (see `WallpaperPalette`) —
    /// dark text on bright wallpapers, light text on dark ones — instead of a
    /// flat white. Without a wallpaper the design token is used unchanged.
    ///
    /// `secondary` picks the softer of the two derived colours, for supporting
    /// text like section headers and unselected tab items.
    func relayWallpaperAwareForeground(_ token: Color, secondary: Bool = false) -> some View {
        modifier(WallpaperAwareForeground(token: token, secondary: secondary))
    }
}

/// ⚠️ 这个 modifier 会逐个文字元素实例化（网格里就是每个 cell 一份），所以它
/// **只观察色板、不观察 view model**：早先版本在这里读
/// `boxData.usercfgs?.resolvedWallpaperURL(...)`，等于每个 label 每次 body 都把
/// `bgimgs` 整串重新解析一遍，且让每个 cell 都订阅了共享 view model 的任何变更。
private struct WallpaperAwareForeground: ViewModifier {
    @ObservedObject private var palette = WallpaperPalette.shared
    let token: Color
    let secondary: Bool

    func body(content: Content) -> some View {
        if let colors = palette.colors {
            let tint = secondary ? colors.onWallpaperSecondary : colors.onWallpaper
            content
                .foregroundColor(tint)
                // 对比色已经保证了明暗方向，阴影只用来压住壁纸本身的高频细节
                // （像素画、噪点），所以比之前配纯白时轻得多。
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            content.foregroundColor(token)
        }
    }
}
