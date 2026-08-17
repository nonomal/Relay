//
//  RelayNavigationBarLayer.swift
//  Relay
//
//  Ported from screenhop's design system (same author).
//
//  页面声明 NavigationBarPresentation，modifier 持有导航栏实现并与页面内容并列。
//
//  ## 形状：栏与内容并列，不是栏包住内容
//
//  架构对齐 Telegram-iOS：`ViewController.swift:210` 是
//  `public let navigationBar: NavigationBar?`——导航栏由容器长期持有，屏幕自己的
//  `displayNode` 与它**并列**；屏幕只往栏里插内容（`setContentNode`）和推状态
//  （`updateBackgroundAlpha`），**从不被导航栏包住**。
//
//  所以这里是一个 modifier 而不是整页容器：**页面保留自己的 ScrollView**，
//  想换 List、加 refreshable、插 safeAreaInset 都是页面自己的事，不用改这个文件。
//  （上一版 ImmersiveHeroPage 把 ScrollView 和内容一起吃进去了，方向反了：
//  页面被容器绑架，heroFraction 这种纯版式细节被迫上浮成组件参数。）
//
//  ## 用法
//
//      ScrollView {
//          VStack(spacing: 0) {
//              MyHero(height: heroHeight)
//              ...正文...
//          }
//      }
//      .navigationBar(.init(chrome: .plain(background: .gradientTop),
//                           title: .fixed("应用订阅")))
//
//  Relay 目前只用 `.plain` 这一条装配线（tab 根页 + push 详情页）。`.immersive`
//  头图那条路径连同 `FullBleedHeroMetrics` / trailingContent 一起从 screenhop
//  原样保留，但本仓库暂无调用方。
//
//  ## ⚠️⚠️ 这个 modifier 存在的首要理由：把挂载顺序焊死
//
//  抽象这层曾经翻过一次车——漏掉挂载层级约束，真机复现「iOS 26 上标题不再垂直
//  居中、掉到导航栏下方」。硬约束是：
//    · 渐隐条 / 标题 / 右上角按钮三层**必须同层级**，都在承载滚动内容那层的
//      `.ignoresSafeArea(.container, edges: .top)` **之后**、
//      `.applyImmersiveNavigationBarAppearance()` 等系统导航栏 modifier **之前**；
//    · 挂到页面 body 最外层（导航栏 modifier 之后）那层坐标系里导航栏是「真实
//      存在、占位」的控件，内部 overlay 定位测出的 safe-area 语义
//      会变，标题整体跑偏一个导航栏高度；
//    · `.scrollEdgeVisible` 必须直接挂在 ScrollView 本身，挂到内部内容上静默失效。
//
//  这些顺序全部排在本文件的 `body(content:)` 里，**页面挂一次 `.navigationBar`
//  就自动是对的**——这正是它相对「页面自己拼 overlay」的价值所在。
//

import SwiftUI

// MARK: - 头图几何

/// 头图高度的标准算法。页面自己算头图高度（那是页面的版式），但公式共享——
/// 踩过「丢掉 topInset 整体视觉偏上」的回归，别各写各的。
enum FullBleedHeroMetrics {
    /// Hero 高度 = **全出血视口**（可用视口 + 顶部安全区）× fraction。
    /// ScrollView 向上延伸到安全区后，Hero 顶边多占的那一截被状态栏/导航栏吸走；
    /// 按全出血算，模糊起点、渐变分布、信息文字块随总高统一下移，避免整体视觉偏上。
    /// ⚠️ 别改成只用 `viewport.size.height`（丢掉 topInset 那版出过回归）。
    static func height(in viewport: GeometryProxy, fraction: CGFloat) -> CGFloat {
        (viewport.size.height + viewport.safeAreaInsets.top) * fraction
    }
}

// MARK: - 系统导航栏 shim
//
// 这两个只服务沉浸式体系，跟着这一层放（原先住在 Features/Schedule/PaneBottomBar.swift，
// 一个 Schedule 功能文件里，找不到也想不到）。

