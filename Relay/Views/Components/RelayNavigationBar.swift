//
//  RelayNavigationBar.swift
//  Relay
//
//  Ported from screenhop's design system (same author).
//
//  导航栏唯一页面入口：声明一份 NavigationBarPresentation，挂 `.navigationBar(…)`。
//  对应 Telegram-iOS 的 NavigationBarPresentationData + ViewController.navigationBar 分工
//  （TG 全场景共用一个 NavigationBar 类，深浅语境是 theme.overallDarkAppearance 一个字段，
//  不按场景分裂组件）——这里同理：沉浸头图页 / tab 根页 / 白底详情页全走本入口，
//  差异全部收进 chrome × title 两个正交配置维度，不再有场景化命名的旁支 API。
//
//  NavigationBarModifier 持有具体栏实现（渐隐条 / 标题层 / 按钮 / 挂载顺序硬约束），
//  与页面滚动内容并列；页面保留自己的 ScrollView。
//

import SwiftUI
import UIKit

/// 导航栏垂直几何的**唯一口径来源**——栏高、内容带锚点、渐隐条延伸量全在这里，
/// 页面与组件一律从此取数，不许各自写死。
enum NavigationBarMetrics {
    /// 栏内容高（状态栏之下的部分）。iOS 26（Liquid Glass）的系统栏比经典 44pt
    /// 高一截——TG 的 Glass 适配把自家栏高从 44 调成 60（中间版本写作
    /// `44.0 + 12.0`，定稿 `60.0`），我们这套自绘渐隐条 + 自管让位实质也是
    /// 自建导航栏，跟 TG 定稿口径走；26 以下保持 HIG 经典 44。
    /// ⚠️ 这是**拿不到真实系统栏时的推算值**（如统计页容器 ignoresSafeArea 后
    /// 的让位）；能锚真实栏的场景用 `systemBand`。
    static var barHeight: CGFloat {
        if #available(iOS 26.0, *) { return 60 } else { return 44 }
    }

    /// 渐隐条底边压过导航栏下沿的额外延伸段（TG 聊天页 `topExtent = 34`；
    /// TG 在 Glass 改栏高 44→60 时没动这个值，延伸段与栏高是独立的两个量）。
    private static let fadeOverhang: CGFloat = 34

    /// 渐隐条整条总高 = **真实栏下沿** + 延伸段，最小 100。TG 同款结构
    /// （ChatControllerNode：`max(100, listInsets.bottom + topExtent)`，基数是
    /// 它自建栏 frame 的 maxY）——基数走 systemBand 而不是挂载层安全区：
    /// iOS 18 两者相等，iOS 26 安全区含呼吸空间会漂，栏 frame 才与标题/按钮
    /// 同锚。两条装配线（immersive / plain 的 EdgeFadeBar）都从这里拿。
    static var fadeBarHeight: CGFloat {
        let band = systemBand
        return max(100, band.top + band.height + fadeOverhang)
    }

    /// 栏内容带（窗口坐标系顶边 + 高度）：锚**真实 UINavigationBar 的 frame**。
    /// ⚠️ 别的口径全踩过坑，各差几 pt（iPhone 16 Pro UI 测试实测，系统返回钮
    /// midY = 78.3）：
    /// - 窗口 safeAreaInsets.top（62）：灵动岛机型含岛下留白，比栏上沿大，
    ///   内容带整体偏低 ~6pt（标题 midY 84.0）；
    /// - statusBarManager 状态栏 frame 下沿（54）：系统栏实际上沿 56.33，
    ///   又偏高 2.33pt（标题 midY 76.0）；
    /// - 当前视图 safe-area 底边倒推：iOS 26 多一段呼吸空间，偏低。
    /// 系统返回钮就画在 UINavigationBar 里，锚它的 frame 才是同一坐标系的
    /// 对齐，任何版本（含 iOS 26 加高的栏）自动跟系统走。找不到系统栏时回退
    /// 「状态栏 frame 下沿 + 44」。护栏：NavBarTitleAlignmentUITests。
    static var systemBand: (top: CGFloat, height: CGFloat) {
        if let bar = locateSystemBar(), let window = bar.window {
            let frame = window.convert(bar.bounds, from: bar)
            if frame.height > 0 { return (frame.minY, frame.height) }
        }
        let status = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame.height }
            .max() ?? 59
        return (status, 44)
    }

    /// 栏**内容带**（窗口坐标系顶边 + 高度）——自绘标题/按钮的垂直对齐用这条，
    /// 不是整个 systemBand：系统把返回钮排在栏 frame **顶部的经典 44pt** 里，
    /// iOS 26 Liquid Glass 的栏 frame 更高（iPhone 17 模拟器实测 54，多出的下沿
    /// 是呼吸空间、不放内容），照整栏居中会比系统返回钮低 ~5pt
    /// （实测标题 midY 89 vs 返回钮 84 = 栏顶 62 + 22）。26 以下栏高本就 44，
    /// 两个口径等价。渐隐条基线（fadeBarHeight）与 reveal 阈值仍锚整栏下沿——
    /// 那两个要的是玻璃栏的**视觉下缘**，不是内容线。
    static var contentBand: (top: CGFloat, height: CGFloat) {
        let band = systemBand
        return (band.top, min(band.height, 44))
    }

    /// 弱引用缓存系统栏实例：systemBand 在滚动期间每帧都被读，不能每帧遍历
    /// 视图树；栏离开窗口（weak 置 nil 或 window 为 nil）时自动重找。
    private static weak var cachedBar: UINavigationBar?

    private static func locateSystemBar() -> UINavigationBar? {
        if let bar = cachedBar, bar.window != nil { return bar }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !window.isHidden {
                if let bar = firstNavBar(in: window) {
                    cachedBar = bar
                    return bar
                }
            }
        }
        return nil
    }

    private static func firstNavBar(in view: UIView) -> UINavigationBar? {
        if let bar = view as? UINavigationBar { return bar }
        for subview in view.subviews {
            if let bar = firstNavBar(in: subview) { return bar }
        }
        return nil
    }
}

