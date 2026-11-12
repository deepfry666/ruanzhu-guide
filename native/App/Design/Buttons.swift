import SwiftUI

/// 规范第 6 节的按钮：高 28，左右内边距 12，圆角中（10），正文加粗；按下用「弹性按压」，禁用为 40% 不透明度。
/// `role: .destructive` 的次要按钮自动显示为危险按钮。
struct DesignButtonStyle: ButtonStyle {
    enum Kind {
        /// 主色底 + 反白文字；悬停换「主色·悬停」。一个区域最多一个
        case primary
        /// 填充底 + 主文字；悬停混入 6% 主文字
        case secondary
        /// 失败色浅底 + 失败色文字。只用在确认框的最后一步
        case danger
        /// 透明底 + 主色文字；悬停加主色浅底，左右内边距 8
        case text
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        DesignButtonBody(kind: configuration.role == .destructive && kind == .secondary ? .danger : kind, configuration: configuration)
    }
}

private struct DesignButtonBody: View {
    let kind: DesignButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private static let clear = Swatch(light: .init(0x000000, alpha: 0), dark: .init(0x000000, alpha: 0))

    var body: some View {
        let shape = Radius.shape(Radius.medium)
        configuration.label
            .font(Typography.bodyStrong.font)
            .lineLimit(1)
            .padding(.horizontal, kind == .text ? Spacing.sm : Spacing.md)
            .frame(minHeight: Metrics.buttonHeight)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : Palette.disabledOpacity)
            .pressEffect(configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private var foreground: Swatch {
        switch kind {
        case .primary: Palette.onColor
        case .secondary: Palette.text
        case .danger: Palette.danger
        case .text: Palette.primary
        }
    }

    private var background: Swatch {
        let hovered = hovering && isEnabled
        switch kind {
        case .primary: return hovered ? Palette.primaryHover : Palette.primary
        case .secondary: return hovered ? Palette.secondaryHover : Palette.fill
        // 悬停时浅底再深 8%（和效果图一致）
        case .danger: return hovered ? Palette.danger.opacity(light: Palette.tintLight + 0.08, dark: Palette.tintDark + 0.08) : Palette.danger.tint
        case .text: return hovered ? Palette.primary.tint : Self.clear
        }
    }
}

extension ButtonStyle where Self == DesignButtonStyle {
    /// 主要按钮：这一块最重要的一个动作
    static var primary: DesignButtonStyle { DesignButtonStyle(kind: .primary) }
    /// 次要按钮：其余动作（全局默认）
    static var secondary: DesignButtonStyle { DesignButtonStyle(kind: .secondary) }
    /// 危险按钮：确认框的最后一步
    static var danger: DesignButtonStyle { DesignButtonStyle(kind: .danger) }
    /// 文字按钮：卡片里的小操作
    static var textAction: DesignButtonStyle { DesignButtonStyle(kind: .text) }
}
