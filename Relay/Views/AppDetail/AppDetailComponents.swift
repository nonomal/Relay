//
//  AppDetailComponents.swift
//  NEBox
//
//  Card-based building blocks for the redesigned AppDetailView.
//

import SwiftUI
import AnyCodable

// MARK: - Layout Metrics

enum DetailMetrics {
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let rowHPadding: CGFloat = 14
    static let rowVPadding: CGFloat = 12
    static let groupSpacing: CGFloat = 16
}

// MARK: - Group Header

/// Uppercase section label with an optional trailing action.
struct DetailGroupHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundColor(.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DetailMetrics.rowHPadding)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }
}

// MARK: - Card Container

/// Rounded card that hairlines its children apart.
struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: DetailMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DetailMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.borderSubtle, lineWidth: 1)
        )
        // Lifts the card off the wallpaper; without it a light card on a light
        // photo has no edge at all.
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
    }
}

/// Hairline used between rows inside a `DetailCard`.
struct DetailRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.borderSubtle)
            .frame(height: 1)
    }
}

/// Group header + card, the repeating unit of the detail page.
///
/// The header lives *inside* the card. Floating it above meant the label sat directly
/// on the wallpaper, where a single tint can never win: a busy image puts both light
/// and dark pixels behind the same line of text. The card's opaque ground fixes the
/// contrast regardless of what is behind it.
struct DetailGroup<Content: View>: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        DetailCard {
            DetailGroupHeader(title: title, actionTitle: actionTitle, action: action)
            DetailRowDivider()
            content
        }
    }
}

// MARK: - Setting Row Shell

/// Standard setting row: a control line with the description pinned beneath it.
struct DetailSettingRow<Control: View>: View {
    let title: String
    var desc: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            control
            if let desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11.5))
                    .lineSpacing(1)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DetailMetrics.rowHPadding)
        .padding(.vertical, DetailMetrics.rowVPadding)
    }
}

/// Title on the left, control right-aligned at its natural width.
struct DetailInlineLabel<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

// MARK: - Option Cards (radios / checkboxes)

/// Full-width tappable option with an optional secondary line.
struct DetailOptionRow: View {
    let label: String
    var detail: String? = nil
    let isSelected: Bool
    /// Circle for single-select, rounded square for multi-select.
    let isMultiSelect: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                indicator
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundColor(.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, DetailMetrics.rowHPadding)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accent.opacity(0.09) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var indicator: some View {
        if isMultiSelect {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accent : Color.clear)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accent : Color.borderStrong, lineWidth: 1.5)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(isSelected ? 1 : 0)
                )
                .padding(.top, 1)
        } else {
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? Color.accent : Color.borderStrong,
                                  lineWidth: isSelected ? 2 : 1.5)
                    .frame(width: 20, height: 20)
                if isSelected {
                    Circle()
                        .fill(Color.accent)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.top, 1)
        }
    }
}

// MARK: - Controls

/// Muted pill that fronts a Menu.
struct DetailPillLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.textTertiary)
        }
        .foregroundColor(.textPrimary)
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .padding(.vertical, 5)
        .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// −/value/+ control for small integer settings.
struct DetailStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...99

    var body: some View {
        HStack(spacing: 0) {
            button("minus") {
                value = max(range.lowerBound, value - 1)
            }
            Text(String(format: "%.0f", value))
                .font(.system(size: 13, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.textPrimary)
                .frame(width: 34, height: 28)
            button("plus") {
                value = min(range.upperBound, value + 1)
            }
        }
        .background(Color.bgMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accent)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Text field on a muted ground that switches to an accent outline on focus.
struct DetailTextField: View {
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false
    var keyboard: UIKeyboardType = .default
    var footnote: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: $text)
                .font(.system(size: 13.5, design: isMonospaced ? .monospaced : .default))
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: DetailMetrics.controlRadius, style: .continuous)
                        .fill(isFocused ? Color.bgCard : Color.bgMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DetailMetrics.controlRadius, style: .continuous)
                        .strokeBorder(isFocused ? Color.accent : Color.clear, lineWidth: 1.5)
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)

            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundColor(.textTertiary)
            }
        }
    }
}

