//
//  EdgeFadeBar.swift
//  Relay
//
//  Ported from screenhop's design system (same author).
//
//  顶部导航栏「边缘渐隐」背景条——Telegram 聊天页顶部效果
//  （ChatControllerNode.topBackgroundEdgeEffectNode / WallpaperEdgeEffectNodeImpl）
//  的 SwiftUI 移植，两层结构与参数照搬：
//  ① 可变模糊层：私有 CAFilter("variableBlur")，最大半径仅 1.0pt——TG 的「化开」
//     几乎不靠糊，字的形体一直在；mask 顶部满强度、底部 fadeHeight 段沿曲线衰减。
//  ② 背景色层（真正的主角）：页面背景色盖在内容上，用 TG 手调的 90 段感知曲线
//     （前密后疏，非 2-stop 线性）渐隐 mask，整层再乘 0.8——字被「同色背景洗掉」
//     而不是「糊掉」，这才是隐约可见的来源（TG 图片壁纸 0.7 / 纯色壁纸 0.85）。
//  私有 filter 拿不到（系统内部结构变化）时回落为只有②的纯渐隐——模糊本来只有
//  1pt，砍掉也不破相。
//

import SwiftUI
import UIKit

struct EdgeFadeBar: View {
    /// 盖在内容上的背景色层（详情页用海报取色主题色），对应 TG 的壁纸克隆层。
    let tint: Color
    /// 整条总高。TG 聊天页取「导航栏侧 inset + 34，最小 100」，底边落在导航栏下沿
    /// 再往下 34pt，化开段在总高内部的底段。
    let height: CGFloat
    /// 化开段高度，TG 聊天页 edge.size = 80。
    var fadeHeight: CGFloat = 80
    /// 整条显隐（0...1）。默认常驻——TG 聊天页这层不随滚动显隐。
    var progress: CGFloat = 1

    var body: some View {
        ZStack {
            // 模糊层不套 alpha mask——它的化开由 filter 自己的半径 mask 完成，
            // 外面再罩 alpha 会变成「半透明的糊拷贝叠在原文上」的奶雾感。
            VariableBlurBackdrop(maxBlurRadius: 1, totalHeight: height, fadeHeight: fadeHeight)
            tint
                .opacity(0.8)
                .mask(alignment: .top) {
                    LinearGradient(stops: Self.maskStops(solidFraction: max(0, (height - fadeHeight) / max(height, 1))),
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .opacity(progress)
        .allowsHitTesting(false)
    }

    /// [0, solidFraction] 全强度，其后把渐隐曲线压缩进剩余区间。
    private static func maskStops(solidFraction: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0)]
        for (alpha, location) in zip(curveAlphaNum, curveLocationNum) {
            stops.append(.init(color: .black.opacity(alpha / 216),
                               location: solidFraction + (location / 287) * (1 - solidFraction)))
        }
        return stops
    }

    /// variableBlur 的强度 mask 位图（1px 宽竖条，同 TG legacy 路径的 inputMaskImage
    /// 合成方式）：顶部满强度段填纯黑（alpha 1 = 最大半径），底部 fadeHeight 段画
    /// 感知曲线渐变衰减到 0。
    fileprivate static func blurMaskImage(totalHeight: CGFloat, fadeHeight: CGFloat) -> UIImage {
        let height = max(totalHeight, 1)
        let fade = min(fadeHeight, height)
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: height)).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(white: 0, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 1, height: height - fade))
            let colors = curveAlphaNum.map { UIColor(white: 0, alpha: $0 / 216).cgColor } as CFArray
            let locations = curveLocationNum.map { $0 / 287 }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: locations) {
                cg.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: height - fade),
                                      end: CGPoint(x: 0, y: height),
                                      options: [])
            }
        }
    }

    // Telegram EdgeEffect.swift `generateEdgeGradientData` 的手调曲线原始数据，
    // 化成整数分子存储：alpha = n/216（首项即最大值，天然归一），位置 = n/287。
    // 前密后疏的分布是它比朴素线性渐变柔和的关键，别用等差数据「简化」它。
    fileprivate static let curveAlphaNum: [CGFloat] = [
        216, 215, 214, 213, 212, 211, 210, 209, 208, 207,
        206, 205, 204, 203, 202, 201, 200, 199, 198, 197,
        196, 195, 194, 193, 192, 191, 190, 189, 188, 187,
        186, 185, 184, 183, 182, 181, 179, 177, 175, 173,
        171, 168, 166, 164, 161, 159, 157, 154, 152, 150,
        147, 144, 141, 138, 135, 132, 129, 126, 124, 121,
        118, 116, 113, 110, 107, 105, 102, 99, 96, 93,
        90, 87, 84, 81, 78, 75, 72, 69, 66, 62,
        59, 55, 51, 46, 41, 36, 30, 23, 12, 0,
    ]
    fileprivate static let curveLocationNum: [CGFloat] = [
        0, 6, 17, 25, 31, 35, 38, 41, 44, 46,
        49, 52, 55, 58, 60, 61, 63, 65, 67, 68,
        70, 71, 73, 74, 75, 77, 78, 79, 81, 82,
        83, 84, 85, 86, 87, 88, 90, 92, 94, 96,
        98, 100, 102, 104, 106, 108, 109, 111, 113, 114,
        116, 118, 120, 122, 124, 126, 128, 130, 131, 133,
        135, 136, 138, 140, 142, 143, 145, 147, 149, 151,
        153, 155, 157, 159, 161, 163, 165, 167, 169, 172,
        174, 177, 180, 184, 189, 194, 200, 209, 227, 287,
    ]
}

/// 真·可变模糊（模糊半径沿 mask 渐变）：拿 UIVisualEffectView 的 backdrop 子层，
/// 把它的 filters 换成单个私有 CAFilter("variableBlur")——TG legacy 路径
/// （EdgeEffect.swift updateLegacyEffect）的同款配置：inputRadius / inputMaskImage /
/// inputNormalizeEdges。CAFilter 通过 NSClassFromString 反射获取，不链接私有符号；
/// 任一环节拿不到就撤掉整个 effect，回落为纯渐隐（无模糊）。
private struct VariableBlurBackdrop: UIViewRepresentable {
    let maxBlurRadius: CGFloat
    let totalHeight: CGFloat
    let fadeHeight: CGFloat

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        guard let maskImage = EdgeFadeBar.blurMaskImage(totalHeight: totalHeight, fadeHeight: fadeHeight).cgImage,
              let filter = Self.makeVariableBlurFilter(radius: maxBlurRadius, maskImage: maskImage),
              let backdrop = view.subviews.first,
              String(describing: type(of: backdrop)).contains("Backdrop")
        else {
            view.effect = nil
            return view
        }
        backdrop.layer.filters = [filter]
        // backdrop 默认低分辨率抓屏（正常的大半径高斯会盖住低清），换成 1pt 的
        // variableBlur 后低清采样直接透出来成花斑；提到全分辨率采样。
        // （TG 在自建 backdrop 上也显式设这个 key，它取 0.5 是性能取舍。）
        backdrop.layer.setValue(1.0, forKey: "scale")
        for subview in view.subviews where subview.description.contains("VisualEffectSubview") {
            subview.isHidden = true
        }
        return view
    }

    // 本页总高由安全区决定、页内恒定（iPhone 竖屏 app），不需要动态重建 mask。
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}

    private static func makeVariableBlurFilter(radius: CGFloat, maskImage: CGImage) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("filterWithName:")
        guard filterClass.responds(to: selector),
              let filter = filterClass.perform(selector, with: "variableBlur" as NSString)?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(maskImage, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }
}
