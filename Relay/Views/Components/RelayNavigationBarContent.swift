//
//  RelayNavigationBarContent.swift
//  Relay
//
//  Ported from screenhop's design system (same author).
//
//  NavigationBarPresentation 是页面 API；本文件只保留标题 presentation、
//  内容槽、几何与旧系统 UIKit bridge。完整导航栏由 NavigationBarModifier 持有。
//

import SwiftUI
import UIKit

// MARK: - 配置（纯数据，对应 TG 的 NavigationBarTheme）

/// 导航栏标题的内部呈现数据。页面使用 NavigationBarPresentation；
/// NavigationBarModifier 再把公开配置映射到这里。
/// 白底普通 push 页也可以**直接**用这份 presentation 挂 `.navigationBarTitle`
/// （不经过沉浸头图 facade）：传 `tint: .textPrimary` + `barColorScheme: nil`，
/// 标题要常显再加 `mode: .always`（如设置页）。
struct NavigationBarTitlePresentation {
    /// 标题呈现方式。沉浸头图页用 `.revealOnScroll`（片名已在头图里大字排着，
    /// 静止时栏上不重复，滚过阈值才浮现）；页面内没有替代性大标题的普通 push 页
    /// 用 `.always` 常显（此时 scrollOffset 不用传）。
    enum Mode { case revealOnScroll, always }

    /// 标题文字。
    var title: String
    /// 返回箭头颜色 + 标题文字色。沉浸页通常是白（压在深色头图上）；白底页传 .textPrimary。
    var tint: Color = .white
    /// 左侧按钮组宽度，用于标题居中避让——nil 表示无按钮，走默认安全边距。
    /// 默认 44（系统返回箭头）。
    var leadingButtonWidth: CGFloat? = 44
    /// 右侧按钮组宽度，用于标题居中避让——nil 表示无按钮。滚动时才出现的按钮组，
    /// 调用方把这个值做成随进度变化的 @State 传进来即可，不用改布局公式。
    var trailingButtonWidth: CGFloat? = nil
    /// 右侧按钮组的**最宽态**宽度。给了它，标题布局按最宽态恒定预留，
    /// `trailingButtonWidth` 的变化改用平移表达——文字不重排，标题跟着按钮
    /// 一起左右滑，两者同一拍。按钮组会随滚动增减时都该传。
    /// 详见 NavigationBarContent.trailingButtonMaxWidth。
    var trailingButtonMaxWidth: CGFloat? = nil
    /// 标题在左右按钮避让后的可用区域内如何对齐。
    var horizontalAlignment: HorizontalAlignment = .center
    /// 标题浮现方式，见 Mode。
    var mode: Mode = .revealOnScroll
    /// iOS 26 分支对导航栏强制的配色（决定系统返回箭头深浅）：深色沉浸页 .dark
    /// （白箭头压深色头图）；**白底页必须传 nil**（不强制、跟随环境 = 深色箭头，
    /// 传 .dark 会白箭头压白底看不见）。<26 的箭头颜色走 NavigationBarTintBridge(tint)，
    /// 与本参数无关。
    var barColorScheme: ColorScheme? = .dark
    /// `.revealOnScroll` 在 iOS 26 以下的落点：默认自绘 overlay（沉浸页——栏背景
    /// 已隐藏，overlay 不会被盖，17-25 已验证）；**白底页必须传 true 改走系统
    /// principal**——26 以下系统栏材质随滚动浮现在内容层之上，恰好在标题该出现的
    /// 时机把自绘 overlay 盖掉。`.always` 恒走 principal，不看本字段。
    var legacyUsesPrincipal: Bool = false
    /// 锚点模式的浮现阈值（滚动量口径）：页面标了 `.navigationBarRevealAnchor()` 时
    /// 由 NavigationBarModifier 换算传入；nil 走固定阈值。见 NavigationBarReveal。
    var revealAt: CGFloat? = nil
}

enum NavigationBarReveal {
    static func progress(scrollOffset: CGFloat) -> CGFloat {
        min(1, max(0, (scrollOffset - 12) / 50))
    }

