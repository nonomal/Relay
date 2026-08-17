//
//  RelayNavBar.swift
//  Relay
//
//  Shared navigation bar for the app's custom-chrome screens.
//
//  Home / Subscribe / SubDetail each used to hand-roll a bare 56pt `HStack` with no
//  background, which left page content sliding visibly underneath the status bar.
//  This component gives all of them one opaque, layered surface:
//
//   - a solid `bgCard` fill that extends up through the status bar area
//   - a hairline bottom separator that fades in only once content scrolls under it
//   - consistent 56pt height, 20pt horizontal insets and title typography
//
//  Screens supply their own leading/trailing content, so each page keeps its own
//  controls while sharing the chrome.
//

import SwiftUI

// MARK: - Scroll offset plumbing

/// Reports the top of the scrolling content so the bar knows when to show its separator.
struct RelayScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Coordinate space name screens apply to their `ScrollView` so offsets are measured
/// against the scroll container rather than the window.
enum RelayScroll {
    static let space = "relayScroll"
}

extension View {
    /// Attach to the first element inside a `ScrollView` to drive `RelayNavBar`'s
    /// scrolled state.
    func relayScrollOffsetReporter(coordinateSpace: String = RelayScroll.space) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RelayScrollOffsetKey.self,
                    value: proxy.frame(in: .named(coordinateSpace)).minY
                )
            }
        )
    }
}

// MARK: - Nav bar

struct RelayNavBar<Leading: View, Trailing: View>: View {
    /// Shown centred when the screen has no custom leading content of its own.
    var title: String? = nil
    /// Drives the separator + subtle elevation once content scrolls beneath the bar.
    var isScrolled: Bool = false

    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading()

            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing()
        }
        .frame(height: 56)
        .padding(.horizontal, 20)
        .background(background)
    }

    private var background: some View {
        // `gradientTop`, not `bgCard`: the page behind is a gradient starting at this
        // exact colour, so the bar reads as part of the page. `bgCard` is pure white
        // and made the bar look like a detached white slab.
        Color.gradientTop
            // Paint up through the status bar so scrolled content never shows through.
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(isScrolled ? 1 : 0)
            }
            .shadow(
                color: .black.opacity(isScrolled ? 0.06 : 0),
                radius: 8,
                y: 2
            )
            .animation(.easeInOut(duration: 0.2), value: isScrolled)
    }
}

// MARK: - Convenience initialisers

extension RelayNavBar where Leading == EmptyView {
    init(title: String, isScrolled: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, isScrolled: isScrolled, leading: { EmptyView() }, trailing: trailing)
    }
}

extension RelayNavBar where Trailing == EmptyView {
    init(isScrolled: Bool = false, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: nil, isScrolled: isScrolled, leading: leading, trailing: { EmptyView() })
    }
}

// MARK: - Back button

/// Standard leading back control for pushed screens.
struct RelayBackButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.accent)
                label()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("返回")
    }
}

extension RelayBackButton where Label == EmptyView {
    init(action: @escaping () -> Void) {
        self.init(action: action, label: { EmptyView() })
    }
}
