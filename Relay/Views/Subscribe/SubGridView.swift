//
//  SubGridView.swift
//  Relay
//
//  Native SwiftUI replacement for the former `SubCollectionViewWrapper`
//  (UICollectionView + UIViewRepresentable).
//
//  Behaviours carried over from the UIKit implementation:
//   - 2-column card grid, 12pt gaps, 20pt horizontal inset, 128pt rows
//   - pull-to-refresh (reloads every subscription)
//   - long-press to enter edit mode + jiggle animation and delete badge
//   - drag to reorder while in edit mode, persisting `usercfgs.appsubs`
//   - tap anywhere outside a card leaves edit mode
//   - context menu: refresh / open in browser / copy URL / delete
//   - relative "updated" label refreshed on a 60s tick
//

import SwiftUI
import SDWebImageSwiftUI

struct SubGridView: View {
    @Binding var items: [AppSubSummary]
    let boxModel: BoxJsViewModel
    @ObservedObject var router: RelayRouter
    @Binding var isEditMode: Bool
    /// Builds the pushed destination for a tapped subscription. Attached per-card so
    /// Transmission's zoom morphs out of that card rather than the whole page.
    var destination: ((AppSubSummary) -> AnyView)? = nil
    /// Set once content scrolls under the nav bar, so it can show its separator.
    var onScrolled: Binding<Bool> = .constant(false)

    @Environment(\.openURL) private var openURL

    /// Drives recomputation of the relative update time shown on each card.
    @State private var timeTick = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        card(item).id(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, adaptiveBottomInset())
                .relayScrollOffsetReporter()
            }
            // Re-tapping the active tab scrolls back to the top (Telegram behaviour).
            .onReceive(NotificationCenter.default.publisher(for: .relayTabReselected)) { _ in
                guard let first = items.first else { return }
                withAnimation { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
        .coordinateSpace(name: RelayScroll.space)
        .onPreferenceChange(RelayScrollOffsetKey.self) { minY in
            let scrolled = minY < -2
            if scrolled != onScrolled.wrappedValue { onScrolled.wrappedValue = scrolled }
        }
        .refreshable {
            await boxModel.reloadAllAppSub()
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { if isEditMode { isEditMode = false } }
        )
        .onReceive(tick) { timeTick = $0 }
    }

    /// Kept type-stable across edit-mode changes so the card's async avatar isn't
    /// re-keyed and reloaded mid-jiggle — see the note on `AppGridView.gridItem`.
    private func card(_ item: AppSubSummary) -> some View {
        SubCard(
            item: item,
            isEditMode: isEditMode,
            timeTick: timeTick,
            onDelete: { delete(item) }
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            if isEditMode {
                isEditMode = false
            } else if let url = item.url {
                router.push(.subDetail(url: url))
            }
        }
        .onLongPressGesture(minimumDuration: 0.18) { beginEditing() }
        // Attached per-card so the zoom morphs out of this card.
        .modifier(
            SubCardDestinationModifier(
                isPresented: router.binding(for: .subDetail(url: item.url ?? "")),
                destination: destination.map { build in { build(item) } }
            )
        )
        .contextMenu { if !isEditMode { menu(for: item) } }
        .onDrag {
            guard isEditMode else { return NSItemProvider() }
            SubDragState.currentID = item.id
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: SubReorderDropDelegate(
                item: item,
                items: $items,
                isEnabled: isEditMode,
                onReorder: persistOrder
            )
        )
    }

    @ViewBuilder
    private func menu(for item: AppSubSummary) -> some View {
        Button {
            guard let url = item.url else { return }
            Task { await boxModel.reloadAppSub(url: url) }
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }

        Button {
            guard let url = URL(string: item.repo) else { return }
            openURL(url)
        } label: {
            Label("在浏览器中打开", systemImage: "safari")
        }

        Button {
            PlatformBridge.copyToPasteboard(item.url ?? "")
        } label: {
            Label("复制订阅 URL", systemImage: "doc.on.doc")
        }

        Button(role: .destructive) {
            delete(item)
        } label: {
            Label("删除订阅", systemImage: "minus.circle")
        }
    }

    // MARK: - Actions

    private func beginEditing() {
        guard !isEditMode else { return }
        Vibration.light.vibrate()
        withAnimation(.easeInOut(duration: 0.2)) { isEditMode = true }
    }

    private func delete(_ item: AppSubSummary) {
        guard let url = item.url else { return }
        Task { await boxModel.deleteAppSub(url: url) }
    }

    /// Maps the reordered summaries back onto the stored `appsubs` entries so the
    /// server keeps each subscription's `enable`/`id` fields intact.
    private func persistOrder() {
        let subs = boxModel.boxData.appsubs
        let reordered = items
            .compactMap { ordered in subs.first { $0.url == ordered.url } }
            .map { ["url": $0.url, "enable": $0.enable, "id": $0.id ?? ""] as [String: Any] }
        Task { @MainActor in
            boxModel.updateData(path: "usercfgs.appsubs", data: reordered)
        }
    }
}

