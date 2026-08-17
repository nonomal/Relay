import SwiftUI
import SDWebImageSwiftUI
import os.log

private let homeLog = Logger(subsystem: "Relay", category: "HomeView")

/// Fallback icon URL derived from env id
private func fallbackIconURL(for envId: String) -> String {
    let key = envId.lowercased()
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "")
    return "https://raw.githubusercontent.com/Orz-3/mini/master/Color/\(key).png"
}

/// URL scheme to open the corresponding proxy app
private func appURLScheme(for envId: String) -> String? {
    switch envId.lowercased().replacingOccurrences(of: " ", with: "") {
    case "loon":          return "loon://"
    case "surge":         return "surge://"
    case "shadowrocket":  return "shadowrocket://"
    case "quantumultx", "quanx":   return "quantumult-x://"
    case "stash":         return "stash://"
    default:              return nil
    }
}

/// Icon URL for a SysEnv based on color scheme: icons[0] = dark, icons[1] = light
private func iconURL(for env: SysEnv, isDark: Bool) -> String {
    if let icons = env.icons {
        let index = isDark ? 0 : 1
        if index < icons.count, !icons[index].isEmpty { return icons[index] }
        if let first = icons.first, !first.isEmpty { return first }
    }
    return fallbackIconURL(for: env.id)
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var boxModel: BoxJsViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    var onSearch: () -> Void

    @State var items: [AppModel] = []
    @StateObject private var router = RelayRouter()
    @State private var isEditMode: Bool = false

    private var activeEnv: String? { boxModel.boxData.syscfgs?.env }
    private var availableEnvs: [SysEnv] { boxModel.boxData.syscfgs?.envs ?? [] }

    var body: some View {
        neboxNavigationContainer {
            ZStack(alignment: .top) {
                RelayPageBackground()

                Group {
                    if !boxModel.isDataLoaded {
                        VStack {
                            Spacer()
                            ProgressView().scaleEffect(1.2)
                            Spacer()
                        }
                    } else if !boxModel.favApps.isEmpty {
                        AppGridView(
                            items: $items,
                            boxModel: boxModel,
                            router: router,
                            isEditMode: $isEditMode,
                            destination: { app in
                                AnyView(AppDetailView(app: app))
                            }
                        )
                    } else {
                        emptyStateView
                    }
                }
                .onAppear { items = boxModel.favApps }
                .onDisappear { isEditMode = false }
                .onReceive(boxModel.$favApps) { favApps in
                    items = favApps
                }
            }
            // Destination is attached per-cell inside `AppGridView` so the zoom
            // transition originates from the tapped icon.
            //
            // 沉浸式导航栏：tab 根页走 `.plain` — 系统栏保留（右上角按钮仍是系统
            // ToolbarItem，保住 Liquid Glass 胶囊与热区），栏背景换成常驻的手绘
            // 渐隐条，内容从栏下「化开」。tint 跟着页面背景走：有壁纸时用壁纸自身
            // 的洗层色调没有意义，仍取渐变顶色即可（渐隐条是半透明的色洗层）。
            //
            // `ownsScrollEdge: false`：真正的 ScrollView 在 `AppGridView` 内部，
            // 不是这一层。渐隐条仍只画一份在这里，压制系统边缘效果则由那个
            // ScrollView 自己挂 `.navigationBarScrollEdge()`（挂到非滚动容器上会
            // 静默失效）。
            .navigationBar(.init(
                chrome: .plain(background: .gradientTop, ownsScrollEdge: false),
                title: .none
            ))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { openProxyApp() } label: {
                        toolAvatarView
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !boxModel.favApps.isEmpty {
                        Button {
                            isEditMode.toggle()
                        } label: {
                            Image(systemName: isEditMode
                                  ? "checkmark.circle"
                                  : "circle.grid.2x2")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .accessibilityLabel(isEditMode ? "完成" : "编辑")
                    }
                }
            }
        }
        .neboxLiquidGlassTabBarChrome()
    }


    @ViewBuilder
    private var toolAvatarView: some View {
        if let envId = activeEnv, !envId.isEmpty {
            let urlString: String = {
                if let sysEnv = availableEnvs.first(where: { $0.id == envId }) {
                    return iconURL(for: sysEnv, isDark: colorScheme == .dark)
                }
                return fallbackIconURL(for: envId)
            }()
            WebImage(url: URL(string: urlString)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(envId.prefix(1))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gradientTop)
            }
        } else {
            Image(systemName: "network")
                .font(.system(size: 18))
                .foregroundColor(.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gradientTop)
        }
    }

    // MARK: - Actions

    private func openProxyApp() {
        guard let envId = activeEnv,
              let scheme = appURLScheme(for: envId),
              let url = URL(string: scheme) else { return }
        openURL(url)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .relayWallpaperAwareForeground(.textSecondary.opacity(0.4))
            Text("还没有收藏应用")
                .relayWallpaperAwareForeground(.textSecondary.opacity(0.7))
            Button {
                onSearch()
            } label: {
                Text("搜索并添加")
                    .font(.system(size: 14))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accent)
                    .foregroundColor(.onAccent)
                    .cornerRadius(8)
            }
            Spacer()
        }
    }

}

#Preview {
    HomeView(onSearch: {})
}