    /// `revealAt` 非空 = 锚点模式：页面用 `.navigationBarRevealAnchor()` 报了页内
    /// 大标题的真实位置，栏标题等**那个标题滚过导航栏下沿**才浮现（revealAt 是换算
    /// 好的滚动量阈值），滞回 6pt 防抖。nil = 固定阈值兜底（12pt 死区 + 50pt 窗口
    /// 的进度滞回），服务没标锚点的页面。
    static func showsTitle(currentlyVisible: Bool, scrollOffset: CGFloat,
                           revealAt: CGFloat? = nil) -> Bool {
        if let revealAt {
            return scrollOffset > (currentlyVisible ? revealAt - 6 : revealAt)
        }
        let progress = progress(scrollOffset: scrollOffset)
        return currentlyVisible ? progress > 0.45 : progress > 0.65
    }
}

// MARK: - Modifier：标题 + 返回箭头 tint

extension View {
    /// 沉浸式导航栏标题 + 返回箭头 tint。scrollOffset 是页面自己算好的原始滚动量
    /// （顶部为 0，上滚为正）——内部统一做「12pt 死区 + 50pt 窗口渐显 + 滞回」的
    /// 映射（同 Telegram 列表页 min(30, offset)/30 的接线思路），页面不用自己
    /// 重复实现这套阈值逻辑。
    ///
    /// 「静止不显示、滚动过阈值才进出场」，编舞两个分支统一：进场从下方 6pt 带
    /// 模糊（blur 4→0）升到位、随淡入收敛清晰；退场原路下沉变糊淡出（Telegram
    /// 标题 materialize 式，三个属性同一事务同步跑）。阈值/滞回计算两个系统通用，
    /// 但渲染方式按版本分流：
    /// - iOS 26+：没有页面自绘右侧按钮时，`.toolbar(placement: .principal)` 塞
    ///   自定义 Text 进标题位，由系统负责布局；存在自绘按钮时，系统不知道 overlay
    ///   的真实宽度，改走 NavigationBarContent 并用 trailingButtonWidth 避让。
    ///   principal 内的 Text 必须常驻、靠 `.opacity`/`.offset` 表达显隐，不能用
    ///   `if showTitle { ... }` 控制插入/移除——真机验证过 `.transition()` 在
    ///   ToolbarItem 里会被吞掉。
    /// - iOS 26 前：继续用 NavigationBarContent 自绘 + NavigationBarContentArea 定位 +
    ///   NavigationBarTintBridge 手动 tint，这套在 17-25 已验证稳定。
    ///
    /// ⚠️⚠️ 自绘分支的挂载点有硬约束，真机踩过一次坑：必须挂在「承载滚动内容的那个
    /// view 的 `.ignoresSafeArea(.container, edges:.top)` 之后、且在 `.navigationTitle`/
    /// `.immersiveNavigationBar()` 等导航栏 modifier 之前」——不能挂在整个页面
    /// body 修饰链的最外层（导航栏 modifier 之后）！那层坐标系里导航栏是「真实
    /// 存在、占位」的控件，内部 NavigationBarContentArea 测出的 safe-area 语义
    /// 会变（多算进一层导航栏高度），标题会垂直方向跑偏一整个导航栏高度（真机
    /// 复现：iOS 26 上标题完全不居中、掉到导航栏下方）。挂载点应与 EdgeFadeBar
    /// 的 .overlay 同一层级，别把这个 modifier 简单地"加在 view 最后"。
    ///
    /// 只处理标题和 tint，不处理渐隐条背景（EdgeFadeBar）——渐隐条的高度依赖页面
    /// GeometryReader 里的 topInset，与 ScreenTopOverlay 的挂载层级强相关。
    ///
    /// 💡 整页沉浸式头图应走 `.navigationBar(.init(chrome: .immersive(...)))`，
    /// 由 `NavigationBarModifier` 统一封装挂载顺序；这层留给「只要标题一档」的
    /// 特殊场景。（Relay 目前没有沉浸头图页。）
    func navigationBarTitle(_ presentation: NavigationBarTitlePresentation,
                            scrollOffset: CGFloat = 0) -> some View {
        modifier(NavigationBarTitleModifier(presentation: presentation, scrollOffset: scrollOffset))
    }
}

