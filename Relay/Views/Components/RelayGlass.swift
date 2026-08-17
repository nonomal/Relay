//
//  RelayGlass.swift
//  Relay
//
//  Glass surface for iOS < 26.
//
//  Derived from Telegram-iOS (GPL-2.0):
//    submodules/TelegramUI/Components/GlassBackgroundComponent/Sources/LegacyGlassView.swift
//    submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIKitUtils.m  (CAFilter factory)
//    submodules/Display/Source/UIKitUtils.swift                          (CALayer.blur/colorMatrix)
//
//  Relay is GPL-2.0 as a result — see README.
//
//  ── How this works ────────────────────────────────────────────────────────────
//  `.ultraThinMaterial` renders a flat frosted pane. Telegram's glass instead draws
//  into a private `CABackdropLayer` — the same layer type UIKit's own blur views use —
//  and stacks two private `CAFilter`s on it:
//
//    1. `gaussianBlur` with a small `inputRadius` (2.0). Small because the backdrop
//       layer is already sampling live content; a large radius would wash it out.
//    2. `colorMatrix` with `inputBackdropAware = true` and a hand-tuned 4×5 matrix.
//       This is what makes the glass *coloured*: it over-saturates and lifts whatever
//       shows through, rather than greying it down the way a plain material does.
//
//  All three symbols (`CABackdropLayer`, `CAFilter`, `CAColorMatrix`) are private, so
//  they are reached by assembling class names at runtime and calling through
//  `NSClassFromString` / raw IMPs — exactly as Telegram does.
//
//  NOTE: this is private API. It is fine here because Relay is not distributed through
//  the App Store; do not ship this in a Store build.
//

import SwiftUI
import UIKit

// MARK: - Private CoreAnimation access

/// `CABackdropLayer` — the layer type that samples live content behind itself.
private let backdropLayerClass: NSObject.Type? = {
    // Assembled at runtime rather than written literally, matching Telegram.
    let name = ["CA", "Backdrop", "Layer"].joined()
    return NSClassFromString(name) as? NSObject.Type
}()

private func makeBackdropLayer() -> CALayer? {
    guard let cls = backdropLayerClass else { return nil }
    return cls.init() as? CALayer
}

/// `+[CAFilter filterWithName:]` — private filter factory.
private func makeCAFilter(_ name: String) -> NSObject? {
    guard let cls = NSClassFromString(["CA", "Filter"].joined()) as? NSObject.Type else { return nil }
    let selector = NSSelectorFromString("filterWithName:")
    guard cls.responds(to: selector) else { return nil }
    guard let imp = cls.method(for: selector) else { return nil }
    typealias FilterWithName = @convention(c) (AnyObject, Selector, NSString) -> NSObject?
    let fn = unsafeBitCast(imp, to: FilterWithName.self)
    return fn(cls, selector, name as NSString)
}

/// Suppresses implicit animations on the backdrop layer — without this the filters
/// re-animate on every layout pass and the pane visibly pulses.
private final class NullActionDelegate: NSObject, CALayerDelegate {
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

// MARK: - Backdrop view

/// Hosts a `CABackdropLayer` carrying Telegram's blur + colour-matrix filter stack.
private final class RelayBackdropView: UIView {
    private let backdropLayer: CALayer?
    private let nullDelegate = NullActionDelegate()

    init() {
        self.backdropLayer = makeBackdropLayer()
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.cornerCurve = .continuous

        guard let backdropLayer else { return }
        backdropLayer.delegate = nullDelegate
        // Telegram sets `scale` to 1.0 so the backdrop samples at native resolution.
        backdropLayer.setValue(1.0, forKey: "scale")
        backdropLayer.rasterizationScale = 1.0
        layer.addSublayer(backdropLayer)

        applyFilters()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyFilters() {
        guard let backdropLayer,
              let blur = makeCAFilter("gaussianBlur"),
              let colorMatrix = makeCAFilter("colorMatrix")
        else { return }

        blur.setValue(2.0 as NSNumber, forKey: "inputRadius")

        // Telegram's tuned matrix (LegacyGlassView.swift). Rows are R/G/B/A; the
        // trailing column is the additive bias. The large off-diagonal terms are what
        // over-saturate the sampled backdrop.
        var matrix: [Float32] = [
             2.6705,     -1.1087999, -0.1117,     0.0, 0.049999997,
            -0.3295,      1.8914,    -0.111899994, 0.0, 0.049999997,
            -0.3297,     -1.1084,     2.8881,      0.0, 0.049999997,
             0.0,         0.0,        0.0,         1.0, 0.0,
        ]
        colorMatrix.setValue(
            NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}"),
            forKey: "inputColorMatrix"
        )
        // Makes the matrix operate on what is *behind* the layer.
        colorMatrix.setValue(true as NSNumber, forKey: "inputBackdropAware")

        backdropLayer.filters = [colorMatrix, blur]
    }

