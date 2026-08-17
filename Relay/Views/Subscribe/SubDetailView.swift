//
//  SubDetailView.swift
//  NEBox

import SwiftUI
import SDWebImageSwiftUI

private enum SubDetailLayoutMode: String {
    case grid
    case list

    static let userDefaultsKey = "subDetailLayoutMode"
}

struct SubDetailView: View {
    let subURL: String?

    @EnvironmentObject var boxModel: BoxJsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(SubDetailLayoutMode.userDefaultsKey) private var layoutModeRaw: String = SubDetailLayoutMode.grid.rawValue

    @State private var items: [AppModel] = []
    @StateObject private var router = RelayRouter()
    @State private var isScrolled: Bool = false

    /// Derived from boxData on appear / change — only the header fields, no apps array.
    @State private var subName: String = ""
    @State private var subIcon: String = ""

    private var isListMode: Bool {
        SubDetailLayoutMode(rawValue: layoutModeRaw) == .list
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Same gradient as HomeView
            LinearGradient(
                colors: Color.pageGradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Color.clear.frame(height: 56)

                if items.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 48))
                            .foregroundColor(.textSecondary.opacity(0.4))
                        Text("该订阅暂无应用")
                            .foregroundColor(.textSecondary.opacity(0.7))
                        Spacer()
                    }
                } else if isListMode {
                    appListView
                } else {
                    appGridView
                }
            }

            // Nav bar on top — opaque, so grid content scrolls cleanly underneath.
            VStack {
                navBar
                Spacer()
            }
        }
        .neboxHiddenNavigationBar()
        .background(Color.gradientBottom.ignoresSafeArea(edges: .bottom))
        // Destinations are attached per-cell/row so the zoom originates there.
        .onAppear { loadSubDetail() }
        .onDisappear {
            Task {
                await boxModel.flushPendingDataUpdates()
            }
        }
        .enableSwipeBack()
    }

    private func loadSubDetail() {
        guard let url = subURL,
              let detail = boxModel.boxData.displayAppSubDetail(for: url) else { return }
        subName = detail.name
        subIcon = detail.icon
        items = detail.apps
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        RelayNavBar(isScrolled: isScrolled) {
            RelayBackButton(action: { dismiss() }) {
                HStack(spacing: 6) {
                    subAvatar

                    Text(subName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.textPrimary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            HStack(spacing: 14) {
                // Layout toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutModeRaw = isListMode
                            ? SubDetailLayoutMode.grid.rawValue
                            : SubDetailLayoutMode.list.rawValue
                    }
                } label: {
                    Image(systemName: isListMode ? "square.grid.2x2" : "list.bullet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.accent)
                }

                // App count badge
                Text("\(items.count) 个应用")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var subAvatar: some View {
        if !subIcon.isEmpty, let iconURL = URL(string: subIcon) {
            WebImage(url: iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                subAvatarFallback
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        } else if !subName.isEmpty {
            subAvatarFallback
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        }
    }

    private var subAvatarFallback: some View {
        Text(String(subName.prefix(1)))
            .font(.system(size: 28 * 0.42, weight: .semibold, design: .rounded))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgMuted)
    }

    // MARK: - Card List View

    private var favAppIds: Set<String> {
        Set(boxModel.favApps.map { $0.id })
    }

    private var appListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { app in
                    appCard(app)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture {
                            router.push(.appDetail(appID: app.id))
                        }
                        // Per-row, so the zoom animates out of this card.
                        .neboxNavigationDestination(
                            isPresented: router.binding(for: .appDetail(appID: app.id))
                        ) {
                            AppDetailView(app: app)
                        }
                        .contextMenu {
                            let favIds = boxModel.boxData.usercfgs?.favapps ?? []
                            let isFav = favIds.contains(app.id)
                            Button {
                                Task { @MainActor in
                                    let ids = boxModel.boxData.usercfgs?.favapps ?? []
                                    if ids.contains(app.id) {
                                        boxModel.updateData(path: "usercfgs.favapps", data: ids.filter { $0 != app.id })
                                    } else {
                                        boxModel.updateData(path: "usercfgs.favapps", data: ids + [app.id])
                                    }
                                }
                            } label: {
                                Label(isFav ? "取消收藏" : "加入收藏",
                                      systemImage: isFav ? "heart.slash" : "heart.fill")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, adaptiveBottomInset())
        }
    }

    /// Read-only grid: no edit mode or reordering, tap opens the app detail.
    private var appGridView: some View {
        AppGridView(
            items: $items,
            boxModel: boxModel,
            router: router,
            isEditMode: .constant(false),
            allowsEdit: false,
            favAppIds: favAppIds,
            contextMenu: { app in
                let isFav = favAppIds.contains(app.id)
                return AnyView(
                    Button {
                        toggleFavorite(app)
                    } label: {
                        Label(
                            isFav ? "取消收藏" : "加入收藏",
                            systemImage: isFav ? "heart.slash" : "heart.fill"
                        )
                    }
                )
            },
            destination: { app in
                AnyView(AppDetailView(app: app))
            },
            onScrolled: $isScrolled
        )
    }

    private func toggleFavorite(_ app: AppModel) {
        Task { @MainActor in
            let ids = boxModel.boxData.usercfgs?.favapps ?? []
            if ids.contains(app.id) {
                boxModel.updateData(path: "usercfgs.favapps", data: ids.filter { $0 != app.id })
            } else {
                boxModel.updateData(path: "usercfgs.favapps", data: ids + [app.id])
            }
        }
    }

    private func appCard(_ app: AppModel) -> some View {
        let appearance = IconAppearance(rawValue: UserDefaults.standard.string(forKey: IconAppearance.userDefaultsKey) ?? "") ?? .auto
        let isDark = appearance.isDark(systemIsDark: colorScheme == .dark)
        let isFav = favAppIds.contains(app.id)

        return HStack(spacing: 14) {
            // App icon
            if let url = app.adaptiveIconURL(isDark: isDark) {
                WebImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(String(app.name.prefix(1)))
                        .font(.system(size: 48 * 0.42, weight: .semibold, design: .rounded))
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.bgMuted)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 48 * 0.2237, style: .continuous))
            } else {
                Text(String(app.name.prefix(1)))
                    .font(.system(size: 48 * 0.42, weight: .semibold, design: .rounded))
                    .foregroundColor(.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 48 * 0.2237, style: .continuous))
            }

            // Name + description
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.textPrimary)
                    .lineLimit(2)

                if let desc = app.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(app.author)
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Favorite heart button
            Button {
                Task { @MainActor in
                    let ids = boxModel.boxData.usercfgs?.favapps ?? []
                    if ids.contains(app.id) {
                        boxModel.updateData(path: "usercfgs.favapps", data: ids.filter { $0 != app.id })
                    } else {
                        boxModel.updateData(path: "usercfgs.favapps", data: ids + [app.id])
                    }
                }
            } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isFav ? .red : .textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 2)
    }

}