private struct NavigationBarTitleModifier: ViewModifier {
    let presentation: NavigationBarTitlePresentation
    let scrollOffset: CGFloat
    /// 标题走阈值触发 + 时间曲线淡入淡出（不随滚动线性跟手），带滞回防抖。
    /// 两个系统共用同一份状态，只是消费方式不同（自绘 overlay 的 visible 参数 /
    /// 系统 .navigationTitle 的字符串是否为空）。
    @State private var showTitle = false
    /// principal 常驻 Text 实际渲染的字符串。bar item 吞转场逼着 Text 常驻、用属性
    /// 动画表达显隐，但 opacity 0 的常驻标题在 AX 树里仍摸得到——`accessibilityHidden`
    /// 穿不过 bar item 桥接（iPhone 17 模拟器 XCUI 实测），VoiceOver / UI 测试都会撞到
    /// 一份看不见的标题。隐藏稳态把字符串清空元素才真消失；清空延后到退场动画播完，
    /// 下沉变糊淡出的编舞不受影响。（screenhop 侧有 UI 测试护栏；Relay 无测试 target，改动这段要手动验。）
    @State private var residentTitle = ""

    func body(content: Content) -> some View {
        Group {
            if presentation.mode == .always {
                // 常显标题：**所有版本**统一走系统 principal bar item。静态常驻文本
                // 没有进出场转场（bar item 吞转场的限制打不到它），且必须画在**栏
                // 内容层**：iOS 26 以下系统栏材质会随滚动浮现在页面内容之上，画在
                // 内容层的自绘 overlay 标题一滚动就被材质盖掉（真机踩过：静止有
                // 标题、一滚就"消失"）。
                // 自绘 overlay 分支只服务「浮现标题 + 栏背景已隐藏」的沉浸页组合。
                // 注：常显 + 页面自绘右上角按钮组（trailingButtonWidth）的组合未支持
                // ——principal 不知道 overlay 按钮的宽度，长标题会压到按钮下面；
                // 真出现该需求时再按 reveal 分支的避让方案扩展。
                Group {
                    if #available(iOS 26.0, *) {
                        content
                    } else {
                        // 返回箭头颜色沿用命令式 bridge（17-25 已验证，见其文档注释）。
                        content.background(NavigationBarTintBridge(color: UIColor(presentation.tint)))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .relayToolbarColorScheme(presentation.barColorScheme)
                // 走具名的 `principalToolbar`：`relayToolbarColorScheme` 返回
                // `some View` 后，编译器无法从内联闭包推断该选 ToolbarContent 还是
                // View 那个 `toolbar` 重载（screenhop 直连系统 API 时没这个歧义）。
                .toolbar(content: principalToolbar)
            } else if #available(iOS 26.0, *) {
                if presentation.trailingButtonWidth != nil {
                    // 右侧按钮是页面 overlay 时，系统 .principal 不知道它的宽度，长标题
                    // 会直接压到按钮下面。此时改走自绘内容槽，按真实按钮宽度避让。
                    content
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarColorScheme(presentation.barColorScheme, for: .navigationBar)
                        .overlay(alignment: .top) {
                            NavigationBarContent(
                                visible: showTitle,
                                horizontalAlignment: presentation.horizontalAlignment,
                                leadingButtonWidth: presentation.leadingButtonWidth,
                                trailingButtonWidth: presentation.trailingButtonWidth,
                                trailingButtonMaxWidth: presentation.trailingButtonMaxWidth
                            ) {
                                title
                            }
                        }
                } else {
                    // 没有自绘右侧按钮时继续用系统 principal，由系统负责导航栏布局。
                    content
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarColorScheme(presentation.barColorScheme, for: .navigationBar)
                        // Text 必须常驻；ToolbarItem 会吞掉条件插入/移除的 transition。
                        // 隐藏稳态的 AX 语义靠 residentTitle 清空（见其注释）。
                        .toolbar(content: animatedPrincipalToolbar)
                }
            } else if presentation.legacyUsesPrincipal {
                // 26 以下的白底页浮现标题：走系统 principal + 常驻属性动画（与 26+
                // principal 分支同一套编舞）——自绘 overlay 会被随滚动浮现的系统栏
                // 材质盖掉（见 legacyUsesPrincipal 字段注释）。
                content
                    .navigationBarTitleDisplayMode(.inline)
                    // 同 26+ principal：隐藏稳态靠 residentTitle 清空
                    .toolbar(content: animatedPrincipalToolbar)
                    .background(NavigationBarTintBridge(color: UIColor(presentation.tint)))
            } else {
                content
                    .overlay(alignment: .top) {
                        NavigationBarContent(visible: showTitle,
                                             horizontalAlignment: presentation.horizontalAlignment,
                                             leadingButtonWidth: presentation.leadingButtonWidth,
                                             trailingButtonWidth: presentation.trailingButtonWidth,
                                             trailingButtonMaxWidth: presentation.trailingButtonMaxWidth) {
                            title
                        }
                    }
                    .background(NavigationBarTintBridge(color: UIColor(presentation.tint)))
            }
        }
        // 单参数 onChange：双参数那版是 iOS 17+，Relay 还要支持 15。
        .onChange(of: scrollOffset) { newValue in
            guard presentation.mode == .revealOnScroll else { return }
            // 滞回：显、隐用不同阈值，避免停在临界点时来回闪
            let show = NavigationBarReveal.showsTitle(currentlyVisible: showTitle,
                                                      scrollOffset: newValue,
                                                      revealAt: presentation.revealAt)
            if show != showTitle {
                if show { residentTitle = presentation.title }   // 进场前先备好字符串
                // withAnimation 是两个分支唯一的动画驱动（内部不再各挂 .animation）：
                // iOS 26 分支靠它插值 .principal 里 Text 的 .opacity/.offset/.blur
                // （常驻视图的属性动画，不是插入/移除过渡）；自绘分支靠它驱动
                // if visible 的插入/移除——Pow 转场吃的就是状态变更这一刻的事务，
                // 跟表单候选行 withAnimation 包插入的驱动模式相同。
                // 0.22s：0.44 真机试过偏拖沓，导航栏这种高频进出的小元素要干脆，
                // 位移/模糊幅度本来就小（6pt/4pt），短时长下依然读得出方向感。
                withAnimation(.easeInOut(duration: 0.22)) {
                    showTitle = show
                }
                if !show {
                    // 退场动画（0.22s）播完再清空；期间又滚回显示态就跳过
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !showTitle { residentTitle = "" }
                    }
                }
            }
        }
    }

    private var title: some View {
        Text(presentation.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(presentation.tint)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// 具名的 principal 内容，给 `.toolbar(content:)` 一个明确的 `ToolbarContent`
    /// 类型（见调用处注释）。
    @ToolbarContentBuilder
    private func principalToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .principal) { title }
    }

    /// 浮现标题的 principal 内容：常驻 Text + 属性动画（ToolbarItem 会吞掉
    /// 插入/移除转场，所以只能这么表达显隐）。26+ 与 26 以下两条分支共用。
    @ToolbarContentBuilder
    private func animatedPrincipalToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            principalTitle
                .opacity(showTitle ? 1 : 0)
                .offset(y: showTitle ? 0 : 6)
                .blur(radius: showTitle ? 0 : 4)
        }
    }

    /// principal 常驻位用的标题：字符串走 residentTitle（隐藏稳态为空，见其注释）。
    /// 自绘 overlay 分支不用它——那边 `if visible` 插拔，隐藏时本来就不在树里。
    private var principalTitle: some View {
        Text(residentTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(presentation.tint)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

// MARK: - tab 根页的顶部渐隐条（无标题）

extension View {
    /// tab 根页的顶部导航区处理：把系统默认的顶部边缘效果换成与场次详情页同一套
    /// 手绘渐隐条（EdgeFadeBar：1pt 可变模糊 + 页面底色洗层 + TG 感知曲线渐隐带），
    /// 让滚动内容在导航栏下方「化开」而不是被系统那条硬边/玻璃切断。
    ///
    /// 与 `.navigationBarTitle` 的分工：那个管「滚动过阈值浮现的标题」，是详情页
    /// （push 进来、有片名、有返回箭头）的场景；**tab 根页没有标题**（导航栏只承载
    /// 右上角工具栏按钮），所以这里不碰标题、不碰 tint，只换背景那一层。右上角按钮
    /// 继续走系统 ToolbarItem——iOS 26 上保留 Liquid Glass 胶囊外观与系统热区/无障碍，
    /// 我们只接管它背后的那条渐隐背景。
    ///
    /// 渐隐条常驻不随滚动显隐（同 Telegram 聊天页 topBackgroundEdgeEffectNode 那层）：
    /// tab 根页背景是页面渐变/壁纸、没有沉浸头图，「静止时保持干净」无从谈起——这条
    /// 渐隐带的职责就是让顶部一直有化开效果，不是一个随滚动出现的装饰。
    ///
    /// ⚠️ 挂载层级与 `.navigationBarTitle` 同一个硬约束（原因见那边的注释）：必须挂在
    /// 承载滚动内容的那层上、在导航栏 modifier 之前，内部 overlay 定位才能测到
    /// 正确语义的 `safeAreaInsets.top`。
    ///
    /// **全版本统一手绘常驻渐隐**（2026-07 产品定案，推翻早先「26 以下靠系统材质」的
    /// 取舍——系统材质是滚动才浮现的模糊条，与 26+ 的常驻化开观感不一致）：
    /// - iOS 26+：系统 scroll edge effect 整条关掉（Liquid Glass 版本在「降低透明度」
    ///   下会被强制换成纯色硬边且无公开 API 可覆盖），换手绘条。
    /// - iOS 26 以下：`.toolbarBackground(.hidden)` 掀掉系统栏背景材质（同沉浸页的
    ///   掀法——只隐背景不整条隐藏，右滑返回的 interactivePopGestureRecognizer 保留），
    ///   换同一条手绘常驻带。栏上元素（返回箭头 / 标题 principal / ToolbarItem）仍由
    ///   系统画在栏层、渐隐带之上，不受影响。
    ///
    /// - Parameter tint: 盖在内容上的洗层颜色，取页面自己的背景色（tab 根页即 `.gradientTop`）。
    /// - Parameter enabled: 滚动区域不是整页的模式传 false 原样直通（如日程页的
    ///   日历视图：网格自己管滚动、内容不会滚到导航栏下方，这条渐隐带没有对象可
    ///   「化开」，挂着只会把静态表头洗糊一层）。
    /// - Parameter ownsScrollEdge: 本层就是承载滚动的 ScrollView（默认）。传 false =
    ///   「渐隐条画在我这层，但真正的 ScrollView 是我的子孙」——横滑分页页面
    ///   （统计详情页的月/年分页）用：那里每页各有自己的 ScrollView，压制系统边缘
    ///   效果必须逐页挂 `.navigationBarScrollEdge()`，画渐隐条则只能在这层挂一次。
    @ViewBuilder
    func navigationBarEdgeFade(tint: Color, enabled: Bool = true,
                               ownsScrollEdge: Bool = true) -> some View {
        if enabled {
            if #available(iOS 26.0, *) {
                navigationBarScrollEdge(enabled: ownsScrollEdge)
                    .overlay(alignment: .top) { edgeFadeOverlay(tint: tint) }
            } else {
                relayHiddenToolbarBackground()
                    .overlay(alignment: .top) { edgeFadeOverlay(tint: tint) }
            }
        } else {
            self
        }
    }

    /// 压制 iOS 26 系统 scroll edge effect（顶+底），**必须直接挂在真正的 ScrollView
    /// 上**——挂到外层容器（TabView / VStack）会静默失效，症状是开了「降低透明度」
    /// 辅助功能后，页面头尾各留一条常驻实色遮盖带。
    ///
    /// 通常由 `.navigationBar(.plain())` 内部替页面挂好，页面不用管。只有**页面自己
    /// 的滚动视图不是导航栏挂载的那一层**时才需要显式挂：典型是横滑分页
    /// （`TabView(.page)` / `.scrollTargetBehavior(.paging)`）——导航栏挂在分页容器
    /// 外层（渐隐条只能有一份），每一页内部的 ScrollView 就得各自挂一次本 modifier。
    ///
    /// ⚠️ 顶底两端都要关（immersive 分支踩过的同一个坑）：只关 .top 的话，隐藏
    /// tab bar 的 push 二级页内容延伸到 Home Indicator 时，底部的系统 scroll edge
    /// effect 在「降低透明度」下露出一条实色遮挡带；tab 根页的 tab bar 是不透明背景
    /// （OpaqueTabBar），关掉底部无副作用。
    @ViewBuilder
    func navigationBarScrollEdge(enabled: Bool = true) -> some View {
        if enabled {
            scrollEdgeVisible(false, for: [.top, .bottom])
        } else {
            self
        }
    }

    private func edgeFadeOverlay(tint: Color) -> some View {
        // ⚠️ Relay 与 screenhop 的差异点：那边这个 overlay 的宿主是 ScrollView
        // （尺寸确定），这边多数页面是 ZStack —— 尺寸由子视图反推。`ScreenTopOverlay`
        // 内部是个裸 GeometryReader，会贪心占满建议尺寸，与「靠子视图定尺寸」的
        // ZStack 形成循环依赖，实测整页塌成空白。用 fadeBarHeight 把高度钉死、
        // 顶部对齐，overlay 就不再参与父容器的尺寸推导。
        ScreenTopOverlay {
            // 总高口径统一走 NavigationBarMetrics.fadeBarHeight（真实栏下沿 +
            // 延伸段，80pt 化开段在总高内部的底段收尾），几何同场次详情页。
            //
            // 洗层色取壁纸顶部主色（见 WallpaperPaletteTintedFadeBar）：渐隐条的
            // 原理是「拿页面背景色把内容洗掉」，色不对就成了盖一层异色。
            WallpaperPaletteTintedFadeBar(fallbackTint: tint)
        }
        .frame(height: NavigationBarMetrics.fadeBarHeight)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - overlay 定位

/// 从物理屏幕顶端（global y = 0）开始铺 overlay；用于渐隐背景。
/// 不能假设 overlay 获得的局部区域从屏幕顶开始，因此用 global 坐标反向抵消。
struct ScreenTopOverlay<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(maxWidth: .infinity, alignment: .top)
                .offset(y: -geo.frame(in: .global).minY)
        }
        .allowsHitTesting(false)
    }
}