extension View {
    /// 系统顶部渐隐/模糊的显隐开关（`scrollEdgeEffectHidden` 的语义是反的——hidden，
    /// 这里包一层正向的 visible 语义，调用方不用自己记反）。
    ///
    /// ⚠️ `scrollEdgeEffectHidden` 是 iOS 26+ API，**符号本身**在 Xcode 16.4 的 SDK 里
    /// 不存在（不是单纯的运行时版本限制）——`#available` 管不住，必须靠
    /// `#if compiler(>=6.2)` 在编译期整段跳过，否则本机构建会因找不到符号直接失败
    /// （还会连锁触发同一 modifier 链后续调用一起报「无法推断类型」的假错误）。
    /// 本机没有 Xcode 26 前，改这行前先看 [[local-build-baseline]] 那条项目记忆。
    @ViewBuilder
    func scrollEdgeVisible(_ visible: Bool, for edge: Edge.Set) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(!visible, for: edge)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// 沉浸式全屏头图页的导航栏处理：露顶满头图，同时保住系统返回箭头/边缘右滑。
    /// 两个系统都保持导航栏整条可见，差别只在导航背景的系统默认行为：
    ///
    /// - iOS 26（Liquid Glass）：导航栏本身默认透明，系统默认边缘效果已被
    ///   `.scrollEdgeVisible(false)` 整条关掉；返回箭头仍是系统 Liquid Glass 控件浮在
    ///   内容上，右滑返回与交互式转场都保留。
    /// - iOS 26 前：`.toolbarBackground(.hidden)` 隐掉背景材质即可（整条隐藏反而会
    ///   停用 interactivePopGestureRecognizer，丢掉右滑返回）。
    ///
    /// tabBar 在 iOS 26 由本页（被 push 的目标）声明隐藏，让 push 转场协调 inset 收回，
    /// 避免容器层条件隐藏时 tab bar 高度的底部安全区留白收不回。
    @ViewBuilder
    fileprivate func applyImmersiveNavigationBarAppearance() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
                .toolbar(.visible, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
        } else {
            self
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        // Relay 的部署目标是 iOS 15（screenhop 是 17），这两个 API 都是 16+，
        // 所以这条分支要比原实现多一层运行时判断；15 上退回系统默认栏背景。
        if #available(iOS 16.0, *) {
            self
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
        #endif
    }
}

// MARK: - 挂载

struct NavigationBarModifier<Trailing: View>: ViewModifier {
    let presentation: NavigationBarPresentation<Trailing>

