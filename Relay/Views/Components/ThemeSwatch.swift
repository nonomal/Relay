//
//  ThemeSwatch.swift
//  Relay
//
//  A round colour chip used by the theme-colour settings rows.
//

import SwiftUI

/// A round colour chip.
struct ThemeSwatch: View {
    let hex: String
    var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}