/// 把标题或按钮放进系统导航栏的内容区（锚真实 UINavigationBar frame，
/// 口径与踩坑记录见 `NavigationBarMetrics.systemBand`）。
struct NavigationBarContentArea<Content: View>: View {
    var verticalAlignment: VerticalAlignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            // 内容带不是整栏 frame：iOS 26 玻璃栏比 44 高、内容仍排顶部 44pt（见 contentBand）
            let band = NavigationBarMetrics.contentBand
            let screenTopOffset = -geo.frame(in: .global).minY
            content()
                .frame(maxWidth: .infinity)
                .frame(
                    height: band.height,
                    alignment: Alignment(horizontal: .center, vertical: verticalAlignment)
                )
                .offset(y: screenTopOffset + band.top)
        }
        // ⚠️ 恒不可命中：这是展示型内容槽（吸顶日期/标题）。曾给票夹徽标开过
        // interactive 开关——26 真机上根本点不到（UIKit 导航栏在内容层之上吃掉触摸），
        // 已回退；栏上要可点的东西走 ToolbarItem（+ sharedBackgroundVisibility 去玻璃）。
        .allowsHitTesting(false)
    }
}

// MARK: - 导航栏返回箭头 tint

/// 命令式设导航栏 tintColor（返回箭头颜色），绕开 SwiftUI 环境值传递链——
/// 沉浸式头图页导航栏背景故意隐藏（露全屏头图），toolbarColorScheme 类 API 要求
/// 背景可见才生效，.tint() 对 push 页面的系统返回箭头又有已知不稳定行为，两条路
/// 都走不通。零尺寸的透明 UIViewController，挂在页面任意位置即可通过其
/// navigationController 拿到承载它的那条 UINavigationBar 直接改 tintColor。
///
/// ⚠️ 曾经还兼管标题（写 navigationItem.titleView），已删除——那条路是系统私有
/// 布局黑箱，连续踩了运行时测量值跨版本不一致、SwiftUI 侧猜测可用区域两次跑偏、
/// 显式 Auto Layout 约束因「赋值时视图还没插入树」在 iOS 26 上直接崩溃（no common
/// ancestor）、退回默认布局后 iOS 26 上标题本身就不居中（Apple 未修复的已知回归，
/// forums thread 795114/816953）且 iOS 18 上标题直接不显示——四个独立的坑，同一
/// 个病根：titleView 内部实现是私有的，我们从来没有真正的确定性。标题现在改走
/// NavigationBarContent 纯 SwiftUI 自绘。
struct NavigationBarTintBridge: UIViewControllerRepresentable {
    let color: UIColor

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.navigationController?.navigationBar.tintColor = color
    }
}