/// 背景语境：决定渐隐条行为、系统栏 chrome 处理与标题/箭头配色。页面选语境，不逐项拼。
enum NavigationBarChrome {
    /// 深色沉浸头图 push 页（场次详情）：隐藏系统栏背景 + 隐藏 tab bar + 内容顶到
    /// 物理屏幕顶，渐隐条随滚动浮现（静止时整页干净露头图），标题/按钮白色。
    /// 关联值 = 头图主题色（渐隐条 tint + 页面背景）。
    case immersive(Color)
    /// 白底页（tab 根页 / 普通 push 详情页）：保留系统栏行为与 tab bar，
    /// 渐隐条**常驻**（全版本统一手绘：26+ 关系统 scroll edge effect、26 以下掀系统栏
    /// 材质，见 navigationBarEdgeFade 注释——沉浸页那条是滚动才浮现，这条是常驻），
    /// 标题/箭头 Theme.fg。
    /// `fade: false` 关掉渐隐带——滚动区域不是整页的模式（如日程页日历视图，
    /// 网格自己管滚动、内容不会滚到栏下，渐隐带没有对象可化开）。
    ///
    /// `ownsScrollEdge: false` = 「这层不是真正的 ScrollView，我的子孙才是」：
    /// 横滑分页页面（统计详情页）挂在分页容器上——渐隐条仍只画一份在这层，但
    /// 系统 scroll edge effect 的压制交给页面**逐页**挂 `.navigationBarScrollEdge()`
    /// （那个 modifier 挂在非 ScrollView 上会静默失效，见其注释）。
    case plain(background: Color = .gradientTop, fade: Bool = true, ownsScrollEdge: Bool = true)
}

/// 标题槽。自定义标题内容（如议程吸顶日期，TG 的 titleView 语义）不在此枚举——
/// 显隐驱动/动画事务归页面业务，页面自己 overlay `NavigationBarContent`（挂在
/// `.navigationBar` 之后，内容压渐隐条上层）。
enum NavigationBarTitleSlot {
    /// 空标题：tab 根页（栏上只有工具按钮），或 principal 位被页面自己的系统控件
    /// 占用（统计详情页的周期分段 Picker）。
    case none
    /// 常显标题（设置页）：走系统 principal bar item，任何版本都压在渐隐/材质之上。
    case fixed(String)
    /// 滚动过阈值浮现（场次详情页片名）：滚动源组件内部接好，页面不用接线。
    /// ⚠️ iOS 17 兜底路径需要页面在滚动内容上挂 `.navigationBarScrollSource()`。
    case reveal(String)

    var text: String? {
        switch self {
        case .none: nil
        case .fixed(let t), .reveal(let t): t
        }
    }
}

struct NavigationBarPresentation<Trailing: View> {
    let chrome: NavigationBarChrome
    let title: NavigationBarTitleSlot
    var titleAlignment: HorizontalAlignment = .center
    let trailingWidth: CGFloat?
    let trailingMaxWidth: CGFloat?
    /// 自绘右上角按钮组（沉浸页专用：深色玻璃 + 自定义过渡）。白底页的右上角按钮
    /// 走页面自己的系统 ToolbarItem（保留 Liquid Glass 胶囊/热区/无障碍），本字段忽略。
    let trailingContent: (() -> Trailing)?
    var onScroll: ((CGFloat) -> Void)?

    fileprivate init(
        chrome: NavigationBarChrome,
        title: NavigationBarTitleSlot,
        titleAlignment: HorizontalAlignment,
        trailingWidth: CGFloat?,
        trailingMaxWidth: CGFloat?,
        trailingContent: (() -> Trailing)?,
        onScroll: ((CGFloat) -> Void)?
    ) {
        self.chrome = chrome
        self.title = title
        self.titleAlignment = titleAlignment
        self.trailingWidth = trailingWidth
        self.trailingMaxWidth = trailingMaxWidth
        self.trailingContent = trailingContent
        self.onScroll = onScroll
    }
}

extension NavigationBarPresentation where Trailing == EmptyView {
    init(
        chrome: NavigationBarChrome,
        title: NavigationBarTitleSlot,
        titleAlignment: HorizontalAlignment = .center,
        onScroll: ((CGFloat) -> Void)? = nil
    ) {
        self.init(
            chrome: chrome,
            title: title,
            titleAlignment: titleAlignment,
            trailingWidth: nil,
            trailingMaxWidth: nil,
            trailingContent: nil,
            onScroll: onScroll
        )
    }
}

extension NavigationBarPresentation {
    init(
        chrome: NavigationBarChrome,
        title: NavigationBarTitleSlot,
        trailingWidth: CGFloat,
        trailingMaxWidth: CGFloat,
        titleAlignment: HorizontalAlignment = .center,
        onScroll: ((CGFloat) -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            chrome: chrome,
            title: title,
            titleAlignment: titleAlignment,
            trailingWidth: trailingWidth,
            trailingMaxWidth: trailingMaxWidth,
            trailingContent: trailing,
            onScroll: onScroll
        )
    }
}

extension View {
    /// 挂在承载滚动的 ScrollView 上；挂载顺序和系统版本分支由组件内部保证。
    func navigationBar<Trailing: View>(
        _ presentation: NavigationBarPresentation<Trailing>
    ) -> some View {
        modifier(NavigationBarModifier(presentation: presentation))
    }
}
