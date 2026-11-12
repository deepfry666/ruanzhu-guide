import SwiftUI

extension Toast.Kind {
    /// 停留时间：成功和信息 2.5 秒，失败（和警告）5 秒
    var dwell: Double {
        switch self {
        case .success, .info: ToastMotion.shortDwell
        case .warning, .error: ToastMotion.longDwell
        }
    }

    var swatch: Swatch {
        switch self {
        case .success: Palette.success
        case .info: Palette.info
        case .warning: Palette.warning
        case .error: Palette.danger
        }
    }

    var glyph: String {
        switch self {
        case .success: "checkmark"
        case .info: "info"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }
}

/// 窗口底部居中的提示：卡片底 + 分隔线描边 + 浮起阴影，圆角中，内边距 8 / 12；左边 16 的圆形状态色图标。
/// 进出场用「弹出提示」动画（`ToastMotion`）。
struct ToastOverlay: View {
    let toasts: [Toast]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(toasts) { toast in
                ToastView(toast: toast)
                    .transition(ToastMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .padding(.bottom, Spacing.xl)
        .padding(.horizontal, Spacing.xl)
        .frame(maxWidth: 560)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        let shape = Radius.shape(Radius.medium)
        HStack(spacing: Spacing.sm) {
            Image(systemName: toast.kind.glyph)
                .font(.system(size: Metrics.iconSmall, weight: .bold))
                .imageScale(.small)
                .foregroundStyle(Palette.onColor)
                .frame(width: Metrics.icon, height: Metrics.icon)
                .background(toast.kind.swatch, in: Circle())
            Text(toast.text)
                .textStyle(Typography.body)
                .foregroundStyle(Palette.text)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .background(Palette.card, in: shape)
        .overlay(shape.strokeBorder(Palette.divider, lineWidth: Palette.hairline))
        .elevation(.raised, in: shape)
    }
}
