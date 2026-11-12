import SwiftUI

// MARK: 2 按钮变形

/// 开始生成、导出、创建并开始、修改、开始执行这类耗时按钮。
/// 点下后 0.4 秒弹性收成圆形（宽 = 高），中间转圈（0.8 秒一圈，匀速循环）；`action` 返回 true 后
/// 0.4 秒弹性恢复宽度，0.25 秒变为成功浅底 + 成功色，对勾 0.35 秒描出（晚 0.1 秒开始）；停 1.6 秒后复原。
/// `action` 返回 false（失败、取消）时直接弹回原样。
/// 减弱动态效果：宽度不变，文字直接换成转圈，再直接换成「✓ 已开始」。
struct MorphButton: View {
    let title: String
    var systemImage: String? = nil
    var doneTitle = "已开始"
    var kind: DesignButtonStyle.Kind = .primary
    let action: () async -> Bool

    private enum Phase { case idle, loading, done }

    @State private var phase = Phase.idle
    @State private var succeeded = false
    @State private var idleWidth: CGFloat = 0
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let doneHold: Double = 1.6

    var body: some View {
        let collapsed = phase == .loading && !reduceMotion
        let shape = Radius.shape(collapsed ? Metrics.buttonHeight / 2 : Radius.medium)
        Button(action: start) {
            content
                .font(Typography.bodyStrong.font)
                .lineLimit(1)
                .padding(.horizontal, collapsed ? 0 : Spacing.md)
                .frame(width: width, height: Metrics.buttonHeight)
                .foregroundStyle(foreground)
                .background(background, in: shape)
                .contentShape(shape)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if phase == .idle { idleWidth = width }
                }
        }
        .buttonStyle(MorphPressStyle())
        .opacity(isEnabled ? 1 : Palette.disabledOpacity)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        case .loading:
            Spinner()
        case .done:
            HStack(spacing: Spacing.xs) {
                if reduceMotion { Text("✓") } else { DrawnCheck() }
                Text(doneTitle)
            }
        }
    }

    private var width: CGFloat? {
        switch phase {
        case .idle: nil
        case .loading: reduceMotion ? idleWidth : Metrics.buttonHeight
        case .done: idleWidth
        }
    }

    private var foreground: Swatch {
        if succeeded { return Palette.success }
        switch kind {
        case .primary: return Palette.onColor
        case .secondary: return Palette.text
        case .danger: return Palette.danger
        case .text: return Palette.primary
        }
    }

    private var background: Swatch {
        if succeeded { return Palette.success.tint }
        let hovered = hovering && isEnabled && phase == .idle
        switch kind {
        case .primary: return hovered ? Palette.primaryHover : Palette.primary
        case .secondary: return hovered ? Palette.secondaryHover : Palette.fill
        case .danger: return Palette.danger.tint
        case .text: return hovered ? Palette.primary.tint : Palette.primary.opacity(0)
        }
    }

    private func start() {
        guard phase == .idle else { return }
        animate(Motion.spring) { phase = .loading }
        Task {
            let ok = await action()
            guard ok else {
                animate(Motion.spring) { phase = .idle }
                return
            }
            animate(Motion.spring) { phase = .done }
            animate(Motion.linear(0.25)) { succeeded = true }
            try? await Task.sleep(for: .seconds(Self.doneHold))
            animate(Motion.spring) {
                phase = .idle
                succeeded = false
            }
        }
    }

    private func animate(_ animation: Animation, _ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(animation, change) }
    }
}

/// 变形按钮只要弹性按压，外观由按钮自己画
private struct MorphPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressEffect(configuration.isPressed)
    }
}

/// 转圈：14 的圆环缺一角，0.8 秒一圈匀速循环
struct Spinner: View {
    var size: CGFloat = 14
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
