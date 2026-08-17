//
//  WallpaperPalette.swift
//  Relay
//
//  Extracts a colour palette from the active wallpaper so the page gradient,
//  the nav bar edge-fade and on-wallpaper text can all follow the image
//  instead of the fixed design tokens.
//

import DominantColors
import SDWebImage
import SwiftUI
import UIKit

/// Colours derived from the current wallpaper.
struct WallpaperColors: Equatable {
    /// 壁纸顶部区域的主色——导航栏渐隐条的洗层色用它，
    /// 「化开」才是同色系的，而不是盖一层异色。
    let top: Color
    /// 整图主色，用作页面底色渐变的中段。
    let mid: Color
    /// 壁纸底部区域主色，页面底色渐变的收尾。
    let bottom: Color
    /// 压在壁纸上的文字色（对比色）。
    let onWallpaper: Color
    /// 次级文字色（说明文字、非选中态）。
    let onWallpaperSecondary: Color
}

/// Loads the wallpaper and derives `WallpaperColors`, cached per URL.
///
/// Extraction is expensive (full-image k-means), so results are memoised and the
/// work happens off the main thread. Views observe this object and re-render
/// once a palette lands; until then they use the default gradient/tokens.
@MainActor
final class WallpaperPalette: ObservableObject {
    static let shared = WallpaperPalette()

    @Published private(set) var colors: WallpaperColors?

    /// URL the published palette belongs to — guards against a slow extraction
    /// for an old wallpaper overwriting a newer one.
    private var currentURL: URL?
    private var cache: [URL: WallpaperColors] = [:]
    private var inFlight: Set<URL> = []

    private init() {}

    /// Call whenever the resolved wallpaper URL changes (including to `nil`).
    func update(for url: URL?) {
        guard currentURL != url else { return }
        currentURL = url

        guard let url else {
            colors = nil
            return
        }
        if let cached = cache[url] {
            colors = cached
            return
        }
        // 换了壁纸但新色板还没算出来：先清空，页面回落默认渐变，
        // 免得新壁纸配着上一张的颜色。
        colors = nil
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)

        Task { await extract(url: url) }
    }

    private func extract(url: URL) async {
        let image = await Self.loadImage(url: url)
        guard let image else {
            inFlight.remove(url)
            return
        }

        let derived = await Task.detached(priority: .utility) {
            Self.palette(from: image)
        }.value

        inFlight.remove(url)
        guard let derived else { return }
        cache[url] = derived
        // 期间用户可能又换了壁纸，只认当前这张的结果。
        guard currentURL == url else { return }
        colors = derived
    }

    /// Reuses SDWebImage's cache — the wallpaper is already being fetched to
    /// display, so this normally resolves straight from cache without a
    /// second network request.
    private static func loadImage(url: URL) async -> UIImage? {
        await withCheckedContinuation { continuation in
            SDWebImageManager.shared.loadImage(
                with: url,
                options: [.retryFailed],
                progress: nil
            ) { image, _, _, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    // MARK: - Extraction

    nonisolated private static func palette(from image: UIImage) -> WallpaperColors? {
        // 顶部/底部各取一条带来分别提主色：壁纸常常是上下分明的（天空 vs 地面），
        // 只取整图主色的话渐隐条会跟它盖住的那块区域对不上。
        let topStrip = image.strip(topFraction: 0.25)
        let bottomStrip = image.strip(bottomFraction: 0.25)

        let overall = (try? image.dominantColors(max: 6)) ?? []
        guard let overallMain = overall.first else { return nil }

        let topMain = (try? topStrip?.dominantColors(max: 3))?.first ?? overallMain
        let bottomMain = (try? bottomStrip?.dominantColors(max: 3))?.first ?? overallMain

        // 文字色锚在顶部主色上——文字（App 名、section title、导航栏）主要压在
        // 页面上半部分。
        let text = Self.textColors(over: topMain)

        return WallpaperColors(
            top: Color(topMain),
            mid: Color(overallMain),
            bottom: Color(bottomMain),
            onWallpaper: text.primary,
            onWallpaperSecondary: text.secondary
        )
    }

    /// 按背景亮度取中性深/浅字色。
    ///
    /// 刻意不用 DominantColors 的 `ContrastColors`：它要求 `orderedColors.count > 1`、
    /// 且深色背景模式下要求存在亮度 < 0.5 的色，多条路径会返回 nil；它挑的又是
    /// 「调色板里的另一个颜色」，壁纸配色相近时对比度可能不够，用在正文上有可读性
    /// 风险。亮度判断这一档任何壁纸下都成立。
    nonisolated private static func textColors(
        over background: UIColor
    ) -> (primary: Color, secondary: Color) {
        let isBright = background.cgColor.relativeLuminance > 0.5
        let base: UIColor = isBright
            ? UIColor(white: 0.11, alpha: 1)
            : UIColor(white: 0.97, alpha: 1)
        let secondary = base.withAlphaComponent(0.72)
        return (Color(base), Color(secondary))
    }
}

// MARK: - Image cropping

private extension UIImage {
    func strip(topFraction: CGFloat) -> UIImage? {
        crop(relativeRect: CGRect(x: 0, y: 0, width: 1, height: topFraction))
    }

    func strip(bottomFraction: CGFloat) -> UIImage? {
        crop(relativeRect: CGRect(x: 0, y: 1 - bottomFraction, width: 1, height: bottomFraction))
    }

    func crop(relativeRect: CGRect) -> UIImage? {
        guard let cg = cgImage else { return nil }
        let rect = CGRect(
            x: relativeRect.origin.x * CGFloat(cg.width),
            y: relativeRect.origin.y * CGFloat(cg.height),
            width: relativeRect.width * CGFloat(cg.width),
            height: relativeRect.height * CGFloat(cg.height)
        ).integral
        guard rect.width >= 1, rect.height >= 1,
              let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