// MARK: - 导航栏自绘内容槽（任意 View 钉进导航栏内容带）

/// 导航栏自绘内容的通用槽位：任意 View（内容样式全归调用方）钉进导航栏 44pt
/// 内容带垂直居中（经 NavigationBarContentArea，锚定口径见其注释），水平按
/// `alignment` 摆放，进出场转场可换。原先是只吃字符串的居中片名组件，按产品
/// 要求泛型化成内容槽——字体/颜色不做参数，调用方直接在 content 里写。
///
/// 布局参数只有三组：**水平对齐**（leading/center/trailing，在左右按钮避让后的
/// 区间内摆放）、**垂直对齐**（top/center/bottom，导航栏 44pt 内容带内，直通
/// NavigationBarContentArea 的带内定位）、**左右按钮宽度**（避让输入：有按钮传按钮组宽，
/// nil = 无按钮走默认安全边距 16；有按钮时再加导航栏边缘 16pt 和按钮间距 12pt。
/// 居中时保留 TG `NavigationBarImpl.swift:1065-1071` 的单侧镜像兜底——只有一侧
/// 有按钮时另一侧 inset 镜像过去，避免内容偏向无按钮的那侧。原先按文本测量宽度
/// 的两级居中策略随字符串参数一起退役：对称避让下容器居中与整屏居中等价，真出现
/// 不对称长标题需求再回 git 史找）。
///
/// 进出场：`if visible` 插入/移除 + `transition`（默认 Pow 三件套：模糊显形 +
/// 淡入淡出 + 6pt 位移，自动镜像）。动画事务来自调用方状态变更处的
/// withAnimation，这里不自带 .animation——两个来源会打架。
/// ⚠️ 仅限自绘 overlay 落点使用；ToolbarItem 桥接内容里插入/移除转场会被吞
/// （见 .principal 分支注释），bar item 场景请用常驻属性编舞。
/// 标题避让的纯几何算法。抽出来是为了能单测——布局对不对眼睛看不准，
/// 但这几个数字算错就是标题跟按钮脱节。
enum NavigationBarGeometry {
    /// 按钮尚未展开到最宽态时，标题整体右移的补偿量。
    ///
    /// 布局按最宽态预留（文字排版才不会随按钮增减重排），按钮收起时右侧那块
    /// 预留是空的、标题看起来偏左；把差额加回去，标题就回到「按当前按钮宽度
    /// 居中」的位置。于是按钮向左长出来 → 标题跟着向左；按钮收起 → 标题向右
    /// 归位，两者同一个动画事务，节奏一致。
    ///
    /// 居中时补偿减半：容器两侧 inset 对称，视觉中心只移动差额的一半；
    /// 靠左对齐时标题贴着左 inset，右侧空出多少就要补多少，取全额。
    static func titleOffsetX(current: CGFloat?, layout: CGFloat?, centered: Bool) -> CGFloat {
        guard let current, let layout else { return 0 }
        let slack = layout - current
        guard slack > 0 else { return 0 }
        return centered ? slack / 2 : slack
    }
}