// MARK: - Drop delegate

private struct SubReorderDropDelegate: DropDelegate {
    let item: AppSubSummary
    @Binding var items: [AppSubSummary]
    /// See `AppReorderDropDelegate.isEnabled`.
    let isEnabled: Bool
    let onReorder: () -> Void

    func validateDrop(info: DropInfo) -> Bool { isEnabled }

    func dropEntered(info: DropInfo) {
        guard isEnabled,
              let draggedID = SubDragState.currentID,
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
        SubDragState.currentID = nil
        onReorder()
        return true
    }
}

/// Synchronous side-channel for the in-flight drag (see `AppDragState`).
enum SubDragState {
    static var currentID: String?
}

// MARK: - Per-card destination

/// Attaches the push destination to an individual card so Transmission's zoom
/// originates there. A `ViewModifier` rather than a `@ViewBuilder` if/else so the view
/// type stays constant (see `AppGridView.gridItem`).
private struct SubCardDestinationModifier: ViewModifier {
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

// MARK: - Card

private struct SubCard: View {
    let item: AppSubSummary
    let isEditMode: Bool
    /// Only used to invalidate the view so the relative date recomputes.
    let timeTick: Date
    let onDelete: () -> Void

    /// Current rotation in degrees; the wobble animates this directly.
    @State private var angle: Double = 0
    /// Generated once — see `AppGridCell.phase`. Randomising inside `body` restarts
    /// the animation on every render and makes the async avatar flicker.
    @State private var phase: Double = Double.random(in: 0...0.025)

    private var dateText: String {
        item.updateTime.isEmpty ? "--" : formattedTimeDifference(from: item.updateTime)
    }

    // Split into small sub-expressions: as one chained literal the body pushed the
    // type-checker past its time limit.
    var body: some View {
        cardBody
            .padding(16)
            .frame(height: 128)
            .background(cardBackground)
            .overlay(alignment: .topLeading) { deleteBadge }
            .rotationEffect(.degrees(angle))
            .onChange(of: isEditMode) { editing in
                setJiggle(editing)
            }
            .onAppear { setJiggle(isEditMode) }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                SubAvatarView(name: item.name, icon: item.icon)
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                Text(dateText)
                    .font(.system(size: 12))
                    .foregroundColor(.textTertiary)

                Spacer()

                Text("\(item.appCount)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.textPrimary)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.textPrimary.opacity(0.031), radius: 5, y: 2)
    }

    @ViewBuilder
    private var deleteBadge: some View {
        if isEditMode {
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(.darkGray))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .offset(x: -10, y: -10)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel("删除 \(item.name)")
        }
    }

    /// Animates `angle` explicitly — see `AppGridCell.setJiggle` for why deriving the
    /// angle from `isEditMode` left cards wobbling after leaving edit mode.
    private func setJiggle(_ editing: Bool) {
        if editing {
            angle = -1.15
            withAnimation(.easeInOut(duration: 0.14 + phase).repeatForever(autoreverses: true)) {
                angle = 1.15
            }
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                angle = 0
            }
        }
    }
}

// MARK: - Avatar

/// 40pt circular subscription icon with a letter fallback.
private struct SubAvatarView: View {
    let name: String
    let icon: String

    /// Keyed on the URL rather than a bare flag, so re-renders during the jiggle
    /// can't reset it and flip the avatar back to its letter fallback.
    @State private var failedURL: URL?

    private var iconURL: URL? {
        guard !icon.isEmpty, let url = URL(string: icon) else { return nil }
        return url == failedURL ? nil : url
    }

    var body: some View {
        // Structurally constant — no if/else around `WebImage`, no `.id(...)` — so its
        // `@StateObject` image cache survives re-renders (see `AppIconView`).
        WebImage(url: iconURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            fallback
        }
        .onFailure { _ in failedURL = iconURL }
        .frame(width: 40, height: 40)
        .background(Color.bgMuted)
        .clipShape(Circle())
    }

    private var fallback: some View {
        Text(name.first.map(String.init) ?? "")
            .font(.system(size: 40 * 0.42, weight: .semibold, design: .rounded))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
