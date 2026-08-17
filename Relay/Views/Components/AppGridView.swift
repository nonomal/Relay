//
//  AppGridView.swift
//  Relay
//
//  Native SwiftUI replacement for the former `CollectionViewWrapper`
//  (UICollectionView + UIViewRepresentable) used on Home and Sub-detail.
//
//  Behaviours carried over from the UIKit implementation:
//   - 4-column grid, 24pt line spacing, 16pt horizontal inset, 90pt rows
//   - pull-to-refresh
//   - long-press to enter edit mode (with haptic) + jiggle animation
//   - drag to reorder while in edit mode, persisting `usercfgs.favapps`
//   - delete badge (edit mode) and favourite badge
//   - context menu support
//

import SwiftUI

struct AppGridView: View {
    @Binding var items: [AppModel]
    var boxModel: BoxJsViewModel
    @ObservedObject var router: RelayRouter
    @Binding var isEditMode: Bool

    var bottomInset: CGFloat = adaptiveBottomInset()
    /// 首行与导航栏之间的留白。首页（栏上无标题）用默认 24；订阅详情那类
    /// 带标题的页面要小一些，否则首行离栏太远。
    var topInset: CGFloat = 24
    /// When false the grid is read-only: no long-press edit, no reordering.
    var allowsEdit: Bool = true
    /// Replaces the default "navigate to detail" tap behaviour.
    var tapOverride: ((AppModel) -> Void)? = nil
    var favAppIds: Set<String> = []
    /// Optional per-app context menu. Returning an empty view disables the menu.
    var contextMenu: ((AppModel) -> AnyView)? = nil
    /// Builds the pushed destination for a tapped app. Attached per-cell so
    /// Transmission's zoom transition originates from that cell's frame rather than
    /// from the whole page.
    var destination: ((AppModel) -> AnyView)? = nil
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(items) { app in
                        gridItem(app).id(app.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                // `.reveal` 标题在 iOS 17 的滚动量来源（18+ 走官方
                // onScrollGeometryChange，挂着也无害）。没有它，用网格模式的
                // 详情页在 iOS 17 上标题永远不浮现。
                .navigationBarScrollSource()
            }
            // 压制 iOS 26 系统 scroll edge effect：必须直接挂在 ScrollView 上，
            // 挂到外层容器会静默失效（页面那层传的是 ownsScrollEdge: false）。
            .navigationBarScrollEdge()
            // Re-tapping the active tab scrolls back to the top (Telegram behaviour).
            .onReceive(NotificationCenter.default.publisher(for: .relayTabReselected)) { _ in
                guard let first = items.first else { return }
                withAnimation { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
        .neboxDismissKeyboardOnScroll()
        .refreshable {
            await boxModel.fetchDataAsync()
        }
        // Tapping empty space leaves edit mode, matching the home-screen idiom.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if isEditMode { isEditMode = false } }
        )
    }

    // The view tree here must be **type-stable**: `WebImage` (inside the cell) stores
    // its decoded image in a `@StateObject`, which SwiftUI discards whenever a view's
    // identity changes, falling back to the placeholder until it reloads. Applying
    // behaviours through `@ViewBuilder` if/else helpers produced a *different concrete
    // type* per branch, so toggling edit mode re-keyed every cell — the image ⇄ letter
    // flicker during the jiggle. Everything below therefore applies unconditionally
    // and varies only its parameters.
    private func gridItem(_ app: AppModel) -> some View {
        let editing = allowsEdit && isEditMode

        return AppGridCell(
            app: app,
            isEditMode: editing,
            showsFavBadge: favAppIds.contains(app.id),
            onDelete: { remove(app) },
            // Attached to the icon *inside* the cell so the zoom anchors on the icon
            // artwork alone, not on the icon-plus-label block.
            isPresented: router.binding(for: .appDetail(appID: app.id)),
            destination: destination.map { build in { build(app) } }
        )
        .contentShape(Rectangle())
        .onTapGesture { handleTap(app) }
        .onLongPressGesture(minimumDuration: 0.4) { beginEditing() }
        .contextMenu { contextMenu?(app) }
        // `onDrag` is only meaningful in edit mode; returning an empty provider
        // outside it keeps the modifier — and thus the view type — constant.
        .onDrag {
            guard editing else { return NSItemProvider() }
            // Recorded synchronously so `dropEntered` can identify the source
            // immediately — resolving the provider's payload would be async.
            AppDragState.currentID = app.id
            return NSItemProvider(object: app.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: AppReorderDropDelegate(
                item: app,
                items: $items,
                isEnabled: editing,
                onReorder: persistOrder
            )
        )
    }

    // MARK: - Actions

    private func handleTap(_ app: AppModel) {
        if let tapOverride {
            tapOverride(app)
        } else if allowsEdit && isEditMode {
            // In edit mode a tap on the icon body is a no-op; removal is the badge.
            return
        } else {
            // `push` wraps the state change in `withAnimation` — Transmission only
            // animates the presentation when the transaction carries an animation.
            router.push(.appDetail(appID: app.id))
        }
    }

    private func beginEditing() {
        guard allowsEdit, !isEditMode else { return }
        Vibration.medium.vibrate()
        withAnimation(.easeInOut(duration: 0.2)) { isEditMode = true }
    }

    private func remove(_ app: AppModel) {
        let remaining = items.map(\.id).filter { $0 != app.id }
        Task { @MainActor in
            boxModel.updateData(path: "usercfgs.favapps", data: remaining)
        }
    }

    private func persistOrder() {
        let ids = items.map(\.id)
        Task { @MainActor in
            boxModel.updateData(path: "usercfgs.favapps", data: ids)
        }
    }
}

// MARK: - Icon-anchored destination

/// Attaches the push destination to the icon artwork so Transmission's zoom morphs out
/// of the icon itself — Transmission uses the view the modifier is attached to as the
/// transition's source. Written as a `ViewModifier` rather than a `@ViewBuilder`
/// if/else so the view type stays constant (see `gridItem`).
private struct AppIconDestinationModifier: ViewModifier {
    let isPresented: Binding<Bool>
    let destination: (() -> AnyView)?

    func body(content: Content) -> some View {
        if let destination {
            content.neboxNavigationDestination(isPresented: isPresented) {
                destination()
            }
        } else {
            content
        }
    }
}

// MARK: - Drop delegate

/// Reorders `items` live as the dragged app passes over other cells.
private struct AppReorderDropDelegate: DropDelegate {
    let item: AppModel
    @Binding var items: [AppModel]
    /// Reordering only applies in edit mode; the delegate stays attached regardless so
    /// the view type never changes.
    let isEnabled: Bool
    let onReorder: () -> Void

    func validateDrop(info: DropInfo) -> Bool { isEnabled }

    func dropEntered(info: DropInfo) {
        guard isEnabled,
              let draggedID = AppDragState.currentID,
              draggedID != item.id,
              let from = items.firstIndex(where: { $0.id == draggedID }),
              let to = items.firstIndex(where: { $0.id == item.id })
        else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            let moved = items.remove(at: from)
            items.insert(moved, at: to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        AppDragState.currentID = nil
        onReorder()
        return true
    }
}

/// Tracks which app is mid-drag. `onDrag`'s `NSItemProvider` is asynchronous, so a
/// synchronous side-channel keeps `dropEntered` responsive.
enum AppDragState {
    static var currentID: String?
}

// MARK: - Cell

private struct AppGridCell: View {
    let app: AppModel
    let isEditMode: Bool
    let showsFavBadge: Bool
    let onDelete: () -> Void
    let isPresented: Binding<Bool>
    let destination: (() -> AnyView)?

    /// Current rotation in degrees; the wobble animates this directly.
    @State private var angle: Double = 0
    /// Per-cell phase offset, generated **once**. Calling `Double.random` inside
    /// `body` would mint a new `Animation` on every re-render, restarting the jiggle
    /// and thrashing the icon's async-load state (image ⇄ fallback flicker).
    @State private var phase: Double = Double.random(in: 0...0.04)

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AppIconView(app: app, size: 60)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

                if showsFavBadge {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.yellow, .white)
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: .topLeading) {
                if isEditMode {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(.darkGray))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .offset(x: -6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("移除 \(app.name)")
                }
            }
            // The badge hangs 6pt outside the 60pt icon on the top/leading edges.
            // Without this padding the cell hugs the icon exactly and the grid column
            // clips the overhang, slicing the badge in half.
            .padding(.top, badgeOverhang)
            .padding(.horizontal, badgeOverhang)
            // Anchored here — on the icon alone — rather than on the whole cell, so the
            // zoom morphs out of the artwork instead of the icon-plus-label block.
            .modifier(
                AppIconDestinationModifier(
                    isPresented: isPresented,
                    destination: destination
                )
            )

            Text(app.name)
                .font(.system(size: 11.5, weight: .medium))
                .relayWallpaperAwareForeground(.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 90 + badgeOverhang, alignment: .top)
        .rotationEffect(.degrees(angle))
        .onChange(of: isEditMode) { editing in
            setJiggle(editing)
        }
        .onAppear { setJiggle(isEditMode) }
    }

    /// Starts/stops the wobble.
    ///
    /// `angle` holds the rotation directly and is animated *explicitly*. Two earlier
    /// attempts failed because the exit path never produced a real value change:
    /// deriving the angle from `isEditMode` meant it had already snapped to 0 by the
    /// time the stop animation ran, so that animation interpolated 0 → 0 and never
    /// displaced the still-attached `repeatForever` curve — the cells kept wobbling
    /// after "完成". Animating `angle` itself guarantees a 2° → 0° change to carry.
    private func setJiggle(_ editing: Bool) {
        if editing {
            // Snap to one extreme un-animated, then let the repeating curve swing to the
            // other and back, so the wobble is symmetric about upright.
            angle = -2
            withAnimation(.easeInOut(duration: 0.125 + phase).repeatForever(autoreverses: true)) {
                angle = 2
            }
        } else {
            // A real value change, so this animation displaces the repeating one.
            withAnimation(.easeOut(duration: 0.15)) {
                angle = 0
            }
        }
    }

    /// How far the delete badge extends beyond the icon's top/leading edges.
    private var badgeOverhang: CGFloat { 6 }

}