struct NavigationBarContent<Content: View>: View {
    let visible: Bool
    var horizontalAlignment: HorizontalAlignment = .center
    var verticalAlignment: VerticalAlignment = .center
    /// 左侧按钮组宽度（如返回箭头 44），nil = 无按钮（默认安全边距）。
    var leadingButtonWidth: CGFloat? = 44
    /// 右侧按钮组宽度，nil = 无按钮。
    var trailingButtonWidth: CGFloat? = nil
    /// 右侧按钮组的**最宽态**宽度（展开后）。传了它，标题的布局宽度就按最宽态
    /// 恒定预留，`trailingButtonWidth` 的变化改用 offset 平移表达。
    ///
    /// ⚠️ 为什么要分开：padding 直接跟着按钮宽度变，会触发**重新布局**——文字
    /// 换行位置/截断点当场重算，那是不可插值的离散变化，看起来就是「宽度一变
    /// 文字瞬切」，和右侧按钮的滑动完全脱节。按最宽态定死布局、只动 offset，
    /// 文字排版全程不变，标题就能跟着按钮一起平移。
    /// nil = 老行为（padding 直接跟随，适合不带动画的静态场景）。
    var trailingButtonMaxWidth: CGFloat? = nil
    /// 进出场转场；默认 Pow 三件套。不要动画的场景传 .identity。
    /// screenhop 用 Pow 的 `.movingParts.blur`；Relay 没有这个依赖，
    /// 退回原生 opacity + 位移（模糊那一档是装饰，缺了不破相）。
    var transition: AnyTransition = .opacity.combined(with: .offset(y: 6))
    @ViewBuilder let content: () -> Content

