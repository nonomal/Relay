//
//  RelayTabBar.swift
//  Relay
//
//  Tab bar modelled on Telegram-iOS's `TabBarUI`, reimplemented in SwiftUI.
//
//  Nothing is ported from Telegram (it is GPL-2.0 and its tab bar is built on
//  AsyncDisplayKit / Display / SwiftSignalKit — a ~3.2M-line dependency closure).
//  What is borrowed is the *behaviour and its tuning constants*, read off
//  `submodules/TabBarUI/Sources/TabBarNode.swift` and `TabBarController.swift`:
//
//   - Tapping the already-selected tab does not re-select; it asks that tab to scroll
//     to top (TabBarController.swift — `scrollToTopWithTabBar`).
//   - Long-pressing a tab raises a separate action (`longTapWithTabBar`).
//   - Pressing a tab plays a two-stage bounce: 1.0 → 0.87 over 0.1s, then 0.87 → 1.0
//     over 0.14s (TabBarNode.swift:594).
//   - Badge: 18pt tall pill, 13pt regular text, min width 18pt for a single character,
//     otherwise `text width + 11` (TabBarNode.swift:761).
//
//  Telegram's sliding "liquid lens" selection pill is deliberately not reproduced.
//

import SwiftUI

extension Notification.Name {
    /// Posted when the already-selected tab is tapped again. Screens observe this to
    /// scroll their content back to the top, matching Telegram's `scrollToTopWithTabBar`.
    static let relayTabReselected = Notification.Name("relayTabReselected")
}

// MARK: - Item

struct RelayTabItem: Identifiable {
    let id: Int
    let title: String
    /// SF Symbol shown when unselected.
    let icon: String
    /// SF Symbol shown when selected.
    let selectedIcon: String
    /// Unread-style badge. `nil` hides it.
    var badge: String? = nil

    init(id: Int, title: String, icon: String, selectedIcon: String? = nil, badge: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.selectedIcon = selectedIcon ?? "\(icon).fill"
        self.badge = badge
    }
}

// MARK: - Tab bar

struct RelayTabBar: View {
    let items: [RelayTabItem]
    @Binding var selection: Int

    /// Called when the *already selected* tab is tapped again. Telegram uses this to
    /// scroll the current screen to the top rather than re-selecting.
    var onReselect: ((Int) -> Void)? = nil
    /// Called on long-press of a tab.
    var onLongPress: ((Int) -> Void)? = nil
    /// When set, a search button is shown as a separate pill to the right of the tabs,
    /// as in Telegram (`TabBarComponent.swift:901` — a `barHeight` square, 8pt gap).
    var onSearch: (() -> Void)? = nil

    /// Height of the floating pane, matching iOS 26's Liquid Glass tab bar rather than
    /// the classic 49pt UIKit bar — the floating style is noticeably taller.
    ///
    /// 64 = 56pt item + 4pt inset top and bottom, which is what Telegram uses for its
    /// own iOS 26 bar (`TabBarComponent.swift:664`). No iOS 26 runtime is installed
    /// here to measure the system bar directly, so this follows Telegram's shipped
    /// value as the closest available reference.
    private let barHeight: CGFloat = 64
    /// Telegram's gap between the tab group and the search pill.
    private let searchGap: CGFloat = 8

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        // Telegram splits the bar into two separate glass panes: the tab group, and a
        // square search button 8pt to its right (TabBarComponent.swift:901).
        HStack(spacing: searchGap) {
            tabGroup
            if onSearch != nil {
                searchButton
            }
        }
        .padding(.horizontal, 21)
        .padding(.bottom, 4)
    }

    private var tabGroup: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    select(item.id)
                } label: {
                    RelayTabButton(item: item, isSelected: selection == item.id)
                }
                .buttonStyle(RelayTabPressStyle())
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            Vibration.medium.vibrate()
                            onLongPress?(item.id)
                        }
                )
            }
        }
        .frame(height: barHeight)
        .glassTabBar(cornerRadius: barHeight / 2)
    }

    private func select(_ id: Int) {
        if selection == id {
            // Telegram: re-tapping the current tab scrolls it to top rather than
            // re-selecting, which would rebuild the screen for nothing.
            onReselect?(id)
        } else {
            Vibration.light.vibrate()
            selection = id
        }
    }

    /// Square search pill sitting apart from the tab group, matching Telegram.
    private var searchButton: some View {
        Button {
            Vibration.light.vibrate()
            onSearch?()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(NEBoxTabBarPalette.unselected)
                .frame(width: barHeight, height: barHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RelayTabPressStyle())
        .glassTabBar(cornerRadius: barHeight / 2)
        .accessibilityLabel("搜索")
    }

}

// MARK: - Search button style

/// Press feedback for tabs and the search pill, mirroring Telegram's icon squash
/// (TabBarNode.swift:594 — 1.0 → 0.87 on press).
private struct RelayTabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.87 : 1)
            .animation(.easeInOut(duration: configuration.isPressed ? 0.1 : 0.14),
                       value: configuration.isPressed)
    }
}

// MARK: - Tab item

private struct RelayTabButton: View {
    let item: RelayTabItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: isSelected ? item.selectedIcon : item.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isSelected ? NEBoxTabBarPalette.selected : NEBoxTabBarPalette.unselected)
                    // Reserve the badge's overhang so it is never clipped.
                    .frame(width: 28, height: 24)

                if let badge = item.badge, !badge.isEmpty {
                    RelayTabBadge(value: badge)
                        .offset(x: 11, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            Text(item.title)
                .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? NEBoxTabBarPalette.selected : NEBoxTabBarPalette.unselected)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: item.badge)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Badge

/// Unread pill matching Telegram's metrics: 18pt tall, 13pt regular text, 18pt wide
/// for a single character and `text + 11` beyond that (TabBarNode.swift:761).
private struct RelayTabBadge: View {
    let value: String

    private var isSingleCharacter: Bool { value.count == 1 }

    var body: some View {
        Text(value)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, isSingleCharacter ? 0 : 5.5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.accentRed, in: Capsule())
    }
}
