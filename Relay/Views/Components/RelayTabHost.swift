//
//  RelayTabHost.swift
//  Relay
//
//  Hosts the legacy tabs in a real `UITabBarController`, with each tab rooted in a real
//  `UINavigationController`.
//
//  ## Why
//
//  The tabs used to be a `switch` inside a `ZStack`, with `RelayTabBar` as a sibling at
//  `zIndex(10)`. That paints the bar above everything, so a pushed detail page could
//  never cover it. The page therefore had to *ask* for the bar to be hidden, through a
//  preference key — and preference values only reach the root after SwiftUI finishes
//  reducing them for the whole tree, which happens after the post-pop layout pass. The
//  bar came back a couple of seconds late.
//
//  With a real tab bar controller the layering is UIKit's job. Transmission performs a
//  genuine `pushViewController`; the pushed controller carries `hidesBottomBarWhenPushed`;
//  UIKit slides the bar away and back as part of the navigation transition itself. No
//  visibility state remains, so there is nothing left to lag.
//
//  ## What stays SwiftUI
//
//  The navigation *bar* is untouched. `RelayNavigationBar` builds itself entirely out of
//  SwiftUI's toolbar API — `navigationTitle`, `navigationBarTitleDisplayMode`,
//  `ToolbarItem`, `toolbarBackground` — all of which work inside any
//  `UINavigationController`, including the ones created here. Only the *container*
//  changes; the 1200-line bar system keeps working as-is.
//
//  The system `UITabBar` is kept but blanked: it supplies the layout slot and the
//  `hidesBottomBarWhenPushed` machinery, while `RelayTabBar` remains what the user sees,
//  parented to the bar so it slides along with it.
//

import SwiftUI
import UIKit

// MARK: - SwiftUI entry point

/// Wraps the app's tabs in a `UITabBarController`.
struct RelayTabHost<Bar: View>: UIViewControllerRepresentable {
    let tabCount: Int
    @Binding var selection: Int
    /// Height of the custom bar, used to size its slot and inset tab content.
    let barHeight: CGFloat
    /// Builds the root view for a tab index.
    let content: (Int) -> AnyView
    @ViewBuilder let bar: () -> Bar

    func makeUIViewController(context: Context) -> RelayTabBarController {
        let controller = RelayTabBarController()
        controller.delegate = context.coordinator
        controller.barHeight = barHeight

        controller.viewControllers = (0..<tabCount).map { index in
            let host = RelayTabRootController(rootView: content(index))
            // The custom bar floats over the bottom, so the *tab root* insets past it.
            //
            // Set on the root controller rather than the navigation controller on
            // purpose: a pushed page hides the tab bar (`hidesBottomBarWhenPushed`),
            // so it must not inherit an inset for a bar that is no longer there — its
            // own bottom capsule would sit a bar's height too high.
            host.additionalSafeAreaInsets.bottom = barHeight

            // A real `UINavigationController` as a *direct* child of the tab bar
            // controller. That exact relationship is what `hidesBottomBarWhenPushed`
            // walks: pushed controller → its navigation controller → its tabBarController.
            let nav = RelayTabNavigationController(rootViewController: host)
            nav.view.backgroundColor = .clear
            return nav
        }
        controller.selectedIndex = min(selection, tabCount - 1)
        controller.installCustomBar(UIHostingController(rootView: bar()))
        return controller
    }

    func updateUIViewController(_ controller: RelayTabBarController, context: Context) {
        let clamped = min(max(selection, 0), (controller.viewControllers?.count ?? 1) - 1)
        if controller.selectedIndex != clamped {
            controller.selectedIndex = clamped
        }
        controller.updateCustomBar(bar())

        for (index, child) in (controller.viewControllers ?? []).enumerated() {
            let root = (child as? UINavigationController)?.viewControllers.first
            (root as? RelayTabRootController)?.rootView = content(index)
        }
    }

    static func dismantleUIViewController(_ controller: RelayTabBarController, coordinator: Coordinator) {
        controller.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate {
        @Binding var selection: Int

        init(selection: Binding<Int>) {
            _selection = selection
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
            guard selection != tabBarController.selectedIndex else { return }
            selection = tabBarController.selectedIndex
        }
    }
}

// MARK: - Tab root

/// Hosting controller for a tab's root view.
private final class RelayTabRootController: UIHostingController<AnyView> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

// MARK: - Per-tab navigation controller

/// Navigation controller for one tab.
///
/// `RelayNavigationBar` renders into the SwiftUI toolbar of whatever navigation
/// controller hosts the view, so this one carries the whole existing bar design —
/// titles, back button, trailing menus — without any of it being rewritten.
final class RelayTabNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // The bar stays *visible* — hiding it would drop the tab root's own toolbar
        // items (the logo and grid button `RelayNavigationBar` installs as
        // `ToolbarItem`s), which is what a previous attempt got wrong. Instead it is
        // made fully transparent so the pages' own backgrounds show through, exactly
        // as they did under SwiftUI's `NavigationStack`.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.isTranslucent = true

        // The pages paint their own backgrounds (wallpaper / gradient).
        view.backgroundColor = .clear
    }
}

// MARK: - Tab bar controller

/// `UITabBar` that also accepts touches landing on subviews which overhang its bounds.
///
/// The custom bar is taller than the system bar it is parented to, so the part sticking
/// out above would otherwise be untappable — `hitTest` stops at the parent's bounds.
final class RelayOverhangingTabBar: UITabBar {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return subviews.contains { subview in
            !subview.isHidden
                && subview.alpha > 0.01
                && subview.point(inside: convert(point, to: subview), with: event)
        }
    }
}

/// `UITabBarController` that draws `RelayTabBar` over its own (blanked) tab bar.
final class RelayTabBarController: UITabBarController {
    var barHeight: CGFloat = 68

    private var customBarHost: UIViewController?

    /// `UITabBarController` builds its own `UITabBar`; swapping in the subclass has to
    /// happen through KVC before the view loads.
    override func viewDidLoad() {
        setValue(RelayOverhangingTabBar(), forKey: "tabBar")
        super.viewDidLoad()

        view.backgroundColor = .clear
        // The real bar stays in the hierarchy — it is what `hidesBottomBarWhenPushed`
        // animates — but nothing of it is visible behind the custom bar.
        tabBar.backgroundImage = UIImage()
        tabBar.shadowImage = UIImage()
        tabBar.backgroundColor = .clear
        tabBar.barTintColor = .clear
        tabBar.isTranslucent = true
    }

    func installCustomBar(_ host: UIViewController) {
        customBarHost = host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        // Added *as a subview of the tab bar itself*, not as a sibling: UIKit slides the
        // tab bar off screen for `hidesBottomBarWhenPushed`, and a child rides along
        // automatically. Tracking its frame from outside would lag the transition.
        tabBar.addSubview(host.view)
        host.didMove(toParent: self)

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: tabBar.topAnchor),
            host.view.heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }

    func updateCustomBar<Bar: View>(_ bar: Bar) {
        (customBarHost as? UIHostingController<Bar>)?.rootView = bar
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The custom bar overhangs its parent, so drawing must not be clipped.
        tabBar.clipsToBounds = false
        if let barView = customBarHost?.view {
            tabBar.bringSubviewToFront(barView)
        }
    }
}