    @State private var scrollOffset: CGFloat = 0
    /// 渐隐条显隐进度（仅沉浸页用）：静止时 0（整页干净的沉浸头图），一滚动才浮现。
    @State private var barProgress: CGFloat = 0
    /// 页内大标题锚点的**静止位**（滚动量为 0 时标题底边的屏幕坐标）：
    /// 报上来的实时坐标 + 当下滚动量还原而得——布局静态量，滚动中不变，
    /// iOS 18+ 滚动不重报 preference 也不影响。nil = 页面没标锚点，走固定阈值。
    @State private var anchorRestBottom: CGFloat? = nil

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            switch presentation.chrome {
            case .immersive(let background):
                immersiveBody(content, background: background)
            case .plain(let background, let fade, let ownsScrollEdge):
                plainBody(content, background: background, fade: fade, ownsScrollEdge: ownsScrollEdge)
            }
        }
        .onPreferenceChange(NavigationBarRevealAnchorKey.self) { globalBottom in
            let rest = globalBottom.map { $0 + scrollOffset }
            // 0.5pt 容差去重：iOS 17 滚动中 preference 每帧重报，还原值恒等，别白写 state
            if let rest, let old = anchorRestBottom, abs(rest - old) < 0.5 { return }
            anchorRestBottom = rest
        }
    }

    /// 锚点模式的浮现阈值（滚动量口径）：标题底边滚到导航栏下沿即触发。
    /// 栏下沿锚真实系统栏（NavigationBarMetrics.systemBand，别的口径都踩过坑）。
    private var revealAt: CGFloat? {
        anchorRestBottom.map { rest in
            let band = NavigationBarMetrics.systemBand
            return rest - (band.top + band.height)
        }
    }

    // MARK: 沉浸头图 push 页

    private func immersiveBody(_ content: Content, background: Color) -> some View {
        titled(
            content
                // iOS 26 自带的顶部+底部边缘效果整条关掉：渐隐不分系统统一走下面 overlay
                // 里的 EdgeFadeBar 手绘（系统 Liquid Glass 版本在「降低透明度」开启时会被
                // 强制换成纯色硬边且无法覆盖，与其读环境值来回切分支，不如全走自己可控的
                // 手绘方案）。底边同理——曾经只关了 .top，内容与 tab bar / Home Indicator
                // 衔接处在「降低透明度」下会露出一条实色遮挡带。
                // ⚠️ 必须直接挂在 ScrollView 本身，挂到内部内容上会**静默失效**。
                .scrollEdgeVisible(false, for: [.top, .bottom])
                // 必须直接作用于真正承载滚动的视图。挂在外层容器只会扩展几何范围，
                // NavigationStack 仍可能为内部 UIScrollView 保留顶部导航区，表现为
                // 导航栏背景虽透明、头图却仍从返回按钮下方才开始。
                .ignoresSafeArea(.container, edges: .top)
                // ⚠️ 以下三层（渐隐条 / 标题 / 右上角按钮）必须都在这个位置：
                // ignoresSafeArea 之后、导航栏 modifier 之前。见文件头。
                .overlay(alignment: .top) {
                    ScreenTopOverlay {
                        EdgeFadeBar(tint: background,
                                    height: NavigationBarMetrics.fadeBarHeight,
                                    progress: barProgress)
                    }
                },
            // 箭头压在深色头图上，必须白；不能跟随主题色。
            tint: .white, arrowTint: .white,
            barColorScheme: .dark, legacyUsesPrincipal: false
        )
        .overlay(alignment: .top) {
            if let trailingContent = presentation.trailingContent {
                NavigationBarContentArea {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)   // 推到右侧，右边缘钉死
                        trailingContent()
                    }
                    .padding(.trailing, 20)
                }
                // 压在深色头图上，玻璃/材质要按深色语境渲染才和左侧系统返回钮一致。
                .environment(\.colorScheme, .dark)
                // NavigationBarContentArea 默认 allowsHitTesting(false)（本是给标题那类
                // 纯展示内容用的），按钮要可点必须显式打开。
                .allowsHitTesting(true)
            }
        }
        .navigationBarScrollChange { offset in
            scrollOffset = offset
            // 渐变窗口外恒为 0/1——不写 state 就不触发整页 body 重算
            let progress = NavigationBarReveal.progress(scrollOffset: offset)
            if progress != barProgress { barProgress = progress }
            presentation.onScroll?(offset)
        }
        .background(background.ignoresSafeArea())
        .modifier(NavigationBarLegacyTitle())
        .applyImmersiveNavigationBarAppearance()
    }

    // MARK: 白底页（tab 根 / 普通 push 详情）

    /// 保留系统栏行为与 tab bar；渐隐条常驻（26+）；空系统标题（inline 最矮栏高，
    /// 顺带让 push 出去的返回按钮只留箭头）。自绘 trailing 在此语境忽略——白底页
    /// 右上角按钮走页面自己的系统 ToolbarItem（Liquid Glass 胶囊/热区/无障碍）。
    private func plainBody(_ content: Content, background: Color, fade: Bool,
                           ownsScrollEdge: Bool) -> some View {
        scrollWired(
            titled(content.navigationBarEdgeFade(tint: background, enabled: fade,
                                                 ownsScrollEdge: ownsScrollEdge),
                   // 标题走正文色；箭头传 nil = 跟随主题色（iOS 惯例）。
                   tint: .textPrimary, arrowTint: nil,
                   barColorScheme: nil, legacyUsesPrincipal: true)
        )
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// plain 的滚动接线只在需要时挂（reveal 标题 / 页面要 onScroll 回调）；
    /// 常驻渐隐不吃滚动进度，没必要白订阅滚动几何。
    @ViewBuilder
    private func scrollWired<V: View>(_ view: V) -> some View {
        if case .reveal = presentation.title {
            view.navigationBarScrollChange { offset in
                scrollOffset = offset
                presentation.onScroll?(offset)
            }
        } else if presentation.onScroll != nil {
            view.navigationBarScrollChange { presentation.onScroll?($0) }
        } else {
            view
        }
    }

    // MARK: 标题槽

    @ViewBuilder
    private func titled<V: View>(_ view: V, tint: Color,
                                 arrowTint: Color?,
                                 barColorScheme: ColorScheme?,
                                 legacyUsesPrincipal: Bool) -> some View {
        switch presentation.title {
        case .none:
            view
        case .fixed(let text):
            view.navigationBarTitle(NavigationBarTitlePresentation(
                title: text, tint: tint, arrowTint: arrowTint,
                trailingButtonWidth: presentation.trailingWidth,
                trailingButtonMaxWidth: presentation.trailingMaxWidth,
                horizontalAlignment: presentation.titleAlignment,
                mode: .always, barColorScheme: barColorScheme))
        case .reveal(let text):
            view.navigationBarTitle(NavigationBarTitlePresentation(
                title: text, tint: tint, arrowTint: arrowTint,
                trailingButtonWidth: presentation.trailingWidth,
                trailingButtonMaxWidth: presentation.trailingMaxWidth,
                horizontalAlignment: presentation.titleAlignment,
                mode: .revealOnScroll, barColorScheme: barColorScheme,
                legacyUsesPrincipal: legacyUsesPrincipal,
                revealAt: revealAt),
                scrollOffset: scrollOffset)
        }
    }
}