    private static var safeMargin: CGFloat { 16 }
    private static var buttonSpacing: CGFloat { 12 }

    /// 布局用的右侧按钮宽度：给了最宽态就恒用它（布局稳定，差额走 offset），
    /// 否则退回老行为（padding 直接跟随当前宽度）。
    private var layoutTrailingWidth: CGFloat? {
        guard let trailingButtonWidth else { return nil }
        return trailingButtonMaxWidth.map { max($0, trailingButtonWidth) } ?? trailingButtonWidth
    }

    /// 左右避让：边缘 16pt + 按钮宽 + 12pt 间距；无按钮只走安全边距。
    /// 右侧用 layoutTrailingWidth（最宽态）而非当前宽度——见 trailingButtonMaxWidth。
    private var insets: (leading: CGFloat, trailing: CGFloat) {
        var leading = leadingButtonWidth.map {
            Self.safeMargin + $0 + Self.buttonSpacing
        } ?? Self.safeMargin
        var trailing = layoutTrailingWidth.map {
            Self.safeMargin + $0 + Self.buttonSpacing
        } ?? Self.safeMargin
        if horizontalAlignment == .center,
           (leadingButtonWidth != nil) != (layoutTrailingWidth != nil) {
            if leadingButtonWidth != nil { trailing = leading } else { leading = trailing }
        }
        return (leading, trailing)
    }

