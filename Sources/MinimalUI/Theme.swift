import SwiftUI
import AppKit

extension Color {
    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    public init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

public enum MNTheme {
    nonisolated(unsafe) public private(set) static var accent = MNColor.defaultAccent
    nonisolated(unsafe) public private(set) static var accentBackground = MNColor.defaultAccentBackground

    public static func configure(accent: Color, accentBackground: Color) {
        Self.accent = accent
        Self.accentBackground = accentBackground
    }
}

public enum MNColor {
    public static let primary = Color(light: 0x000000, dark: 0xFFFFFF)
    public static let defaultAccent = Color(light: 0x005BAC, dark: 0x00AFEC)
    public static let defaultAccentBackground = Color(light: 0xE5F4FC, dark: 0x002A38)
    public static var secondary: Color { MNTheme.accent }

    public static let contents000 = Color(light: 0x000000, dark: 0xFFFFFF)
    public static let contents100 = Color(light: 0x424242, dark: 0xEBEBEB)
    public static let contents150 = Color(light: 0x808080, dark: 0xBDBDBD)
    public static let contents200 = Color(light: 0xBDBDBD, dark: 0x808080)
    public static let contents300 = Color(light: 0xD4D4D4, dark: 0x424242)
    public static let contents999 = Color(light: 0xFFFFFF, dark: 0x000000)

    public static let bg100 = Color(light: 0xFFFFFF, dark: 0x1A1A1A)
    public static let bg200 = Color(light: 0xFAFAFA, dark: 0x000000)
    public static let bg300 = Color(light: 0xF2F2F2, dark: 0x000000)
    public static var bgSecondary: Color { MNTheme.accentBackground }
    public static let bgRoleRed = Color(light: 0xFFF5F5, dark: 0x381515)
    public static let bgRoleYellow = Color(light: 0xFFF7E5, dark: 0x383015)
    public static let bgRoleBlue = Color(light: 0xEDF4FF, dark: 0x002861)
    public static let bgRoleGreen = Color(light: 0xD9FCF2, dark: 0x15382E)
    public static let bgRolePurple = Color(light: 0xF9F5FF, dark: 0x291E3C)

    public static let roleRed = Color(light: 0xED4E4E, dark: 0xD13636)
    public static let roleYellow = Color(light: 0xFDB100, dark: 0xD1AD36)
    public static let roleBlue = Color(light: 0x2679ED, dark: 0x085DD4)
    public static let roleGreen = Color(light: 0x239E7B, dark: 0x21C798)
    public static let rolePurple = Color(light: 0x8133FF, dark: 0xA770FF)
    public static let roleOrange = Color(light: 0xC2410C, dark: 0xFB923C)

    public static let divider = Color(light: 0xD4D4D4, dark: 0x424242)
    public static let dividerLite = Color(light: 0xEBEBEB, dark: 0x2E2E2E)
    public static let bgCode = Color(light: 0xF2F2F2, dark: 0x1A1A1A)
    public static let disabled = Color(light: 0xD4D4D4, dark: 0x808080)

    public static let fixedWhite = Color(hex: 0xFFFFFF)

    public static func identity(for label: String) -> Color {
        let palette = [roleBlue, roleGreen, roleOrange, rolePurple, roleRed]
        let hash = label.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}

public enum MNFont {
    private static func base(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        if NSFont(name: "Pretendard Variable", size: size) != nil {
            return .custom("Pretendard Variable", size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    public static let headline = base(24, .semibold)
    public static let title1 = base(20, .semibold)
    public static let title2 = base(18, .semibold)
    public static let subtitle1 = base(16, .semibold)
    public static let subtitle2 = base(14, .semibold)
    public static let body1 = base(18, .regular)
    public static let body2 = base(16, .regular)
    public static let body3 = base(14, .regular)
    public static let caption1 = base(12, .medium)
    public static let caption2 = base(10, .medium)

    public static let mono = Font.system(size: 13, design: .monospaced)

    public static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let font = NSFont(name: "Pretendard Variable", size: size) ?? .systemFont(ofSize: size)
        return max(0, size * lineHeight - (font.ascender - font.descender + font.leading))
    }
}

public enum MNSpacing {
    public static let s4: CGFloat = 4
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s20: CGFloat = 20
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
}

public enum MNRadius {
    public static let r4: CGFloat = 4
    public static let r6: CGFloat = 6
    public static let r8: CGFloat = 8
    public static let r12: CGFloat = 12
}

private struct MNButtonBody<Background: View>: View {
    let configuration: ButtonStyle.Configuration
    let foreground: Color
    let background: Background
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(MNFont.subtitle2)
            .foregroundStyle(enabled ? foreground : MNColor.disabled)
            .padding(.horizontal, MNSpacing.s16)
            .padding(.vertical, MNSpacing.s8)
            .background(background.opacity(enabled ? 1 : 0.4))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

public struct MNSolidButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        MNButtonBody(configuration: configuration, foreground: MNColor.contents999,
                     background: RoundedRectangle(cornerRadius: MNRadius.r6)
                        .fill(MNColor.primary))
    }
}

public struct MNOutlineButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        MNButtonBody(configuration: configuration, foreground: MNColor.contents100,
                     background: RoundedRectangle(cornerRadius: MNRadius.r6)
                        .stroke(MNColor.divider, lineWidth: 1))
    }
}

public struct MNDangerButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        MNButtonBody(configuration: configuration, foreground: MNColor.roleRed,
                     background: RoundedRectangle(cornerRadius: MNRadius.r6)
                        .stroke(MNColor.roleRed.opacity(0.5), lineWidth: 1))
    }
}

