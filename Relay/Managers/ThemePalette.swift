//
//  ThemePalette.swift
//  Relay
//
//  Derives the app's accent colours from the BoxJs theme-colour preferences
//  (`usercfgs.color_light_primary` / `color_dark_primary`, selected by
//  `usercfgs.theme`), so the accent follows what the user picked in BoxJs
//  instead of the fixed `accentBlue` design token.
//

import DominantColors
import SwiftUI
import UIKit

/// One accent colour plus the two companions the design system needs.
///
/// The asset catalogue ships a hand-tuned trio (`accentBlue` /
/// `accentBlueDark` / `accentBlueLight`); a user-picked hex arrives alone, so
/// the companions get derived from it to keep gradients and tint fills working.
struct ThemeColors: Equatable, Sendable {
    /// 主色本身，对应网页版 Vuetify 的 `primary`。
    let primary: Color
    /// 渐变收尾用的深一档，对应 `accentBlueDark`。
    let primaryDark: Color
    /// 浅底填充用的淡一档，对应 `accentBlueLight`。
    let primaryLight: Color
    /// 压在主色上的前景色，按主色亮度取黑/白。
    let onPrimary: Color
}

/// Non-isolated mirror of the active palette.
///
/// `Color.accent` and friends are `static var`s on `Color`, reachable from any
/// context, so they cannot read the `@MainActor` `ThemePalette` directly.
/// `ThemePalette` writes through to here on every change and these statics read
/// it — a plain value snapshot behind a lock, no actor hop at the call site.
enum ThemeColorSnapshot {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: ThemeColors?

    static var current: ThemeColors? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    static func set(_ colors: ThemeColors?) {
        lock.lock()
        stored = colors
        lock.unlock()
    }
}

/// Publishes the accent palette for the active appearance.
///
/// BoxJs stores two colours and a mode; which one applies depends on the
/// resolved dark/light state, so views feed both in and read `colors` back.
@MainActor
final class ThemePalette: ObservableObject {
    static let shared = ThemePalette()

    /// `nil` until a config lands — callers fall back to the `accentBlue` tokens.
    @Published private(set) var colors: ThemeColors?

    /// Guards against recomputing (and republishing) for an unchanged input.
    ///
    /// 不像 `WallpaperPalette` 那样另开一份 cache：那边缓存的是整图 k-means，
    /// 这边 `derive` 只是一次 HSB 换算，而且这个 guard 已经挡掉了重复计算，
    /// 再加字典只会随用户拖色盘无上限地长。
    private var currentHex: String?

    private init() {}

    /// Call whenever the config or the resolved appearance changes.
    func update(usercfgs: UserConfig?, isDark: Bool) {
        guard let usercfgs else {
            apply(hex: nil)
            return
        }
        apply(hex: usercfgs.resolvedPrimaryHex(isDark: isDark))
    }

    private func apply(hex: String?) {
        guard let hex else {
            // 赋值 `@Published` 即使值没变也会发通知，会白白重绘 tab bar，
            // 所以 nil 路径也要过 guard。
            guard currentHex != nil else { return }
            currentHex = nil
            publish(nil)
            return
        }
        guard currentHex != hex else { return }
        currentHex = hex

        // 解析失败（用户/脚本写了非法串）就回落到默认 token，别让界面变黑。
        publish(Self.derive(hex: hex))
    }

    /// 唯一的写入口——顺带同步给 `ThemeColorSnapshot`，
    /// 免得 `Color.accent` 读到的和 `@Published` 的不是同一份。
    private func publish(_ value: ThemeColors?) {
        colors = value
        ThemeColorSnapshot.set(value)
    }

    // MARK: - Derivation

    /// Builds the trio from a single hex. Returns `nil` for unparseable input.
    static func derive(hex: String) -> ThemeColors? {
        guard let base = UIColor(validHex: hex) else { return nil }

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else { return nil }

        // 深一档：压亮度、略提饱和，和 accentBlue→accentBlueDark 的关系一致。
        let dark = UIColor(
            hue: hue,
            saturation: min(sat * 1.1, 1),
            brightness: max(bri * 0.62, 0.05),
            alpha: alpha
        )
        // 淡一档：低饱和高亮度的同色系底，用于 capsule/卡片背景。
        let light = UIColor(
            hue: hue,
            saturation: min(sat * 0.22, 0.25),
            brightness: max(bri, 0.93),
            alpha: alpha
        )

        return ThemeColors(
            primary: Color(base),
            primaryDark: Color(dark),
            primaryLight: Color(light),
            // 用 DominantColors 的 `relativeLuminance`（`WallpaperPalette` 也用它），
            // 同一个 target 里已经链了这个包，没必要自己再抄一份 WCAG 公式。
            onPrimary: base.cgColor.relativeLuminance > 0.55 ? Color.black : Color.white
        )
    }
}

// MARK: - Hex parsing

extension UIColor {
    /// Strict hex parse — `Color(hex:)` is lenient (a bad string silently yields
    /// black), which would turn a typo'd config into an unreadable accent.
    /// Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA`.
    convenience init?(validHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit) else { return nil }

        switch s.count {
        case 3:
            // #RGB → 每位复制一次
            s = s.map { "\($0)\($0)" }.joined()
        case 6, 8:
            break
        default:
            return nil
        }

        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
