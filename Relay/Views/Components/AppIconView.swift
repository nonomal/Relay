//
//  AppIconView.swift
//  Relay
//

import SwiftUI
import SDWebImageSwiftUI

/// Adaptive app icon that switches between light/dark variants from `AppModel.icons`.
/// Uses standard iOS home-screen icon sizing: 60pt with ~13.4pt continuous corner radius.
struct AppIconView: View {
    let app: AppModel
    var size: CGFloat = 60

    /// iOS home-screen corner radius ratio ≈ 0.2237
    private var cornerRadius: CGFloat { size * 0.2237 }

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(IconAppearance.userDefaultsKey) private var iconAppearanceRaw: String = IconAppearance.auto.rawValue

    private var isDark: Bool {
        let appearance = IconAppearance(rawValue: iconAppearanceRaw) ?? .auto
        return appearance.isDark(systemIsDark: colorScheme == .dark)
    }

    /// Which URL failed, rather than a plain flag: keyed state survives re-renders and
    /// resets only when the icon URL genuinely changes.
    @State private var failedURL: URL?

    var body: some View {
        // `WebImage` keeps the decoded image in a `@StateObject`, which SwiftUI throws
        // away whenever the view's *identity* changes — and it then renders the
        // placeholder until the image reloads. So this tree must stay structurally
        // identical across renders: no `if`/`else` swapping around the WebImage, and
        // no `.id(...)`, both of which re-key it and cause the image ⇄ letter flicker
        // during the edit-mode jiggle.
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isDark ? Color.bgCard : Color.clear)

            // Always present; a nil URL simply renders the placeholder inside it.
            WebImage(url: iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholderView
            }
            .onFailure { _ in
                failedURL = iconURL
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// `nil` once this exact URL has failed, so the placeholder shows instead.
    private var iconURL: URL? {
        guard let url = app.adaptiveIconURL(isDark: isDark) else { return nil }
        return url == failedURL ? nil : url
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.bgMuted)
            .overlay(
                Group {
                    if let first = app.name.first {
                        Text(String(first))
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundColor(.textSecondary)
                    } else {
                        Image(systemName: "app.fill")
                            .foregroundColor(.textTertiary)
                    }
                }
            )
    }
}