public struct MNCard: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(MNSpacing.s16)
            .background(MNColor.bg100, in: RoundedRectangle(cornerRadius: MNRadius.r8))
            .overlay(
                RoundedRectangle(cornerRadius: MNRadius.r8)
                    .stroke(MNColor.dividerLite, lineWidth: 1))
    }
}

extension View {
    public func rmCard() -> some View {
        modifier(MNCard())
    }
}

public struct MNChip: View {
    let text: String
    var color: Color
    var background: Color
    var icon: String?

    public init(text: String, color: Color = MNColor.contents150,
                background: Color = MNColor.bg300, icon: String? = nil) {
        self.text = text
        self.color = color
        self.background = background
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: MNSpacing.s4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(MNFont.caption1)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, MNSpacing.s8)
        .padding(.vertical, 2)
        .background(background, in: Capsule())
    }
}

public struct MNToggleChip: View {
    let label: String
    let isOn: Bool
    let action: (Bool) -> Void

    public init(label: String, isOn: Bool, action: @escaping (Bool) -> Void) {
        self.label = label
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button { action(!isOn) } label: {
            HStack(spacing: MNSpacing.s4) {
                Image(systemName: isOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(MNFont.caption1)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? MNColor.secondary : MNColor.contents150)
            .padding(.horizontal, MNSpacing.s12)
            .padding(.vertical, MNSpacing.s4)
            .background(isOn ? MNColor.bgSecondary : MNColor.bg300, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "켬" : "끔")
    }
}

public struct MNNoticeBar<Buttons: View>: View {
    public enum Kind {
        case info, error

        var textColor: Color {
            switch self {
            case .info: return MNColor.contents100
            case .error: return MNColor.roleRed
            }
        }
    }

    let kind: Kind
    let message: String
    let buttons: Buttons

    public init(kind: Kind, message: String, @ViewBuilder buttons: () -> Buttons) {
        self.kind = kind
        self.message = message
        self.buttons = buttons()
    }

    public var body: some View {
        HStack(spacing: MNSpacing.s12) {
            Text(message)
                .font(MNFont.body3)
                .foregroundStyle(kind.textColor)
            Spacer()
            buttons
        }
        .padding(MNSpacing.s12)
        .background(MNColor.bg200, in: RoundedRectangle(cornerRadius: MNRadius.r8))
    }
}

public struct MNTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font
    @FocusState private var focused: Bool

    public init(_ placeholder: String = "", text: Binding<String>, font: Font = MNFont.body3) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
    }

    public var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(MNColor.contents000)
            .focused($focused)
            .padding(.horizontal, MNSpacing.s8)
            .padding(.vertical, MNSpacing.s8)
            .background(MNColor.bg100, in: RoundedRectangle(cornerRadius: MNRadius.r4))
            .overlay(
                RoundedRectangle(cornerRadius: MNRadius.r4)
                    .stroke(focused ? MNColor.secondary : MNColor.divider, lineWidth: 1))
    }
}

public struct MNTextEditor: View {
    @Binding var text: String
    var font: Font
    var minHeight: CGFloat
    var maxHeight: CGFloat
    @FocusState private var focused: Bool

    public init(text: Binding<String>, font: Font = MNFont.body3,
                minHeight: CGFloat = 120, maxHeight: CGFloat = 260) {
        self._text = text
        self.font = font
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    public var body: some View {
        TextEditor(text: $text)
            .font(font)
            .foregroundStyle(MNColor.contents000)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(MNSpacing.s4)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(MNColor.bg100, in: RoundedRectangle(cornerRadius: MNRadius.r4))
            .overlay(
                RoundedRectangle(cornerRadius: MNRadius.r4)
                    .stroke(focused ? MNColor.secondary : MNColor.divider, lineWidth: 1))
    }
}

public struct MNFlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = MNSpacing.s4) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                              subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(proposal: proposal,
                                                      subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(proposal: ProposedViewSize,
                         subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: frames.map(\.maxX).max() ?? 0, height: y + rowHeight), frames)
    }
}