    /// 按钮尚未展开到最宽态时，标题整体右移的补偿量。
    private var titleOffsetX: CGFloat {
        NavigationBarGeometry.titleOffsetX(current: trailingButtonWidth,
                                           layout: layoutTrailingWidth,
                                           centered: horizontalAlignment == .center)
    }

    var body: some View {
        NavigationBarContentArea(verticalAlignment: verticalAlignment) {
            if visible {
                content()
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                    .frame(maxWidth: .infinity,
                           alignment: Alignment(horizontal: horizontalAlignment, vertical: .center))
                    // 跟着右侧按钮平移（布局宽度恒定，只动位置）——见 titleOffsetX。
                    // 动画事务由调用方的 withAnimation 提供，和按钮同一拍。
                    .offset(x: titleOffsetX)
                    .transition(transition)
            }
        }
    }
}

// MARK: - iOS 15 兼容 shim
//
// screenhop 的部署目标是 iOS 17，这两个 toolbar API（16+）在那边可以直接调用。
// Relay 还要支持 iOS 15，所以包一层可用性判断：15 上退回系统默认栏外观
// （渐隐条本身照画，只是系统栏背景材质掀不掉）。

extension View {
    @ViewBuilder
    func relayToolbarColorScheme(_ scheme: ColorScheme?) -> some View {
        if #available(iOS 16.0, *) {
            toolbarColorScheme(scheme, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func relayHiddenToolbarBackground() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }
}

// MARK: - 壁纸取色的渐隐条

/// `EdgeFadeBar` 的洗层色跟随壁纸顶部主色；没有壁纸色板时用页面传进来的
/// `fallbackTint`（即页面自己的背景色，与 screenhop 原行为一致）。
///
/// 渐隐条的原理是「用页面背景色把滚上来的内容洗掉」，所以这个色必须跟它盖住的
/// 那块区域同色系 —— 壁纸模式下写死 `.gradientTop` 就成了盖一层异色。
private struct WallpaperPaletteTintedFadeBar: View {
    @ObservedObject private var palette = WallpaperPalette.shared
    let fallbackTint: Color

    var body: some View {
        EdgeFadeBar(
            tint: palette.colors?.top ?? fallbackTint,
            height: NavigationBarMetrics.fadeBarHeight
        )
    }
}