// MARK: - 滚动量管线

/// iOS 17 兜底路径用。iOS 18 起 ScrollView 滚动不再触发内容重排，
/// GeometryReader+PreferenceKey 的经典追踪在滚动中不更新（iOS 26 真机实测进度恒 0），
/// 高版本必须走官方 onScrollGeometryChange。
///
/// 页面在内容上挂 `.navigationBarScrollSource()` 提供 17 的数据源（见下）。
private struct NavigationBarScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// iOS 17 兜底路径的滚动量来源：挂在 **ScrollView 内部的内容**上。
    /// 18+ 走官方 onScrollGeometryChange，不读这个（挂着也无害）。
    ///
    /// 内容顶边的屏幕坐标即滚动量（内容 ignoresSafeArea 后顶边静止时贴屏幕顶，
    /// minY == 0），取 .global 不依赖 ScrollView 自身的 inset 口径。
    func navigationBarScrollSource() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: NavigationBarScrollKey.self,
                                       value: -geo.frame(in: .global).minY)
            }
        }
    }
}

/// 页内大标题锚点：报标题底边的实时屏幕坐标（.global maxY）。
/// nil = 页面没标锚点（`.reveal` 退回固定阈值）。
struct NavigationBarRevealAnchorKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// 挂在**页内大标题**（头图片名等）上：`.reveal` 标题的浮现时机改按「这个标题
    /// 滚过导航栏下沿」触发，不再用固定 12/50pt 阈值猜位置。
    /// 组件把报上来的屏幕坐标 + 当下滚动量还原成静止位（布局静态量），
    /// 所以 iOS 18+ 滚动中 GeometryReader 不重报也不影响判定。
    func navigationBarRevealAnchor() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: NavigationBarRevealAnchorKey.self,
                                       value: geo.frame(in: .global).maxY)
            }
        }
    }
}

extension View {
    /// 滚动量回调（挂在 ScrollView 上）：回调值 = 相对静止位的滚动量，顶部 0、上滚为正。
    /// 供 `.navigationBarTitle(_:scrollOffset:)` 的 scrollOffset 数据源使用——不止
    /// `NavigationBarModifier`（沉浸头图）内部消费，任何「push 进来、有标题、
    /// 白底也行」的详情页都能直接挂它驱动标题浮现。
    /// iOS 17 兜底路径还需要页面内容上挂 `.navigationBarScrollSource()`。
    @ViewBuilder
    func navigationBarScrollChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, newValue in
                action(newValue)
            }
        } else {
            onPreferenceChange(NavigationBarScrollKey.self, perform: action)
        }
    }
}

/// iOS 26 上标题已由 .navigationBarTitle 动态设过，再无条件盖一次 "" 会把它冲回空；
/// 空标题只服务旧系统分支（自绘标题不消费 .navigationTitle，留空防止 push 转场里
/// 漏出兜底文字）。
private struct NavigationBarLegacyTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