    private var appliedMeshSize: CGSize = .zero
    private var appliedMeshRadius: CGFloat = -1

    func update(cornerRadius: CGFloat) {
        layer.cornerRadius = cornerRadius
        self.cornerRadius = cornerRadius
        syncBackdrop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncBackdrop()
    }

    private var cornerRadius: CGFloat = 28

    private func syncBackdrop() {
        guard let backdropLayer else { return }
        // Frame changes must not animate, or the backdrop lags behind its container.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        CATransaction.commit()

        applyMeshTransform(to: backdropLayer)
    }

    /// Warps the backdrop near the edges to fake optical refraction.
    ///
    /// Parameters are Telegram's (LegacyGlassView.swift): 20pt displacement, corner
    /// resolution 12, edge distance `min(12, cornerRadius)`, outer edge distance 2,
    /// and a hand-tuned displacement bezier. Rebuilt only when the geometry changes —
    /// mesh generation is not cheap enough to run on every layout pass.
    private func applyMeshTransform(to backdropLayer: CALayer) {
        let size = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        guard size.width > 1, size.height > 1 else { return }
        guard size != appliedMeshSize || cornerRadius != appliedMeshRadius else { return }
        appliedMeshSize = size
        appliedMeshRadius = cornerRadius

        let radius = min(min(size.width, size.height) * 0.5, cornerRadius)
        let displacementMagnitudePoints: CGFloat = 20.0

        let meshTransform = generateGlassMesh(
            size: size,
            cornerRadius: radius,
            edgeDistance: min(12.0, radius),
            displacementMagnitudeU: displacementMagnitudePoints / size.width,
            displacementMagnitudeV: displacementMagnitudePoints / size.height,
            cornerResolution: 12,
            outerEdgeDistance: 2.0,
            bezier: DisplacementBezier(
                x1: 0.816137566137566,
                y1: 0.20502645502645533,
                x2: 0.5806878306878306,
                y2: 0.873015873015873
            )
        ).mesh.makeValue()

        guard let meshTransform else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.setValue(meshTransform, forKey: "meshTransform")
        CATransaction.commit()
    }

    /// False when the private classes are unavailable, so callers can fall back.
    var isSupported: Bool { backdropLayer != nil }
}

// MARK: - SwiftUI bridge

private struct RelayBackdrop: UIViewRepresentable {
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> RelayBackdropView {
        RelayBackdropView()
    }

    func updateUIView(_ uiView: RelayBackdropView, context: Context) {
        uiView.update(cornerRadius: cornerRadius)
    }
}

/// Whether the private backdrop stack is usable on this OS build. Checked once.
private let backdropIsAvailable: Bool = {
    backdropLayerClass != nil && makeCAFilter("colorMatrix") != nil
}()

// MARK: - Glass pane

/// Glass surface used by the floating tab bar on iOS < 26.
struct RelayGlassBackground: View {
    var cornerRadius: CGFloat = 28

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// Telegram's `rootTabBar.backgroundColor` hue (#F2F2F2 light / #1D1D1D dark),
    /// but at a much lower alpha than Telegram's 0.9.
    ///
    /// Telegram can afford 0.9 because their tint sits beneath a `CABackdropLayer` that
    /// samples the *window*, so live content still comes through. Here the tint and the
    /// backdrop are siblings in one SwiftUI stack, so a near-opaque fill simply hides
    /// the glass — it has to stay light enough to see through.
    private var tabBarTint: Color {
        colorScheme == .dark
            ? Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1D / 255).opacity(0.22)
            : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255).opacity(0.18)
    }

    var body: some View {
        ZStack {
            // Telegram tints its bar *behind* the blur (`NavigationBackgroundNode` sits
            // under the effect layer), so the tint goes first and the backdrop samples
            // through it. Painting it on top — as an earlier version did at 90% opacity
            // — covered the glass almost entirely, which is why scrolling content
            // showed no refraction at all.
            shape.fill(tabBarTint)

            if backdropIsAvailable {
                RelayBackdrop(cornerRadius: cornerRadius)
            } else {
                // Fallback if a future OS drops the private classes.
                shape.fill(.ultraThinMaterial)
            }

            // Directional rim: bright along the top, dark along the bottom, as if lit
            // from above. Telegram gets this from an edge mesh warp; a gradient stroke
            // reads the same at tab-bar scale.
            shape.strokeBorder(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.35), Color.white.opacity(0.06), Color.black.opacity(0.20)]
                        : [Color.white.opacity(0.90), Color.white.opacity(0.30), Color.black.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.13), radius: 16, y: 5)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 3, y: 1)
    }
}
