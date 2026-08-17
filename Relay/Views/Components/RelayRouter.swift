//
//  RelayRouter.swift
//  Relay
//
//  Typed routing for the app's pushed screens.
//
//  Previously each screen owned an ad-hoc pair of `@State`s — `selectedApp` +
//  `isNavigationActive` — and every grid cell had to synthesise its own
//  `isPresented` binding out of them:
//
//      isPresented: Binding(
//          get: { selectedApp?.id == app.id && isNavigationActive },
//          set: { if !$0 { isNavigationActive = false } }
//      )
//
//  Grids ended up taking `presentedID` and `isPresented` parameters purely to rebuild
//  that expression internally. `RelayRouter` replaces the whole arrangement: it holds
//  one optional `Route`, and a cell asks only "am I the current route?" via
//  `binding(for:)`.
//
//  The per-cell binding still matters — Transmission anchors its zoom on the view the
//  destination modifier is attached to, so each cell must own its own presentation
//  flag. What changes is that the router derives those bindings from a single source
//  of truth instead of every screen wiring them by hand.
//

import SwiftUI

// MARK: - Route

/// A screen that can be pushed onto the navigation stack.
enum RelayRoute: Hashable, Identifiable {
    case appDetail(appID: String)
    case subDetail(url: String)
    case backupDetail(id: String)

    var id: String {
        switch self {
        case .appDetail(let appID):  return "app:\(appID)"
        case .subDetail(let url):    return "sub:\(url)"
        case .backupDetail(let id):  return "bak:\(id)"
        }
    }
}

// MARK: - Router

/// Holds the currently pushed route for one screen.
///
/// Scoped per screen rather than app-wide: each tab runs its own navigation container,
/// so a shared stack would let one tab's push clobber another's.
@MainActor
final class RelayRouter: ObservableObject {
    @Published private(set) var route: RelayRoute?

    /// Pushes `route`, carrying an animation.
    ///
    /// Transmission only animates the *presentation* when `isPresented` is set inside a
    /// transaction with an animation; setting it bare pushes instantly and leaves only
    /// the dismissal animated. Routing through here means no call site can forget.
    func push(_ route: RelayRoute) {
        withAnimation {
            self.route = route
        }
    }

    func pop() {
        route = nil
    }

    /// Whether `route` is the one currently pushed.
    func isActive(_ route: RelayRoute) -> Bool {
        self.route == route
    }

    /// Presentation binding for a single route.
    ///
    /// Each cell gets its own binding so Transmission can anchor the zoom on that
    /// cell's view. Only the active route ever reads `true`, and clearing it pops.
    func binding(for route: RelayRoute) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.route == route },
            set: { [weak self] isPresented in
                guard !isPresented else { return }
                // Only clear if this route is still the active one; a stale cell
                // reporting `false` must not cancel a newer push.
                if self?.route == route { self?.pop() }
            }
        )
    }
}