public struct MNCollapsibleSection<Content: View>: View {
    let title: String
    var count: Int?
    @State private var expanded: Bool
    let content: () -> Content

    public init(_ title: String, count: Int? = nil, initiallyExpanded: Bool = false,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.count = count
        self._expanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: MNSpacing.s4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(MNColor.contents200)
                    Text(title)
                        .font(MNFont.subtitle2)
                        .foregroundStyle(MNColor.contents100)
                    if let count {
                        Text("\(count)")
                            .font(MNFont.caption1)
                            .foregroundStyle(MNColor.contents200)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public enum MNForm {
    public static let labelWidth: CGFloat = 140
    public static let gutter: CGFloat = MNSpacing.s12
    public static var contentInset: CGFloat { labelWidth + gutter }
}

public struct MNFormSection<Content: View>: View {
    let title: String
    let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s12) {
            Text(title)
                .font(MNFont.subtitle1)
                .foregroundStyle(MNColor.contents000)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rmCard()
    }
}

public struct MNFormRow<Content: View>: View {
    let label: String
    var hint: String?
    var help: String?
    let content: () -> Content

    public init(_ label: String, hint: String? = nil, help: String? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.hint = hint
        self.help = help
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s4) {
            HStack(spacing: MNForm.gutter) {
                Text(label)
                    .font(MNFont.subtitle2)
                    .foregroundStyle(MNColor.contents100)
                    .frame(width: MNForm.labelWidth, alignment: .leading)
                    .accessibilityHint(help ?? "")
                content()
            }
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, MNForm.contentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

public struct MNToggleRow: View {
    let label: String
    var hint: String?
    var help: String?
    @Binding var isOn: Bool

    public init(_ label: String, hint: String? = nil, help: String? = nil,
                isOn: Binding<Bool>) {
        self.label = label
        self.hint = hint
        self.help = help
        self._isOn = isOn
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s4) {
            HStack(spacing: MNForm.gutter) {
                Text(label)
                    .font(MNFont.subtitle2)
                    .foregroundStyle(MNColor.contents100)
                Spacer(minLength: MNForm.gutter)
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(MNColor.secondary)
                    .accessibilityLabel(label)
                    .accessibilityHint(help ?? hint ?? "")
            }
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

public enum MNStatusLevel: Sendable {
    case ready
    case missing
    case unknown
    case problem

    var color: Color {
        switch self {
        case .ready: MNColor.roleGreen
        case .missing: MNColor.roleYellow
        case .unknown: MNColor.contents200
        case .problem: MNColor.roleRed
        }
    }
}

public struct MNStatusRow<Action: View>: View {
    private static var dot: CGFloat { 8 }

    let level: MNStatusLevel
    let label: String
    let status: String
    var detail: String?
    var help: String?
    let action: () -> Action

    public init(_ level: MNStatusLevel, label: String, status: String,
                detail: String? = nil, help: String? = nil,
                @ViewBuilder action: @escaping () -> Action) {
        self.level = level
        self.label = label
        self.status = status
        self.detail = detail
        self.help = help
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MNSpacing.s4) {
            HStack(spacing: MNForm.gutter) {
                Circle()
                    .fill(level.color)
                    .frame(width: Self.dot, height: Self.dot)
                Text(label)
                    .font(MNFont.subtitle2)
                    .foregroundStyle(MNColor.contents100)
                    .frame(width: MNForm.labelWidth - Self.dot - MNForm.gutter,
                           alignment: .leading)
                    .accessibilityHint(help ?? "")
                Text(status)
                    .font(MNFont.caption1)
                    .foregroundStyle(MNColor.contents150)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: MNSpacing.s8)
                action()
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(MNFont.mono)
                    .foregroundStyle(MNColor.contents100)
                    .textSelection(.enabled)
                    .padding(MNSpacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MNColor.bg300,
                                in: RoundedRectangle(cornerRadius: MNRadius.r4))
                    .padding(.leading, MNForm.contentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}

extension MNStatusRow where Action == EmptyView {
    public init(_ level: MNStatusLevel, label: String, status: String,
                detail: String? = nil, help: String? = nil) {
        self.init(level, label: label, status: status,
                  detail: detail, help: help) { EmptyView() }
    }
}