/// Monospaced multi-line editor — BoxJS textareas are almost always JSON or rules.
struct DetailTextEditor: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 190)
                    .neboxDismissKeyboardOnScroll()
                    .modifier(HideScrollContentBackground())
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: DetailMetrics.controlRadius, style: .continuous)
                            .fill(Color.bgMuted)
                    )
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(.placeholderText))
                        .padding(.top, 15)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Spacer()
                Text("\(text.count) 字符")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.textTertiary)
            }
        }
    }
}

// MARK: - Status Dot

struct DetailStatusDot: View {
    enum State { case ok, warning, danger, idle }

    let state: State
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }

    private var color: Color {
        switch state {
        // No green exists in the asset catalog; `.green` is the only system colour used here
        // and it reads correctly on both the light and dark card grounds.
        case .ok: return .green
        case .warning: return .accentWarning
        case .danger: return .accentRed
        case .idle: return .textTertiary
        }
    }
}

// MARK: - Bottom Action Button

/// Three visual weights, one shape. The save button changes fill, never size.
struct DetailActionButton: View {
    enum Emphasis {
        /// Grey ground — nothing pending.
        case neutral
        /// Accent-tinted ground — has unsaved changes, but ranks below `.primary`.
        case soft
        /// Solid accent — the screen's main action.
        case primary
    }

    let title: String
    let systemImage: String
    let emphasis: Emphasis
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if isBusy {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(foreground)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
            }
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            // Fills the 64pt capsule minus its 6pt inset top and bottom. At 42 the
            // buttons left a thick glass margin and read as flat slots.
            .frame(height: RelayTabBar.barHeight - 12)
            // Capsule, so the buttons echo the glass pane that wraps them.
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isBusy ? 0.85 : 1)
        .disabled(isBusy)
        .animation(.easeOut(duration: 0.18), value: emphasis)
    }

    private var foreground: Color {
        switch emphasis {
        case .neutral: return .textPrimary
        case .soft:    return .accent
        case .primary: return .white
        }
    }

    private var background: Color {
        switch emphasis {
        // Slightly translucent so the glass pane behind still reads through the
        // low-emphasis states; `.primary` stays solid to hold its weight.
        case .neutral: return .bgMuted.opacity(0.75)
        case .soft:    return .accent.opacity(0.16)
        case .primary: return .accent
        }
    }
}

// MARK: - Overflow Toolbar

/// Places the page's overflow menu in the nav bar's trailing slot.
///
/// Shared by both the iOS 26 toolbar path and the legacy `safeAreaInset` path, so the
/// menu sits in the same place on every OS version.
struct AppOverflowToolbar<Menu: View>: ViewModifier {
    let menu: Menu

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                menu
            }
        }
    }
}

// MARK: - Relative Time

enum RelativeTime {
    /// BoxJS stores ISO-8601-ish timestamps; fall back to the raw prefix when parsing fails.
    static func string(from raw: String) -> String {
        guard let date = parse(raw) else {
            return String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
        }

        let seconds = Date().timeIntervalSince(date)
        guard seconds >= 0 else { return "刚刚" }

        switch seconds {
        case ..<60:      return "刚刚"
        case ..<3600:    return "\(Int(seconds / 60)) 分钟前"
        case ..<86400:   return "\(Int(seconds / 3600)) 小时前"
        case ..<604800:  return "\(Int(seconds / 86400)) 天前"
        case ..<2592000: return "\(Int(seconds / 604800)) 周前"
        case ..<31536000: return "\(Int(seconds / 2592000)) 个月前"
        default:         return "\(Int(seconds / 31536000)) 年前"
        }
    }

    /// Full timestamp for the long-press / detail affordance.
    static func absolute(from raw: String) -> String {
        String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let plain: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func parse(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        let normalized = String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
        return plain.date(from: normalized)
    }
}

// MARK: - Value Formatting

enum SettingValue {
    /// Classifies a stored value so data rows can show a type chip.
    static func typeLabel(_ val: AnyCodable?) -> String? {
        guard let value = val?.value else { return nil }
        switch value {
        case is Bool: return "BOOL"
        case is Int, is Double: return "NUM"
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return "JSON" }
            return trimmed.isEmpty ? nil : "TEXT"
        case is [Any], is [String: Any]: return "JSON"
        default: return nil
        }
    }
}
